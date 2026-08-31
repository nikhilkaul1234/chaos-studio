# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    The immutable dated study store.

.DESCRIPTION
    A study is a directory. Its state is derived from which files exist, never
    from a status field that could disagree with reality:

        PLANNED    study-plan.v1.json exists, run-record.v1.json does not
        EXECUTED   run-record.v1.json exists, SEALED does not
        SEALED     SEALED exists - the study is read-only forever
        ABANDONED  PLANNED, and older than the abandonment horizon

    Layout under $CHAOS_STUDY_ROOT:

        <scopeHash>/<studyId>/
            manifest.json          identity, pins, hashes  (written at seal)
            study-plan.v1.json     what we intended to test
            approval-preview.v1.json  exact one-time blast-radius/RBAC preview
            run-record.v1.json     what actually happened
            findings.v1.json       what it means
            report.html            the artifact a human reads
            commands.jsonl         append-only command trail
            evidence/{pre,during,post}/*.json
            SEALED                 presence = sealed

    Sealing is ordered so a crash can never produce a study that claims to be
    sealed but is not: render report -> hash every file -> write manifest ->
    create SEALED -> append to index.json. index.json is a rebuildable cache,
    never the source of truth.

    Requires Common.ps1 to be dot-sourced first.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command Get-ChaosSha256 -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

$ChaosStudyManifestVersion = 1
$ChaosStudyAbandonHorizonDays = 7

# -- Root resolution (FR-14) ------------------------------
function Test-ChaosStudyRootSafe {
    <#
    .SYNOPSIS
        Refuse dangerous study roots.

    .DESCRIPTION
        A study root inside a git repo turns evidence into accidental commits.
        A study root under the system temp directory silently loses history on
        reboot. Both are refused. CHAOS_STUDY_ALLOW_TEMP_ROOT=1 lifts only the
        temp restriction, and exists for offline validation.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)

    $probe = $full
    while ($probe) {
        if (Test-Path -LiteralPath (Join-Path $probe '.git')) {
            return [pscustomobject]@{ ok = $false; reason = "Study root '$full' is inside the git repository at '$probe'. Evidence must not live in source control." }
        }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe -or [string]::IsNullOrEmpty($parent)) { break }
        $probe = $parent
    }

    if ($env:CHAOS_STUDY_ALLOW_TEMP_ROOT -ne '1') {
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        if ($full.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ ok = $false; reason = "Study root '$full' is under the system temp directory. Studies would be lost. Set CHAOS_STUDY_ROOT to a durable path, or set CHAOS_STUDY_ALLOW_TEMP_ROOT=1 for a throwaway run." }
        }
    }

    return [pscustomobject]@{ ok = $true; reason = $null }
}

function Get-ChaosStudyRoot {
    <#
    .SYNOPSIS
        Resolve the study root: CHAOS_STUDY_ROOT, then .chaos-plugins.yaml
        studyRoot, then a per-user application-data path.
    #>
    param([string]$WorkspacePath = (Get-Location).Path, [switch]$NoCreate)

    $candidate = $null
    $source = $null

    if ($env:CHAOS_STUDY_ROOT) {
        $candidate = $env:CHAOS_STUDY_ROOT
        $source = 'CHAOS_STUDY_ROOT'
    }

    if (-not $candidate) {
        $configPath = Join-Path $WorkspacePath '.chaos-plugins.yaml'
        if (Test-Path -LiteralPath $configPath) {
            foreach ($line in [System.IO.File]::ReadAllLines($configPath)) {
                if ($line -match '^\s*studyRoot\s*:\s*(.+?)\s*$') {
                    $candidate = $Matches[1].Trim().Trim('"').Trim("'")
                    $source = '.chaos-plugins.yaml'
                    break
                }
            }
        }
    }

    if (-not $candidate) {
        $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($appData)) { $appData = Join-Path $HOME '.local/share' }
        $candidate = Join-Path (Join-Path $appData 'chaos-studio') 'studies'
        $source = 'default'
    }

    $safety = Test-ChaosStudyRootSafe -Path $candidate
    if (-not $safety.ok) { throw $safety.reason }

    $full = [System.IO.Path]::GetFullPath($candidate)
    if (-not $NoCreate -and -not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
    }

    return [pscustomobject]@{ path = $full; source = $source }
}

# -- Identity ---------------------------------------------
function Get-ChaosScopeHash {
    <#
    .SYNOPSIS
        Stable identity for "the same system under test".

    .DESCRIPTION
        Two studies are comparable only if this matches. It deliberately
        excludes anything that changes run to run - times, study ids, which
        scenario or action was chosen, scenario parameters - and includes only
        the identity of the system under test, which in V2 is the workspace and
        the scopes it observes.
    #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [AllowNull()][AllowEmptyCollection()][string[]]$Scope = @(),
        [AllowNull()][AllowEmptyString()][string]$Region
    )
    $identity = [ordered]@{
        subscriptionId = $SubscriptionId.ToLowerInvariant()
        resourceGroup  = $ResourceGroup.ToLowerInvariant()
        workspaceName  = $WorkspaceName.ToLowerInvariant()
        scopes         = @(@($Scope) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
        region         = if ($Region) { $Region.ToLowerInvariant() } else { $null }
    }
    return Get-ChaosDigest -InputObject $identity
}

function New-ChaosStudyId {
    <#
    .SYNOPSIS
        <UTC yyyyMMddTHHmmssZ>-<8 hex>. Sorts chronologically as text, and the
        suffix keeps two studies started in the same second distinct.
    #>
    param([datetime]$Instant = [datetime]::UtcNow)
    $stamp = $Instant.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "$stamp-$suffix"
}

# -- Paths ------------------------------------------------
function Resolve-ChaosStudyPath {
    <#
    .SYNOPSIS
        Resolve a path inside a study directory. This is the only place study
        paths are constructed, so the layout has exactly one definition.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyRoot,
        [Parameter(Mandatory)][string]$ScopeHash,
        [Parameter(Mandatory)][string]$StudyId,
        [ValidateSet('root', 'manifest', 'plan', 'approvalPreview', 'runRecord', 'findings', 'report', 'commands', 'sealed', 'evidencePre', 'evidenceDuring', 'evidencePost')]
        [string]$Artifact = 'root'
    )
    $dir = Join-Path (Join-Path $StudyRoot $ScopeHash) $StudyId
    switch ($Artifact) {
        'root'           { return $dir }
        'manifest'       { return Join-Path $dir 'manifest.json' }
        'plan'           { return Join-Path $dir 'study-plan.v1.json' }
        'approvalPreview' { return Join-Path $dir 'approval-preview.v1.json' }
        'runRecord'      { return Join-Path $dir 'run-record.v1.json' }
        'findings'       { return Join-Path $dir 'findings.v1.json' }
        'report'         { return Join-Path $dir 'report.html' }
        'commands'       { return Join-Path $dir 'commands.jsonl' }
        'sealed'         { return Join-Path $dir 'SEALED' }
        'evidencePre'    { return Join-Path (Join-Path $dir 'evidence') 'pre' }
        'evidenceDuring' { return Join-Path (Join-Path $dir 'evidence') 'during' }
        'evidencePost'   { return Join-Path (Join-Path $dir 'evidence') 'post' }
    }
}

# -- Lifecycle --------------------------------------------
function New-ChaosStudy {
    <#
    .SYNOPSIS
        Create a study directory and return its handle. Creates directories
        only; a study with no plan yet is legitimately empty.
    #>
    param(
        [Parameter(Mandatory)][string]$ScopeHash,
        [string]$StudyRoot,
        [string]$StudyId
    )
    if (-not $StudyRoot) { $StudyRoot = (Get-ChaosStudyRoot).path }
    if (-not $StudyId) { $StudyId = New-ChaosStudyId }

    $dir = Resolve-ChaosStudyPath -StudyRoot $StudyRoot -ScopeHash $ScopeHash -StudyId $StudyId
    foreach ($sub in @('evidence/pre', 'evidence/during', 'evidence/post')) {
        New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force | Out-Null
    }

    return [pscustomobject]@{
        studyId   = $StudyId
        scopeHash = $ScopeHash
        studyRoot = $StudyRoot
        path      = $dir
        createdAt = Get-ChaosUtcNow
        state     = 'PLANNED'
    }
}

function Test-ChaosStudySealed {
    param([Parameter(Mandatory)][string]$StudyPath)
    return (Test-Path -LiteralPath (Join-Path $StudyPath 'SEALED'))
}

function Save-ChaosStudyArtifact {
    <#
    .SYNOPSIS
        Write an artifact into a study, refusing to touch a sealed study.

    .DESCRIPTION
        This is the single write path into the store. It is the only place the
        sealed check lives, so "sealed means immutable" cannot be bypassed by
        a caller that forgot to check. Throws a StudyAlreadySealed-tagged
        error, which callers map to exit code 13.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowNull()][object]$Content,
        [switch]$AsText,
        [switch]$SkipRedaction
    )
    if (Test-ChaosStudySealed -StudyPath $StudyPath) {
        throw "StudyAlreadySealed: '$StudyPath' is sealed and cannot be modified. Start a new study instead."
    }
    $target = Join-Path $StudyPath $RelativePath
    if ($AsText) { return Write-ChaosTextFile -Path $target -Content ([string]$Content) }
    return Write-ChaosJsonFile -Path $target -InputObject $Content -SkipRedaction:$SkipRedaction
}

function Add-ChaosCommandTrailEntry {
    <#
    .SYNOPSIS
        Append one redacted command to commands.jsonl (FR-16).

    .DESCRIPTION
        Append-only and newline-delimited so a crash mid-write loses at most
        the last line, and so the trail can be tailed while a study runs.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$Command,
        [string]$Phase = 'unknown',
        [AllowNull()][object]$Arguments = $null,
        [AllowNull()][object]$ExitCode = $null,
        [AllowNull()][string]$Note = $null
    )
    if (Test-ChaosStudySealed -StudyPath $StudyPath) {
        throw "StudyAlreadySealed: '$StudyPath' is sealed and cannot be modified."
    }
    $entry = [ordered]@{
        at        = Get-ChaosUtcNow
        phase     = $Phase
        command   = Protect-ChaosSecret -Text $Command
        arguments = if ($null -ne $Arguments) { Protect-ChaosObject -InputObject $Arguments } else { $null }
        exitCode  = $ExitCode
        note      = if ($Note) { Protect-ChaosSecret -Text $Note } else { $null }
    }
    $line = ($entry | ConvertTo-Json -Depth 16 -Compress)
    $path = Join-Path $StudyPath 'commands.jsonl'
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Add-Content -LiteralPath $path -Value $line -Encoding utf8
    return $entry
}

function Get-ChaosStudyState {
    <#
    .SYNOPSIS
        Derive state from files on disk. There is no status field to drift.
    #>
    param([Parameter(Mandatory)][string]$StudyPath, [int]$AbandonAfterDays = $ChaosStudyAbandonHorizonDays)
    if (-not (Test-Path -LiteralPath $StudyPath)) { return 'MISSING' }
    if (Test-Path -LiteralPath (Join-Path $StudyPath 'SEALED')) { return 'SEALED' }
    if (Test-Path -LiteralPath (Join-Path $StudyPath 'run-record.v1.json')) { return 'EXECUTED' }
    if (Test-Path -LiteralPath (Join-Path $StudyPath 'study-plan.v1.json')) {
        $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $StudyPath).LastWriteTimeUtc
        if ($age.TotalDays -gt $AbandonAfterDays) { return 'ABANDONED' }
        return 'PLANNED'
    }
    return 'EMPTY'
}

function Get-ChaosStudy {
    <#
    .SYNOPSIS
        Load a study from disk: state, manifest, plan, run record, findings.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [switch]$IncludeArtifacts
    )
    if (-not (Test-Path -LiteralPath $StudyPath)) { return $null }
    $manifest = Read-ChaosJsonFile -Path (Join-Path $StudyPath 'manifest.json')
    $result = [pscustomobject]@{
        path      = $StudyPath
        studyId   = Split-Path -Leaf $StudyPath
        scopeHash = Split-Path -Leaf (Split-Path -Parent $StudyPath)
        state     = Get-ChaosStudyState -StudyPath $StudyPath
        manifest  = $manifest
        plan      = $null
        runRecord = $null
        findings  = $null
        hasReport = (Test-Path -LiteralPath (Join-Path $StudyPath 'report.html'))
    }
    if ($IncludeArtifacts) {
        $result.plan = Read-ChaosJsonFile -Path (Join-Path $StudyPath 'study-plan.v1.json')
        $result.runRecord = Read-ChaosJsonFile -Path (Join-Path $StudyPath 'run-record.v1.json')
        $result.findings = Read-ChaosJsonFile -Path (Join-Path $StudyPath 'findings.v1.json')
    }
    return $result
}

function Get-ChaosStudyFileHashes {
    <#
    .SYNOPSIS
        SHA-256 of every file in a study except manifest.json and SEALED.

    .DESCRIPTION
        Those two are excluded because manifest.json contains the hashes (it
        cannot hash itself) and SEALED is written after the manifest.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)
    $hashes = [ordered]@{}
    $files = Get-ChildItem -LiteralPath $StudyPath -Recurse -File |
        Where-Object { $_.Name -ne 'manifest.json' -and $_.Name -ne 'SEALED' } |
        Sort-Object -Property FullName
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($StudyPath.Length).TrimStart('\', '/').Replace('\', '/')
        $hashes[$relative] = Get-ChaosSha256 -Path $file.FullName
    }
    return $hashes
}

function New-ChaosStudyManifest {
    <#
    .SYNOPSIS
        Build the manifest payload without writing or sealing the study.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][hashtable]$Identity,
        [AllowNull()][object]$Summary = $null,
        [string]$SealedAt = (Get-ChaosUtcNow),
        [switch]$ExcludeReport
    )

    $hashes = Get-ChaosStudyFileHashes -StudyPath $StudyPath
    if ($ExcludeReport -and $hashes.Contains('report.html')) {
        $hashes.Remove('report.html')
    }
    return [ordered]@{
        manifestVersion = $ChaosStudyManifestVersion
        studyId         = Split-Path -Leaf $StudyPath
        scopeHash       = Split-Path -Leaf (Split-Path -Parent $StudyPath)
        sealedAt        = $SealedAt
        identity        = $Identity
        summary         = $Summary
        apiVersions     = if (Get-Command Get-ChaosApiVersionTable -ErrorAction SilentlyContinue) { Get-ChaosApiVersionTable } else { $null }
        files           = $hashes
        contentHash     = Get-ChaosSha256 -Text (ConvertTo-ChaosCanonicalJson -InputObject $hashes)
    }
}

function Complete-ChaosStudy {
    <#
    .SYNOPSIS
        Seal a study: hash contents, write the manifest, create SEALED, index.

    .DESCRIPTION
        Ordered so a crash never yields a study that claims to be sealed but
        whose manifest is missing or stale. The report must already exist -
        sealing a study with no readable artifact would be sealing nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][hashtable]$Identity,
        [AllowNull()][object]$Summary = $null,
        [string]$SealedAt,
        [switch]$AllowMissingReport
    )
    if (Test-ChaosStudySealed -StudyPath $StudyPath) {
        throw "StudyAlreadySealed: '$StudyPath' is already sealed."
    }
    if (-not $AllowMissingReport -and -not (Test-Path -LiteralPath (Join-Path $StudyPath 'report.html'))) {
        throw "Cannot seal '$StudyPath': report.html has not been rendered yet."
    }

    $manifestArgs = @{
        StudyPath = $StudyPath
        Identity  = $Identity
        Summary   = $Summary
    }
    if ($SealedAt) { $manifestArgs['SealedAt'] = $SealedAt }
    $manifest = New-ChaosStudyManifest @manifestArgs

    Write-ChaosJsonFile -Path (Join-Path $StudyPath 'manifest.json') -InputObject $manifest | Out-Null
    Write-ChaosTextFile -Path (Join-Path $StudyPath 'SEALED') -Content ((Get-ChaosUtcNow) + "`n") | Out-Null

    try {
        Add-ChaosStudyIndexEntry -StudyPath $StudyPath -Manifest $manifest | Out-Null
    } catch {
        # The index is a cache. A failure to update it must never invalidate a
        # sealed study - Get-ChaosStudyIndex -Rebuild recovers it from disk.
        Write-ChaosStudyNote "Sealed successfully, but the index could not be updated: $($_.Exception.Message)"
    }

    return $manifest
}

Set-Alias -Name Seal-ChaosStudy -Value Complete-ChaosStudy -Scope Global -ErrorAction SilentlyContinue

# -- Index (a cache, never the source of truth) -----------
function Add-ChaosStudyIndexEntry {
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][AllowNull()][object]$Manifest
    )
    $studyRoot = Split-Path -Parent (Split-Path -Parent $StudyPath)
    $indexPath = Join-Path $studyRoot 'index.json'
    $index = Read-ChaosJsonFile -Path $indexPath
    $entries = @()
    if ($index -and $index.PSObject.Properties.Name -contains 'studies') { $entries = @($index.studies) }

    $studyId = Split-Path -Leaf $StudyPath
    $entries = @($entries | Where-Object { $_.studyId -ne $studyId })
    $entries += [ordered]@{
        studyId   = $studyId
        scopeHash = Split-Path -Leaf (Split-Path -Parent $StudyPath)
        sealedAt  = $Manifest.sealedAt
        identity  = $Manifest.identity
        summary   = $Manifest.summary
    }

    $payload = [ordered]@{
        indexVersion = 1
        updatedAt    = Get-ChaosUtcNow
        studies      = @($entries | Sort-Object -Property studyId -Descending)
    }
    Write-ChaosJsonFile -Path $indexPath -InputObject $payload | Out-Null
    return $payload
}

function Get-ChaosStudyIndex {
    <#
    .SYNOPSIS
        List studies. -Rebuild walks the store and ignores index.json entirely,
        which is the recovery path when the cache is stale or missing.
    #>
    param([string]$StudyRoot, [switch]$Rebuild)
    if (-not $StudyRoot) { $StudyRoot = (Get-ChaosStudyRoot).path }
    if (-not (Test-Path -LiteralPath $StudyRoot)) { return @() }

    if (-not $Rebuild) {
        $index = Read-ChaosJsonFile -Path (Join-Path $StudyRoot 'index.json')
        if ($index -and $index.PSObject.Properties.Name -contains 'studies') { return @($index.studies) }
    }

    $results = @()
    foreach ($scopeDir in (Get-ChildItem -LiteralPath $StudyRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($studyDir in (Get-ChildItem -LiteralPath $scopeDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            $manifest = Read-ChaosJsonFile -Path (Join-Path $studyDir.FullName 'manifest.json')
            $results += [pscustomobject]@{
                studyId   = $studyDir.Name
                scopeHash = $scopeDir.Name
                state     = Get-ChaosStudyState -StudyPath $studyDir.FullName
                sealedAt  = if ($manifest) { $manifest.sealedAt } else { $null }
                identity  = if ($manifest) { $manifest.identity } else { $null }
                summary   = if ($manifest) { $manifest.summary } else { $null }
                path      = $studyDir.FullName
                studyRoot = $StudyRoot
            }
        }
    }
    return @($results | Sort-Object -Property studyId -Descending)
}

function Find-ChaosStudy {
    <#
    .SYNOPSIS
        Resolve a study id (or 'latest') to a path, always rebuilding from disk
        so a stale index can never hide a study.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyId,
        [string]$StudyRoot,
        [string]$ScopeHash
    )
    if (-not $StudyRoot) { $StudyRoot = (Get-ChaosStudyRoot).path }
    $all = Get-ChaosStudyIndex -StudyRoot $StudyRoot -Rebuild
    if ($ScopeHash) { $all = @($all | Where-Object { $_.scopeHash -eq $ScopeHash }) }
    if ($StudyId -eq 'latest') { return ($all | Select-Object -First 1) }
    return ($all | Where-Object { $_.studyId -eq $StudyId } | Select-Object -First 1)
}
