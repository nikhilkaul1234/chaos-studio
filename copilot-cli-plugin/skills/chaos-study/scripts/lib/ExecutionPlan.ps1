# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Shared scope/run projection: both phases must hash the same executable legs.
Set-StrictMode -Version Latest

function Get-ChaosLegField {
    param([AllowNull()][object]$Leg, [Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $Leg) { return $null }
    foreach ($name in $Names) {
        if ($Leg -is [System.Collections.IDictionary]) {
            if ($Leg.Contains($name) -and $null -ne $Leg[$name]) { return $Leg[$name] }
        } elseif ($Leg -is [pscustomobject]) {
            if (($Leg.PSObject.Properties.Name -contains $name) -and $null -ne $Leg.$name) { return $Leg.$name }
        }
    }
    return $null
}

function Get-ChaosExecutionPlanLegs {
    <#
    .SYNOPSIS
        Project live keyed actions, legacy legs, or step/branch/action targets.
    .DESCRIPTION
        executionPlanJson is a JSON string in ARM validation responses.
        Each keyed action is one declared leg, including skipped actions with
        unresolved selectors. Its target set is retained without inventing legs.
    #>
    param([AllowNull()][object]$ExecutionPlan)
    if ($null -eq $ExecutionPlan) { return @() }

    $roots = [System.Collections.Generic.List[object]]::new()
    $roots.Add($ExecutionPlan)
    for ($index = 0; $index -lt $roots.Count; $index++) {
        $root = $roots[$index]
        if ($root -is [string]) {
            try { $root = ConvertFrom-Json -InputObject $root -NoEnumerate -ErrorAction Stop }
            catch { throw "InvalidExecutionPlan: executionPlanJson is not valid JSON. $($_.Exception.Message)" }
            if ($root -isnot [pscustomobject] -and $root -isnot [System.Collections.IDictionary]) {
                throw 'InvalidExecutionPlan: executionPlanJson must contain an object.'
            }
            $roots[$index] = $root
        }
        foreach ($name in @('properties', 'executionPlan', 'executionPlanJson')) {
            $child = Get-ChaosLegField -Leg $root -Names @($name)
            if ($null -ne $child) { $roots.Add($child) }
        }
    }

    foreach ($root in $roots) {
        $legs = Get-ChaosLegField -Leg $root -Names @('legs', 'effectiveLegs')
        if ($null -ne $legs) { return @($legs) }
    }

    foreach ($root in $roots) {
        $actions = Get-ChaosLegField -Leg $root -Names @('actions')
        if ($actions -isnot [System.Collections.IDictionary] -and $actions -isnot [pscustomobject]) { continue }
        $names = if ($actions -is [System.Collections.IDictionary]) { @($actions.Keys) } else { @($actions.PSObject.Properties | ForEach-Object { $_.Name }) }
        $mapped = @(foreach ($name in $names) {
            $action = Get-ChaosLegField -Leg $actions -Names @($name)
            $skip = Get-ChaosLegField -Leg $action -Names @('skip')
            if ($skip -isnot [bool]) { throw "InvalidExecutionPlan: action '$name' must report a boolean skip value." }
            $properties = Get-ChaosLegField -Leg $action -Names @('properties')
            $targets = Get-ChaosLegField -Leg $properties -Names @('targetResources')
            [pscustomobject]@{
                legSelector = [string]$name
                action = Get-ChaosLegField -Leg $properties -Names @('faultUrn')
                skipped = $skip
                targets = @($targets | Where-Object { $null -ne $_ })
            }
        })
        return @($mapped)
    }

    foreach ($root in $roots) {
        $steps = Get-ChaosLegField -Leg $root -Names @('steps')
        if ($null -eq $steps) { continue }
        $expanded = @()
        foreach ($step in @($steps | Where-Object { $null -ne $_ })) {
            $branches = Get-ChaosLegField -Leg $step -Names @('branches')
            foreach ($branch in @($branches | Where-Object { $null -ne $_ })) {
                $actions = Get-ChaosLegField -Leg $branch -Names @('actions')
                foreach ($action in @($actions | Where-Object { $null -ne $_ })) {
                    $actionName = Get-ChaosLegField -Leg $action -Names @('name', 'actionName', 'type', 'actionId')
                    $targets = Get-ChaosLegField -Leg $action -Names @('targets', 'selectors', 'resources')
                    if ($null -eq $targets) {
                        $expanded += [ordered]@{ action = $actionName; target = $null; reason = (Get-ChaosLegField -Leg $action -Names @('reason', 'skipReason')); status = (Get-ChaosLegField -Leg $action -Names @('status', 'state')) }
                        continue
                    }
                    foreach ($target in @($targets | Where-Object { $null -ne $_ })) {
                        $expanded += [ordered]@{
                            action = $actionName
                            target = $target
                            reason = Get-ChaosLegField -Leg $target -Names @('reason', 'skipReason')
                            status = Get-ChaosLegField -Leg $target -Names @('status', 'state')
                        }
                    }
                }
            }
        }
        if ($expanded.Count -gt 0) { return @($expanded) }
    }
    return @()
}

function Test-ChaosLegSkipped {
    param([AllowNull()][object]$Leg)
    $executable = Get-ChaosLegField -Leg $Leg -Names @('executable', 'willExecute', 'included')
    if ($executable -is [bool] -and -not $executable) { return $true }
    $reason = Get-ChaosLegField -Leg $Leg -Names @('reason', 'skipReason', 'skippedReason')
    if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { return $true }
    $status = [string](Get-ChaosLegField -Leg $Leg -Names @('status', 'state'))
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        $skipStates = @('skipped', 'notapplicable', 'not-applicable', 'excluded', 'unsupported', 'notsupported', 'ineligible', 'filtered')
        if ($skipStates -contains $status.Trim().ToLowerInvariant().Replace(' ', '')) { return $true }
    }
    $skippedFlag = Get-ChaosLegField -Leg $Leg -Names @('skipped')
    if ($skippedFlag -is [bool] -and $skippedFlag) { return $true }
    return $false
}

function Get-ChaosLegSelectorText {
    param([AllowNull()][object]$Leg)
    $selector = Get-ChaosLegField -Leg $Leg -Names @('legSelector', 'selector', 'targetSelector', 'key', 'name')
    if (-not [string]::IsNullOrWhiteSpace([string]$selector)) { return [string]$selector }
    $target = Get-ChaosLegField -Leg $Leg -Names @('target', 'resource')
    if ($null -ne $target -and $target -isnot [string]) {
        $nested = Get-ChaosLegField -Leg $target -Names @('legSelector', 'selector', 'targetSelector', 'key', 'name')
        if (-not [string]::IsNullOrWhiteSpace([string]$nested)) { return [string]$nested }
    }
    $resource = Get-ChaosLegField -Leg $Leg -Names @('resourceSelector', 'resourceId', 'id')
    if ([string]::IsNullOrWhiteSpace([string]$resource) -and $null -ne $target -and $target -isnot [string]) {
        $resource = Get-ChaosLegField -Leg $target -Names @('resourceSelector', 'resourceId', 'id')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$resource)) { return [string]$resource }
    if ($null -ne $target -and $target -is [string]) { return [string]$target }
    return ''
}
