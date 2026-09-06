# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Readiness = "$script:Skills/chaos-study-scope/scripts/lib/Readiness.ps1"
    $script:Fixture = "$PSScriptRoot/fixtures/live-service-execution-plan.json"
    . $script:Readiness
    . "$script:Skills/chaos-study-scope/scripts/lib/Workspace.ps1"
    . "$script:Skills/chaos-study/scripts/lib/Study.ps1"

    function New-ZonePlan {
        @{
            scenario = @{ name = 'ZoneDown-1.0'; parameters = @(); parameterSpec = @() }
            action = @{ parametersSchema = @{ properties = @{ Zones = @{ type = @('array', 'null') } } } }
            scope = @{ blastRadius = @{ filters = $null } }
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }
    function Invoke-ZoneGuard {
        param([object]$Plan, [object]$ExecutionPlan, [string]$ScenarioName = 'ZoneDown-1.0')
        $inputPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.clixml')
        @{ Plan = $Plan; ExecutionPlan = $ExecutionPlan } | Export-Clixml $inputPath -Depth 20
        $command = @"
. '$script:Readiness'
`$input = Import-Clixml '$inputPath'
`$effective = Resolve-ChaosEffectiveLegs `$input.ExecutionPlan
`$guardArgs = @{ ScenarioName = '$ScenarioName'; EffectiveLegs = `$effective }
if ((Get-Command Assert-ChaosScenarioNameHonest).Parameters.ContainsKey('Plan')) { `$guardArgs.Plan = `$input.Plan }
Assert-ChaosScenarioNameHonest @guardArgs | Out-Null
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        return [pscustomobject]@{ code = $LASTEXITCODE; output = $output | Out-String }
    }
}

Describe 'G2b authoritative zone declarations' {
    It 'does not mistake the captured scenario version for a declared zone' {
        $scenario = Get-Content "$PSScriptRoot/fixtures/live-zone-down-scenario.json" -Raw | ConvertFrom-Json
        $action = Get-Content "$PSScriptRoot/fixtures/live-shutdown-action.json" -Raw | ConvertFrom-Json
        $scenario.name | Should -Be 'ZoneDown-1.0'
        $scenario.properties.version | Should -Be '1.0'
        @($scenario.properties.parameters | Where-Object name -eq Zones).Count | Should -Be 0
        ($scenario.properties.actions | Where-Object name -eq vmZoneDown).parameters[0].value | Should -Be '%%{filters.zones}%%'
        $action.properties.parametersSchema.properties.Zones.PSObject.Properties.Name | Should -Not -Contain default
    }

    It 'enforces an effective <Source> zone declaration independently of the versioned name' -ForEach @(
        @{ Source = 'scenario-default' }, @{ Source = 'scenario-override' }, @{ Source = 'filter' },
        @{ Source = 'action-default' }, @{ Source = 'action-override' }
    ) {
        $plan = New-ZonePlan
        switch ($Source) {
            scenario-default { $plan.scenario.parameterSpec = @([pscustomobject]@{ name = 'Zones'; default = @('2') }) }
            scenario-override {
                $plan.scenario.parameterSpec = @([pscustomobject]@{ name = 'Zones'; default = @('1') })
                $plan.scenario.parameters = @([pscustomobject]@{ key = 'Zones'; value = '["2"]' })
            }
            filter { $plan.scope.blastRadius.filters = [pscustomobject]@{ zones = @('2') } }
            action-default { $plan.action.parametersSchema.properties.Zones | Add-Member default @('2') }
            action-override {
                $plan.action.parametersSchema.properties.Zones | Add-Member default @('1')
                $plan.action | Add-Member parameters @([pscustomobject]@{ key = 'Zones'; value = @('2') })
            }
        }
        $execution = Get-Content $script:Fixture -Raw | ConvertFrom-Json
        $rejected = Invoke-ZoneGuard -Plan $plan -ExecutionPlan $execution
        $rejected.code | Should -Be 14 -Because $rejected.output
        $execution.actions.vmZoneDown.properties.targetResources[0].metadata.zones = @('2')
        $accepted = Invoke-ZoneGuard -Plan $plan -ExecutionPlan $execution
        $accepted.code | Should -Be 0 -Because $accepted.output
        (Invoke-ZoneGuard -Plan $plan -ExecutionPlan $execution -ScenarioName 'zone-1-down').code | Should -Be 0
    }

    It 'requires every executable target zone to be declared and refuses unknown metadata' -ForEach @(
        @{ Case = 'extra-zone'; Zones = @('1','2'); Unknown = $false }
        @{ Case = 'unknown-target'; Zones = @('1'); Unknown = $true }
    ) {
        $plan = New-ZonePlan
        $plan.scope.blastRadius.filters = [pscustomobject]@{ zones = @('1') }
        $execution = Get-Content $script:Fixture -Raw | ConvertFrom-Json
        $execution.actions.vmZoneDown.properties.targetResources[0].metadata.zones = $Zones
        if ($Unknown) { $execution.actions.vmZoneDown.properties.targetResources += [pscustomobject]@{ fullyQualifiedIdentifier = '/unknown'; metadata = [pscustomobject]@{} } }
        $result = Invoke-ZoneGuard -Plan $plan -ExecutionPlan $execution
        $result.code | Should -Be 14 -Because $result.output
    }

    It 'keeps an unfiltered versioned scenario and legacy targetless behavior free of invented zone claims' {
        $plan = New-ZonePlan
        $execution = Get-Content $script:Fixture -Raw | ConvertFrom-Json
        $execution.actions.vmZoneDown.properties.targetResources[0].metadata.zones = @('2')
        (Invoke-ZoneGuard -Plan $plan -ExecutionPlan $execution).code | Should -Be 0
        (Invoke-ZoneGuard -Plan $plan -ExecutionPlan ([pscustomobject]@{ legs = @([pscustomobject]@{ legSelector = 'zone-1' }) })).code | Should -Be 0
    }
}

Describe 'G2b exact captured scenario scope' {
    It 'prints <Label> before approval in both scope and dry-run' -ForEach @(
        @{ Label = 'the declared zone'; Filter = '1'; ExpectedText = 'Declared zone filter: ["1"]' }
        @{ Label = 'no zone claim'; Filter = $null; ExpectedText = 'Declared zone filter: none - no zone claim' }
    ) {
        $root = "$TestDrive/display-$Filter"
        $effective = Resolve-ChaosEffectiveLegs ([IO.File]::ReadAllText($script:Fixture))
        $scopeHash = Get-ChaosScopeHash -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Scope @('/subscriptions/sub/resourceGroups/rg') -Region westus2
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash $scopeHash -ScenarioName 'ZoneDown-1.0' -EffectiveLegs $effective
        $args = @{
            Skills = $script:Skills; StudyRoot = $root; ExecutionPlanPath = $script:Fixture; UseLiveZoneDefinitions = $true
            AcceptPartialScenario = Get-ChaosPartialScenarioPhrase -EffectiveLegs $effective -BindingHash $binding
        }
        if ($Filter) { $args.FilterZone = $Filter }
        $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" @args 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match ([regex]::Escape($ExpectedText))
        $preview = & pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($preview | Out-String)
        ($preview | Out-String) | Should -Match ([regex]::Escape($ExpectedText))
    }

    It 'uses declared FilterZone 1 for ZoneDown-1.0 with target zone <TargetZone>' -ForEach @(
        @{ TargetZone = '1'; Expected = 0 }, @{ TargetZone = '2'; Expected = 14 }
    ) {
        $root = "$TestDrive/scope-$TargetZone"
        $execution = Get-Content $script:Fixture -Raw | ConvertFrom-Json
        $execution.actions.vmZoneDown.properties.targetResources[0].metadata.zones = @($TargetZone)
        $path = "$TestDrive/execution-$TargetZone.json"
        $execution | ConvertTo-Json -Depth 32 | Set-Content $path
        $effective = Resolve-ChaosEffectiveLegs $execution
        $scopeHash = Get-ChaosScopeHash -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Scope @('/subscriptions/sub/resourceGroups/rg') -Region westus2
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash $scopeHash -ScenarioName 'ZoneDown-1.0' -EffectiveLegs $effective
        $phrase = Get-ChaosPartialScenarioPhrase -EffectiveLegs $effective -BindingHash $binding
        $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" `
            -Skills $script:Skills -StudyRoot $root -ExecutionPlanPath $path -UseLiveZoneDefinitions -FilterZone 1 -AcceptPartialScenario $phrase -DeleteResult absent 2>&1
        $LASTEXITCODE | Should -Be $Expected -Because ($output | Out-String)
        $calls = @(Get-Content "$root/az-calls")
        if ($Expected -eq 14) {
            @($calls | Where-Object { $_ -like '*scenario config delete *' }).Count | Should -Be 1
            @($calls | Where-Object { $_ -like '*scenario config list *' }).Count | Should -Be 1
            $ledger = @(Get-ChildItem $root -Recurse -Filter residue-ledger.json)[0]
            (Read-ChaosJsonFile $ledger.FullName).entries[0].cleanup.observation.certainty | Should -Be effective-with-service-error
            @(Get-ChildItem $root -Recurse -Filter study-plan.v4.json).Count | Should -Be 0
        } else {
            @($calls | Where-Object { $_ -like '*scenario config delete *' }).Count | Should -Be 0
            $planFile = @(Get-ChildItem $root -Recurse -Filter study-plan.v4.json)[0]
            $plan = Read-ChaosJsonFile $planFile.FullName
            $plan.scenario.name | Should -Be 'ZoneDown-1.0'
            $plan.scope.blastRadius.filters.zones | Should -Be @('1')
        }
    }
}
