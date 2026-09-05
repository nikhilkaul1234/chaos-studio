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

# The findings contract version. v2 split the single verdict into a predicate
# verdict and a study verdict and gave every finding a kind, so a v1 findings
# file cannot be read as if it were a v2 one: its `verdict` conflates two
# questions and its findings have no kind at all. Comparisons across the
# boundary are refused rather than silently coerced.
$script:ChaosFindingsContractVersion = 'findings.v2'
$script:ChaosFindingsLegacyVersions = @('findings.v1')

function Get-ChaosFindingsContractVersion {
    <#
    .SYNOPSIS
        The version this library writes.
    #>
    return $script:ChaosFindingsContractVersion
}

function Test-ChaosFindingsComparable {
    <#
    .SYNOPSIS
        Whether two findings documents can be compared without lying.

    .DESCRIPTION
        Same contract version compares cleanly. A v1 document has no predicate
        verdict and no finding kinds, so a v1-to-v2 delta would either invent
        the missing half or quietly compare a study verdict against a predicate
        verdict. Both are worse than refusing.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][string]$Left,
        [Parameter(Mandatory)][AllowNull()][string]$Right
    )
    $l = if ([string]::IsNullOrWhiteSpace($Left)) { 'findings.v1' } else { $Left }
    $r = if ([string]::IsNullOrWhiteSpace($Right)) { 'findings.v1' } else { $Right }
    return ($l -eq $r)
}

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
    L11 = 'Partial scenario - the service execution plan ran fewer legs than the scenario declares, so some actions never applied'
    L12 = 'Insufficient exposure - too little work reached the vulnerable path for the absence of failures to mean anything'
    L13 = 'Action timing approximate - the exact action-active window was not reported, so evidence is aligned to the observation window instead'
    L14 = 'Unresolved residue - resources or grants created by this study could not be confirmed removed'
    L15 = 'Design provisional - candidate hypotheses were ranked without live action discovery, so platform availability is unconfirmed'
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

