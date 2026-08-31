#Requires -Version 7.0
<#
.SYNOPSIS
    Preconditions that decide whether a study's result will mean anything.

.DESCRIPTION
    Running a study is cheap. Running one whose result cannot be interpreted is
    expensive, because it consumes a change window and then produces a document
    that looks like evidence. These gates check, before any fault is planned,
    the conditions that separate those two outcomes:

      steady state    without a numeric objective stated in advance there is
                      nothing to breach, so there is nothing to pass either
      scope           the workspace has to have discovered something, or the
                      run touches nothing and reports success
      action fit      the action must be one the service reports for a resource
                      type in scope, with the parameters its schema requires
      observability   without a signal source the study can only prove the
                      control plane accepted the scenario run
      blast radius    a window long enough to observe, short enough to bound

    Gates are `blocking` or `advisory`. Blocking gates stop scoping with exit
    code 10. Advisory gates become limitations on the report - they weaken the
    conclusion without invalidating it.

    A gate that cannot be evaluated returns 'unknown', never 'pass'. The two
    lead to different next actions and collapsing them loses the distinction
    exactly when it matters.

    Nothing here knows what kind of resource is being studied. Every fact about
    the fault comes from the live action record discovered at scope time.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot 'ActionDiscovery.ps1')

function New-ChaosReadinessGate {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'unknown')][string]$Status,
        [Parameter(Mandatory)][ValidateSet('blocking', 'advisory')][string]$Severity,
        [Parameter(Mandatory)][string]$Detail,
        [AllowNull()][AllowEmptyString()][string]$Remediation = $null,
        [AllowNull()][AllowEmptyString()][string]$LimitationCode = $null
    )
    return [pscustomobject]@{
        id             = $Id
        title          = $Title
        status         = $Status
        severity       = $Severity
        detail         = $Detail
        remediation    = $Remediation
        limitationCode = $LimitationCode
    }
}

