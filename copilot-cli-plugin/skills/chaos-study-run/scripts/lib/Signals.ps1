#Requires -Version 7.0
<#
.SYNOPSIS
    Evidence collection for a chaos study.

.DESCRIPTION
    The rule this file exists to enforce: a measurement that could not be taken
    is recorded as null with a caveat, never as zero and never as a guess. A
    study that reports "0 errors" when it actually failed to query anything is
    worse than a study that reports nothing, because it is believed.

    Every collector here returns the shape produced by New-ChaosSignalResult,
    and every failure path returns that same shape with values = $null and a
    caveat naming what went wrong.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Operation.ps1')

function Resolve-ChaosSignalAdapter {
    <#
    .SYNOPSIS
        Choose the adapter probe-signal collection routes through.

    .DESCRIPTION
        Evidence collection - including the mechanism probe - must reach Azure
        through the same operation seam as everything else, never a direct
        Invoke-ChaosStudyAzRest. The adapter is taken from an explicit override, then the
        adapter frozen on the plan, and only then the in-process 'local-az' path
        that preserves how this suite has always collected signals. This is a
        read-only collection default, not a control-plane fallback.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][object]$Plan
    )
    if (-not [string]::IsNullOrWhiteSpace($Adapter)) { return $Adapter }
    if ($null -ne $Plan -and ($Plan.PSObject.Properties.Name -contains 'adapter') -and -not [string]::IsNullOrWhiteSpace([string]$Plan.adapter)) {
        return [string]$Plan.adapter
    }
    return 'local-az'
}

# -- Source specifications -------------------------------------------------

function ConvertFrom-ChaosSignalSourceSpec {
    <#
    .SYNOPSIS
        Parse a signal source string into a structured spec.

    .DESCRIPTION
        Accepted forms:
          metrics:<name>             Azure Monitor metric on the single scoped
                                     resource, when the scope holds exactly one
          metrics:<name>@<resourceId>   ... on a named resource
          metrics:<name>|<aggregation> ... with an explicit aggregation
          logs:<workspaceId>#<kql>   Log Analytics query

        There is deliberately no resource-specific collector here. What counts
        as evidence depends on the system under study, so the operator names it.
    #>
    param([Parameter(Mandatory)][string]$Spec)

    $text = $Spec.Trim()

    if ($text -like 'metrics:*') {
        $rest = $text.Substring('metrics:'.Length)
        $aggregation = 'Average'
        if ($rest.Contains('|')) {
            $parts = $rest.Split('|', 2)
            $rest = $parts[0]
            $aggregation = $parts[1]
        }
        $resourceId = $null
        if ($rest.Contains('@')) {
            $parts = $rest.Split('@', 2)
            $rest = $parts[0]
            $resourceId = $parts[1]
        }
        if ([string]::IsNullOrWhiteSpace($rest)) {
            throw "Signal source '$Spec' is missing a metric name. Use 'metrics:<metricName>'."
        }
        return [pscustomobject]@{
            kind        = 'metrics'
            id          = "metrics:$rest"
            metricName  = $rest
            aggregation = $aggregation
            resourceId  = $resourceId
            raw         = $text
        }
    }

    if ($text -like 'logs:*') {
        $rest = $text.Substring('logs:'.Length)
        if (-not $rest.Contains('#')) {
            throw "Signal source '$Spec' is missing its query. Use 'logs:<workspaceId>#<kql>'."
        }
        $parts = $rest.Split('#', 2)
        if ([string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            throw "Signal source '$Spec' needs both a workspace id and a query."
        }
        return [pscustomobject]@{
            kind        = 'logs'
            id          = "logs:$($parts[0])"
            workspaceId = $parts[0]
            query       = $parts[1]
            raw         = $text
        }
    }

    throw "Signal source '$Spec' is not recognised. Use 'metrics:<name>' or 'logs:<workspaceId>#<kql>'."
}

# -- Collectors ------------------------------------------------------------

function Get-ChaosWindowTimespan {
    <#
    .SYNOPSIS
        The Azure Monitor "start/end" timespan for a study window.

    .DESCRIPTION
        New-ChaosWindow emits startUtc/endUtc - already ISO-8601 - and that is
        the only window shape this suite produces. Reading .start/.end instead
        finds nothing: under StrictMode that throws, and without it the timespan
        silently becomes garbage. Both failures land in the same place, an
        evidence window that does not describe the time we actually measured, so
        the field names live here once rather than at each collector.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Window)

    $start = [string]$Window.startUtc
    $end = [string]$Window.endUtc
    if ([string]::IsNullOrWhiteSpace($start) -or [string]::IsNullOrWhiteSpace($end)) {
        throw "Window '$($Window.name)' carries no startUtc/endUtc, so no evidence window can be named for it."
    }
    return "$start/$end"
}

