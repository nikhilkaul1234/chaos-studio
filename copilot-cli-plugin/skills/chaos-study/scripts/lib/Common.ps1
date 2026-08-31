# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    Shared primitives for the chaos-study skill suite.

.DESCRIPTION
    Dot-source this file at the TOP LEVEL of a study script:

        . "$PSScriptRoot/lib/Common.ps1"

    Dot-sourcing at top level is required: functions defined inside a function
    scope vanish when that function returns.

    This file owns four things and nothing else:

      1. Locating the plugin root and read-only dot-sourcing the SHIPPED
         plugin scripts (Render.ps1, Invoke-AzChaos.ps1, Invoke-AzRest.ps1,
         Ensure-AzLogin.ps1). The study suite never modifies them.
      2. Deterministic serialisation - canonical JSON and SHA-256 - so a study
         can be hashed, sealed and byte-compared.
      3. Crash-safe writes - temp file plus rename, never a partial artifact.
      4. Redaction, HTML escaping, and the study exit-code contract.

    Nothing here calls Azure. Nothing here has a clock dependency other than
    Get-ChaosUtcNow, which is the single place time enters the suite.
#>

Set-StrictMode -Version Latest

# -- Roots ------------------------------------------------
# $PSScriptRoot is per-file, so this resolves correctly no matter which skill
# dot-sourced us.  lib -> scripts -> chaos-study -> skills -> copilot-cli-plugin
$ChaosStudyLibDir = $PSScriptRoot
$ChaosStudyPluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..'))
$ChaosStudySkillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
$ChaosStudyReferenceRoot = Join-Path $ChaosStudySkillRoot 'references'

function Get-ChaosStudyPluginRoot { return $ChaosStudyPluginRoot }
function Get-ChaosStudyReferenceRoot { return $ChaosStudyReferenceRoot }
function Get-ChaosStudyLibDir { return $ChaosStudyLibDir }

# -- Read-only reuse of the shipped plugin scripts --------
# These are dot-sourced, never edited. If one is missing (a trimmed install),
# the study suite still loads; the callers degrade explicitly rather than
# failing at import time.
$ChaosStudySharedScriptDir = Join-Path $ChaosStudyPluginRoot 'scripts'
$ChaosStudyLoadedSharedScripts = @()
foreach ($sharedName in @('Render.ps1', 'Invoke-AzRest.ps1', 'Invoke-AzChaos.ps1', 'Ensure-AzLogin.ps1')) {
    $sharedPath = Join-Path $ChaosStudySharedScriptDir $sharedName
    if (Test-Path -LiteralPath $sharedPath) {
        try {
            . $sharedPath
            $ChaosStudyLoadedSharedScripts += $sharedName
        } catch {
            [Console]::Error.WriteLine("[chaos-study] WARNING: could not load shared script '$sharedName': $($_.Exception.Message)")
        }
    }
}

function Get-ChaosSharedScriptStatus {
    <#
    .SYNOPSIS
        Which shipped plugin scripts were available at load time.
    #>
    return [pscustomobject]@{
        directory = $ChaosStudySharedScriptDir
        loaded    = @($ChaosStudyLoadedSharedScripts | Sort-Object)
    }
}

# -- Exit-code contract (additive; the shipped skills own 0-4) --
$ChaosStudyExit = @{
    Success                    = 0
    Error                      = 1
    BroadFixUnconsented        = 4
    ReadinessFailed            = 10
    ConsentDeclined            = 11
    ConfigurationDrift         = 12
    StudyAlreadySealed         = 13
    ScopeUnverified            = 14
    StudyIncomparable          = 15
    ActionDiscoveryUnavailable = 16
    ValidationFailed           = 17
}

function Get-ChaosStudyExitCode {
    <#
    .SYNOPSIS
        Resolve a named study exit code. Fails loudly on an unknown name so a
        typo can never silently become exit 0.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if (-not $ChaosStudyExit.ContainsKey($Name)) {
        throw "Unknown study exit code '$Name'. Known: $(($ChaosStudyExit.Keys | Sort-Object) -join ', ')"
    }
    return $ChaosStudyExit[$Name]
}

