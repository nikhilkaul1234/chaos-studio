#Requires -Version 7.0
<#
.SYNOPSIS
    Turn evidence into findings. Pure logic, no side effects.

.DESCRIPTION
    Every function here is a pure function of its arguments. No file access, no
    network, no clock, no `az`. That is deliberate: interpretation is the part
    of the pipeline most likely to be wrong, and the only way to argue about it
    is to be able to run it on fixed inputs and get a fixed answer.

    Two rules do most of the work.

    A control-plane success is not proof. Chaos Studio reporting a scenario run
    as Succeeded means the action was accepted and dispatched, not that it
    reached the data plane. Only a data-plane signal that actually moved can set
    mechanismProven, and without it the verdict is Inconclusive rather than a
    pass.

    A gap is not a zero. A signal that could not be read is null with a caveat,
    and it lowers confidence instead of quietly becoming a healthy number.
#>

Set-StrictMode -Version Latest

$script:ChaosLimitationText = [ordered]@{
    L1 = 'Scope - this study covers one action, one workspace scope and one window'
    L2 = 'Observability coverage - at least one signal source was unavailable'
    L3 = 'Mechanism unproven - the control plane accepted the action but no data-plane signal confirmed it landed'
    L4 = 'Sampling resolution - metric granularity is coarser than the injection window'
    L5 = 'Environment - conditions were not representative of production load'
    L6 = 'Concurrency - other activity during the window could confound the result'
    L7 = 'Duration - the window may be too short to observe slow failure modes'
    L8 = 'Aborted - the run stopped before the planned window completed'
    L9 = 'Configuration drift - the scope changed between planning and execution'
    L10 = 'Discovery unverified - action metadata was not confirmed against the live Chaos Studio action list'
}

function Get-ChaosLimitationText {
    param([Parameter(Mandatory)][string]$Code)
    if ($script:ChaosLimitationText.Contains($Code)) { return $script:ChaosLimitationText[$Code] }
    return $Code
}

function Get-ChaosSignalValue {
    <#
    .SYNOPSIS
        Pull one named measurement out of a collected signal, or $null.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Signal,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Signal -or $null -eq $Signal.values) { return $null }
    $map = Get-ChaosSignalValueMap -Signal $Signal
    if (-not $map.Contains($Name)) { return $null }
    return $map[$Name]
}

function Get-ChaosImpactDelta {
    <#
    .SYNOPSIS
        Did any measured signal actually move between two windows?

    .DESCRIPTION
        This is the proof that the fault reached the system rather than being
        accepted by the API and quietly doing nothing. It is deliberately
        resource-agnostic: the study compares the numbers it was told to
        collect, whatever they are, and reports movement in the operator's own
        terms.

        A signal has "moved" when a numeric value it reported in the baseline
        window differs during injection. No threshold is applied here - the
        question is only whether the system noticed, not whether it suffered.
    #>
    param(
        [AllowNull()][object[]]$Before,
        [AllowNull()][object[]]$During
    )

    $beforeSignals = @(@($Before) | Where-Object { $null -ne $_ })
    $duringSignals = @(@($During) | Where-Object { $null -ne $_ })
    $measuredDuring = @($duringSignals | Where-Object { $null -ne $_.values })

    if ($measuredDuring.Count -eq 0) {
        return [pscustomobject]@{ moved = $null; detail = 'No signal was measured during injection, so there is nothing to compare.' }
    }

    $movements = @()
    # These loop variables must not reuse the parameter names: $Before/$During
    # are constrained to [object[]], and PowerShell re-applies that constraint on
    # every assignment - so a single signal assigned to $during would be silently
    # re-wrapped into an array and read as a time series of signal objects,
    # making the movement check unable to ever fire.
    foreach ($duringSignal in $measuredDuring) {
        $baseline = @($beforeSignals | Where-Object { $_.source -eq $duringSignal.source })
        if ($baseline.Count -eq 0 -or $null -eq $baseline[0].values) { continue }

        $names = @((Get-ChaosSignalValueMap -Signal $duringSignal).Keys)
        foreach ($name in $names) {
            $b = Get-ChaosSignalValue -Signal $baseline[0] -Name $name
            $d = Get-ChaosSignalValue -Signal $duringSignal -Name $name
            if ($null -eq $b -or $null -eq $d) { continue }

            $bNum = 0.0
            $dNum = 0.0
            if (-not [double]::TryParse([string]$b, [ref]$bNum)) { continue }
            if (-not [double]::TryParse([string]$d, [ref]$dNum)) { continue }
            if ($bNum -eq $dNum) { continue }

            $direction = if ($dNum -lt $bNum) { 'fell' } else { 'rose' }
            $movements += "$($duringSignal.source).$name $direction from $b to $d"
        }
    }

    if ($movements.Count -gt 0) {
        return [pscustomobject]@{ moved = $true; detail = ($movements -join '; ') }
    }

    $comparable = @($measuredDuring | Where-Object { $s = $_; @($beforeSignals | Where-Object { $_.source -eq $s.source -and $null -ne $_.values }).Count -gt 0 })
    if ($comparable.Count -eq 0) {
        return [pscustomobject]@{
            moved  = $null
            detail = 'Signals were measured during injection but not in the baseline window, so no comparison is possible.'
        }
    }

    return [pscustomobject]@{
        moved  = $false
        detail = 'No measured signal changed between the baseline and injection windows.'
    }
}

