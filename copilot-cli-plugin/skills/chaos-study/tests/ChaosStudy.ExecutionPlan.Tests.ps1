# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Fixture = "$PSScriptRoot/fixtures/live-service-execution-plan.json"
    . "$script:Skills/chaos-study-scope/scripts/lib/Readiness.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . "$script:Skills/chaos-study-scope/scripts/lib/Workspace.ps1"
    $script:FixtureText = [IO.File]::ReadAllText($script:Fixture)
    $script:FixtureHash = '9e0de423acf2eea8f14a0d1dbb1c8390431ec447a55918850e0404f91851a7c2'
}

Describe 'G1 live execution-plan projection' {
    It 'uses the byte-identical captured service execution plan' {
        Get-ChaosSha256 -Path $script:Fixture | Should -Be $script:FixtureHash
    }

    It 'maps <Shape> to the 23 declared actions and the one executable VM leg' -ForEach @(
        @{ Shape = 'string' }, @{ Shape = 'object' }, @{ Shape = 'normalized-validation' }, @{ Shape = 'ARM-validation' }
    ) {
        $plan = switch ($Shape) {
            string { $script:FixtureText }
            object { $script:FixtureText | ConvertFrom-Json }
            normalized-validation { [pscustomobject]@{ status = 'Succeeded'; executionPlanJson = $script:FixtureText } }
            ARM-validation { [pscustomobject]@{ properties = [pscustomobject]@{ status = 'Succeeded'; executionPlanJson = $script:FixtureText } } }
        }
        $effective = Resolve-ChaosEffectiveLegs -ExecutionPlan $plan
        $effective.total | Should -Be 23
        $effective.executable | Should -Be 1
        $effective.executableSelectors | Should -Be @('vmZoneDown')
        $effective.skipped.Count | Should -Be 22
        $leg = @(Get-ChaosExecutionPlanLegs $plan | Where-Object legSelector -eq vmZoneDown)[0]
        $leg.skipped | Should -BeFalse
        @($leg.targets).Count | Should -Be 1
        $leg.targets[0].fullyQualifiedIdentifier | Should -Be '/subscriptions/fb74b135-894b-4c1d-9b2e-8a3c231abc14/resourceGroups/chaos-demo-rg/providers/Microsoft.Compute/virtualMachines/renzo-demo-vmss_3a6899ac'
        $leg.targets[0].metadata.zones | Should -Be @('1')
        $expected = Get-ChaosDigest ([ordered]@{
            total = 23; executable = 1; skipped = @($effective.skipped.legSelector | Sort-Object)
        })
        Get-ChaosRunEffectivePlanHash -Validation $plan | Should -Be $expected
    }

    It 'preserves <Shape> projections and matching run hashes' -ForEach @(@{ Shape = 'legs' }, @{ Shape = 'steps' }) {
        $legs = @(
            [pscustomobject]@{ legSelector = 'a'; action = 'fault' }
            [pscustomobject]@{ legSelector = 'b'; action = 'fault'; reason = 'excluded' }
        )
        $plan = if ($Shape -eq 'legs') { [pscustomobject]@{ legs = $legs } } else {
            [pscustomobject]@{ steps = @([pscustomobject]@{ branches = @([pscustomobject]@{
                actions = @([pscustomobject]@{ name = 'fault'; targets = $legs })
            }) }) }
        }
        $effective = Resolve-ChaosEffectiveLegs $plan
        $effective.total | Should -Be 2
        $effective.executable | Should -Be 1
        $effective.executableSelectors | Should -Be @('a')
        $effective.skipped[0].legSelector | Should -Be b
        Get-ChaosRunEffectivePlanHash $plan | Should -Be (Get-ChaosDigest ([ordered]@{ total = 2; executable = 1; skipped = @('b') }))
    }

    It 'rejects malformed executionPlanJson rather than treating it as zero legs' {
        { Get-ChaosExecutionPlanLegs ([pscustomobject]@{ executionPlanJson = 'not-json' }) } | Should -Throw '*InvalidExecutionPlan*'
    }

    It 'freezes a scope from the captured plan when its exact partial scope is accepted' {
        $effective = [pscustomobject]@{
            total = 23; executable = 1
            skipped = @(
                ($script:FixtureText | ConvertFrom-Json).actions.PSObject.Properties |
                    Where-Object { $_.Value.skip } | ForEach-Object { [pscustomobject]@{ legSelector = $_.Name } }
            )
        }
        $scopeHash = Get-ChaosScopeHash -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Scope @('/subscriptions/sub/resourceGroups/rg') -Region westus2
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash $scopeHash -ScenarioName fixture -EffectiveLegs $effective
        $phrase = Get-ChaosPartialScenarioPhrase -EffectiveLegs $effective -BindingHash $binding
        $root = "$TestDrive/accepted"
        $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" -Skills $script:Skills -StudyRoot $root -ExecutionPlanPath $script:Fixture -AcceptPartialScenario $phrase 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $study = Find-ChaosStudy -StudyRoot $root -StudyId latest
        $plan = Read-ChaosJsonFile (Get-ChaosArtifactReader -StudyPath $study.path -Artifact plan).path
        $plan.declaredVsEffective.legs.total | Should -Be 23
        $plan.declaredVsEffective.legs.executable | Should -Be 1
        $plan.declaredVsEffective.effectivePlanHash | Should -Be (Get-ChaosRunEffectivePlanHash ([pscustomobject]@{ executionPlanJson = $script:FixtureText }))
        (Get-Content "$root/az-calls" -Raw) | Should -Not -Match 'config delete'
    }
}

