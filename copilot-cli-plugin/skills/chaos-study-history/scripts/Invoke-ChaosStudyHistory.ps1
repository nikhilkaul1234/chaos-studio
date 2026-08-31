#Requires -Version 7.0
<#
.SYNOPSIS
    List, inspect, compare and rerun past studies.

.DESCRIPTION
    A single chaos study is an anecdote. The value comes from the series - the
    same question asked of the same workspace scope over time, so a change in
    the answer means something changed in the system.

    This skill never mutates a sealed study. `-Action rerun` prints the plan
    needed to repeat one; it does not inject anything itself, because rerunning
    is an execution decision and execution requires consent from the run skill.

.EXAMPLE
    ./Invoke-ChaosStudyHistory.ps1
    Lists every sealed study, newest first.

.EXAMPLE
    ./Invoke-ChaosStudyHistory.ps1 -Action compare -StudyId latest -Against previous
    Diffs the two most recent studies of the same scope.
#>

[CmdletBinding()]
param(
    [ValidateSet('list', 'show', 'compare', 'rerun')]
    [string]$Action = 'list',
    [string]$StudyId = 'latest',
    [string]$Against = 'previous',
    [string]$ScopeHash,
    [string]$StudyRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedLib = Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib'
. (Join-Path $sharedLib 'Common.ps1')
. (Join-Path $sharedLib 'Study.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Compare.ps1')

function Get-StudyFindings {
    param([Parameter(Mandatory)][object]$Entry)
    $path = Join-Path $Entry.path 'findings.v1.json'
    $findings = Read-ChaosJsonFile -Path $path
    if (-not $findings) { return ,@() }
    # A study with no findings round-trips as $null through @(); filter it out so
    # callers always get a clean array rather than an array containing nothing.
    return ,@(@($findings.findings) | Where-Object { $null -ne $_ })
}

function Resolve-Entry {
    <#
    .SYNOPSIS
        Resolve 'latest', 'previous' or an explicit id against the index.
    #>
    param([Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pool)
    $ordered = @($Pool | Sort-Object -Property studyId -Descending)
    switch ($Reference) {
        'latest'   { return ($ordered | Select-Object -First 1) }
        'previous' { return ($ordered | Select-Object -Skip 1 -First 1) }
        default    { return ($ordered | Where-Object { $_.studyId -eq $Reference } | Select-Object -First 1) }
    }
}

function ConvertTo-ChaosPowerShellLiteral {
    <#
    .SYNOPSIS
        Render a frozen value as a safe PowerShell literal for rerun output.
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '$null' }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @(
            foreach ($key in @($Value.Keys | Sort-Object)) {
                "$(ConvertTo-ChaosPowerShellLiteral -Value ([string]$key)) = $(ConvertTo-ChaosPowerShellLiteral -Value $Value[$key])"
            }
        )
        return '@{' + ($pairs -join '; ') + '}'
    }
    if ($Value -is [pscustomobject]) {
        $pairs = @(
            foreach ($property in @($Value.PSObject.Properties | Sort-Object -Property Name)) {
                "$(ConvertTo-ChaosPowerShellLiteral -Value $property.Name) = $(ConvertTo-ChaosPowerShellLiteral -Value $property.Value)"
            }
        )
        return '@{' + ($pairs -join '; ') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-ChaosPowerShellLiteral -Value $_ })
        return '@(' + ($items -join ', ') + ')'
    }
    if ($Value -is [System.IFormattable]) {
        return $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ConvertTo-ChaosPowerShellLiteral -Value ([string]$Value)
}

function ConvertTo-ChaosTagTable {
    <#
    .SYNOPSIS
        Restore the authoring hashtable from persisted {key,value} tag pairs.
    #>
    param([AllowNull()][object[]]$Tags)

    [hashtable]$table = @{}
    foreach ($pair in @($Tags)) {
        if ($null -eq $pair) { continue }
        $key = if ($pair -is [System.Collections.IDictionary]) { [string]$pair['key'] } else { [string]$pair.key }
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $table[$key] = if ($pair -is [System.Collections.IDictionary]) { $pair['value'] } else { $pair.value }
    }
    return $table
}

if ($MyInvocation.InvocationName -eq '.') { return }

$indexArgs = @{}
if ($StudyRoot) { $indexArgs['StudyRoot'] = $StudyRoot }
$index = @(Get-ChaosStudyIndex @indexArgs -Rebuild)