function Test-ChaosSteadyStatePredicate {
    <#
    .SYNOPSIS
        Blocking: a study without a stated objective cannot fail, so it cannot
        pass either.
    #>
    param([AllowNull()][object]$Predicate)

    if ($null -eq $Predicate -or -not $Predicate.signal -or $null -eq $Predicate.threshold) {
        return New-ChaosReadinessGate -Id 'steady-state' -Title 'Steady state is defined numerically' `
            -Status 'fail' -Severity 'blocking' `
            -Detail 'No steady-state predicate was supplied. Without a signal, a comparison and a threshold stated before injection, there is no definition of "breached", so the study cannot produce a verdict - only a narrative.' `
            -Remediation 'Re-run with -SteadyState "successRate >= 99.5" (or a latency objective).'
    }

    return New-ChaosReadinessGate -Id 'steady-state' -Title 'Steady state is defined numerically' `
        -Status 'pass' -Severity 'blocking' `
        -Detail "Steady state: $($Predicate.signal) $($Predicate.comparison) $($Predicate.threshold)$($Predicate.unit)."
}

function Test-ChaosScopePopulated {
    <#
    .SYNOPSIS
        Blocking: did the workspace actually discover anything to act on?

    .DESCRIPTION
        A workspace whose scopes resolve to no discovered resources will accept
        a scenario configuration and run it to a clean Succeeded. Nothing was
        touched, so nothing broke, and the report reads like a pass. That is the
        single most misleading outcome this suite can produce, so an empty scope
        stops scoping outright.

        That verdict depends on having actually looked. When discovery was
        deliberately skipped the count is not zero, it is unknown, and the gate
        says so instead of failing: reporting "no resources" for a question we
        never asked would be inventing evidence. The plan then carries L10 and
        the run refuses to arm until discovery has confirmed the scope.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$ScopedResources,
        [switch]$DiscoverySkipped
    )

    $count = @(@($ScopedResources) | Where-Object { $null -ne $_ }).Count

    if ($DiscoverySkipped) {
        return New-ChaosReadinessGate -Id 'scope-populated' -Title 'Workspace scope contains resources' `
            -Status 'unknown' -Severity 'blocking' -LimitationCode 'L10' `
            -Detail 'Discovery was skipped, so the workspace was never asked what it discovered. Whether the scope resolves to any resource at all is unverified.' `
            -Remediation 'Re-scope without -SkipDiscovery before running this study, so an empty scope cannot be mistaken for a resilient result.'
    }

    if ($count -eq 0) {
        return New-ChaosReadinessGate -Id 'scope-populated' -Title 'Workspace scope contains resources' `
            -Status 'fail' -Severity 'blocking' `
            -Detail 'The workspace reported no discovered resources. A scenario run against an empty scope succeeds without touching anything, which is indistinguishable from a resilient result.' `
            -Remediation 'Check the workspace scopes cover the resources you meant to study, then run az chaos workspace refresh-recommendation and re-scope.'
    }

    return New-ChaosReadinessGate -Id 'scope-populated' -Title 'Workspace scope contains resources' `
        -Status 'pass' -Severity 'blocking' `
        -Detail "The workspace reported $count discovered resource(s) in scope."
}

function Test-ChaosActionScopeFit {
    <#
    .SYNOPSIS
        Blocking: does the service report this action for a type in scope?

    .DESCRIPTION
        The answer comes from the action record the service returned, not from
        a local expectation about what the action ought to support. When no
        resource type in scope appears in the action's applicability list the
        run has nothing to act on, and finding that out here costs nothing.
    #>
    param(
        [Parameter(Mandatory)][object]$Action,
        [AllowNull()][AllowEmptyCollection()][string[]]$ScopedResourceTypes
    )

    $supported = @($Action.appliesTo | ForEach-Object { $_.resourceType })
    $inScope = @(@($ScopedResourceTypes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($inScope.Count -eq 0) {
        # An unverified action has no appliesTo list; appending an empty join
        # would print a dangling "for: ." and imply the service said nothing.
        $supportedText = if ($supported.Count -gt 0) { " The service reports this action for: $($supported -join ', ')." } else { '' }
        return New-ChaosReadinessGate -Id 'action-scope-fit' -Title 'Action applies to a resource in scope' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail "No resource type could be read from the workspace scope, so its fit with action '$($Action.name)' is unverified.$supportedText" `
            -LimitationCode 'L10'
    }

    $overlap = @($inScope | Where-Object { $supported -contains $_ })
    if ($overlap.Count -eq 0) {
        return New-ChaosReadinessGate -Id 'action-scope-fit' -Title 'Action applies to a resource in scope' `
            -Status 'fail' -Severity 'blocking' `
            -Detail "Chaos Studio reports action '$($Action.name)' for $($supported -join ', '), none of which are in scope ($($inScope -join ', ')). The run would act on nothing." `
            -Remediation 'Run scoping with -ListActions to see the actions the service reports for the resource types this workspace discovered.'
    }

    return New-ChaosReadinessGate -Id 'action-scope-fit' -Title 'Action applies to a resource in scope' `
        -Status 'pass' -Severity 'blocking' `
        -Detail "The service reports action '$($Action.name)' for $($overlap -join ', '), which is in scope."
}

function Test-ChaosActionParameterFit {
    <#
    .SYNOPSIS
        Blocking: do the supplied parameters satisfy the action's live schema?
    #>
    param(
        [Parameter(Mandatory)][object]$Action,
        [AllowNull()][object]$Parameters
    )

    $schema = $Action.parametersSchema
    if ($null -eq $schema) {
        return New-ChaosReadinessGate -Id 'action-parameters' -Title 'Action parameters match the service schema' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail "Chaos Studio returned no parameter schema for action '$($Action.name)', so the supplied parameters could not be checked before injection." `
            -LimitationCode 'L10'
    }

    $problems = ConvertTo-ChaosList (Test-ChaosActionParameters -Schema $schema -Parameters $Parameters)
    if ($problems.Count -gt 0) {
        return New-ChaosReadinessGate -Id 'action-parameters' -Title 'Action parameters match the service schema' `
            -Status 'fail' -Severity 'blocking' `
            -Detail ($problems -join ' ') `
            -Remediation 'Run scoping with -ListActions to print this action''s parameter schema, then supply -Parameters accordingly.'
    }

    $specs = ConvertTo-ChaosList (Get-ChaosActionParameterSpec -Schema $schema)
    $requiredNames = @($specs | Where-Object { $_.required } | ForEach-Object { $_.name })
    $detail = if ($requiredNames.Count -gt 0) {
        "All required parameters supplied: $($requiredNames -join ', ')."
    } else {
        'This action declares no required parameters.'
    }

    return New-ChaosReadinessGate -Id 'action-parameters' -Title 'Action parameters match the service schema' `
        -Status 'pass' -Severity 'blocking' -Detail $detail
}

function Test-ChaosObservabilityCoverage {
    <#
    .SYNOPSIS
        Blocking: can a signal prove the fault landed and enforce live abort?
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AvailableSources,
        [AllowNull()][object]$SteadyState = $null
    )

    if (@($AvailableSources).Count -eq 0) {
        return New-ChaosReadinessGate -Id 'observability' -Title 'A signal can prove the fault landed' `
            -Status 'fail' -Severity 'blocking' `
            -Detail 'No signal source was configured. The steady-state predicate and telemetry-loss abort condition could not be evaluated during injection, so the safety contract would not be enforceable.' `
            -Remediation 'Re-run with -SignalSource "metrics:<metricName>" or -SignalSource "logs:<workspaceId>#<kql>".' `
            -LimitationCode 'L3'
    }

    # A predicate naming a signal that nothing collects is the quietest way for
    # a study to be useless: it runs, it reports, and the objective is simply
    # never evaluated. That is caught here rather than discovered in the report.
    if ($null -ne $SteadyState) {
        $signal = [string]$SteadyState.signal
        $matched = @($AvailableSources | Where-Object {
                $_ -eq $signal -or $_ -like "*:$signal" -or $_ -like "*:$signal#*"
            })
        if ($matched.Count -eq 0) {
            return New-ChaosReadinessGate -Id 'observability' -Title 'A signal can prove the fault landed' `
                -Status 'fail' -Severity 'blocking' `
                -Detail "The steady-state objective is about '$signal', but no configured signal source produces it (configured: $($AvailableSources -join ', ')). The study would run to completion and never evaluate its own objective." `
                -Remediation "Name the source after the signal the objective uses, for example -SignalSource 'metrics:$signal', or restate the objective in terms of a signal that is collected." `
                -LimitationCode 'L2'
        }
    }

    return New-ChaosReadinessGate -Id 'observability' -Title 'A signal can prove the fault landed' `
        -Status 'pass' -Severity 'advisory' `
        -Detail "Signal sources: $($AvailableSources -join ', ')."
}