Describe 'G1 unverifiable preflight cleanup' {
    It 'exits 14 and performs bounded cleanup for <Case> with <DeleteResult>' -ForEach @(
        @{ Case = 'malformed'; DeleteResult = 'absent'; Lists = 1; Status = 'succeeded'; Scenario = 'fixture' }
        @{ Case = 'all-skipped'; DeleteResult = 'success'; Lists = 0; Status = 'succeeded'; Scenario = 'fixture' }
        @{ Case = 'empty'; DeleteResult = 'present'; Lists = 1; Status = 'failed'; Scenario = 'fixture' }
        @{ Case = 'empty-actions'; DeleteResult = 'success'; Lists = 0; Status = 'succeeded'; Scenario = 'fixture' }
        @{ Case = 'zone-mismatch'; DeleteResult = 'success'; Lists = 0; Status = 'succeeded'; Scenario = 'zone-2-down' }
    ) {
        $root = "$TestDrive/$Case"
        New-Item -ItemType Directory $root -Force | Out-Null
        $raw = switch ($Case) {
            malformed { 'not-json "sig=must-remain-verbatim"' }
            all-skipped { '{"actions":{"vm":{"skip":true,"properties":{"targetResources":[]}}}}' }
            empty { '{"legs":[]}' }
            empty-actions { '{"actions":{}}' }
            zone-mismatch { '{"legs":[{"legSelector":"zone-1","action":"fault"}]}' }
        }
        $path = "$root/input-plan.json"
        [IO.File]::WriteAllText($path, $raw)
        $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" -Skills $script:Skills -StudyRoot $root -ExecutionPlanPath $path -DeleteResult $DeleteResult -ScenarioName $Scenario 2>&1
        $LASTEXITCODE | Should -Be 14 -Because ($output | Out-String)
        $ledgerFile = @(Get-ChildItem $root -Recurse -Filter residue-ledger.json)
        $ledgerFile.Count | Should -Be 1
        $ledger = Read-ChaosJsonFile $ledgerFile[0].FullName
        $ledger.entries.Count | Should -Be 1
        $ledger.entries[0].kind | Should -Be preflightConfiguration
        $ledger.entries[0].cleanup.status | Should -Be $Status
        $calls = @(Get-Content "$root/az-calls")
        @($calls | Where-Object { $_ -like '*scenario config delete *' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like '*scenario config list *' }).Count | Should -Be $Lists
        @($calls | Where-Object { $_ -like '*scenario run start *' }).Count | Should -Be 0
        @(Get-ChildItem $root -Recurse -Filter 'study-plan.v4.json').Count | Should -Be 0
        $rawEvidence = Join-Path $ledgerFile[0].Directory.FullName 'evidence/preflight/execution-plan.json'
        [IO.File]::ReadAllText($rawEvidence) | Should -BeExactly $raw
        if ($Case -eq 'malformed') { ($output | Out-String) | Should -Match InvalidExecutionPlan }
    }
}