function Get-ChaosMetricSignal {
    <#
    .SYNOPSIS
        An Azure Monitor metric series over the window.
    #>
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ResourceId,
        [Parameter(Mandatory)][object]$Window,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$StudyPath = $null
    )

    $windowName = $Window.name
    $metricTarget = if ($Spec.resourceId) { $Spec.resourceId } else { $ResourceId }
    if ([string]::IsNullOrWhiteSpace($metricTarget)) {
        # A V2 study can span many scoped resources, so there is no single
        # implied resource to charge a metric against. Rather than silently
        # picking one and reporting its numbers as if they described the whole
        # scope, say so and let the operator pin the resource explicitly.
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName `
            -Caveat "No resource could be resolved for metric '$($Spec.metricName)'. Pin one with 'metrics:$($Spec.metricName)@<resourceId>' - a study over several scoped resources has no single implied resource."
    }
    $timespan = Get-ChaosWindowTimespan -Window $Window
    $query = [ordered]@{
        resourceId  = $metricTarget
        metric      = $Spec.metricName
        aggregation = $Spec.aggregation
        timespan    = $timespan
        interval    = 'PT1M'
    }

    if (-not (Get-Command Invoke-ChaosStudyOperation -ErrorAction SilentlyContinue)) {
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat 'The operation adapter seam is unavailable, so Azure Monitor could not be queried.'
    }

    # Probe-signal collection is routed through the operation seam - never a
    # direct Invoke-ChaosStudyAzRest - so the mechanism probe reaches Azure the same way
    # every other operation does and can be brokered or stubbed as one.
    $uri = "$metricTarget/providers/Microsoft.Insights/metrics?timespan=$timespan&interval=PT1M&metricnames=$($Spec.metricName)&aggregation=$($Spec.aggregation)"
    try {
        $response = Invoke-ChaosStudyOperation -Kind 'metrics.query' -Arguments @{ uri = $uri } `
            -ExpectedSchema 'any.v1' -Adapter $Adapter -StudyPath $StudyPath
    } catch {
        $message = "Azure Monitor query failed: $($_.Exception.Message)"
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat (Protect-ChaosSecret -Text $message)
    }

    $series = @()
    if ($response -and $response.body -and $response.body.PSObject.Properties.Name -contains 'value') {
        foreach ($metric in @($response.body.value | Where-Object { $null -ne $_ })) {
            foreach ($timeseries in @($metric.timeseries | Where-Object { $null -ne $_ })) {
                foreach ($point in @($timeseries.data | Where-Object { $null -ne $_ })) {
                    $value = $null
                    foreach ($candidate in @('average', 'total', 'maximum', 'minimum', 'count')) {
                        if ($point.PSObject.Properties.Name -contains $candidate -and $null -ne $point.$candidate) {
                            $value = $point.$candidate
                            break
                        }
                    }
                    $series += [ordered]@{ timestamp = $point.timeStamp; value = $value }
                }
            }
        }
    }

    if ($series.Count -eq 0) {
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat "Azure Monitor returned no data points for '$($Spec.metricName)' in this window. The metric may not be emitted for this resource, or ingestion may lag the window."
    }

    return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Values $series -Query $query
}

