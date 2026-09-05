<#
.SYNOPSIS
    Pester 5 unit tests for the Req C (Epic 3) scope-side effective-legs model in
    Readiness.ps1: the declared-vs-effective projection, the partial-scenario
    binding, the all-skipped / partial gates, and the scenario-name honesty guard.

.DESCRIPTION
    Coverage of the epic's validation matrix:
      - V-skip:    all legs skipped -> exit 14 (ScopeUnverified)
      - V-partial: executable < total -> L11 + N-of-M names; fail-closed unless
                   the bound -AcceptPartialScenario phrase is supplied
      - scope<->run mirror: the scope-frozen effective-plan hash equals the hash
        the run recomputes (Get-ChaosRunEffectivePlanHash), including the
        skipped=$true-only leg shape
      - Assert-ChaosScenarioNameHonest blocks a name that claims a zone with no
        executable leg

    The exit-driven gates are proved in child pwsh processes; the pure decision
    and hash functions are tested in-process.

    Run:   Invoke-Pester -Path ./tests/EffectiveLegs.Tests.ps1
#>

BeforeAll {
    $script:SkillRoot     = Split-Path $PSScriptRoot -Parent
    $script:ReadinessLib  = Join-Path $script:SkillRoot 'scripts' 'lib' 'Readiness.ps1'
    $script:RunExecuteLib = Join-Path (Split-Path $script:SkillRoot -Parent) 'chaos-study-run' 'scripts' 'lib' 'Execute.ps1'
    . $script:ReadinessLib

    function New-Leg {
        param([string]$Selector, [string]$Action = 'shutdown', [switch]$Skipped, [string]$Reason, [switch]$SkippedBoolOnly)
        $leg = [ordered]@{ legSelector = $Selector; action = $Action }
        if ($SkippedBoolOnly) { $leg['skipped'] = $true }
        elseif ($Skipped) { $leg['reason'] = if ($Reason) { $Reason } else { 'unsupported' } }
        return [pscustomobject]$leg
    }
    function New-ExecutionPlan {
        param([object[]]$Legs)
        return [pscustomobject]@{ legs = @($Legs) }
    }
    function Invoke-ChaosChildExit {
        param([Parameter(Mandatory)][string]$Body)
        $output = & pwsh -NoProfile -NonInteractive -Command $Body 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 134) { Write-Host ($output | Out-String) }
        return $code
    }
}

Describe 'Resolve-ChaosEffectiveLegs' {

    It 'counts every leg executable when none is skipped' {
        $plan = New-ExecutionPlan -Legs @((New-Leg 'zone-1'), (New-Leg 'zone-2'))
        $eff = Resolve-ChaosEffectiveLegs -ExecutionPlan $plan
        $eff.total | Should -Be 2
        $eff.executable | Should -Be 2
        @($eff.skipped).Count | Should -Be 0
    }

    It 'projects a partial plan with skipped selectors and reasons' {
        $plan = New-ExecutionPlan -Legs @(
            (New-Leg 'zone-1'),
            (New-Leg 'zone-2' -Skipped -Reason 'no capacity')
        )
        $eff = Resolve-ChaosEffectiveLegs -ExecutionPlan $plan
        $eff.total | Should -Be 2
        $eff.executable | Should -Be 1
        @($eff.skipped).Count | Should -Be 1
        $eff.skipped[0].legSelector | Should -Be 'zone-2'
        $eff.skipped[0].reason | Should -Be 'no capacity'
    }

    It 'classifies a skipped=$true-only leg as skipped (mirror of the run fix)' {
        $plan = New-ExecutionPlan -Legs @((New-Leg 'zone-1'), (New-Leg 'zone-2' -SkippedBoolOnly))
        $eff = Resolve-ChaosEffectiveLegs -ExecutionPlan $plan
        $eff.executable | Should -Be 1
        $eff.skipped[0].legSelector | Should -Be 'zone-2'
    }

    It 'reports total 0 / executable 0 for an empty plan' {
        $eff = Resolve-ChaosEffectiveLegs -ExecutionPlan (New-ExecutionPlan -Legs @())
        $eff.total | Should -Be 0
        $eff.executable | Should -Be 0
    }
}

