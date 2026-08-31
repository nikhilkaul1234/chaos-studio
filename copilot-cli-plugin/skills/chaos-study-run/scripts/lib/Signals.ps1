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

function Get-ChaosMetricSignal {
    <#
    .SYNOPSIS
        An Azure Monitor metric series over the window.
    #>
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ResourceId,
        [Parameter(Mandatory)][object]$Window
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
    $timespan = "$($Window.startUtc)/$($Window.endUtc)"
    $query = [ordered]@{
        resourceId  = $metricTarget
        metric      = $Spec.metricName
        aggregation = $Spec.aggregation
        timespan    = $timespan
        interval    = 'PT1M'
    }

    if (-not (Get-Command Invoke-AzRest -ErrorAction SilentlyContinue)) {
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat 'The shared Invoke-AzRest helper is unavailable, so Azure Monitor could not be queried.'
    }

    $uri = "$metricTarget/providers/Microsoft.Insights/metrics?timespan=$timespan&interval=PT1M&metricnames=$($Spec.metricName)&aggregation=$($Spec.aggregation)"
    try {
        $response = Invoke-AzRest -Method GET -Uri $uri -ApiVersion (Get-ChaosApiVersion -Name 'metrics')
    } catch {
        $message = "Azure Monitor query failed: $($_.Exception.Message)"
        return New-ChaosSignalResult -Source $Spec.id -Window $windowName -Query $query `
            -Caveat (Protect-ChaosSecret -Text $message)
    }

    $series = @()
    if ($response -and $response.body -and $response.body.PSObject.Properties.Name -contains 'value') {
        foreach ($metric in @($response.body.value)) {
            foreach ($timeseries in @($metric.timeseries)) {
                foreach ($point in @($timeseries.data)) {
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

function Invoke-ChaosLogAnalyticsQuery {
    <#
    .SYNOPSIS
        Run a KQL query against a Log Analytics workspace.

    .DESCRIPTION
        The shared Invoke-AzRest helper is pinned to the ARM audience, so it
        cannot reach the Log Analytics data plane. This calls az rest directly
        with the correct audience rather than modifying a shipped script.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$Timespan
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'The Azure CLI is not on PATH.'
    }

    $endpoint = Get-ChaosEndpoint -Name 'logAnalytics'
    $uri = "$endpoint/v1/workspaces/$WorkspaceId/query"
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $body = @{ query = $Query; timespan = $Timespan } | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::WriteAllText($bodyFile, $body, [System.Text.UTF8Encoding]::new($false))
        $raw = & az rest --method POST --uri $uri --resource $endpoint `
            --headers 'Content-Type=application/json' --body "@$bodyFile" --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($raw | Out-String).Trim())
        }
        return ($raw | Out-String) | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ChaosLogSignal {
    <#
    .SYNOPSIS
        A Log Analytics result set over the window.
    #>
    param(
        [Parameter(Mandatory)][object]$Spec,
        [Parameter(Mandatory)][object]$Window
    )

    $windowName = $Window.name
    $timespan = "$($Window.startUtc)/$($Window.endUtc)"
    $query = [ordered]@{ workspaceId = $Spec.workspaceId; kql = $Spec.query; timespan = $timespan }

    try {
        $response = Invoke-ChaosLogAnalyticsQuery -WorkspaceId $Spec.workspaceId -Query $Spec.query -Timespan $timespan
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
            $columns = @($table.columns | ForEach-Object { $_.name })
            foreach ($row in @($table.rows)) {
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
        [switch]$DryRun
    )

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
    $scopedResources = @($Plan.scope.projectedResources | Where-Object { $_ -and $_.resourceId })
    $implicitResourceId = if ($scopedResources.Count -eq 1) { [string]$scopedResources[0].resourceId } else { $null }

    foreach ($spec in $specs) {
        if ($DryRun) {
            $results += New-ChaosSignalResult -Source $spec.id -Window $Window.name `
                -Caveat 'Dry run: no query was issued, so no measurement exists for this window.'
            continue
        }

        switch ($spec.kind) {
            'metrics' {
                $results += Get-ChaosMetricSignal -Spec $spec -ResourceId $implicitResourceId -Window $Window
            }
            'logs' {
                $results += Get-ChaosLogSignal -Spec $spec -Window $Window
            }
            default {
                $results += New-ChaosSignalResult -Source $spec.id -Window $Window.name `
                    -Caveat "No collector is implemented for source kind '$($spec.kind)'."
            }
        }
    }

    return ,@($results)
}