function Get-ChaosLogSignal {
    <#
    .SYNOPSIS
        A Log Analytics result set over the window.
    #>
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$Window,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$StudyPath = $null
    )

    $windowName = $Window.name
    $timespan = Get-ChaosWindowTimespan -Window $Window
    $query = [ordered]@{ workspaceId = $Spec.workspaceId; kql = $Spec.query; timespan = $timespan }

    if (-not (Get-Command Invoke-ChaosStudyOperation -ErrorAction SilentlyContinue)) {
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat 'The operation adapter seam is unavailable, so Log Analytics could not be queried.'
    }

    # Routed through the seam so the mechanism probe's log query is brokered or
    # stubbed like any other operation, never a direct az rest call from here.
    try {
        $response = Invoke-ChaosStudyOperation -Kind 'logs.query' `
            -Arguments @{ workspaceId = $Spec.workspaceId; query = $Spec.query; timespan = $timespan } `
            -ExpectedSchema 'any.v1' -Adapter $Adapter -StudyPath $StudyPath
    } catch {
        $message = "Log Analytics query failed: $($_.Exception.Message)"
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat (Protect-ChaosSecret -Text $message)
    }

    $rows = @()
    $columns = @()
    if ($response -and $response.PSObject.Properties.Name -contains 'tables') {
        $table = @($response.tables) | Select-Object -First 1
        if ($table) {
            $columns = @($table.columns | Where-Object { $null -ne $_ } | ForEach-Object { $_.name })
            foreach ($row in @($table.rows | Where-Object { $null -ne $_ })) {
                $record = [ordered]@{}
                for ($i = 0; $i -lt $columns.Count; $i++) { $record[$columns[$i]] = $row[$i] }
                $rows += $record
            }
        }
    }

    if ($rows.Count -eq 0) {
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat 'The Log Analytics query returned no rows for this window. Ingestion latency of several minutes is normal; an empty result is not evidence of health.'
    }

    return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Values $rows -Query $query
}

# -- Orchestration ---------------------------------------------------------