Describe 'scope-to-run effective-plan hash mirror' {

    It 'produces the same digest scope and run compute for an identical partial plan' {
        $plan = New-ExecutionPlan -Legs @(
            (New-Leg 'zone-1'),
            (New-Leg 'zone-2' -SkippedBoolOnly)
        )
        $eff = Resolve-ChaosEffectiveLegs -ExecutionPlan $plan

        # Scope side: the exact projection Invoke-ChaosStudyScope.ps1 hashes.
        $scopeProjection = [ordered]@{
            total      = $eff.total
            executable = $eff.executable
            skipped    = @(@($eff.skipped) | ForEach-Object { [string]$_.legSelector } | Sort-Object)
        }
        $scopeHash = Get-ChaosDigest -InputObject $scopeProjection

        # Run side: recompute from a validation carrying the same legs.
        . $script:RunExecuteLib
        $validation = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'zone-1' }
            [pscustomobject]@{ legSelector = 'zone-2'; skipped = $true }
        ) }
        $runHash = Get-ChaosRunEffectivePlanHash -Validation $validation

        $runHash | Should -Be $scopeHash
    }
}

Describe 'Get-ChaosEffectiveLegsDecision' {

    It 'is "all" when every leg is executable' {
        $eff = [pscustomobject]@{ total = 3; executable = 3; skipped = @() }
        $decision = Get-ChaosEffectiveLegsDecision -EffectiveLegs $eff -BindingHash 'h'
        $decision.kind | Should -Be 'all'
        $decision.accepted | Should -BeTrue
        $decision.limitationCodes | Should -Not -Contain 'L11'
    }

    It 'is "none" when nothing is executable' {
        $eff = [pscustomobject]@{ total = 2; executable = 0; skipped = @() }
        $decision = Get-ChaosEffectiveLegsDecision -EffectiveLegs $eff -BindingHash 'h'
        $decision.kind | Should -Be 'none'
        $decision.accepted | Should -BeFalse
    }

    It 'is "partial" and carries L11 when executable < total' {
        $eff = [pscustomobject]@{ total = 3; executable = 1; skipped = @(
            [pscustomobject]@{ legSelector = 'b' }, [pscustomobject]@{ legSelector = 'c' }
        ) }
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash 's' -ScenarioName 'zone-down' -EffectiveLegs $eff
        $decision = Get-ChaosEffectiveLegsDecision -EffectiveLegs $eff -BindingHash $binding
        $decision.kind | Should -Be 'partial'
        $decision.accepted | Should -BeFalse
        $decision.limitationCodes | Should -Contain 'L11'
    }

    It 'accepts a partial scenario only for the exact bound phrase' {
        $eff = [pscustomobject]@{ total = 3; executable = 1; skipped = @(
            [pscustomobject]@{ legSelector = 'b' }, [pscustomobject]@{ legSelector = 'c' }
        ) }
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash 's' -ScenarioName 'zone-down' -EffectiveLegs $eff
        $phrase = Get-ChaosPartialScenarioPhrase -EffectiveLegs $eff -BindingHash $binding

        $accepted = Get-ChaosEffectiveLegsDecision -EffectiveLegs $eff -BindingHash $binding -AcceptPartialScenario $phrase
        $accepted.accepted | Should -BeTrue

        $wrong = Get-ChaosEffectiveLegsDecision -EffectiveLegs $eff -BindingHash $binding -AcceptPartialScenario 'accept partial scenario 1 of 3 deadbeef'
        $wrong.accepted | Should -BeFalse
    }

    It 'binds the phrase to the exact effective legs (different legs -> different hash)' {
        $effA = [pscustomobject]@{ total = 3; executable = 1; skipped = @([pscustomobject]@{ legSelector = 'b' }) }
        $effB = [pscustomobject]@{ total = 3; executable = 1; skipped = @([pscustomobject]@{ legSelector = 'x' }) }
        $hashA = Get-ChaosEffectiveLegsBindingHash -ScopeHash 's' -ScenarioName 'zone-down' -EffectiveLegs $effA
        $hashB = Get-ChaosEffectiveLegsBindingHash -ScopeHash 's' -ScenarioName 'zone-down' -EffectiveLegs $effB
        $hashA | Should -Not -Be $hashB
    }
}

