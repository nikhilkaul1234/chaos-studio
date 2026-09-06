# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Readiness = "$script:Skills/chaos-study-scope/scripts/lib/Readiness.ps1"
    $script:Fixture = "$PSScriptRoot/fixtures/live-service-execution-plan.json"
    $script:ScopeFixture = "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1"
    . $script:Readiness
    . "$script:Skills/chaos-study-scope/scripts/lib/Workspace.ps1"
    . "$script:Skills/chaos-study/scripts/lib/Study.ps1"
}

Describe 'G2 partial preflight cleanup' {
    It 'records cleanup before exit 20 with <DeleteResult>' -ForEach @(
        @{ DeleteResult = 'success'; ExpectedStatus = 'succeeded'; Lists = 0 }
        @{ DeleteResult = 'absent'; ExpectedStatus = 'succeeded'; Lists = 1 }
        @{ DeleteResult = 'present'; ExpectedStatus = 'failed'; Lists = 1 }
    ) {
        $root = "$TestDrive/partial-$DeleteResult"
        $output = & pwsh -NoProfile -NonInteractive -File $script:ScopeFixture -Skills $script:Skills -StudyRoot $root -ExecutionPlanPath $script:Fixture -DeleteResult $DeleteResult 2>&1
        $LASTEXITCODE | Should -Be 20 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match '1 of 23'
        $ledgerFile = @(Get-ChildItem $root -Recurse -Filter residue-ledger.json)
        $ledgerFile.Count | Should -Be 1
        $entry = (Read-ChaosJsonFile $ledgerFile[0].FullName).entries[0]
        $entry.kind | Should -Be preflightConfiguration
        $entry.cleanup.status | Should -Be $ExpectedStatus
        $entry.cleanup.attemptedAt | Should -Not -BeNullOrEmpty
        $calls = @(Get-Content "$root/az-calls")
        @($calls | Where-Object { $_ -like '*scenario config create *' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like '*scenario config delete *' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like '*scenario config list *' }).Count | Should -Be $Lists
        if ($DeleteResult -eq 'absent') { $entry.cleanup.observation.certainty | Should -Be effective-with-service-error }
    }

    It 'does not leave two configurations when a follow-up scope accepts the partial plan (<DeleteResult>)' -ForEach @(
        @{ DeleteResult = 'success' }, @{ DeleteResult = 'absent' }
    ) {
        $root = "$TestDrive/followup-$DeleteResult"
        $inventory = "$TestDrive/inventory-$DeleteResult.json"
        $args = @{
            Skills = $script:Skills; StudyRoot = $root; ExecutionPlanPath = $script:Fixture
            DeleteResult = $DeleteResult; ConfigurationInventoryPath = $inventory
        }
        $output = & pwsh -NoProfile -NonInteractive -File $script:ScopeFixture @args 2>&1
        $LASTEXITCODE | Should -Be 20 -Because ($output | Out-String)
        $firstLedger = @(Get-ChildItem $root -Recurse -Filter residue-ledger.json)[0].FullName
        $firstName = (Read-ChaosJsonFile $firstLedger).entries[0].id
        $phrase = [regex]::Match(($output | Out-String), 'accept partial scenario 1 of 23 [0-9a-f]+').Value
        $phrase | Should -Not -BeNullOrEmpty
        $args.AcceptPartialScenario = $phrase
        $output = & pwsh -NoProfile -NonInteractive -File $script:ScopeFixture @args 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $planFiles = @(Get-ChildItem $root -Recurse -Filter study-plan.v4.json)
        $planFiles.Count | Should -Be 1
        $plan = Read-ChaosJsonFile $planFiles[0].FullName
        $remaining = @(Get-Content $inventory -Raw | ConvertFrom-Json)
        $remaining.Count | Should -Be 1
        $remaining[0] | Should -Be $plan.declaredVsEffective.preflight.configurationName
        $remaining | Should -Not -Contain $firstName
        (Read-ChaosJsonFile $firstLedger).entries[0].cleanup.status | Should -Be succeeded
        $calls = @(Get-Content "$root/az-calls")
        @($calls | Where-Object { $_ -like '*scenario config create *' }).Count | Should -Be 2
        @($calls | Where-Object { $_ -like '*scenario config delete *' }).Count | Should -Be 1
    }
}

Describe 'Target-metadata zone honesty' {
    It 'accepts zone 1 from executable vmZoneDown target metadata' {
        $child = @"
. '$script:Readiness'
`$plan = [IO.File]::ReadAllText('$script:Fixture')
`$effective = Resolve-ChaosEffectiveLegs `$plan
Assert-ChaosScenarioNameHonest -ScenarioName 'zone-1-down' -EffectiveLegs `$effective | Out-Null
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }

    It 'rejects a misleading selector when <Case>' -ForEach @(
        @{ Case = 'target belongs to another zone'; Target = '{"metadata":{"zones":["1"]}}' }
        @{ Case = 'target zone is unknown'; Target = '{"metadata":{}}' }
    ) {
        $child = @"
. '$script:Readiness'
`$plan = '{"actions":{"zone-2":{"skip":false,"properties":{"targetResources":[$Target]}},"skipped-zone-2":{"skip":true,"properties":{"targetResources":[{"metadata":{"zones":["2"]}}]}}}}' | ConvertFrom-Json
`$effective = Resolve-ChaosEffectiveLegs `$plan
Assert-ChaosScenarioNameHonest -ScenarioName 'zone-2-down' -EffectiveLegs `$effective | Out-Null
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 14 -Because ($output | Out-String)
    }
}