function Test-ChaosPredicate {
    <#
    .SYNOPSIS
        Evaluate a steady-state predicate against a measurement.

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

function Test-ChaosMechanismProbe {
    <#
    .SYNOPSIS
        Prove the frozen mechanism, not the accident of any signal moving.

    .DESCRIPTION
        This is the difference between "something changed while we were
        injecting" and "the specific thing the stated mechanism predicts
        changed, on the resource it predicts". It evaluates the exact
        mechanismProbe frozen at scope time over the actual action window's
        evidence only, and it looks at that probe's own signal - never any
        other. Unrelated movement can therefore never set mechanismProven true.

        The probe carries an expectedDirection:
          up          the probe's value is higher during the action window
          down        it is lower
          appears     it was absent before and is present during
          disappears  it was present before and is absent during
          crosses     it moved across the threshold named in condition

        And a resourceCorrelation: the resource the movement must belong to.
        When the study knows its scoped resources, the correlation has to be one
        of them; a probe that resolves elsewhere is not proof about this study.

    .OUTPUTS
        { proven; direction; signal; detail }
        proven is $true only when the probe's own signal moved as predicted and
        correlates to the expected resource; $false when it did not; $null when
        the probe's signal was not measured, which is a gap, not a disproof.
    #>
    param(
        [AllowNull()][object]$Probe,
        [AllowNull()][object[]]$Before,
        [AllowNull()][object[]]$During,
        [AllowNull()][AllowEmptyCollection()][string[]]$ExpectedResourceIds = @()
    )

    if ($null -eq $Probe) {
        return [pscustomobject]@{
            proven    = $null
            direction = $null
            signal    = $null
            detail    = 'No mechanism probe was frozen on this plan, so the mechanism cannot be proven - a signal moving is not, on its own, evidence the stated mechanism reached the system.'
        }
    }

    $signalName = if ($Probe.PSObject.Properties.Name -contains 'signal') { [string]$Probe.signal } else { '' }
    $query = if ($Probe.PSObject.Properties.Name -contains 'query') { [string]$Probe.query } else { '' }
    $direction = if ($Probe.PSObject.Properties.Name -contains 'expectedDirection') { [string]$Probe.expectedDirection } else { '' }
    $correlation = if ($Probe.PSObject.Properties.Name -contains 'resourceCorrelation') { [string]$Probe.resourceCorrelation } else { '' }
    $condition = if ($Probe.PSObject.Properties.Name -contains 'condition') { [string]$Probe.condition } else { '' }

    $probeLabel = if (-not [string]::IsNullOrWhiteSpace($signalName)) { $signalName } else { 'query' }

    # The resource the movement must belong to. When scope is known, an
    # off-scope correlation is disqualifying: it would be proof about some other
    # resource, not this study's.
    $ids = @(@($ExpectedResourceIds) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($ids.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($correlation)) {
        $resolves = @($ids | Where-Object { $_ -eq $correlation -or $_ -like "*$correlation" -or $correlation -like "*$_" })
        if ($resolves.Count -eq 0) {
            return [pscustomobject]@{
                proven    = $false
                direction = $direction
                signal    = $probeLabel
                detail    = "The mechanism probe correlates to '$correlation', which is not a resource in scope, so any movement of $probeLabel cannot prove the mechanism for this study."
            }
        }
    }

    # A query-based probe may name its workspace as 'logs:<workspaceId>#<kql>'.
    # When it does, only that workspace's source can prove this probe - a
    # movement in some other workspace's logs is not evidence about it.
    $probeWorkspaceId = $null
    if (-not [string]::IsNullOrWhiteSpace($query) -and $query -like 'logs:*') {
        $probeRest = $query.Substring('logs:'.Length)
        if ($probeRest.Contains('#')) {
            $probeWsPart = $probeRest.Split('#', 2)[0]
            if (-not [string]::IsNullOrWhiteSpace($probeWsPart)) { $probeWorkspaceId = $probeWsPart.Trim() }
        }
    }

    # Only the probe's OWN signal is considered. This is what stops an unrelated
    # signal's movement from ever being read as proof of the mechanism.
    $matchesProbe = {
        param($sig)
        if ($null -eq $sig) { return $false }
        $source = [string]$sig.source
        if (-not [string]::IsNullOrWhiteSpace($signalName)) {
            return ($source -eq $signalName -or $source -eq "metrics:$signalName" -or $source -like "*:$signalName" -or $source -like "*:$signalName#*")
        }
        # A query-based probe binds to a logs source. When the probe names a
        # workspace, bind only to that workspace so a plan with several log
        # sources cannot prove the mechanism from the wrong one; otherwise any
        # logs source is acceptable.
        if (-not [string]::IsNullOrWhiteSpace($probeWorkspaceId)) {
            return ($source -eq "logs:$probeWorkspaceId" -or $source -like "logs:$probeWorkspaceId#*")
        }
        return ($source -like 'logs:*')
    }

    $duringMatch = @(@($During) | Where-Object { $null -ne $_ -and (& $matchesProbe $_) }) | Select-Object -First 1
    $beforeMatch = @(@($Before) | Where-Object { $null -ne $_ -and (& $matchesProbe $_) }) | Select-Object -First 1

    # For 'disappears' the probe's absence during the action window IS the
    # predicted movement, so during-absence must reach the switch rather than
    # be reported as an unmeasured gap. Every other direction needs the during
    # signal present to say anything, so absence there is a genuine gap.
    if ($direction -ne 'disappears' -and ($null -eq $duringMatch -or $null -eq $duringMatch.values)) {
        return [pscustomobject]@{
            proven    = $null
            direction = $direction
            signal    = $probeLabel
            detail    = "The mechanism probe signal '$probeLabel' was not measured during the action window, so whether the mechanism landed is unknown - this is a gap in evidence, not a disproof."
        }
    }

    $readValue = {
        param($sig)
        if ($null -eq $sig -or $null -eq $sig.values) { return $null }
        foreach ($candidate in @($signalName, 'last', 'mean', 'value', 'count')) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $v = Get-ChaosSignalValue -Signal $sig -Name $candidate
            if ($null -ne $v) {
                $parsed = 0.0
                if ([double]::TryParse([string]$v, [ref]$parsed)) { return $parsed }
            }
        }
        return $null
    }

    # A query-based probe can return rows whose columns are named nothing the
    # numeric read knows (e.g. a 'HealthScore' column). That is a probe
    # configuration error, not a measurement gap, so it must be reported as one
    # rather than looking like the signal was never collected.
    $numericColumnMissing = {
        param($sig)
        if ($null -eq $sig -or $null -eq $sig.values) { return $false }
        foreach ($candidate in @($signalName, 'last', 'mean', 'value', 'count')) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $v = Get-ChaosSignalValue -Signal $sig -Name $candidate
            if ($null -ne $v) {
                $parsed = 0.0
                if ([double]::TryParse([string]$v, [ref]$parsed)) { return $false }
            }
        }
        return $true
    }

    $expectedColumns = {
        $cols = @('value', 'count', 'last', 'mean')
        if (-not [string]::IsNullOrWhiteSpace($signalName)) { $cols = @($signalName) + $cols }
        "'" + ($cols -join "', '") + "'"
    }

    $duringPresent = ($null -ne $duringMatch -and $null -ne $duringMatch.values)
    $beforePresent = ($null -ne $beforeMatch -and $null -ne $beforeMatch.values)
    $dValue = & $readValue $duringMatch
    $bValue = & $readValue $beforeMatch

    $result = {
        param($ok, $detail)
        [pscustomobject]@{ proven = $ok; direction = $direction; signal = $probeLabel; detail = $detail }
    }

    switch ($direction) {
        'appears' {
            if (-not $beforePresent -and $duringPresent) {
                return & $result $true "The mechanism probe '$probeLabel' was absent before injection and appeared during the action window, as the mechanism predicts."
            }
            return & $result $false "The mechanism probe '$probeLabel' did not appear during the action window as predicted, so the mechanism is not proven."
        }
        'disappears' {
            if ($beforePresent -and -not $duringPresent) {
                return & $result $true "The mechanism probe '$probeLabel' was present before injection and disappeared during the action window, as the mechanism predicts."
            }
            return & $result $false "The mechanism probe '$probeLabel' did not disappear during the action window as predicted, so the mechanism is not proven."
        }
        'crosses' {
            $threshold = $null
            if ($condition -match '(-?[0-9]+(?:\.[0-9]+)?)') { $threshold = [double]$Matches[1] }
            if ($null -ne $threshold -and $null -ne $bValue -and $null -ne $dValue) {
                # Local names must not collide with the $Before/$During parameters:
                # those are type-constrained to [object[]], so assigning a bool to
                # $before/$during would coerce it back into an array and break the
                # comparison. Use distinct names.
                $beforeCrossed = ($bValue -ge $threshold)
                $duringCrossed = ($dValue -ge $threshold)
                if ($beforeCrossed -ne $duringCrossed) {
                    return & $result $true "The mechanism probe '$probeLabel' crossed the threshold in '$condition' (from $bValue to $dValue), as the mechanism predicts."
                }
                return & $result $false "The mechanism probe '$probeLabel' did not cross the threshold in '$condition' (stayed at $dValue), so the mechanism is not proven."
            }
            # Without a numeric threshold or comparable values, any movement of
            # the probe's own signal is the best available evidence.
            if ($null -ne $bValue -and $null -ne $dValue -and $bValue -ne $dValue) {
                return & $result $true "The mechanism probe '$probeLabel' moved from $bValue to $dValue during the action window."
            }
            if (($duringPresent -and (& $numericColumnMissing $duringMatch)) -or ($beforePresent -and (& $numericColumnMissing $beforeMatch))) {
                return [pscustomobject]@{
                    proven    = $null
                    direction = $direction
                    signal    = $probeLabel
                    detail    = "The mechanism probe '$probeLabel' returned rows but no numeric column named $(& $expectedColumns) could be read, so whether it crossed '$condition' cannot be judged. Have the probe query project one of those columns."
                }
            }
            return & $result $false "The mechanism probe '$probeLabel' did not move during the action window, so the mechanism is not proven."
        }
        default {
            if ($null -eq $bValue -or $null -eq $dValue) {
                # Distinguish a real measurement gap from a probe misconfigured
                # to project no readable numeric column: the latter is a config
                # error the operator can fix, not evidence the mechanism was
                # simply not observed.
                if (($duringPresent -and (& $numericColumnMissing $duringMatch)) -or ($beforePresent -and (& $numericColumnMissing $beforeMatch))) {
                    return [pscustomobject]@{
                        proven    = $null
                        direction = $direction
                        signal    = $probeLabel
                        detail    = "The mechanism probe '$probeLabel' returned rows but no numeric column named $(& $expectedColumns) could be read, so its '$direction' movement cannot be judged. Have the probe query project one of those columns."
                    }
                }
                return [pscustomobject]@{
                    proven    = $null
                    direction = $direction
                    signal    = $probeLabel
                    detail    = "The mechanism probe '$probeLabel' could not be compared across the baseline and action windows, so whether it moved '$direction' is unknown."
                }
            }
            $moved = if ($direction -eq 'up') { $dValue -gt $bValue } elseif ($direction -eq 'down') { $dValue -lt $bValue } else { $false }
            if ($moved) {
                return & $result $true "The mechanism probe '$probeLabel' moved $direction (from $bValue to $dValue) within the action window, as the mechanism predicts."
            }
            return & $result $false "The mechanism probe '$probeLabel' did not move $direction within the action window (from $bValue to $dValue), so the mechanism is not proven."
        }
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
        [ValidateSet('predicate', 'collateral', 'operational', 'residue')][string]$Kind = 'operational',
        [string[]]$Remediation = @()
    )
    if (@($Evidence).Count -eq 0) {
        throw "Finding '$Key' has no evidence reference. Findings must cite the signal and window they rest on."
    }
    return [ordered]@{
        findingKey     = $Key
        kind           = $Kind
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

function Get-ChaosPredicateVerdict {
    <#
    .SYNOPSIS
        What happened to the one thing the study said it was testing.

    .DESCRIPTION
        This verdict is deliberately narrow. It answers exactly one question -
        did the declared steady-state predicate hold while the action was live -
        and it answers it from the measurement, not from how the study felt.

        Keeping it separate from the study verdict is the whole point. A study
        can do real damage while the predicate holds, and a study can leave the
        predicate untouched while everything else went fine. Collapsing both
        into one sentence is how a report ends up claiming "steady state
        breached" about a predicate that was never breached, or claiming a pass
        for a run that flattened something else.

        The ordering is by strength of statement about the predicate itself:
        an observed breach outranks everything; a missing measurement means we
        cannot speak; a predicate that held while nothing exercised it is not
        evidence of resilience.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$PredicateDuring,
        [AllowNull()][object]$Exercise = $null
    )
    if ($PredicateDuring -eq $false) { return 'Breached' }
    if ($null -eq $PredicateDuring) { return 'Not evaluated' }
    if ($null -ne $Exercise -and $Exercise.exercised -eq $false) { return 'Not exercised' }
    return 'Held'
}

function Get-ChaosCriticalCollateral {
    <#
    .SYNOPSIS
        Critical findings that are not about the predicate.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings
    )
    return ConvertTo-ChaosList -InputObject @($Findings | Where-Object {
            $_.severity -eq 'critical' -and
            ($_.PSObject.Properties.Name -contains 'kind' -or $_ -is [System.Collections.IDictionary]) -and
            (Get-ChaosFindingKind -Finding $_) -eq 'collateral'
        })
}

