# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Captured service responses are fixtures only. No Azure executable is invoked.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Shared = "$script:Skills/chaos-study/scripts/lib"
    $script:ScopeEntry = "$script:Skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1"
    $script:ValidationFixture = "$PSScriptRoot/fixtures/live-validation-internal-error.json"
    . "$script:Shared/Operation.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Signals.ps1"
}

Describe 'L1 captured ARM validation contract' {
    It 'normalizes <Shape> validation through the operation seam without losing errors or execution plan' -ForEach @(
        @{ Shape = 'nested' }, @{ Shape = 'flattened' }
    ) {
        $script:CapturedValidation = Read-ChaosJsonFile $script:ValidationFixture
        if ($Shape -eq 'flattened') { $script:CapturedValidation = $script:CapturedValidation.properties }
        Mock Test-ChaosLocalAzAdapterReady { @() }
        Mock Invoke-ChaosStudyAzChaos { $script:CapturedValidation }
        $result = Invoke-ChaosStudyOperation -Kind config.validate -Arguments @{ cliArgs = @('--subscription', 'sub') } -ExpectedSchema validation.v2 -Adapter local-az
        $result.status | Should -Be RequiresAttention
        $result.errors[0].errorCode | Should -Be InternalError
        ($result.errors -is [object[]]) | Should -BeTrue
        $result.executionPlanJson | Should -Not -BeNullOrEmpty
        $error = @(Get-ChaosValidationError $result)[0]
        $error.repairable | Should -BeFalse
        $error.category | Should -Match system
    }

    Describe 'L2 data-derived telemetry tolerance' {
        It 'freezes live readiness samples in v4 and enforces scope override <Override>' -ForEach @(
            @{ Override = $null; ExpectedExit = 0; ExpectedIntervals = 3 }
            @{ Override = 2; ExpectedExit = 10; ExpectedIntervals = $null }
            @{ Override = 4; ExpectedExit = 0; ExpectedIntervals = 4 }
        ) {
            $root = "$TestDrive/scope-$Override"
            $args = @{ Skills = $script:Skills; StudyRoot = $root }
            if ($null -ne $Override) { $args.UnavailableIntervals = $Override }
            $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" @args 2>&1
            $LASTEXITCODE | Should -Be $ExpectedExit -Because ($output | Out-String)
            if ($ExpectedExit -ne 0) {
                ($output | Out-String) | Should -Match 'minimum 3'
                (Get-Content "$root/az-calls" -Raw) | Should -Not -Match 'config create'
                return
            }
            $study = Find-ChaosStudy -StudyRoot $root -StudyId latest
            $reader = Get-ChaosArtifactReader -StudyPath $study.path -Artifact plan
            $reader.version | Should -Be 4
            $plan = Read-ChaosJsonFile $reader.path
            $plan.planVersion | Should -Be study-plan.v4
            $plan.discovery.telemetryLag.derivedUnavailableIntervals | Should -Be 3
            $plan.discovery.telemetryLag.queries.Count | Should -Be 2
            $plan.discovery.telemetryLag.queries[0].ageSeconds | Should -Be 63
            $plan.discovery.telemetryLag.queries[1].ageSeconds | Should -Be 67
            ($output | Out-String) | Should -Match "$ExpectedIntervals intervals"
            ($output | Out-String) | Should -Match 'ageSeconds'
            ($plan.safety.abortConditions | Where-Object kind -eq missing-signal).unavailableIntervals | Should -Be $ExpectedIntervals
            @(Get-Content "$root/sleeps").Count | Should -Be 1
            @(Get-Content "$root/sleeps")[0] | Should -Be '60'
            $preview = & pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -StudyRoot $root 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($preview | Out-String)
            ($preview | Out-String) | Should -Match "$ExpectedIntervals intervals"
            ($preview | Out-String) | Should -Match 'ageSeconds'
        }

        It 'stops full scoping before config creation when <Reason>' -ForEach @(
            @{ Reason = 'the baseline is one grain'; Baseline = 1; Empty = $false }
            @{ Reason = 'telemetry has no non-null buckets'; Baseline = 5; Empty = $true }
        ) {
            $root = "$TestDrive/refused-$Baseline"
            $args = @{ Skills = $script:Skills; StudyRoot = $root; BaselineMinutes = $Baseline }
            if ($Empty) { $args.NoBuckets = $true }
            $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" @args 2>&1
            $LASTEXITCODE | Should -Be 10 -Because ($output | Out-String)
            (Get-Content "$root/az-calls" -Raw) | Should -Not -Match 'config create'
            @(Get-ChildItem $root -Recurse -Filter 'study-plan.*.json').Count | Should -Be 0
        }

        It 'derives three intervals from the observed 63/66/67-second ages and preserves samples' {
            $queries = @(63, 66, 67 | ForEach-Object {
                [pscustomobject]@{ atUtc = '2026-09-06T00:21:07Z'; newestNonNullBucketUtc = '2026-09-06T00:20:00Z'; ageSeconds = $_ }
            })
            $lag = New-ChaosTelemetryLag -Queries $queries -BaselineMinutes 5 -GrainSeconds 60
            $lag.derivedUnavailableIntervals | Should -Be 3
            $lag.unavailableIntervals | Should -Be 3
            $lag.queries.Count | Should -Be 3
            ($lag.queries.ageSeconds -join ',') | Should -Be '63,66,67'
            { New-ChaosTelemetryLag -Queries $queries -BaselineMinutes 5 -GrainSeconds 60 -UnavailableIntervals 2 } | Should -Throw '*minimum 3*'
            (New-ChaosTelemetryLag -Queries $queries -BaselineMinutes 5 -GrainSeconds 60 -UnavailableIntervals 4).unavailableIntervals | Should -Be 4
        }

        It 'measures exactly twice one grain apart over the existing baseline budget' {
            $script:LagQueries = 0
            $script:LagClock = [datetime]'2026-09-06T00:21:07Z'
            Mock Get-ChaosUtcNow { ConvertTo-ChaosUtcIso $script:LagClock }
            Mock Start-Sleep { $script:LagClock = $script:LagClock.AddSeconds($Seconds) }
            Mock Invoke-ChaosSignalCollection {
                $script:LagQueries++
                $age = if ($script:LagQueries -eq 1) { 63 } else { 67 }
                return ,@(New-ChaosSignalResult -Source metrics:Availability -Window $Window.name -Values @(
                    [pscustomobject]@{ timestamp = ConvertTo-ChaosUtcIso $script:LagClock.AddSeconds(-$age); value = 1 }
                ))
            }
            $plan = [pscustomobject]@{ scope = [pscustomobject]@{ projectedResources = @('/r') } }
            $lag = Measure-ChaosTelemetryLag -Plan $plan -Sources @('metrics:Availability') -BaselineMinutes 5 -Adapter local-az -StudyPath $TestDrive
            $lag.derivedUnavailableIntervals | Should -Be 3
            $lag.queries.Count | Should -Be 2
            $lag.bucketBudget | Should -Be 5
            $lag.queries[0].ageSeconds | Should -Be 63
            $lag.queries[1].ageSeconds | Should -Be 67
            Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 60 }
            Should -Invoke Invoke-ChaosSignalCollection -Times 2 -ParameterFilter { $Window.durationSeconds -eq 300 }
        }

        It 'refuses to freeze without two grains of baseline or any non-null buckets' {
            Mock Invoke-ChaosSignalCollection { return ,@(New-ChaosSignalResult -Source metrics:Availability -Window readiness -Caveat 'No non-null buckets') }
            Mock Start-Sleep {}
            $plan = [pscustomobject]@{ scope = [pscustomobject]@{ projectedResources = @('/r') } }
            { Measure-ChaosTelemetryLag -Plan $plan -Sources @('metrics:Availability') -BaselineMinutes 1 -Adapter local-az -StudyPath $TestDrive } | Should -Throw '*two grains*'
            Should -Invoke Invoke-ChaosSignalCollection -Times 0
            { Measure-ChaosTelemetryLag -Plan $plan -Sources @('metrics:Availability') -BaselineMinutes 5 -Adapter local-az -StudyPath $TestDrive } | Should -Throw '*non-null*'
        }

        It 'uses the derived frozen tolerance while a missing predicate remains unmeasured' {
            $lag = New-ChaosTelemetryLag -Queries @([pscustomobject]@{ ageSeconds = 67 }) -BaselineMinutes 5 -GrainSeconds 60
            $plan = @{ safety = @{ abortConditions = @(
                @{ id = 'predicate'; kind = 'predicate'; predicate = @{ raw = 'Availability >= 1'; signal = 'Availability'; comparison = '>='; threshold = 1 } }
                @{ id = 'missing'; kind = 'missing-signal'; sources = @('metrics:Availability'); intervalSeconds = 60; unavailableIntervals = $lag.unavailableIntervals }
            ) } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $start = ConvertFrom-ChaosUtcIso '2026-09-06T00:20:00Z'
            $state = [ordered]@{}
            $check = Invoke-ChaosAbortEvaluation -Plan $plan -Signals @() -Window (New-ChaosWindow abort-check $start $start.AddSeconds(120)) -InjectionStartedAt $start -State $state
            $check.triggered | Should -BeFalse
            ($check.evaluations | Where-Object kind -eq predicate).status | Should -Be not-measured
            (Invoke-ChaosAbortEvaluation -Plan $plan -Signals @() -Window (New-ChaosWindow abort-check $start $start.AddSeconds(180)) -InjectionStartedAt $start -State $state).trigger.kind | Should -Be missing-signal
            $plan | Add-Member discovery ([pscustomobject]@{ telemetryLag = $lag })
            $plan | Add-Member frozenConfigHash abc
            $plan | Add-Member scenario ([pscustomobject]@{ parameters = @() })
            $plan | Add-Member action ([pscustomobject]@{ actionType = 'Cancelable' })
            $text = Write-ChaosStudyDryRunContract -Plan $plan -ConfigurationName cfg | Out-String
            $text | Should -Match '3 interval'
            $text | Should -Match '67'
        }

        It 'versions the lag-bearing plan and reads v3 plans without allowing writes' {
            Get-ChaosArtifactFileName plan | Should -Be study-plan.v4.json
            '{}' | Set-Content "$TestDrive/study-plan.v3.json"
            $reader = Get-ChaosArtifactReader -StudyPath $TestDrive -Artifact plan
            $reader.version | Should -Be 3
            { Assert-ChaosStudyWriteCompatible -StudyPath $TestDrive } | Should -Throw '*read-only*'
        }
    }

    It 'cleans up and exits 17 for <Shape> through the real operation seam' -ForEach @(
        @{ Shape = 'nested' }, @{ Shape = 'flattened' }, @{ Shape = 'missing-status' }
    ) {
        $root = "$TestDrive/$Shape"
        New-Item -ItemType Directory $root -Force | Out-Null
        $child = @"
`$ErrorActionPreference = 'Stop'
. '$script:Skills/chaos-study-run/scripts/lib/Execute.ps1'
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$script:ScopeEntry',[ref]`$null,[ref]`$null)
foreach (`$node in `$ast.EndBlock.Statements) {
    if (`$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -match '^(New-ChaosPreflightConfiguration|Get-ChaosPreflightConfigurationName|Get-ChaosPreflightValidationStatus)$') { . ([scriptblock]::Create(`$node.Extent.Text)) }
}
function global:az { throw 'Azure is prohibited' }
function Invoke-ChaosStudyAzChaos {
    param(`$ChaosArgs,`$JsonArg,`$AllowFailure)
    `$ChaosArgs[2] | Add-Content '$root/calls'
    switch (`$ChaosArgs[2]) {
        create { [pscustomobject]@{name='preflight-test'} }
        validate {
            `$raw = Read-ChaosJsonFile '$script:ValidationFixture'
            if ('$Shape' -eq 'flattened') { `$raw.properties }
            elseif ('$Shape' -eq 'missing-status') { [pscustomobject]@{name='cfg';properties=[pscustomobject]@{errors=`$raw.properties.errors}} }
            else { `$raw }
        }
        delete { throw 'BadRequest: Nullable object must have a value.' }
        list { return ,@() }
        default { throw "Unexpected operation: `$ChaosArgs" }
    }
}
`$plan = [pscustomobject]@{
    workspace=[pscustomobject]@{subscriptionId='sub';resourceGroup='rg';name='ws'}
    scenario=[pscustomobject]@{name='scenario';parameters=@()}
    scope=[pscustomobject]@{blastRadius=`$null}
}
New-ChaosPreflightConfiguration -StudyId test -Plan `$plan -Adapter local-az -StudyPath '$root'
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        $calls = @(Get-Content "$root/calls")
        @($calls | Where-Object { $_ -eq 'delete' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -eq 'list' }).Count | Should -Be 1
        $entry = (Read-ChaosJsonFile "$root/residue-ledger.json").entries[0]
        $entry.cleanup.status | Should -Be succeeded
        $entry.cleanup.observation.certainty | Should -Be effective-with-service-error
        $validation = Get-Content "$root/evidence/preflight/validation.json" -Raw
        if ($Shape -eq 'missing-status') { $validation | Should -Match 'ValidationFailed.*status' }
        else { $validation | Should -Match InternalError }
        ($output | Out-String) | Should -Not -Match 'null-valued expression'
    }

    It 'propagates a failed scope exit before reading an empty study id' {
        $root = "$TestDrive/front"
        New-Item -ItemType Directory "$root/skills" -Force | Out-Null
        Copy-Item "$script:Skills/chaos-study*" "$root/skills" -Recurse
        "param([Parameter(ValueFromRemainingArguments)]`$Rest); exit 17" | Set-Content "$root/skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1"
        $output = & pwsh -NoProfile -NonInteractive -File "$root/skills/chaos-study/scripts/Invoke-ChaosStudy.ps1" -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Brief unused 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        ($output | Out-String) | Should -Not -Match 'null-valued expression'
    }
}
