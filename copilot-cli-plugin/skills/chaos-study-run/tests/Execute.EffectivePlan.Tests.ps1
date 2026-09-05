<#
.SYNOPSIS
    Pester 5 unit tests for the Req C (Epic 3) run-side effective-plan logic in
    Execute.ps1: the scope-mirror hash, the equality gate, and configuration
    resolution (reuse / re-create / back-compat).

.DESCRIPTION
    These are security-path tests. The effective-plan hash is what proves a run
    injects exactly the legs scope validated and the operator consented to, so
    the guarantees below are asserted by committed tests CI can re-run rather
    than trusted from a one-off session:

      - Get-ChaosRunEffectivePlanHash is a faithful mirror of the scope-side
        projection across every skip-signal shape, including a leg that carries
        ONLY `skipped = $true` (the shape that previously diverged).
      - Assert-ChaosEffectivePlanEquality returns true on match and exits 14 on
        mismatch (verified in a child process because it terminates the runspace).
      - Resolve-ChaosRunConfiguration reuses a still-matching preflight config,
        re-creates + proves equality when reuse is impossible, and falls back to
        the historical path when the plan carries no frozen effective plan.

    No network or az calls: every az-touching helper is mocked.

    Run:   Invoke-Pester -Path ./tests/Execute.EffectivePlan.Tests.ps1
#>

BeforeAll {
    $script:SkillRoot   = Split-Path $PSScriptRoot -Parent
    $script:ExecuteLib  = Join-Path $script:SkillRoot 'scripts' 'lib' 'Execute.ps1'
    . $script:ExecuteLib

    # The scope-side projection Get-ChaosRunEffectivePlanHash must mirror. This
    # is the exact shape Invoke-ChaosStudyScope.ps1 hashes into declaredVsEffective.
    function New-ScopeEffectivePlanHash {
        param([int]$Total, [int]$Executable, [string[]]$SkippedSelectors)
        $projection = [ordered]@{
            total      = $Total
            executable = $Executable
            skipped    = @(@($SkippedSelectors) | Sort-Object)
        }
        return Get-ChaosDigest -InputObject $projection
    }

    # Run a script body in a child pwsh and return its exit code. Used to prove
    # the fail-closed exit codes of functions that call `exit` (which terminates
    # the current runspace and cannot be asserted in-process).
    function Invoke-ChaosChildExit {
        param([Parameter(Mandatory)][string]$Body)
        $output = & pwsh -NoProfile -NonInteractive -Command $Body 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 134) { Write-Host ($output | Out-String) }
        return $code
    }
}

Describe 'Get-ChaosRunEffectivePlanHash - scope mirror' {

    It 'hashes an all-executable plan to the same digest scope froze' {
        $validation = [pscustomobject]@{ executionPlan = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'zone-1' }
            [pscustomobject]@{ legSelector = 'zone-2' }
        ) } }
        $expected = New-ScopeEffectivePlanHash -Total 2 -Executable 2 -SkippedSelectors @()
        Get-ChaosRunEffectivePlanHash -Validation $validation | Should -Be $expected
    }

    It 'classifies a leg carrying only skipped=$true as skipped (the divergence fix)' {
        # Platform returns a leg with ONLY the boolean set - no executable=$false,
        # no reason, no skip status. Scope classifies it skipped; the run mirror
        # must too, or the identical plan would hash differently and trip exit 14.
        $validation = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'zone-1' }
            [pscustomobject]@{ legSelector = 'zone-2'; skipped = $true }
        ) }
        $expected = New-ScopeEffectivePlanHash -Total 2 -Executable 1 -SkippedSelectors @('zone-2')
        Get-ChaosRunEffectivePlanHash -Validation $validation | Should -Be $expected
    }

    It 'treats each skip signal (reason, status, executable flag, skipped bool) as skipped' {
        $validation = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'a' }
            [pscustomobject]@{ legSelector = 'b'; reason = 'unsupported sku' }
            [pscustomobject]@{ legSelector = 'c'; status = 'Skipped' }
            [pscustomobject]@{ legSelector = 'd'; executable = $false }
            [pscustomobject]@{ legSelector = 'e'; skipped = $true }
        ) }
        $expected = New-ScopeEffectivePlanHash -Total 5 -Executable 1 -SkippedSelectors @('b', 'c', 'd', 'e')
        Get-ChaosRunEffectivePlanHash -Validation $validation | Should -Be $expected
    }

    It 'is insensitive to skipped-leg order (selectors are sorted both sides)' {
        $forward = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'x'; skipped = $true }
            [pscustomobject]@{ legSelector = 'y'; skipped = $true }
        ) }
        $reverse = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'y'; skipped = $true }
            [pscustomobject]@{ legSelector = 'x'; skipped = $true }
        ) }
        Get-ChaosRunEffectivePlanHash -Validation $forward |
            Should -Be (Get-ChaosRunEffectivePlanHash -Validation $reverse)
    }

    It 'ignores free-text reason wording (equality means same legs, not same words)' {
        $a = [pscustomobject]@{ legs = @([pscustomobject]@{ legSelector = 'z'; reason = 'not applicable' }) }
        $b = [pscustomobject]@{ legs = @([pscustomobject]@{ legSelector = 'z'; reason = 'resource type unsupported' }) }
        Get-ChaosRunEffectivePlanHash -Validation $a |
            Should -Be (Get-ChaosRunEffectivePlanHash -Validation $b)
    }

    It 'reads effectiveLegs on the properties root' {
        $validation = [pscustomobject]@{ properties = [pscustomobject]@{ effectiveLegs = @(
            [pscustomobject]@{ selector = 'only-one' }
        ) } }
        $expected = New-ScopeEffectivePlanHash -Total 1 -Executable 1 -SkippedSelectors @()
        Get-ChaosRunEffectivePlanHash -Validation $validation | Should -Be $expected
    }
}