function Get-ChaosFindingKind {
    <#
    .SYNOPSIS
        A finding's kind, tolerating findings.v1 objects that have none.
    #>
    param([Parameter(Mandatory)][object]$Finding)
    if ($Finding -is [System.Collections.IDictionary]) {
        if ($Finding.Contains('kind')) { return [string]$Finding['kind'] }
        return 'operational'
    }
    if ($Finding.PSObject.Properties.Name -contains 'kind') { return [string]$Finding.kind }
    return 'operational'
}

function Get-ChaosStudyVerdict {
    <#
    .SYNOPSIS
        What the study as a whole concluded, which is not the same question.

    .DESCRIPTION
        The study verdict may be worse than the predicate verdict - critical
        collateral damage matters even when the declared objective survived -
        but it may never misdescribe the predicate. If the predicate was not
        breached, no wording produced here is allowed to say it was. That is
        enforced below rather than left to whoever edits the strings next.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$PredicateVerdict,
        [Parameter(Mandatory)][AllowNull()][object]$MechanismProven
    )

    $collateral = ConvertTo-ChaosList -InputObject (Get-ChaosCriticalCollateral -Findings $Findings)
    $severities = @($Findings | ForEach-Object { $_.severity })

    $verdict =
    if ($PredicateVerdict -eq 'Breached') { 'Steady state breached' }
    elseif ($collateral.Count -gt 0) {
        switch ($PredicateVerdict) {
            'Held' { 'Critical collateral damage (steady state held)' }
            'Not exercised' { 'Critical collateral damage (predicate not exercised)' }
            default { 'Critical collateral damage (predicate not evaluated)' }
        }
    }
    elseif ($PredicateVerdict -eq 'Not exercised') { 'Not exercised' }
    elseif ($PredicateVerdict -eq 'Not evaluated') { 'Inconclusive' }
    elseif ($MechanismProven -ne $true) { 'Inconclusive' }
    elseif ($severities -contains 'high' -or $severities -contains 'medium') { 'Degraded but recovered' }
    else { 'Steady state held' }

    # The wording guard. A reader quotes the headline; it must never assert a
    # breach the measurement does not support.
    if ($PredicateVerdict -ne 'Breached' -and $verdict -eq 'Steady state breached') {
        throw "Verdict wording guard: the study verdict claims a steady-state breach while the predicate verdict is '$PredicateVerdict'."
    }

    return $verdict
}