# -- Output helpers ---------------------------------------
function Write-ChaosStudyNote {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info', 'warn')][string]$Level = 'info'
    )
    $prefix = if ($Level -eq 'warn') { '[chaos-study] WARNING:' } else { '[chaos-study]' }
    [Console]::Error.WriteLine("$prefix $Message")
}

function Write-ChaosStudyCard {
    <#
    .SYNOPSIS
        Present a block of operator-facing output, using the host's card
        renderer when one is available and plain markdown when it is not.

    .DESCRIPTION
        Every skill in this suite reports the same way, so the fallback lives
        here rather than being re-implemented at each call site where it can
        drift.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    if (Get-Command Write-Card -ErrorAction SilentlyContinue) {
        Write-Card -Title $Title -Body $Body
    } else {
        Write-Output "## $Title"
        Write-Output ''
        Write-Output $Body
    }
}

function Write-ChaosStudyFailure {
    <#
    .SYNOPSIS
        Loud, structured failure. Never swallow - this is the only sanctioned
        way for a study script to report that it could not do its job.

    .DESCRIPTION
        The card is written to the host stream rather than the success stream.
        That distinction matters: assertion helpers are routinely called as
        `Assert-Something ... | Out-Null` to discard their boolean result, and a
        card written with Write-Output would be discarded along with it - the
        operator would see a bare exit code and no explanation. Rendering through
        Write-Host makes the failure unsuppressible by a caller's pipeline, which
        is what "never swallow" has to mean in practice.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [string]$Remediation
    )
    $lines = @(
        if (Get-Command Write-Error-Card -ErrorAction SilentlyContinue) {
            Write-Error-Card -Title $Title -ErrorMessage $Message -RemediationCommand $Remediation
        } else {
            "## ERROR: $Title"
            ''
            $Message
            if ($Remediation) {
                ''
                "Remediation: $Remediation"
            }
        }
    )
    foreach ($line in $lines) { Write-Host $line }
}

# -- List normalisation -----------------------------------
function ConvertTo-ChaosList {
    <#
    .SYNOPSIS
        Normalise a library result into a flat, null-free array.

    .DESCRIPTION
        The list-returning functions in this suite end with ",@(...)" so that a
        single-element result is not silently unwrapped into a scalar. That
        idiom has one sharp edge: an *empty* result arrives as one pipeline
        object that is itself an empty array, so the usual "@(...)" at the call
        site produces @(@()) - a one-element list whose only member has no
        properties at all.

        Every downstream projection then throws under Set-StrictMode, which
        turns a perfectly legitimate empty result - an exclusion that filtered
        everything out, a region that offers no matching action - into a crash
        instead of the clean, explained failure this suite promises. Callers use
        this so "none" reads as an empty list rather than an exception.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return , @() }

    $flat = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) { continue }
        if ($item -is [array] -or ($item -is [System.Collections.IList] -and $item -isnot [string])) {
            foreach ($inner in $item) { if ($null -ne $inner) { $flat.Add($inner) } }
        }
        else {
            $flat.Add($item)
        }
    }

    return , @($flat.ToArray())
}