Describe 'Assert-ChaosEffectivePlanEquality' {

    It 'returns true when the hashes match' {
        Assert-ChaosEffectivePlanEquality -Expected 'abc123' -Actual 'abc123' -ConfigurationName 'cfg' |
            Should -BeTrue
    }

    It 'exits 14 (ScopeUnverified) when the hashes differ' {
        $lib = $script:ExecuteLib
        $body = ". '$lib'`nAssert-ChaosEffectivePlanEquality -Expected 'frozen-hash' -Actual 'drifted-hash' -ConfigurationName 'cfg' | Out-Null"
        Invoke-ChaosChildExit -Body $body | Should -Be 14
    }

    It 'fails closed (exit 14) when either hash is empty rather than passing vacuously' {
        # Two empty strings are equal, but an absent hash is not proof of equality;
        # the gate must never let an unconstrained run through on a missing hash.
        $lib = $script:ExecuteLib
        $body = ". '$lib'`nAssert-ChaosEffectivePlanEquality -Expected '' -Actual '' -ConfigurationName 'cfg' | Out-Null"
        Invoke-ChaosChildExit -Body $body | Should -Be 14
    }
}

Describe 'Resolve-ChaosRunConfiguration' {

    BeforeAll {
        # An effective plan of 2 legs, 1 executable, 'zone-2' skipped.
        $script:frozen = New-ScopeEffectivePlanHash -Total 2 -Executable 1 -SkippedSelectors @('zone-2')
        function New-PlanWithFrozen {
            param([string]$Hash = $script:frozen, [string]$PreflightName = 'preflight-cfg')
            return [pscustomobject]@{
                declaredVsEffective = [pscustomobject]@{
                    effectivePlanHash = $Hash
                    preflight         = [pscustomobject]@{ configurationName = $PreflightName }
                }
            }
        }
        # A validation whose effective plan matches $frozen (and validates Succeeded).
        $script:matchingValidation = [pscustomobject]@{
            status = 'Succeeded'
            legs   = @(
                [pscustomobject]@{ legSelector = 'zone-1' }
                [pscustomobject]@{ legSelector = 'zone-2'; skipped = $true }
            )
        }
        # A validation whose effective plan does NOT match (both legs run).
        $script:driftedValidation = [pscustomobject]@{
            status = 'Succeeded'
            legs   = @(
                [pscustomobject]@{ legSelector = 'zone-1' }
                [pscustomobject]@{ legSelector = 'zone-2' }
            )
        }
    }

    It 'reuses the preflight configuration when it still validates and matches' {
        Mock -CommandName Write-ChaosStudyNote -MockWith {}
        Mock -CommandName Get-ChaosConfigurationValidation -MockWith { $script:matchingValidation }
        Mock -CommandName New-ChaosStudyConfiguration -MockWith { throw 'must not re-create when reuse is possible' }

        $result = Resolve-ChaosRunConfiguration -Plan (New-PlanWithFrozen) -ConfigurationName 'run-cfg'

        $result.reused | Should -BeTrue
        $result.configurationName | Should -Be 'preflight-cfg'
        $result.status | Should -Be 'Succeeded'
        Should -Invoke -CommandName New-ChaosStudyConfiguration -Times 0 -Scope It
    }

    It 're-creates and proves equality when the preflight config drifted' {
        Mock -CommandName Write-ChaosStudyNote -MockWith {}
        Mock -CommandName Get-ChaosConfigurationValidation -MockWith { $script:driftedValidation }
        Mock -CommandName New-ChaosStudyConfiguration -MockWith {}
        Mock -CommandName Resolve-ChaosConfigurationValidation -MockWith {
            [pscustomobject]@{ validation = $script:matchingValidation; status = 'Succeeded'; permissionFix = $null; approvalRequired = $false; approvalPhrase = $null; grantSet = $null }
        }

        $result = Resolve-ChaosRunConfiguration -Plan (New-PlanWithFrozen) -ConfigurationName 'run-cfg'

        $result.reused | Should -BeFalse
        $result.configurationName | Should -Be 'run-cfg'
        $result.status | Should -Be 'Succeeded'
        # Issue #4: the returned validation is the object equality was proved over,
        # not a third re-fetch. So no extra Get-ChaosConfigurationValidation for run-cfg.
        Should -Invoke -CommandName New-ChaosStudyConfiguration -Times 1 -Scope It
        Should -Invoke -CommandName Resolve-ChaosConfigurationValidation -Times 1 -Scope It
    }

    It 'falls back to the historical create+validate path when no plan is frozen' {
        Mock -CommandName Write-ChaosStudyNote -MockWith {}
        Mock -CommandName New-ChaosStudyConfiguration -MockWith {}
        Mock -CommandName Resolve-ChaosConfigurationValidation -MockWith {
            [pscustomobject]@{ validation = $script:matchingValidation; status = 'Succeeded'; permissionFix = 'fixed'; approvalRequired = $false; approvalPhrase = $null; grantSet = $null }
        }
        Mock -CommandName Get-ChaosConfigurationValidation -MockWith { throw 'reuse path must not run without a frozen hash' }

        $planNoFrozen = [pscustomobject]@{ planVersion = '3' }
        $result = Resolve-ChaosRunConfiguration -Plan $planNoFrozen -ConfigurationName 'run-cfg'

        $result.reused | Should -BeFalse
        $result.configurationName | Should -Be 'run-cfg'
        $result.permissionFix | Should -Be 'fixed'
        Should -Invoke -CommandName Resolve-ChaosConfigurationValidation -Times 1 -Scope It
    }

    It 'exits 14 when the re-created configuration cannot reproduce the frozen plan' {
        # No frozen preflight name (so no reuse attempt), re-create yields a
        # drifted plan; equality must fail-closed with ScopeUnverified.
        $lib = $script:ExecuteLib
        $frozen = $script:frozen
        $body = @"
. '$lib'
function Write-ChaosStudyNote { param([Parameter(ValueFromRemainingArguments)]`$a) }
function New-ChaosStudyConfiguration { param([Parameter(ValueFromRemainingArguments)]`$a) }
function Resolve-ChaosConfigurationValidation {
    param([Parameter(ValueFromRemainingArguments)]`$a)
    [pscustomobject]@{
        validation = [pscustomobject]@{ legs = @(
            [pscustomobject]@{ legSelector = 'zone-1' },
            [pscustomobject]@{ legSelector = 'zone-2' }
        ) }
        status = 'Succeeded'; permissionFix = `$null; approvalRequired = `$false; approvalPhrase = `$null; grantSet = `$null
    }
}
`$plan = [pscustomobject]@{ declaredVsEffective = [pscustomobject]@{ effectivePlanHash = '$frozen' } }
Resolve-ChaosRunConfiguration -Plan `$plan -ConfigurationName 'run-cfg' | Out-Null
"@
        Invoke-ChaosChildExit -Body $body | Should -Be 14
    }
}