function Get-ChaosVerdictRationale {
    <#
    .SYNOPSIS
        One sentence saying why the two verdicts differ, or that they agree.
    #>
    param(
        [Parameter(Mandatory)][string]$PredicateVerdict,
        [Parameter(Mandatory)][string]$StudyVerdict,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings
    )
    $collateral = ConvertTo-ChaosList -InputObject (Get-ChaosCriticalCollateral -Findings $Findings)
    if ($collateral.Count -gt 0) {
        $titles = (@($collateral | ForEach-Object { $_.title }) -join '; ')
        return "The declared predicate verdict is '$PredicateVerdict', but the study caused critical damage outside the predicate, so the study verdict is elevated: $titles."
    }
    if ($PredicateVerdict -eq 'Not exercised') {
        return 'The predicate was measured and did not move, but the run did not produce enough eligible work for that to mean anything. This is not a pass.'
    }
    if ($PredicateVerdict -eq 'Not evaluated') {
        return 'The signal that defines the predicate was not available for the action window, so the study cannot state a predicate outcome.'
    }
    if ($StudyVerdict -eq 'Inconclusive') {
        return 'The predicate held, but the action was not proven to have reached the scoped resources, so the result cannot be read as resilience.'
    }
    return "The study verdict follows the predicate verdict: $PredicateVerdict."
}