function New-ChaosFinding {
    <#
    .SYNOPSIS
        Build one finding. Evidence is mandatory - a finding without evidence is
        an opinion, and opinions do not go in the report.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('critical', 'high', 'medium', 'low')][string]$Severity,
        [Parameter(Mandatory)][ValidateSet('high', 'medium', 'low')][string]$Confidence,
        [Parameter(Mandatory)][string]$Observation,
        [Parameter(Mandatory)][string]$Interpretation,
        [Parameter(Mandatory)][object[]]$Evidence,
        [string[]]$Remediation = @()
    )
    if (@($Evidence).Count -eq 0) {
        throw "Finding '$Key' has no evidence reference. Findings must cite the signal and window they rest on."
    }
    return [ordered]@{
        findingKey     = $Key
        title          = $Title
        severity       = $Severity
        confidence     = $Confidence
        observation    = $Observation
        interpretation = $Interpretation
        evidence       = @($Evidence)
        remediation    = @($Remediation)
    }
}

function Get-ChaosFindingKey {
    <#
    .SYNOPSIS
        A stable identity for a finding, so the same issue matches across runs
        even when its wording changes.

    .DESCRIPTION
        The action URN is the preferred identity because it is what the service
        itself calls the action. It is not always available - a plan scoped with
        discovery skipped never learned it - so the key falls back to whatever
        identity the plan does carry rather than refusing to build a key at all.
        An unidentifiable action still gets a deterministic key, so findings
        remain comparable within a study even when they cannot be matched to
        another study's action.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ActionUrn,
        [Parameter(Mandatory)][string]$Signal,
        [Parameter(Mandatory)][string]$Predicate
    )
    $identity = if ([string]::IsNullOrWhiteSpace($ActionUrn)) { 'action-unidentified' } else { $ActionUrn }
    return Get-ChaosDigest -InputObject @($identity, $Signal, $Predicate)
}

function Get-ChaosVerdict {
    <#
    .SYNOPSIS
        One sentence a reader can quote.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][AllowNull()][object]$MechanismProven,
        [AllowNull()][object]$PredicateMeasured,
        [AllowNull()][object]$RecoveryMeasured,
        [AllowNull()][object]$Abort
    )
    $severities = @($Findings | ForEach-Object { $_.severity })
    if ($severities -contains 'critical') { return 'Steady state breached' }
    if ($null -ne $Abort -and $Abort.triggered -eq $true -and [string]$Abort.kind -eq 'missing-signal') {
        return 'Inconclusive'
    }
    if ($MechanismProven -ne $true) { return 'Inconclusive' }
    if ($null -eq $PredicateMeasured -or $null -eq $RecoveryMeasured) { return 'Inconclusive' }
    if ($severities -contains 'high' -or $severities -contains 'medium') { return 'Degraded but recovered' }
    return 'Steady state held'
}