function Invoke-ChaosSignalCollection {
    <#
    .SYNOPSIS
        Collect every configured signal for one phase window.

    .DESCRIPTION
        Collection never throws. A source that fails produces a null result
        with a caveat, so a partial outage in observability degrades the
        study's confidence rather than destroying the run.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Window,
        [string[]]$Sources = @(),
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$StudyPath = $null,
        [switch]$DryRun
    )

    $selectedAdapter = Resolve-ChaosSignalAdapter -Adapter $Adapter -Plan $Plan

    $results = @()
    $specs = @()

    foreach ($source in @($Sources)) {
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        try {
            $specs += ConvertFrom-ChaosSignalSourceSpec -Spec $source
        } catch {
            $results += New-ChaosSignalResult -Source $source -Window $Window.name `
                -Caveat (Protect-ChaosSecret -Text $_.Exception.Message)
        }
    }

    if ($specs.Count -eq 0 -and $results.Count -eq 0) {
        $results += New-ChaosSignalResult -Source 'none' -Window $Window.name `
            -Caveat 'No signal sources were configured, so this window has no measurement of any kind.'
    }

    # A study can span many scoped resources. Only an unambiguous scope - exactly
    # one resource - implies a metric target; anything else must be pinned per
    # signal, so a number is never attributed to the wrong resource.
    #
    # `projectedResources` is persisted as a list of id STRINGS. Reading
    # `.resourceId` off them threw under StrictMode on every non-empty scope,
    # which is the normal case, so this reads both shapes exactly as the
    # readiness gates do.
    $scopedResourceIds = @(@($Plan.scope.projectedResources) | Where-Object { $_ } | ForEach-Object {
            if ($_ -is [string]) { $_ }
            elseif ($_.PSObject.Properties.Name -contains 'resourceId') { [string]$_.resourceId }
            else { [string]$_ }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $implicitResourceId = if ($scopedResourceIds.Count -eq 1) { $scopedResourceIds[0] } else { $null }

    foreach ($spec in $specs) {
        if ($DryRun) {
            $results += New-ChaosSignalResult -Source $spec.id -Window $Window.name `
                -Caveat 'Dry run: no query was issued, so no measurement exists for this window.'
            continue
        }

        switch ($spec.kind) {
            'metrics' {
                $results += Get-ChaosMetricSignal -Spec $spec -ResourceId $implicitResourceId -Window $Window -Adapter $selectedAdapter -StudyPath $StudyPath
            }
            'logs' {
                $results += Get-ChaosLogSignal -Spec $spec -Window $Window -Adapter $selectedAdapter -StudyPath $StudyPath
            }
            default {
                $results += New-ChaosSignalResult -Source $spec.id -Window $Window.name `
                    -Caveat "No collector is implemented for source kind '$($spec.kind)'."
            }
        }
    }

    return ,@($results)
}

function Get-ChaosPredicateSignalValue {
    param([AllowEmptyCollection()][object[]]$Signals, [Parameter(Mandatory)][object]$Predicate)
    foreach ($signal in $Signals) {
        if ($null -eq $signal) { continue }
        $map = Get-ChaosSignalValueMap -Signal $signal
        if ($map.Contains([string]$Predicate.signal)) { return $map[[string]$Predicate.signal] }
        if ($signal.source -eq "metrics:$($Predicate.signal)" -or $signal.source -eq $Predicate.signal) {
            foreach ($key in @('value', 'last', 'mean')) {
                if ($map.Contains($key)) { return $map[$key] }
            }
        }
    }
    return $null
}

function Invoke-ChaosAbortEvaluation {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Signals,
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][datetime]$InjectionStartedAt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    if (-not $State.Contains('lastSeen')) { $State['lastSeen'] = @{} }
    $observedAt = ConvertFrom-ChaosUtcIso -Text $Window.endUtc
    $evaluations = @()
    $trigger = $null
    foreach ($condition in $Plan.safety.abortConditions) {
        if ($null -eq $condition -or $condition -is [string]) { throw 'Abort conditions must be structured before injection.' }
        switch ($condition.kind) {
            'predicate' {
                $value = Get-ChaosPredicateSignalValue -Signals $Signals -Predicate $condition.predicate
                $held = Test-ChaosPredicate -Predicate $condition.predicate -Value $value
                $evaluations += [pscustomobject]@{
                    conditionId = $condition.id; kind = 'predicate'; value = $value
                    status = if ($null -eq $held) { 'not-measured' } elseif ($held) { 'clear' } else { 'triggered' }
                }
                if ($held -eq $false -and $null -eq $trigger) {
                    $trigger = [ordered]@{ conditionId = $condition.id; kind = 'predicate'; source = $condition.predicate.signal; reason = "Frozen predicate '$($condition.predicate.raw)' was breached." }
                }
            }
            'missing-signal' {
                $threshold = [int]$condition.intervalSeconds * [int]$condition.unavailableIntervals
                if ($threshold -le 0) { throw 'Missing-signal abort requires positive frozen intervals.' }
                foreach ($source in $condition.sources) {
                    $id = (ConvertFrom-ChaosSignalSourceSpec -Spec $source).id
                    $signal = @($Signals | Where-Object { $null -ne $_ -and $_.source -eq $id } | Select-Object -First 1)
                    $measured = $signal.Count -gt 0 -and $null -ne $signal[0].values -and @($signal[0].values).Count -gt 0
                    if ($measured) { $State.lastSeen[$id] = $observedAt }
                    $lastSeen = if ($State.lastSeen.ContainsKey($id)) { [datetime]$State.lastSeen[$id] } else { $InjectionStartedAt }
                    $missingSeconds = ($observedAt - $lastSeen).TotalSeconds
                    $tripped = -not $measured -and $missingSeconds -ge $threshold
                    $evaluations += [pscustomobject]@{
                        conditionId = $condition.id; kind = 'missing-signal'; source = $id
                        status = if ($tripped) { 'triggered' } elseif ($measured) { 'clear' } else { 'pending' }
                        missingSeconds = $missingSeconds; thresholdSeconds = $threshold
                    }
                    if ($tripped -and $null -eq $trigger) {
                        $trigger = [ordered]@{ conditionId = $condition.id; kind = 'missing-signal'; source = $id; reason = "Signal '$id' stopped reporting for the frozen $threshold-second limit." }
                    }
                }
            }
            default { throw "Unsupported abort condition '$($condition.kind)'." }
        }
    }
    return [pscustomobject]@{
        observedAt = $Window.endUtc; window = $Window; triggered = ($null -ne $trigger)
        trigger = $trigger; evaluations = $evaluations; signals = $Signals
    }
}

function Test-ChaosSignalCoverage {
    <#
    .SYNOPSIS
        Summarise how much of the evidence is real, so the report can be honest
        about it rather than presenting gaps as results.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Signals)

    $all = @($Signals)
    $measured = @($all | Where-Object { $null -ne $_.values })
    return [pscustomobject]@{
        total       = $all.Count
        measured    = $measured.Count
        missing     = $all.Count - $measured.Count
        caveats     = @($all | Where-Object { $_.caveat } | ForEach-Object { $_.caveat } | Select-Object -Unique)
        anyMeasured = ($measured.Count -gt 0)
    }
}