# -- Time -------------------------------------------------
function Get-ChaosUtcNow {
    <#
    .SYNOPSIS
        The single clock in the suite. ISO-8601, UTC, 'Z' suffix (NFR-2).
    #>
    param([datetime]$Instant = [datetime]::UtcNow)
    return $Instant.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertTo-ChaosUtcIso {
    param([Parameter(Mandatory)][datetime]$Instant)
    return $Instant.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertFrom-ChaosUtcIso {
    param([Parameter(Mandatory)][string]$Text)
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    return [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
}

function New-ChaosWindow {
    <#
    .SYNOPSIS
        A half-open [start, end) window (NFR-2). There is no other window shape
        in this suite.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][datetime]$End
    )
    if ($End -le $Start) { throw "Window '$Name' is not forward-ordered: start=$Start end=$End" }
    return [pscustomobject]@{
        name            = $Name
        startUtc        = ConvertTo-ChaosUtcIso -Instant $Start
        endUtc          = ConvertTo-ChaosUtcIso -Instant $End
        durationSeconds = [int][math]::Round(($End - $Start).TotalSeconds)
        interval        = 'half-open [start, end)'
    }
}

# -- Redaction (NFR-5) ------------------------------------
$ChaosStudyRedactKeyPattern = '(?i)(password|passwd|secret|token|apikey|api_key|accountkey|primarykey|secondarykey|connectionstring|sharedaccess|sas|credential|authorization|bearer|clientsecret|certificate|thumbprint|private_key|privatekey)'
$ChaosStudyRedactValuePatterns = @(
    '(?i)\bBearer\s+[A-Za-z0-9\-\._~\+\/]+=*',
    '(?i)\bey[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}',
    '(?i)(AccountKey|SharedAccessSignature|sig)=[^;&\s"]+'
)

function Protect-ChaosSecret {
    <#
    .SYNOPSIS
        Redact secret-shaped values from a string. Applied to every command
        trail entry and every value that reaches an artifact or the report.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    foreach ($pattern in $ChaosStudyRedactValuePatterns) {
        $result = [regex]::Replace($result, $pattern, '[REDACTED]')
    }
    return $result
}

function Protect-ChaosObject {
    <#
    .SYNOPSIS
        Recursively redact an object by key name and by value shape.
    #>
    param([AllowNull()][object]$InputObject, [int]$Depth = 0)
    if ($Depth -gt 32) { return '[TRUNCATED]' }
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string]) { return Protect-ChaosSecret -Text $InputObject }
    if ($InputObject -is [bool] -or $InputObject -is [int] -or $InputObject -is [long] -or
        $InputObject -is [double] -or $InputObject -is [decimal] -or $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            if ("$key" -match $ChaosStudyRedactKeyPattern) { $out["$key"] = '[REDACTED]' }
            else { $out["$key"] = Protect-ChaosObject -InputObject $InputObject[$key] -Depth ($Depth + 1) }
        }
        return $out
    }

    if ($InputObject -is [pscustomobject]) {
        $out = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            if ($prop.Name -match $ChaosStudyRedactKeyPattern) { $out[$prop.Name] = '[REDACTED]' }
            else { $out[$prop.Name] = Protect-ChaosObject -InputObject $prop.Value -Depth ($Depth + 1) }
        }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        # The leading comma stops PowerShell unrolling the result, which would
        # otherwise turn a one-element array into a scalar and an empty array
        # into $null - both of which change the JSON shape.
        return ,@(foreach ($item in $InputObject) { Protect-ChaosObject -InputObject $item -Depth ($Depth + 1) })
    }

    return Protect-ChaosSecret -Text ([string]$InputObject)
}

# -- Deterministic serialisation (FR-17, NFR-6) -----------
function ConvertTo-ChaosCanonical {
    <#
    .SYNOPSIS
        Recursively rewrite an object with keys in ordinal-sorted order so that
        two logically identical objects serialise byte-identically.
    #>
    param([AllowNull()][object]$InputObject, [int]$Depth = 0)
    if ($Depth -gt 32) { return '[TRUNCATED]' }
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or
        $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal]) {
        return $InputObject
    }

    if ($InputObject -is [datetime]) { return ConvertTo-ChaosUtcIso -Instant $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in (@($InputObject.Keys) | Sort-Object -CaseSensitive)) {
            $out["$key"] = ConvertTo-ChaosCanonical -InputObject $InputObject[$key] -Depth ($Depth + 1)
        }
        return $out
    }

    if ($InputObject -is [pscustomobject]) {
        $out = [ordered]@{}
        foreach ($prop in ($InputObject.PSObject.Properties | Sort-Object -Property Name -CaseSensitive)) {
            $out[$prop.Name] = ConvertTo-ChaosCanonical -InputObject $prop.Value -Depth ($Depth + 1)
        }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        # See Protect-ChaosObject: the leading comma preserves array-ness.
        return ,@(foreach ($item in $InputObject) { ConvertTo-ChaosCanonical -InputObject $item -Depth ($Depth + 1) })
    }

    return [string]$InputObject
}