if ($ScopeHash) { $index = @($index | Where-Object { $_.scopeHash -eq $ScopeHash }) }

if ($index.Count -eq 0) {
    Write-Card -Title 'No studies yet' -Status 'info' -Body @"
No studies were found under the study root. History becomes useful after the
first sealed study - run the chaos-study skill to create one.
"@
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

switch ($Action) {

    'list' {
        $rows = foreach ($entry in ($index | Sort-Object -Property studyId -Descending)) {
            [pscustomobject]@{
                Study     = $entry.studyId
                State     = $entry.state
                Workspace = $(if ($entry.identity) { [string]$entry.identity.workspace } else { '-' })
                Action    = $(if ($entry.identity) { [string]$entry.identity.action } else { '-' })
                Verdict   = $(if ($entry.summary) { [string]$entry.summary.verdict } else { '-' })
                Findings  = $(if ($entry.summary) { $entry.summary.findingCount } else { '-' })
                Scope     = $entry.scopeHash
            }
        }
        if ($Json) { $rows | ConvertTo-Json -Depth 6; exit (Get-ChaosStudyExitCode -Name 'Success') }
        Write-Table -Title "Studies ($($index.Count))" -Data @($rows)
        $scopes = @($index | Group-Object scopeHash)
        Write-ChaosStudyNote -Message "$($scopes.Count) distinct scope(s). Compare within a scope: -Action compare -ScopeHash <hash>."
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    'show' {
        $entry = Resolve-Entry -Reference $StudyId -Pool $index
        if (-not $entry) {
            Write-ChaosStudyFailure -Title 'Study not found' -Message "No study matched '$StudyId'." -Remediation 'Run this skill with -Action list to see available studies.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        $findings = Get-StudyFindings -Entry $entry
        if ($Json) {
            [ordered]@{ study = $entry; findings = @($findings) } | ConvertTo-Json -Depth 8
            exit (Get-ChaosStudyExitCode -Name 'Success')
        }
        # The URN is the precise identity, but a discovery-skipped study never
        # learned one. Show the name rather than an empty row.
        $shownAction = '-'
        if ($entry.identity) {
            $shownAction = if ([string]::IsNullOrWhiteSpace($entry.identity.actionUrn)) { [string]$entry.identity.action } else { [string]$entry.identity.actionUrn }
            if ([string]::IsNullOrWhiteSpace($shownAction)) { $shownAction = '-' }
        }
        Write-Card -Title "Study $($entry.studyId)" -Status 'info' -Body @"
$(if ($entry.summary) { [string]$entry.summary.verdict } else { 'Not yet reported.' })
"@ -Properties ([ordered]@{
            'State'     = $entry.state
            'Sealed'    = $entry.sealedAt
            'Workspace' = $(if ($entry.identity) { [string]$entry.identity.workspace } else { '-' })
            'Scenario'  = $(if ($entry.identity) { [string]$entry.identity.scenario } else { '-' })
            'Action'    = $shownAction
            'Predicate' = $(if ($entry.identity) { [string]$entry.identity.predicate } else { '-' })
            'Report'    = (Join-Path $entry.path 'report.html')
        })
        if (@($findings).Count -gt 0) {
            Write-Table -Title 'Findings' -Data @($findings | ForEach-Object {
                [pscustomobject]@{ Severity = $_.severity; Confidence = $_.confidence; Finding = $_.title }
            })
        }
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    'compare' {
        $sealed = @($index | Where-Object { $_.state -eq 'SEALED' })
        $candidate = Resolve-Entry -Reference $StudyId -Pool $sealed
        if (-not $candidate) {
            Write-ChaosStudyFailure -Title 'Nothing to compare' -Message "No sealed study matched '$StudyId'." -Remediation 'Seal a study by running the chaos-study-report skill.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        # Restrict the pool to the same scope before picking 'previous', otherwise
        # 'previous' would happily select an unrelated study.
        $pool = @($sealed | Where-Object { $_.scopeHash -eq $candidate.scopeHash -and $_.studyId -ne $candidate.studyId })
        $baseline = Resolve-Entry -Reference $(if ($Against -eq 'previous') { 'latest' } else { $Against }) -Pool $pool

        if (-not $baseline) {
            Write-Card -Title 'Only one study in this scope' -Status 'info' -Body @"
Study $($candidate.studyId) is the only sealed study for scope $($candidate.scopeHash).
A comparison needs two. Run the same study again later and compare then - that
series is where the value is.
"@
            exit (Get-ChaosStudyExitCode -Name 'Success')
        }

        $baseline | Add-Member -NotePropertyName findings -NotePropertyValue (Get-StudyFindings -Entry $baseline) -Force
        $candidate | Add-Member -NotePropertyName findings -NotePropertyValue (Get-StudyFindings -Entry $candidate) -Force

        $comparison = Compare-Study -Baseline $baseline -Candidate $candidate

        if ($Json) { $comparison | ConvertTo-Json -Depth 8; exit $(if ($comparison.comparable) { 0 } else { Get-ChaosStudyExitCode -Name 'StudyIncomparable' }) }

        if (-not $comparison.comparable) {
            Write-ChaosStudyFailure -Title 'These studies are not comparable' -Message @"
$($baseline.studyId) and $($candidate.studyId) did not ask the same question, so
any difference between them would be noise dressed as a signal.

$(@($comparison.reasons | ForEach-Object { "  - $_" }) -join "`n")
"@ -Remediation 'Compare studies that share a scope, a workspace, a scenario, an action, a steady-state objective and comparable window lengths.'
            exit (Get-ChaosStudyExitCode -Name 'StudyIncomparable')
        }

        $status = switch ($comparison.direction) {
            'improved'  { 'success' }
            'regressed' { 'error' }
            'stable'    { 'info' }
            default     { 'warning' }
        }
        Write-Card -Title "Comparison: $($comparison.direction)" -Status $status -Body @"
$($baseline.studyId) ($($comparison.baseline.verdict))
  -> $($candidate.studyId) ($($comparison.candidate.verdict))
"@ -Properties ([ordered]@{
            'Verdict changed' = $comparison.verdictChanged
            'Introduced'      = @($comparison.introduced).Count
            'Resolved'        = @($comparison.resolved).Count
            'Persisted'       = @($comparison.persisted).Count
        })

        foreach ($group in @(
            @{ label = 'Introduced'; items = $comparison.introduced }
            @{ label = 'Resolved'; items = $comparison.resolved }
        )) {
            if (@($group.items).Count -gt 0) {
                Write-Table -Title $group.label -Data @($group.items | ForEach-Object {
                    [pscustomobject]@{ Severity = $_.severity; Finding = $_.title }
                })
            }
        }
        if (@($comparison.persisted).Count -gt 0) {
            Write-Table -Title 'Persisted' -Data @($comparison.persisted | ForEach-Object {
                [pscustomobject]@{ Movement = $_.movement; Was = $_.wasSeverity; Now = $_.nowSeverity; Finding = $_.title }
            })
        }
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    'rerun' {
        $entry = Resolve-Entry -Reference $StudyId -Pool $index
        if (-not $entry) {
            Write-ChaosStudyFailure -Title 'Study not found' -Message "No study matched '$StudyId'." -Remediation 'Run this skill with -Action list to see available studies.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        $plan = Read-ChaosJsonFile -Path (Join-Path $entry.path 'study-plan.v1.json')
        if (-not $plan) {
            Write-ChaosStudyFailure -Title 'Study has no plan' -Message "Study $($entry.studyId) has no study-plan.v1.json to repeat." -Remediation 'Plan a fresh study with the chaos-study-scope skill.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        $scope = Join-Path $PSScriptRoot '..' '..' 'chaos-study-scope' 'scripts' 'Invoke-ChaosStudyScope.ps1'
        # The workspace already exists (this study ran against it), so the rerun
        # command deliberately omits -CreateWorkspace: reruns observe, they do not
        # provision. The scope is re-discovered live, so a resource that has since
        # left the workspace is not silently carried forward from the old plan.
        $regionLine = if ($plan.scope.region) { "`n    -Location $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$plan.scope.region)) ``" } else { '' }
        # -Action accepts a URN or a name. Prefer the URN because it is exact, but
        # a discovery-skipped plan never learned one, and emitting -Action '' would
        # hand the operator a command that cannot run.
        $actionRef = if ([string]::IsNullOrWhiteSpace($plan.action.canonicalId)) { [string]$plan.action.name } else { [string]$plan.action.canonicalId }
        $sourceLines = @($plan.signals.configuredSources | Where-Object { $_ } | ForEach-Object {
                "    -SignalSource $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$_)) ``"
            })
        $parameterTable = [ordered]@{}
        foreach ($pair in @($plan.scenario.parameters)) {
            if ($null -ne $pair -and -not [string]::IsNullOrWhiteSpace([string]$pair.key)) {
                $parameterTable[[string]$pair.key] = $pair.value
            }
        }
        $replayLines = @()
        if ($parameterTable.Count -gt 0) {
            $replayLines += "    -Parameters $(ConvertTo-ChaosPowerShellLiteral -Value $parameterTable) ``"
        }
        $filters = $plan.scope.blastRadius.filters
        if ($null -ne $filters) {
            if ($filters.PSObject.Properties.Name -contains 'locations' -and @($filters.locations).Count -gt 0) {
                $replayLines += "    -FilterLocation $(ConvertTo-ChaosPowerShellLiteral -Value @($filters.locations)) ``"
            }
            if ($filters.PSObject.Properties.Name -contains 'zones' -and @($filters.zones).Count -gt 0) {
                $replayLines += "    -FilterZone $(ConvertTo-ChaosPowerShellLiteral -Value @($filters.zones)) ``"
            }
            if ($filters.PSObject.Properties.Name -contains 'physicalZones' -and @($filters.physicalZones).Count -gt 0) {
                $replayLines += "    -FilterPhysicalZone $(ConvertTo-ChaosPowerShellLiteral -Value ([string](@($filters.physicalZones)[0]))) ``"
            }
        }
        $exclusions = $plan.scope.blastRadius.exclusions
        if ($null -ne $exclusions) {
            if ($exclusions.PSObject.Properties.Name -contains 'resources' -and @($exclusions.resources).Count -gt 0) {
                $replayLines += "    -ExcludeResource $(ConvertTo-ChaosPowerShellLiteral -Value @($exclusions.resources)) ``"
            }
            if ($exclusions.PSObject.Properties.Name -contains 'types' -and @($exclusions.types).Count -gt 0) {
                $replayLines += "    -ExcludeType $(ConvertTo-ChaosPowerShellLiteral -Value @($exclusions.types)) ``"
            }
            if ($exclusions.PSObject.Properties.Name -contains 'tags' -and $null -ne $exclusions.tags) {
                $tagTable = ConvertTo-ChaosTagTable -Tags @($exclusions.tags)
                if ($tagTable.Count -gt 0) {
                    $replayLines += "    -ExcludeTag $(ConvertTo-ChaosPowerShellLiteral -Value $tagTable) ``"
                }
            }
        }
        $command = @(
            "& $(ConvertTo-ChaosPowerShellLiteral -Value $scope) ``"
            "    -SubscriptionId $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$plan.workspace.subscriptionId)) ``"
            "    -ResourceGroup $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$plan.workspace.resourceGroup)) ``"
            "    -WorkspaceName $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$plan.workspace.name)) ``$regionLine"
            "    -Scenario $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$plan.scenario.name)) ``"
            "    -Action $(ConvertTo-ChaosPowerShellLiteral -Value $actionRef) ``"
            "    -SteadyState $(ConvertTo-ChaosPowerShellLiteral -Value ([string]$plan.question.steadyState.raw)) ``"
            $replayLines
            $sourceLines
            "    -DurationMinutes $($plan.windows.injectMinutes) ``"
            "    -BaselineMinutes $($plan.windows.baselineMinutes) ``"
            "    -RecoveryMinutes $($plan.windows.recoveryMinutes)"
        ) | Where-Object { $_ } | ForEach-Object { $_ }
        $command = ($command -join "`n")

        Write-Card -Title "Rerun study $($entry.studyId)" -Status 'info' -Body @"
Rerunning creates a new study rather than overwriting this one, so the pair can
be compared afterwards. The workspace scope and the action are both resolved
live again, so a rerun fails loudly if the platform no longer offers the action
or the workspace no longer covers the same resources. Nothing has been injected
- run the command below, then the chaos-study-run skill with explicit consent.
"@ -Properties ([ordered]@{
            'Workspace' = [string]$plan.workspace.name
            'Scenario'  = [string]$plan.scenario.name
            'Action'    = [string]$plan.action.displayName
            'Predicate' = [string]$plan.question.steadyState.raw
        })
        Write-Card -Title 'Command' -Status 'info' -Body $command
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }
}