function Get-ChaosVerdict {
    <#
    .SYNOPSIS
        One sentence a reader can quote.

    .DESCRIPTION
        Retained as the single-verdict entry point for callers that have not
        moved to the dual-verdict contract. It composes the two verdicts rather
        than duplicating their rules, so there is one place where the wording
        can change.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][AllowNull()][object]$MechanismProven,
        [AllowNull()][object]$Exercise = $null
    )
    $severities = @($Findings | ForEach-Object { $_.severity })

    # Without a predicate outcome to work from, a critical finding of any kind
    # is the strongest thing this function knows.
    $predicateVerdict =
    if ($severities -contains 'critical') { 'Breached' }
    elseif ($null -ne $Exercise -and $Exercise.exercised -eq $false) { 'Not exercised' }
    else { 'Held' }

    return Get-ChaosStudyVerdict -Findings $Findings -PredicateVerdict $predicateVerdict -MechanismProven $MechanismProven
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

    # Mechanism proof binds to the exact frozen probe evaluated over the action
    # window's evidence, never to "any signal moved". A v1/v2 plan carries no
    # frozen probe, so those studies fall back to the generic movement check
    # rather than being refused a report.
    $frozenProbe = $null
    if (($Plan.PSObject.Properties.Name -contains 'mechanism') -and $Plan.mechanism -and
        ($Plan.mechanism.PSObject.Properties.Name -contains 'mechanismProbe')) {
        $frozenProbe = $Plan.mechanism.mechanismProbe
    }

    $expectedResourceIds = @()
    if (($Plan.scope.PSObject.Properties.Name -contains 'projectedResources') -and $Plan.scope.projectedResources) {
        $expectedResourceIds = @($Plan.scope.projectedResources)
    }

    if ($null -ne $frozenProbe) {
        $probeResult = Test-ChaosMechanismProbe -Probe $frozenProbe -Before $pre -During $during -ExpectedResourceIds $expectedResourceIds
        $mechanismProven = $probeResult.proven -eq $true
        $mechanismMoved = $probeResult.proven
        $mechanismDetail = $probeResult.detail
    }
    else {
        $mechanismProven = $delta.moved -eq $true
        $mechanismMoved = $delta.moved
        $mechanismDetail = $delta.detail
    }

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
    if ($RunRecord.scenarioRun.PSObject.Properties.Name -contains 'abort' -and $null -ne $RunRecord.scenarioRun.abort) {
        if ($RunRecord.scenarioRun.abort.kind -eq 'predicate') { $predicateDuring = $false }
        elseif ($RunRecord.scenarioRun.abort.kind -eq 'missing-signal') { $predicateDuring = $null }
    }
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
            -Kind 'predicate' `
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
            -Kind 'predicate' `
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
            -Kind 'operational' `
            -Title 'Injection was not proven to reach the system' `
            -Severity 'low' -Confidence $(if ($null -eq $mechanismMoved) { 'low' } else { 'medium' }) `
            -Observation $mechanismDetail `
            -Interpretation 'Chaos Studio reporting a successful scenario run means the control plane accepted and dispatched the action. Without a signal that moved, a clean result may mean the service is resilient - or that nothing was ever injected. These are not the same, and this study cannot tell them apart.' `
            -Evidence $evidenceRef `
            -Remediation @(
                'Add a signal that would be expected to move under this action, so a clean result can be distinguished from an injection that never landed.'
                "Confirm '$($Plan.action.canonicalId)' is still offered for the resource types in this workspace scope, then repeat the study."
                'Widen the blast radius within the bounds the action allows, so the effect is large enough to observe.'
            )
    }

    # Collateral: the run reached further than the study said it would. The
    # count the service reports is compared against the resource count the
    # operator consented to, because "we only touch these N" is the promise the
    # blast radius bound is supposed to keep. Exceeding it is not a predicate
    # result at all - it is damage the study did on its way to asking the
    # question, and it stays visible even when the predicate held.
    $touchedCount = $null
    if (($RunRecord.PSObject.Properties.Name -contains 'scenarioRun') -and $null -ne $RunRecord.scenarioRun -and
        ($RunRecord.scenarioRun.PSObject.Properties.Name -contains 'observation') -and $null -ne $RunRecord.scenarioRun.observation -and
        ($RunRecord.scenarioRun.observation.PSObject.Properties.Name -contains 'resourcesTouched')) {
        $touchedCount = $RunRecord.scenarioRun.observation.resourcesTouched
    }
    $declaredCount = $null
    if (($Plan.scope.PSObject.Properties.Name -contains 'projectedResourceCount')) {
        $declaredCount = $Plan.scope.projectedResourceCount
    }
    if ($null -ne $touchedCount -and $null -ne $declaredCount -and [int]$touchedCount -gt [int]$declaredCount) {
        $findings += New-ChaosFinding -Key (Get-ChaosFindingKey -ActionUrn $actionIdentity -Signal 'blast-radius' -Predicate 'declared-scope') `
            -Kind 'collateral' `
            -Title 'The run touched more resources than the study declared' `
            -Severity 'critical' -Confidence 'high' `
            -Observation "The scenario run reported $touchedCount resource(s) touched against a declared scope of $declaredCount." `
            -Interpretation 'Consent was given for a bounded blast radius and the run exceeded it. Whatever the predicate did, this study affected resources nobody agreed to expose, and that has to be treated as damage rather than as a footnote.' `
            -Evidence @([ordered]@{ signal = 'scenarioRun.resourcesTouched'; window = 'during'; kind = 'collateral' }) `
            -Remediation @(
                'Reconcile the scenario configuration filters and selectors against the declared scope before repeating this study.'
                'Confirm nothing outside the declared scope was left degraded by this run.'
            )
    }

    $missing = @(@($pre + $during + $post) | Where-Object { $null -eq $_.values })
    if ($missing.Count -gt 0 -and $limitations -notcontains 'L2') { $limitations += 'L2' }
    if ([int]$Plan.windows.injectMinutes -le 3) { $limitations += 'L7' }
    if ($RunRecord.scenarioRun.outcome -in @('Failed', 'Cancelled')) { $limitations += 'L8' }
    if ($RunRecord.planHash -ne $Plan.frozenConfigHash) { $limitations += 'L9' }
    foreach ($code in @($Plan.readiness.limitationCodes)) {
        if ($code -and $limitations -notcontains $code) { $limitations += $code }
    }

    $exercise = $null
    if ($RunRecord.PSObject.Properties.Name -contains 'exercise') { $exercise = $RunRecord.exercise }
    if ($null -ne $exercise -and $exercise.exercised -eq $false -and $limitations -notcontains 'L12') {
        $limitations += 'L12'
    }

    # When the action window is anything less than exact, every statement in
    # this report about "during the action" is really about the window we
    # watched, which is wider. That has to be said out loud rather than left
    # for a reader to infer from a timestamp.
    $actionWindow = $null
    if ($RunRecord.PSObject.Properties.Name -contains 'windows' -and $null -ne $RunRecord.windows -and
        $RunRecord.windows.PSObject.Properties.Name -contains 'action') {
        $actionWindow = $RunRecord.windows.action
    }
    if ($null -ne $actionWindow -and $actionWindow.timing -ne 'exact' -and $limitations -notcontains 'L13') {
        $limitations += 'L13'
    }

    # Residue: anything this study created that it cannot show it removed. The
    # ledger records observed cleanup outcomes, so "not confirmed removed" here
    # means a removal was tried and failed, was deliberately skipped, or was
    # never reached - not that nobody looked. Sealing with residue is allowed;
    # hiding it is not.
    $residue = $null
    if ($RunRecord.PSObject.Properties.Name -contains 'residue') { $residue = $RunRecord.residue }
    if ($null -ne $residue -and $residue.PSObject.Properties.Name -contains 'unresolved' -and
        [int]$residue.unresolved -gt 0) {
        if ($limitations -notcontains 'L14') { $limitations += 'L14' }

        # Severity follows what was left behind, not how the cleanup failed. A
        # stranded role assignment is a standing grant on someone's
        # subscription; a stranded configuration is clutter. Both belong in the
        # report, but they are not the same problem.
        $unresolvedKinds = @(@($residue.entries) |
            Where-Object { $_ -and $_.status -ne 'succeeded' } |
            ForEach-Object { [string]$_.kind })
        $residueSeverity = if (($unresolvedKinds -contains 'roleAssignment') -or ($unresolvedKinds -contains 'workspace')) { 'high' } else { 'medium' }
        $residueList = (@(@($residue.entries) |
                Where-Object { $_ -and $_.status -ne 'succeeded' } |
                ForEach-Object { "$($_.kind) $($_.id) ($($_.status))" }) -join '; ')
        $findings += New-ChaosFinding -Key (Get-ChaosFindingKey -ActionUrn $actionIdentity -Signal 'residue' -Predicate 'cleanup-confirmed') `
            -Kind 'residue' `
            -Title "This study left $([int]$residue.unresolved) resource(s) it could not confirm removed" `
            -Severity $residueSeverity -Confidence 'high' `
            -Observation "Unresolved residue: $residueList." `
            -Interpretation 'These were created by this study and their removal was not observed to succeed. Until each one is removed by hand, the subscription still carries the cost, the access, or both.' `
            -Evidence @([ordered]@{ signal = 'residue-ledger'; window = 'post'; kind = 'residue' }) `
            -Remediation @(
                'Run the exact removal command recorded against each unresolved entry in the residue ledger appendix.'
                'Re-check the ledger after removal; the study will not retry on its own.'
            )
    }

    $order = @{ critical = 0; high = 1; medium = 2; low = 3 }
    $sorted = @($findings | Sort-Object -Property @{ Expression = { $order[$_.severity] } }, @{ Expression = { $_.title } })

    $predicateVerdict = Get-ChaosPredicateVerdict -PredicateDuring $predicateDuring -Exercise $exercise
    $studyVerdict = Get-ChaosStudyVerdict -Findings $sorted -PredicateVerdict $predicateVerdict -MechanismProven $mechanismProven

    return [ordered]@{
        findingsVersion  = $script:ChaosFindingsContractVersion
        studyId          = $RunRecord.studyId
        scopeHash        = $RunRecord.scopeHash
        planHash         = $Plan.frozenConfigHash
        predicateVerdict = $predicateVerdict
        studyVerdict     = $studyVerdict
        verdictRationale = Get-ChaosVerdictRationale -PredicateVerdict $predicateVerdict -StudyVerdict $studyVerdict -Findings $sorted
        # Retained so a reader, a card, or an older consumer that asks for
        # "the verdict" gets the study-level one rather than nothing.
        verdict          = $studyVerdict
        exercise         = $exercise
        actionWindow     = $actionWindow
        residue          = $residue
        mechanismProven  = $mechanismProven
        mechanismDetail  = $mechanismDetail
        predicate        = [ordered]@{
            raw    = $predicate.raw
            during = $predicateDuring
            post   = $predicatePost
        }
        findings         = @($sorted)
        limitations      = @(
            foreach ($code in ($limitations | Select-Object -Unique | Sort-Object)) {
                [ordered]@{ code = $code; text = Get-ChaosLimitationText -Code $code }
            }
        )
    }
}