function ConvertTo-ChaosCanonicalJson {
    <#
    .SYNOPSIS
        Canonical, compact JSON. The input to every hash in this suite.
    #>
    param([AllowNull()][object]$InputObject)
    $canonical = ConvertTo-ChaosCanonical -InputObject $InputObject
    return (ConvertTo-Json -InputObject $canonical -Depth 32 -Compress)
}

function Get-ChaosSha256 {
    <#
    .SYNOPSIS
        Lowercase hex SHA-256 over a string or a file.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(ParameterSetName = 'Text', Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(ParameterSetName = 'File', Mandatory)][string]$Path
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$bytes = if ($PSCmdlet.ParameterSetName -eq 'File') {
            [System.IO.File]::ReadAllBytes($Path)
        } else {
            [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
        }
        return -join ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

function Get-ChaosDigest {
    <#
    .SYNOPSIS
        Short (16 hex) digest of an object's canonical form. Used for
        queryDigest, frozenConfigHash and findingKey.
    #>
    param([AllowNull()][object]$InputObject)
    return (Get-ChaosSha256 -Text (ConvertTo-ChaosCanonicalJson -InputObject $InputObject)).Substring(0, 16)
}

# -- Crash-safe file writes (NFR-6) -----------------------
function Write-ChaosTextFile {
    <#
    .SYNOPSIS
        Atomic write: temp file in the same directory, flushed, then renamed
        over the target. A crash leaves either the old file or the new one,
        never half of either.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temp = Join-Path $directory ('.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $stream = [System.IO.File]::Create($temp)
    try {
        $bytes = $encoding.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    [System.IO.File]::Move($temp, $Path, $true)
    return $Path
}

function Write-ChaosJsonFile {
    <#
    .SYNOPSIS
        Atomically write an object as pretty, canonically-ordered, redacted JSON.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [switch]$SkipRedaction
    )
    $payload = if ($SkipRedaction) { $InputObject } else { Protect-ChaosObject -InputObject $InputObject }
    $canonical = ConvertTo-ChaosCanonical -InputObject $payload
    $json = ($canonical | ConvertTo-Json -Depth 32)
    return Write-ChaosTextFile -Path $Path -Content ($json + "`n")
}

function Read-ChaosJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

# -- Evidence shape (NFR-3) -------------------------------
function New-ChaosSignalResult {
    <#
    .SYNOPSIS
        The one shape every signal collector returns.

    .DESCRIPTION
        A missing measurement is `values: $null` plus a caveat. A reported 0
        must be a measured zero. Conflating the two is a contract violation,
        so this helper refuses to build a null result that does not say why.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Window,
        [AllowNull()][object]$Values = $null,
        [AllowNull()][AllowEmptyString()][string]$Caveat = $null,
        [AllowNull()][object]$Query = $null
    )
    if ($null -eq $Values -and [string]::IsNullOrWhiteSpace($Caveat)) {
        throw "New-ChaosSignalResult: a null result for source '$Source' must carry a caveat explaining why."
    }
    return [pscustomobject]@{
        source      = $Source
        window      = $Window
        requestedAt = Get-ChaosUtcNow
        values      = $Values
        caveat      = if ([string]::IsNullOrWhiteSpace($Caveat)) { $null } else { $Caveat }
        queryDigest = if ($null -ne $Query) { Get-ChaosDigest -InputObject $Query } else { $null }
    }
}

function Get-ChaosSignalValueMap {
    <#
    .SYNOPSIS
        Reduce a signal's measurements to a flat name -> value map.

    .DESCRIPTION
        Collectors report in whichever shape their source speaks. A metric query
        returns a time series; a log query returns a single row of named
        columns. Everything downstream - the predicate, the movement check, the
        evidence table - needs one shape, and it needs it to be derived rather
        than re-measured, so this is the only place the two are reconciled.

        A series is summarised into first/last/min/max/mean/count. Those names
        are then directly comparable across windows, which is what makes
        "did this number move?" answerable without knowing what the number is.

        A signal that was never measured yields an empty map, never zeros.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$Signal)

    $map = [ordered]@{}
    if (-not $Signal -or $null -eq $Signal.values) { return $map }
    $values = $Signal.values

    if ($values -is [System.Collections.IDictionary]) {
        foreach ($key in @($values.Keys)) {
            if ($key -eq 'sampledAt') { continue }
            $map[[string]$key] = $values[$key]
        }
        return $map
    }

    $isSeries = ($values -is [System.Collections.IEnumerable]) -and ($values -isnot [string])
    if (-not $isSeries) {
        foreach ($property in @($values.PSObject.Properties)) {
            if ($property.Name -eq 'sampledAt') { continue }
            $map[$property.Name] = $property.Value
        }
        return $map
    }

    $numbers = [System.Collections.Generic.List[double]]::new()
    foreach ($point in @($values)) {
        if ($null -eq $point) { continue }
        $raw = $point
        if ($point -is [System.Collections.IDictionary] -and $point.Contains('value')) {
            $raw = $point['value']
        } elseif ($point -isnot [string] -and $point.PSObject.Properties.Name -contains 'value') {
            $raw = $point.value
        }
        if ($null -eq $raw) { continue }
        $parsed = 0.0
        if ([double]::TryParse([string]$raw, [ref]$parsed)) { [void]$numbers.Add($parsed) }
    }

    if ($numbers.Count -eq 0) { return $map }

    $map['first'] = $numbers[0]
    $map['last'] = $numbers[$numbers.Count - 1]
    $map['min'] = ($numbers | Measure-Object -Minimum).Minimum
    $map['max'] = ($numbers | Measure-Object -Maximum).Maximum
    $map['mean'] = [math]::Round((($numbers | Measure-Object -Average).Average), 4)
    $map['count'] = $numbers.Count
    return $map
}

function Test-ChaosPredicate {
    <#
    .SYNOPSIS
        Evaluate a frozen steady-state predicate against one measurement.

    .OUTPUTS
        $true held, $false breached, $null not measurable.
    #>
    param(
        [Parameter(Mandatory)][object]$Predicate,
        [AllowNull()][object]$Value
    )
    if ($null -eq $Value) { return $null }
    $threshold = [double]$Predicate.threshold
    $actual = [double]$Value
    switch ([string]$Predicate.comparison) {
        '>=' { return $actual -ge $threshold }
        '>'  { return $actual -gt $threshold }
        '<=' { return $actual -le $threshold }
        '<'  { return $actual -lt $threshold }
        '==' { return $actual -eq $threshold }
        '!=' { return $actual -ne $threshold }
        default { return $null }
    }
}

# -- HTML escaping (NFR-8) --------------------------------
function ConvertTo-ChaosHtmlText {
    <#
    .SYNOPSIS
        Escape a value for HTML text content. Every value drawn from Azure or
        from the model passes through here before it reaches the report.

    .NOTES
        CmdletBinding is deliberate. Without it this is a simple function, and
        PowerShell silently routes an unrecognised named argument into $args
        instead of failing - which renders every escaped value as an empty
        string and produces a structurally valid but entirely blank report.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][object]$Text)
    if ($null -eq $Text) { return '' }
    $value = if ($Text -is [string]) { $Text } else { [string]$Text }
    return $value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}
