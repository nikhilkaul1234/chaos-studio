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
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ExecutionPlan.ps1')
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
        Advisory: is any signal source configured that could prove the fault
        landed?
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AvailableSources,
        [AllowNull()][object]$SteadyState = $null
    )

    if (@($AvailableSources).Count -eq 0) {
        return New-ChaosReadinessGate -Id 'observability' -Title 'A signal can prove the fault landed' `
            -Status 'fail' -Severity 'blocking' `
            -Detail 'No signal source was configured. Automatic signal-based abort cannot operate without telemetry, so this study cannot run.' `
            -Remediation 'Re-run with -SignalSource "metrics:<metricName>" or -SignalSource "logs:<workspaceId>#<kql>".' `
            -LimitationCode 'L3'
    }

    # A predicate naming a signal that nothing collects is the quietest way for
    # a study to be useless: it runs, it reports, and the objective is simply
    # never evaluated. That is caught here rather than discovered in the report.
    if ($null -ne $SteadyState) {
        $signal = [string]$SteadyState.signal
        $matched = @($AvailableSources | Where-Object {
                $_ -eq $signal -or $_ -like "metrics:$signal" -or $_ -like "metrics:$signal@*" -or $_ -like "metrics:$signal|*" -or $_ -like "logs:*#$signal*"
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

function Test-ChaosMechanismTraceable {
    <#
    .SYNOPSIS
        Blocking: is there a falsifiable, traceable mechanism behind this study?

    .DESCRIPTION
        A study that cannot say *how* the action would breach the steady state
        is a guess dressed as an experiment. Three inputs make the claim
        falsifiable and reviewable, and all three must be present and traceable
        before the plan is written:

          failureMechanism    the action's effect, the code or dependency
                              failure it provokes, and how that reaches the
                              predicate
          mechanismEvidence   a concrete reference (file, symbol, architecture)
                              that anchors the mechanism in the real system
          mechanismProbe      the exact signal that proves the mechanism landed,
                              the direction it should move, and the resource it
                              must resolve to

        Traceability is what this gate can check by script: the probe's signal
        must be one the study actually collects, and its resourceCorrelation
        must resolve to a resource in scope. Truthfulness - whether the stated
        mechanism is the real one - is the agent's and code review's
        responsibility, which is exactly why mechanismEvidence must cite
        something a reviewer can open.

        A gap here is blocking, not advisory: without a traceable mechanism the
        report's mechanismProven can only ever be an accident of correlation.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$FailureMechanism,
        [AllowNull()][AllowEmptyString()][string]$MechanismEvidence,
        [AllowNull()][object]$MechanismProbe,
        [AllowEmptyCollection()][string[]]$AvailableSources = @(),
        [AllowNull()][AllowEmptyCollection()][string[]]$ScopedResourceIds = @()
    )

    $problems = @()

    if ([string]::IsNullOrWhiteSpace($FailureMechanism)) {
        $problems += 'no failureMechanism was stated, so the study cannot say how the action would breach the steady state'
    }
    if ([string]::IsNullOrWhiteSpace($MechanismEvidence)) {
        $problems += 'no mechanismEvidence was cited, so the mechanism is not anchored to anything a reviewer can open'
    }

    if ($null -eq $MechanismProbe) {
        $problems += 'no mechanismProbe was supplied, so nothing was named that would prove the mechanism reached the system'
    }
    else {
        $signal = if ($MechanismProbe.PSObject.Properties.Name -contains 'signal') { [string]$MechanismProbe.signal } else { '' }
        $query = if ($MechanismProbe.PSObject.Properties.Name -contains 'query') { [string]$MechanismProbe.query } else { '' }
        $direction = if ($MechanismProbe.PSObject.Properties.Name -contains 'expectedDirection') { [string]$MechanismProbe.expectedDirection } else { '' }
        $correlation = if ($MechanismProbe.PSObject.Properties.Name -contains 'resourceCorrelation') { [string]$MechanismProbe.resourceCorrelation } else { '' }

        if ([string]::IsNullOrWhiteSpace($signal) -and [string]::IsNullOrWhiteSpace($query)) {
            $problems += 'the mechanismProbe names neither a signal nor a query, so there is nothing to measure'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($signal)) {
            # The probe's own signal has to be one the study actually collects,
            # otherwise the proof step would have no series to read.
            $matched = @($AvailableSources | Where-Object {
                    $_ -eq $signal -or $_ -like "*:$signal" -or $_ -like "*:$signal#*"
                })
            if ($matched.Count -eq 0) {
                $sourceList = if (@($AvailableSources).Count -gt 0) { $AvailableSources -join ', ' } else { 'none' }
                $problems += "the mechanismProbe signal '$signal' is not among the configured signal sources ($sourceList), so it is untraceable"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($query)) {
            # A query-based probe may name its workspace as
            # 'logs:<workspaceId>#<kql>'. When it does, a configured source for
            # THAT workspace must exist - a logs source for a different
            # workspace does not make this probe traceable. Without a workspace
            # prefix, any logs source is enough to run the query against.
            $probeWorkspaceId = $null
            if ($query -like 'logs:*') {
                $probeRest = $query.Substring('logs:'.Length)
                if ($probeRest.Contains('#')) {
                    $probeWsPart = $probeRest.Split('#', 2)[0]
                    if (-not [string]::IsNullOrWhiteSpace($probeWsPart)) { $probeWorkspaceId = $probeWsPart.Trim() }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($probeWorkspaceId)) {
                $matchedWs = @($AvailableSources | Where-Object {
                        $_ -eq "logs:$probeWorkspaceId" -or $_ -like "logs:$probeWorkspaceId#*"
                    })
                if ($matchedWs.Count -eq 0) {
                    $sourceList = if (@($AvailableSources).Count -gt 0) { $AvailableSources -join ', ' } else { 'none' }
                    $problems += "the mechanismProbe query targets workspace '$probeWorkspaceId' but no matching logs: signal source is configured ($sourceList), so it is untraceable"
                }
            }
            else {
                $hasLogSource = @($AvailableSources | Where-Object { $_ -like 'logs:*' }).Count -gt 0
                if (-not $hasLogSource) {
                    $problems += 'the mechanismProbe uses a query but no logs: signal source is configured for it to run against, so it is untraceable'
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($direction)) {
            $problems += 'the mechanismProbe has no expectedDirection, so its movement cannot be judged for or against the mechanism'
        }

        if ([string]::IsNullOrWhiteSpace($correlation)) {
            $problems += 'the mechanismProbe has no resourceCorrelation, so a movement could not be tied to the resource under study'
        }
        else {
            # When discovery ran, the correlated resource must be one in scope.
            # When it was skipped the scope is unknown, not empty, so presence is
            # all that can be checked - resolution is deferred rather than faked.
            $ids = @(@($ScopedResourceIds) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($ids.Count -gt 0) {
                $resolves = @($ids | Where-Object { $_ -eq $correlation -or $_ -like "*$correlation" -or $correlation -like "*$_" })
                if ($resolves.Count -eq 0) {
                    $problems += "the mechanismProbe resourceCorrelation '$correlation' does not resolve to any resource in scope, so it is untraceable"
                }
            }
        }
    }

    if ($problems.Count -gt 0) {
        return New-ChaosReadinessGate -Id 'mechanism-traceable' -Title 'The failure mechanism is stated and traceable' `
            -Status 'fail' -Severity 'blocking' `
            -Detail ('A falsifiable study needs a traceable mechanism, but ' + ($problems -join '; ') + '.') `
            -Remediation 'Re-run scoping with -FailureMechanism, -MechanismEvidence, and a -MechanismProbe whose signal is one of -SignalSource and whose resourceCorrelation is a resource in scope. Read the application code and runtime topology first; the evidence reference must cite something a reviewer can open.'
    }

    return New-ChaosReadinessGate -Id 'mechanism-traceable' -Title 'The failure mechanism is stated and traceable' `
        -Status 'pass' -Severity 'blocking' `
        -Detail "Mechanism stated and its probe ($(if ($MechanismProbe.signal) { $MechanismProbe.signal } else { 'query' }), expected to $($MechanismProbe.expectedDirection)) traces to a configured signal and a scoped resource. Truthfulness of the mechanism remains the agent's and reviewer's responsibility."
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
        [AllowNull()][AllowEmptyString()][string]$FailureMechanism = $null,
        [AllowNull()][AllowEmptyString()][string]$MechanismEvidence = $null,
        [AllowNull()][object]$MechanismProbe = $null,
        [AllowNull()][object]$ExerciseModel = $null,
        [switch]$AcceptWeakExercise,
        [switch]$DiscoverySkipped
    )

    $scopedResourceIds = @(@($ScopedResources) | Where-Object { $_ } | ForEach-Object {
            if ($_ -is [string]) { $_ }
            elseif ($_.PSObject.Properties.Name -contains 'resourceId') { [string]$_.resourceId }
            else { [string]$_ }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $gates = @(
        Test-ChaosSteadyStatePredicate -Predicate $SteadyState
        Test-ChaosScopePopulated -ScopedResources $ScopedResources -DiscoverySkipped:$DiscoverySkipped
        Test-ChaosActionScopeFit -Action $Action -ScopedResourceTypes $ScopedResourceTypes
        Test-ChaosActionParameterFit -Action $Action -Parameters $Parameters
        Test-ChaosMechanismTraceable -FailureMechanism $FailureMechanism -MechanismEvidence $MechanismEvidence `
            -MechanismProbe $MechanismProbe -AvailableSources $AvailableSources -ScopedResourceIds $scopedResourceIds
        Test-ChaosActionReversibility -Action $Action
        Test-ChaosInjectionWindow -InjectMinutes $InjectMinutes
        Test-ChaosObservabilityCoverage -AvailableSources $AvailableSources -SteadyState $SteadyState
        Test-ChaosExerciseSufficient -Model $ExerciseModel -Accepted:$AcceptWeakExercise
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
        Fail loudly when a blocking gate failed.

    .DESCRIPTION
        Most blocking failures are readiness failures (exit 10). Insufficient
        exposure gets its own exit code (21) because it is a different kind of
        problem with a different fix: the study is well-formed, it simply would
        not exercise anything, and the caller needs to change load or window
        rather than change the plan.
    #>
    param([Parameter(Mandatory)][object]$Readiness)

    if ($Readiness.ready) { return }

    $lines = $Readiness.blockingFailures | ForEach-Object { "  - [$($_.id)] $($_.detail)" }
    $remediation = ($Readiness.blockingFailures | Where-Object { $_.remediation } | Select-Object -First 1).remediation

    $exposureOnly = (@($Readiness.blockingFailures | Where-Object { $_.id -ne 'exercise-sufficient' }).Count -eq 0)
    $exitName = if ($exposureOnly) { 'InsufficientExposure' } else { 'ReadinessFailed' }

    Write-ChaosStudyFailure -Title 'Study preconditions not met' `
        -Message ("This study would not produce an interpretable result:`n" + ($lines -join "`n") + "`n`nScoping stopped before writing a study plan.") `
        -Remediation $remediation

    exit (Get-ChaosStudyExitCode -Name $exitName)
}

# -- Effective legs (declared vs effective, Req C) -------------------------
#
# A scenario declares what it would do; a validated configuration's execution
# plan is what the platform will actually run. Those two can diverge - a filter
# excludes a resource, an action does not apply to a target, a permission is
# missing - and when they do, the scenario's name and the study's conclusion
# can both overstate what was exercised. These helpers turn the execution plan
# into a declared-vs-effective leg model that later gates and the plan freeze
# can reason about, never inventing a leg the platform did not report.

function Resolve-ChaosEffectiveLegs {
    <#
    .SYNOPSIS
        Turn a preflight execution plan into the declared-vs-effective leg model
        `{ total, executable, skipped[]{legSelector, action, resourceSelector, reason} }`.

    .DESCRIPTION
        `total` is every leg the plan describes; `executable` is the count that
        will actually run; `skipped` names each leg that will not, with the
        platform's own reason. The extra `executableSelectors` list is not
        persisted but lets the scenario-name honesty guard check what really
        runs. When no plan is available the model is total 0 / executable 0,
        which the effective-legs gate reads as an unexecutable scope.
    #>
    param([AllowNull()][object]$ExecutionPlan)

    $legs = @(Get-ChaosExecutionPlanLegs -ExecutionPlan $ExecutionPlan)
    $skipped = @()
    $executableSelectors = @()
    $executableZones = $null

    foreach ($leg in $legs) {
        $selector = Get-ChaosLegSelectorText -Leg $leg
        $action = [string](Get-ChaosLegField -Leg $leg -Names @('action', 'actionName', 'actionId', 'type'))
        if (Test-ChaosLegSkipped -Leg $leg) {
            $reason = [string](Get-ChaosLegField -Leg $leg -Names @('reason', 'skipReason', 'skippedReason', 'status', 'state'))
            $skipped += [pscustomobject]@{
                legSelector      = $selector
                action           = if ([string]::IsNullOrWhiteSpace($action)) { $null } else { $action }
                resourceSelector = $selector
                reason           = if ([string]::IsNullOrWhiteSpace($reason)) { 'no reason reported' } else { $reason }
            }
        } else {
            $executableSelectors += $selector
            if (($leg -is [System.Collections.IDictionary] -and $leg.Contains('targets')) -or $leg.PSObject.Properties.Name -contains 'targets') {
                if ($null -eq $executableZones) { $executableZones = @() }
                foreach ($target in @($leg.targets)) {
                    $metadata = Get-ChaosLegField -Leg $target -Names @('metadata')
                    $executableZones += @(Get-ChaosLegField -Leg $metadata -Names @('zones') | Where-Object { $_ })
                }
            }
        }
    }

    $total = @($legs).Count
    $executableCount = $total - @($skipped).Count

    return [pscustomobject]@{
        total               = $total
        executable          = $executableCount
        skipped             = @($skipped)
        executableSelectors = @($executableSelectors)
        executableZones     = $executableZones
    }
}

function Get-ChaosPartialScenarioPhrase {
    <#
    .SYNOPSIS
        The exact phrase an operator must type to accept a partial scenario.

    .DESCRIPTION
        The phrase carries the executable-of-total count and a short binding
        hash over the plan identity and effective legs, so it cannot be typed
        without reading the divergence, and cannot be reused for a different
        plan or a different set of skipped legs.
    #>
    param(
        [Parameter(Mandatory)][object]$EffectiveLegs,
        [Parameter(Mandatory)][string]$BindingHash
    )
    $short = if ($BindingHash.Length -ge 8) { $BindingHash.Substring(0, 8) } else { $BindingHash }
    return "accept partial scenario $($EffectiveLegs.executable) of $($EffectiveLegs.total) $short"
}

function Get-ChaosEffectiveLegsBindingHash {
    <#
    .SYNOPSIS
        A deterministic hash binding an acceptance phrase to the scope, scenario
        and exact effective legs it was shown for.
    #>
    param(
        [Parameter(Mandatory)][string]$ScopeHash,
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][object]$EffectiveLegs
    )
    $binding = [ordered]@{
        scopeHash  = $ScopeHash
        scenario   = $ScenarioName
        total      = $EffectiveLegs.total
        executable = $EffectiveLegs.executable
        skipped    = @(@($EffectiveLegs.skipped) | ForEach-Object { [string]$_.legSelector } | Sort-Object)
    }
    return Get-ChaosDigest -InputObject $binding
}

function Get-ChaosEffectiveLegsDecision {
    <#
    .SYNOPSIS
        Classify effective legs as all-executable, partial, or none, without any
        side effects, so the decision is testable in isolation.

    .DESCRIPTION
        Returns { kind = 'all'|'partial'|'none'; accepted; expectedPhrase;
        limitationCodes[] }. `none` (nothing executable) is unverifiable;
        `partial` is only accepted when the supplied phrase matches exactly
        (case-sensitive), and always carries L11.
    #>
    param(
        [Parameter(Mandatory)][object]$EffectiveLegs,
        [Parameter(Mandatory)][string]$BindingHash,
        [AllowNull()][AllowEmptyString()][string]$AcceptPartialScenario = $null
    )

    if ($EffectiveLegs.total -le 0 -or $EffectiveLegs.executable -le 0) {
        return [pscustomobject]@{ kind = 'none'; accepted = $false; expectedPhrase = $null; limitationCodes = @() }
    }

    if ($EffectiveLegs.executable -lt $EffectiveLegs.total) {
        $expected = Get-ChaosPartialScenarioPhrase -EffectiveLegs $EffectiveLegs -BindingHash $BindingHash
        $accepted = ($AcceptPartialScenario -and $AcceptPartialScenario.Trim() -ceq $expected)
        return [pscustomobject]@{
            kind            = 'partial'
            accepted        = [bool]$accepted
            expectedPhrase  = $expected
            limitationCodes = @('L11')
        }
    }

    return [pscustomobject]@{ kind = 'all'; accepted = $true; expectedPhrase = $null; limitationCodes = @() }
}

function Assert-ChaosEffectiveLegs {
    <#
    .SYNOPSIS
        Enforce the effective-legs decision: all-skipped stops with exit 14, a
        partial scenario is fail-closed unless the bound acceptance phrase is
        supplied. Returns the decision (with L11) when the study may proceed.

    .DESCRIPTION
        An unexecutable scope is unverifiable, so all-skipped reuses
        ScopeUnverified (14). A partial scenario would run fewer legs than its
        name implies, so it is refused (PartialScenarioUnaccepted, 20) until the
        operator types the phrase that names N-of-M and pins these exact legs.
    #>
    param(
        [Parameter(Mandatory)][object]$EffectiveLegs,
        [Parameter(Mandatory)][string]$ScopeHash,
        [Parameter(Mandatory)][string]$ScenarioName,
        [AllowNull()][AllowEmptyString()][string]$AcceptPartialScenario = $null,
        [scriptblock]$OnScopeUnverified
    )

    $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash $ScopeHash -ScenarioName $ScenarioName -EffectiveLegs $EffectiveLegs
    $decision = Get-ChaosEffectiveLegsDecision -EffectiveLegs $EffectiveLegs -BindingHash $binding -AcceptPartialScenario $AcceptPartialScenario

    if ($decision.kind -eq 'none') {
        Write-ChaosStudyFailure -Title 'Every leg of this scenario is skipped' -Message @"
The preflight configuration validated, but its execution plan runs 0 of
$($EffectiveLegs.total) leg(s). A scenario that executes nothing succeeds without
touching anything, which would read as resilience that was never tested.

$(Format-ChaosSkippedLegs -Skipped $EffectiveLegs.skipped)
"@ -Remediation 'Re-run chaos-study-scope with a wider scope, fewer exclusions, or an action that applies to the resources in scope.'
        if ($OnScopeUnverified) { & $OnScopeUnverified | Out-Null }
        exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
    }

    if ($decision.kind -eq 'partial' -and -not $decision.accepted) {
        $reason = if ([string]::IsNullOrWhiteSpace($AcceptPartialScenario)) {
            'No -AcceptPartialScenario phrase was supplied.'
        } else {
            'The -AcceptPartialScenario phrase did not match these exact legs (comparison is case-sensitive).'
        }
        Write-ChaosStudyFailure -Title "Partial scenario - $($EffectiveLegs.executable) of $($EffectiveLegs.total) legs will run" -Message @"
$reason

The preflight execution plan runs only $($EffectiveLegs.executable) of
$($EffectiveLegs.total) declared leg(s). The scenario named here would not be
fully exercised, so the study is stopped rather than reporting a conclusion that
overstates what ran.

Legs that will NOT run:
$(Format-ChaosSkippedLegs -Skipped $EffectiveLegs.skipped)

To proceed with the partial scenario anyway (this is recorded as limitation L11),
pass this phrase exactly:

  $($decision.expectedPhrase)
"@ -Remediation "-AcceptPartialScenario '$($decision.expectedPhrase)'"
        if ($OnScopeUnverified) { & $OnScopeUnverified | Out-Null }
        exit (Get-ChaosStudyExitCode -Name 'PartialScenarioUnaccepted')
    }

    return $decision
}

function Format-ChaosSkippedLegs {
    <#
    .SYNOPSIS
        Render skipped legs as operator-facing lines.
    #>
    param([AllowNull()][AllowEmptyCollection()][object[]]$Skipped)

    if ($null -eq $Skipped -or @($Skipped).Count -eq 0) { return '  (the platform named no skipped legs)' }
    return (@($Skipped) | ForEach-Object {
            $sel = if ([string]::IsNullOrWhiteSpace([string]$_.legSelector)) { '(unnamed leg)' } else { [string]$_.legSelector }
            $act = if ([string]::IsNullOrWhiteSpace([string]$_.action)) { '' } else { " [$($_.action)]" }
            "  - $sel$act`: $($_.reason)"
        }) -join "`n"
}

function Assert-ChaosScenarioNameHonest {
    <#
    .SYNOPSIS
        Block a scenario name that implies legs which will not run.

    .DESCRIPTION
        A name like "zone-1-down" claims a specific zone. If the executable legs
        contain no leg for that zone, the name overstates what the study
        exercises, so the resulting report would mislead. This guard checks the
        concrete, machine-readable claim - zone numbers named in the scenario or
        its display name - against the zones present in the executable legs, and
        stops (ScopeUnverified, 14) when a claimed zone is absent. Generic names
        with no zone number are left alone; truthfulness of the wider claim
        remains the agent's and reviewer's responsibility.
    #>
    param(
        [Parameter(Mandatory)][string]$ScenarioName,
        [AllowNull()][AllowEmptyString()][string]$DisplayName = $null,
        [Parameter(Mandatory)][object]$EffectiveLegs,
        [scriptblock]$OnScopeUnverified
    )

    $nameText = @($ScenarioName, $DisplayName) -join ' '
    $claimedZones = @([regex]::Matches($nameText, '(?i)zone[\s_-]?([0-9]+)') | ForEach-Object { $_.Groups[1].Value })
    $claimedZones += @([regex]::Matches($nameText, '(?i)\baz([0-9]+)\b') | ForEach-Object { $_.Groups[1].Value })
    $claimedZones = @($claimedZones | Where-Object { $_ } | Select-Object -Unique)
    if ($claimedZones.Count -eq 0) { return $true }

    if ($EffectiveLegs.PSObject.Properties.Name -contains 'executableZones' -and $null -ne $EffectiveLegs.executableZones) {
        $runnableZones = @($EffectiveLegs.executableZones)
    } else {
        # Legacy legs have no target set; retain their selector-based contract.
        $executableText = (@($EffectiveLegs.executableSelectors) -join ' ')
        $runnableZones = @([regex]::Matches($executableText, '(?i)zone[\s_-]?([0-9]+)') | ForEach-Object { $_.Groups[1].Value })
        $runnableZones += @([regex]::Matches($executableText, '(?i)\baz([0-9]+)\b') | ForEach-Object { $_.Groups[1].Value })
    }
    $runnableZones = @($runnableZones | Where-Object { $_ } | Select-Object -Unique)

    $missing = @($claimedZones | Where-Object { $runnableZones -notcontains $_ })
    if ($missing.Count -eq 0) { return $true }

    Write-ChaosStudyFailure -Title 'Scenario name claims a zone that will not run' -Message @"
The scenario name '$ScenarioName' names zone(s) $($missing -join ', '), but the
preflight execution plan has no executable leg for $(if ($missing.Count -gt 1) { 'those zones' } else { 'that zone' }).
Running it would produce a report whose title overstates what was exercised, so
scoping stops here.

Executable legs cover zone(s): $(if ($runnableZones.Count -gt 0) { $runnableZones -join ', ' } else { '(none identifiable)' }).
"@ -Remediation 'Choose a scenario whose name matches the zones actually in scope, or widen the scope so the named zone has an executable leg.'
    if ($OnScopeUnverified) { & $OnScopeUnverified | Out-Null }
    exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
}