function Test-ChaosActionReversibility {
    <#
    .SYNOPSIS
        Advisory: can this action be stopped once it has started?

    .DESCRIPTION
        The service classifies actions as Cancelable, Continuous or Discrete.
        A discrete action completes on its own and cannot be called back, so
        the injection window is a description of what happened rather than a
        bound on it. That changes how much blast radius is acceptable, and the
        operator should be told before consenting, not after.
    #>
    param([Parameter(Mandatory)][object]$Action)

    $type = [string]$Action.actionType

    if ([string]::IsNullOrWhiteSpace($type)) {
        return New-ChaosReadinessGate -Id 'reversibility' -Title 'Injection can be stopped early' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail "Chaos Studio did not report an action type for '$($Action.name)', so whether the fault can be cancelled mid-window is unknown." `
            -LimitationCode 'L10'
    }

    if ($type -ieq 'Discrete') {
        return New-ChaosReadinessGate -Id 'reversibility' -Title 'Injection can be stopped early' `
            -Status 'fail' -Severity 'advisory' `
            -Detail "Action '$($Action.name)' is Discrete: it runs to completion and cannot be cancelled once started. Cancelling the scenario run stops the next action, not this one, so the blast radius is set entirely by the parameters and the configured filters." `
            -Remediation 'Confirm the parameters bound the impact acceptably before consenting; there is no abort once injection begins.' `
            -LimitationCode 'L6'
    }

    return New-ChaosReadinessGate -Id 'reversibility' -Title 'Injection can be stopped early' `
        -Status 'pass' -Severity 'advisory' `
        -Detail "Action '$($Action.name)' is $type, so cancelling the scenario run stops the fault."
}

function Test-ChaosInjectionWindow {
    <#
    .SYNOPSIS
        Advisory: is the window long enough to observe anything?
    #>
    param([Parameter(Mandatory)][int]$InjectMinutes)

    if ($InjectMinutes -le 3) {
        return New-ChaosReadinessGate -Id 'injection-window' -Title 'Injection window is long enough to observe' `
            -Status 'fail' -Severity 'advisory' `
            -Detail "The injection window is $InjectMinutes minute(s). Metric ingestion and aggregation commonly lag by more than that, so a clean result may mean the window closed before the effect became visible." `
            -Remediation 'Re-run with -DurationMinutes 10 or longer.' `
            -LimitationCode 'L7'
    }

    return New-ChaosReadinessGate -Id 'injection-window' -Title 'Injection window is long enough to observe' `
        -Status 'pass' -Severity 'advisory' `
        -Detail "Injection window: $InjectMinutes minutes."
}

function Invoke-ChaosReadinessGates {
    <#
    .SYNOPSIS
        Run every gate and return the collected verdict.
    #>
    param(
        [Parameter(Mandatory)][object]$Action,
        [AllowNull()][AllowEmptyCollection()][string[]]$ScopedResourceTypes,
        [AllowNull()][AllowEmptyCollection()][object[]]$ScopedResources,
        [AllowNull()][object]$Parameters,
        [AllowNull()][object]$SteadyState,
        [Parameter(Mandatory)][int]$InjectMinutes,
        [AllowEmptyCollection()][string[]]$AvailableSources = @(),
        [switch]$DiscoverySkipped
    )

    $gates = @(
        Test-ChaosSteadyStatePredicate -Predicate $SteadyState
        Test-ChaosScopePopulated -ScopedResources $ScopedResources -DiscoverySkipped:$DiscoverySkipped
        Test-ChaosActionScopeFit -Action $Action -ScopedResourceTypes $ScopedResourceTypes
        Test-ChaosActionParameterFit -Action $Action -Parameters $Parameters
        Test-ChaosActionReversibility -Action $Action
        Test-ChaosInjectionWindow -InjectMinutes $InjectMinutes
        Test-ChaosObservabilityCoverage -AvailableSources $AvailableSources -SteadyState $SteadyState
    )

    $blockingFailures = @($gates | Where-Object { $_.severity -eq 'blocking' -and $_.status -eq 'fail' })
    $limitations = @($gates | Where-Object { $_.status -ne 'pass' -and $_.limitationCode } | ForEach-Object { $_.limitationCode } | Select-Object -Unique)

    return [pscustomobject]@{
        gates            = $gates
        ready            = ($blockingFailures.Count -eq 0)
        blockingFailures = $blockingFailures
        limitationCodes  = $limitations
    }
}

function Assert-ChaosReadiness {
    <#
    .SYNOPSIS
        Fail loudly with exit code 10 when a blocking gate failed.
    #>
    param([Parameter(Mandatory)][object]$Readiness)

    if ($Readiness.ready) { return }

    $lines = $Readiness.blockingFailures | ForEach-Object { "  - [$($_.id)] $($_.detail)" }
    $remediation = ($Readiness.blockingFailures | Where-Object { $_.remediation } | Select-Object -First 1).remediation

    Write-ChaosStudyFailure -Title 'Study preconditions not met' `
        -Message ("This study would not produce an interpretable result:`n" + ($lines -join "`n") + "`n`nScoping stopped before writing a study plan.") `
        -Remediation $remediation

    exit (Get-ChaosStudyExitCode -Name 'ReadinessFailed')
}