function Test-ChaosSignalCoverage {
    <#
    .SYNOPSIS
        Summarise how much of the evidence is real, so the report can be honest
        about it rather than presenting gaps as results.
    #>
    param([Parameter(Mandatory)][object[]]$Signals)

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

function Get-ChaosAbortConditionDescription {
    param([Parameter(Mandatory)][object]$Condition)

    if ($Condition -is [string]) { return $Condition }
    if ($Condition.PSObject.Properties.Name -contains 'description') {
        return [string]$Condition.description
    }
    return ConvertTo-ChaosCanonicalJson -InputObject $Condition
}

function Get-ChaosPredicateSignalValue {
    param(
        [Parameter(Mandatory)][object[]]$Signals,
        [Parameter(Mandatory)][object]$Predicate
    )

    $signalName = [string]$Predicate.signal
    $signal = @($Signals | Where-Object {
            $_.source -eq "metrics:$signalName" -or $_.source -eq $signalName
        } | Select-Object -First 1)
    if ($signal.Count -eq 0) { return $null }

    foreach ($candidate in @($signalName, 'value', 'last', 'mean')) {
        $map = Get-ChaosSignalValueMap -Signal $signal[0]
        if ($map.Contains($candidate)) { return $map[$candidate] }
    }
    return $null
}

function Invoke-ChaosAbortEvaluation {
    <#
    .SYNOPSIS
        Evaluate the plan's frozen abort contract against one live signal check.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object[]]$Signals,
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][datetime]$InjectionStartedAt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    if (-not $State.Contains('missingSince')) {
        $State['missingSince'] = [ordered]@{}
    }

    $observedAt = ConvertFrom-ChaosUtcIso -Text ([string]$Window.endUtc)
    $evaluations = @()
    $trigger = $null

    foreach ($condition in @($Plan.safety.abortConditions)) {
        if ($null -eq $condition -or $condition -is [string]) {
            $evaluations += [ordered]@{
                conditionId = 'unsupported'
                status      = 'not-evaluated'
                detail      = 'The frozen abort condition is not structured and cannot be evaluated.'
            }
            continue
        }

        $kind = [string]$condition.kind
        $conditionId = [string]$condition.id
        switch ($kind) {
            'predicate' {
                $value = Get-ChaosPredicateSignalValue -Signals $Signals -Predicate $condition.predicate
                $held = Test-ChaosPredicate -Predicate $condition.predicate -Value $value
                $detail = if ($null -eq $held) {
                    "Predicate '$($condition.predicate.raw)' could not be evaluated in this check."
                } elseif ($held) {
                    "Predicate '$($condition.predicate.raw)' held."
                } else {
                    "Predicate '$($condition.predicate.raw)' was breached."
                }
                $evaluations += [ordered]@{
                    conditionId = $conditionId
                    kind        = $kind
                    status      = if ($null -eq $held) { 'not-measured' } elseif ($held) { 'clear' } else { 'triggered' }
                    value       = $value
                    detail      = $detail
                }
                if ($held -eq $false -and $null -eq $trigger) {
                    $trigger = [ordered]@{
                        conditionId = $conditionId
                        kind        = $kind
                        source      = [string]$condition.predicate.signal
                        reason      = $detail
                    }
                }
            }
            'missing-signal' {
                $intervalSeconds = [int]$condition.intervalSeconds
                $unavailableIntervals = [int]$condition.unavailableIntervals
                $thresholdSeconds = $intervalSeconds * $unavailableIntervals

                foreach ($sourceSpec in @($condition.sources)) {
                    $sourceId = [string]$sourceSpec
                    try { $sourceId = (ConvertFrom-ChaosSignalSourceSpec -Spec ([string]$sourceSpec)).id } catch { }
                    $signal = @($Signals | Where-Object { $_.source -eq $sourceId } | Select-Object -First 1)
                    $measured = ($signal.Count -gt 0 -and $null -ne $signal[0].values)

                    if ($measured) {
                        if ($State.missingSince.Contains($sourceId)) {
                            $State.missingSince.Remove($sourceId)
                        }
                        $evaluations += [ordered]@{
                            conditionId = $conditionId
                            kind        = $kind
                            source      = $sourceId
                            status      = 'clear'
                            detail      = "Signal '$sourceId' reported data."
                        }
                        continue
                    }

                    if (-not $State.missingSince.Contains($sourceId)) {
                        $State.missingSince[$sourceId] = $InjectionStartedAt
                    }
                    $missingSince = [datetime]$State.missingSince[$sourceId]
                    $missingSeconds = [int][math]::Floor(($observedAt - $missingSince).TotalSeconds)
                    $tripped = $missingSeconds -ge $thresholdSeconds
                    $detail = "Signal '$sourceId' has not reported data for $missingSeconds second(s); the frozen limit is $thresholdSeconds second(s)."
                    $evaluations += [ordered]@{
                        conditionId  = $conditionId
                        kind         = $kind
                        source       = $sourceId
                        status       = if ($tripped) { 'triggered' } else { 'pending' }
                        missingSince = ConvertTo-ChaosUtcIso -Instant $missingSince
                        detail       = $detail
                    }
                    if ($tripped -and $null -eq $trigger) {
                        $trigger = [ordered]@{
                            conditionId = $conditionId
                            kind        = $kind
                            source      = $sourceId
                            reason      = $detail
                        }
                    }
                }
            }
            default {
                $evaluations += [ordered]@{
                    conditionId = $conditionId
                    kind        = $kind
                    status      = 'not-evaluated'
                    detail      = "Abort condition kind '$kind' is not supported."
                }
            }
        }
    }

    return [pscustomobject]@{
        observedAt = [string]$Window.endUtc
        window     = $Window
        triggered  = ($null -ne $trigger)
        trigger    = $trigger
        evaluations = @($evaluations)
        signals    = @($Signals)
    }
}