function Build-StudyFindings {
    <#
    .SYNOPSIS
        Interpret one study. Pure: same inputs, same output, always.

    .PARAMETER Plan
        The frozen study plan.

    .PARAMETER RunRecord
        The run record produced by chaos-study-run.

    .PARAMETER Evidence
        A hashtable with pre / during / post keys, each an array of signal
        results.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$RunRecord,
        [Parameter(Mandatory)][object]$Evidence
    )

    $pre = @($Evidence.pre)
    $during = @($Evidence.during)
    $post = @($Evidence.post)

    $delta = Get-ChaosImpactDelta -Before $pre -During $during
    $mechanismProven = $delta.moved -eq $true

    $predicate = $Plan.question.steadyState
    $signalName = [string]$predicate.signal

    $findByName = {
        param($set)
        $match = @($set) | Where-Object { $_.source -eq "metrics:$signalName" -or $_.source -eq $signalName } | Select-Object -First 1
        if ($match) { return $match }
        return $null
    }

    # A collector reports either a named column or a time series. Scoping has
    # already refused to plan a study whose objective no source produces, so the
    # only question here is which key carries the number: the signal's own name
    # for a named column, or the series' final reading.
    $readPredicateValue = {
        param($signal)
        if ($null -eq $signal) { return $null }
        foreach ($candidate in @($signalName, 'value', 'last', 'mean')) {
            $value = Get-ChaosSignalValue -Signal $signal -Name $candidate
            if ($null -ne $value) { return $value }
        }
        return $null
    }

    $predicateDuring = Test-ChaosPredicate -Predicate $predicate -Value (& $readPredicateValue (& $findByName $during))
    $predicatePost = Test-ChaosPredicate -Predicate $predicate -Value (& $readPredicateValue (& $findByName $post))

    $findings = @()
    $limitations = @('L1')

    # Prefer the URN the service assigned; fall back to the plan's action name so
    # a discovery-skipped study still produces stable, comparable finding keys.
    $actionIdentity = if ([string]::IsNullOrWhiteSpace($Plan.action.canonicalId)) { [string]$Plan.action.name } else { [string]$Plan.action.canonicalId }

    $predicateKey = Get-ChaosFindingKey -ActionUrn $actionIdentity -Signal $signalName -Predicate $predicate.raw

    if ($predicateDuring -eq $false) {
        # Severity is a function of recovery, not of how bad it looked at peak.
        $severity = if ($predicatePost -eq $false) { 'critical' } elseif ($null -eq $predicatePost) { 'high' } else { 'medium' }
        $recovery = switch ($predicatePost) {
            $true   { 'The predicate held again after injection stopped.' }
            $false  { 'The predicate was still breached after the recovery window, so the system did not self-heal.' }
            default { 'Recovery could not be confirmed because the signal was unavailable after injection.' }
        }
        $findings += New-ChaosFinding -Key $predicateKey `
            -Title "Steady state breached: $($predicate.raw)" `
            -Severity $severity -Confidence $(if ($mechanismProven) { 'high' } else { 'medium' }) `
            -Observation "During injection, $signalName violated '$($predicate.raw)'." `
            -Interpretation "The fault produced user-visible degradation. $recovery" `
            -Evidence @(
                [ordered]@{ signal = $signalName; window = 'during'; kind = 'predicate' }
                [ordered]@{ signal = $signalName; window = 'post'; kind = 'predicate' }
            ) `
            -Remediation @(
                "Bound the blast radius of this failure mode across the $($Plan.scope.projectedResourceCount) resource(s) in scope - add redundancy, spread the workload across zones, or add a circuit breaker on the dependency the action interrupted."
                'Add an alert on this predicate so the same degradation is detected without a chaos study.'
            )
    } elseif ($null -eq $predicateDuring) {
        $limitations += 'L2'
        $findings += New-ChaosFinding -Key $predicateKey `
            -Title "Steady state could not be evaluated: $($predicate.raw)" `
            -Severity 'medium' -Confidence 'low' `
            -Observation "No measurement of $signalName was available for the injection window." `
            -Interpretation 'The study cannot say whether the service held, because the signal that defines "held" was not being collected. This is a gap in observability, not a clean result.' `
            -Evidence @([ordered]@{ signal = $signalName; window = 'during'; kind = 'missing' }) `
            -Remediation @(
                "Instrument $signalName and make it queryable before repeating this study - a resilience test without its steady-state signal cannot pass or fail."
            )
    }

    if (-not $mechanismProven) {
        $limitations += 'L3'
        $evidenceRef = @([ordered]@{ signal = 'all-sources'; window = 'during'; kind = 'mechanism' })
        $findings += New-ChaosFinding -Key (Get-ChaosFindingKey -ActionUrn $actionIdentity -Signal 'mechanism' -Predicate 'impact-proof') `
            -Title 'Injection was not proven to reach the system' `
            -Severity 'low' -Confidence $(if ($null -eq $delta.moved) { 'low' } else { 'medium' }) `
            -Observation $delta.detail `
            -Interpretation 'Chaos Studio reporting a successful scenario run means the control plane accepted and dispatched the action. Without a signal that moved, a clean result may mean the service is resilient - or that nothing was ever injected. These are not the same, and this study cannot tell them apart.' `
            -Evidence $evidenceRef `
            -Remediation @(
                'Add a signal that would be expected to move under this action, so a clean result can be distinguished from an injection that never landed.'
                "Confirm '$($Plan.action.canonicalId)' is still offered for the resource types in this workspace scope, then repeat the study."
                'Widen the blast radius within the bounds the action allows, so the effect is large enough to observe.'
            )
    }

    $abort = $null
    if ($RunRecord.scenarioRun.PSObject.Properties.Name -contains 'abort') {
        $abort = $RunRecord.scenarioRun.abort
    }
    if ($null -ne $abort -and $abort.triggered -eq $true) {
        $limitations += 'L8'
        $abortSignal = if ([string]::IsNullOrWhiteSpace([string]$abort.source)) { 'all-sources' } else { [string]$abort.source }
        $findings += New-ChaosFinding -Key (Get-ChaosFindingKey -ActionUrn $actionIdentity -Signal $abortSignal -Predicate "abort:$($abort.conditionId)") `
            -Title "Automatic abort triggered: $($abort.conditionId)" `
            -Severity 'low' -Confidence 'high' `
            -Observation "The frozen abort condition tripped at $($abort.observedAt): $($abort.reason)" `
            -Interpretation 'The suite requested cancellation through the Chaos Studio scenario-run cancel operation instead of allowing the injection window to continue.' `
            -Evidence @([ordered]@{ signal = $abortSignal; window = 'during'; kind = 'abort' }) `
            -Remediation @('Review the abort-check evidence and correct the condition that tripped before repeating the study.')
    }

    $missing = @(@($pre + $during + $post) | Where-Object { $null -eq $_.values })
    if ($missing.Count -gt 0 -and $limitations -notcontains 'L2') { $limitations += 'L2' }
    if ([int]$Plan.windows.injectMinutes -le 3) { $limitations += 'L7' }
    if ($RunRecord.scenarioRun.outcome -in @('Failed', 'Canceled', 'Cancelled', 'Aborted')) { $limitations += 'L8' }
    if ($RunRecord.planHash -ne $Plan.frozenConfigHash) { $limitations += 'L9' }
    foreach ($code in @($Plan.readiness.limitationCodes)) {
        if ($code -and $limitations -notcontains $code) { $limitations += $code }
    }

    $order = @{ critical = 0; high = 1; medium = 2; low = 3 }
    $sorted = @($findings | Sort-Object -Property @{ Expression = { $order[$_.severity] } }, @{ Expression = { $_.title } })

    return [ordered]@{
        findingsVersion = 'findings.v1'
        studyId         = $RunRecord.studyId
        scopeHash       = $RunRecord.scopeHash
        planHash        = $Plan.frozenConfigHash
        verdict         = Get-ChaosVerdict -Findings $sorted -MechanismProven $mechanismProven `
            -PredicateMeasured $predicateDuring -RecoveryMeasured $predicatePost -Abort $abort
        mechanismProven = $mechanismProven
        mechanismDetail = $delta.detail
        predicate       = [ordered]@{
            raw    = $predicate.raw
            during = $predicateDuring
            post   = $predicatePost
        }
        findings        = @($sorted)
        limitations     = @(
            foreach ($code in ($limitations | Select-Object -Unique | Sort-Object)) {
                [ordered]@{ code = $code; text = Get-ChaosLimitationText -Code $code }
            }
        )
    }
}