Describe 'Assert-ChaosScenarioNameHonest' {

    It 'passes a generic name with no zone claim' {
        $eff = [pscustomobject]@{ executableSelectors = @('vm-a', 'vm-b') }
        Assert-ChaosScenarioNameHonest -ScenarioName 'shutdown-study' -EffectiveLegs $eff | Should -BeTrue
    }

    It 'passes when the claimed zone has an executable leg' {
        $eff = [pscustomobject]@{ executableSelectors = @('zone-1-vm', 'zone-2-vm') }
        Assert-ChaosScenarioNameHonest -ScenarioName 'zone-1-down' -EffectiveLegs $eff | Should -BeTrue
    }

    It 'blocks (exit 14) when the name claims a zone with no executable leg' {
        $lib = $script:ReadinessLib
        $body = @"
. '$lib'
`$eff = [pscustomobject]@{ executableSelectors = @('zone-2-vm') }
Assert-ChaosScenarioNameHonest -ScenarioName 'zone-1-down' -EffectiveLegs `$eff | Out-Null
"@
        Invoke-ChaosChildExit -Body $body | Should -Be 14
    }
}

Describe 'Assert-ChaosEffectiveLegs (V-skip / V-partial gates)' {

    It 'V-skip: all legs skipped exits 14 (ScopeUnverified)' {
        $lib = $script:ReadinessLib
        $body = @"
. '$lib'
`$eff = [pscustomobject]@{ total = 2; executable = 0; skipped = @(
    [pscustomobject]@{ legSelector = 'a'; action = 'x'; reason = 'unsupported' },
    [pscustomobject]@{ legSelector = 'b'; action = 'x'; reason = 'unsupported' }
) }
Assert-ChaosEffectiveLegs -EffectiveLegs `$eff -ScopeHash 's' -ScenarioName 'zone-down' | Out-Null
"@
        Invoke-ChaosChildExit -Body $body | Should -Be 14
    }

    It 'V-partial: partial without a phrase fails closed with exit 20' {
        $lib = $script:ReadinessLib
        $body = @"
. '$lib'
`$eff = [pscustomobject]@{ total = 3; executable = 1; skipped = @(
    [pscustomobject]@{ legSelector = 'b'; action = 'x'; reason = 'unsupported' },
    [pscustomobject]@{ legSelector = 'c'; action = 'x'; reason = 'unsupported' }
) }
Assert-ChaosEffectiveLegs -EffectiveLegs `$eff -ScopeHash 's' -ScenarioName 'zone-down' | Out-Null
"@
        Invoke-ChaosChildExit -Body $body | Should -Be 20
    }

    It 'V-partial: partial WITH the bound phrase proceeds and returns L11 (in-process)' {
        # In-process companion to the child-process exit test: asserts the actual
        # return value so a silent internal error cannot pass vacuously.
        $eff = [pscustomobject]@{ total = 3; executable = 1; skipped = @(
            [pscustomobject]@{ legSelector = 'b'; action = 'x'; reason = 'unsupported' }
            [pscustomobject]@{ legSelector = 'c'; action = 'x'; reason = 'unsupported' }
        ) }
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash 's' -ScenarioName 'zone-down' -EffectiveLegs $eff
        $phrase = Get-ChaosPartialScenarioPhrase -EffectiveLegs $eff -BindingHash $binding

        $decision = Assert-ChaosEffectiveLegs -EffectiveLegs $eff -ScopeHash 's' -ScenarioName 'zone-down' -AcceptPartialScenario $phrase

        $decision.kind | Should -Be 'partial'
        $decision.accepted | Should -BeTrue
        $decision.limitationCodes | Should -Contain 'L11'
    }

    It 'V-partial: partial WITH the bound phrase proceeds and returns L11' {
        $lib = $script:ReadinessLib
        $body = @"
. '$lib'
`$eff = [pscustomobject]@{ total = 3; executable = 1; skipped = @(
    [pscustomobject]@{ legSelector = 'b'; action = 'x'; reason = 'unsupported' },
    [pscustomobject]@{ legSelector = 'c'; action = 'x'; reason = 'unsupported' }
) }
`$binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash 's' -ScenarioName 'zone-down' -EffectiveLegs `$eff
`$phrase = Get-ChaosPartialScenarioPhrase -EffectiveLegs `$eff -BindingHash `$binding
`$decision = Assert-ChaosEffectiveLegs -EffectiveLegs `$eff -ScopeHash 's' -ScenarioName 'zone-down' -AcceptPartialScenario `$phrase
if (`$decision.kind -ne 'partial') { exit 91 }
if (`$decision.limitationCodes -notcontains 'L11') { exit 92 }
exit 0
"@
        Invoke-ChaosChildExit -Body $body | Should -Be 0
    }
}
