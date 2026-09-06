# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:DiscoveryFixture = "$PSScriptRoot/fixtures/live-discovered-resources.json"
    $script:ExecutionFixture = "$PSScriptRoot/fixtures/live-service-execution-plan.json"
    $script:TargetId = '/subscriptions/fb74b135-894b-4c1d-9b2e-8a3c231abc14/resourceGroups/chaos-demo-rg/providers/Microsoft.Compute/virtualMachines/renzo-demo-vmss_3a6899ac'
    . "$script:Skills/chaos-study-scope/scripts/lib/Workspace.ps1"
    . "$script:Skills/chaos-study-scope/scripts/lib/Readiness.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    $script:LiveResources = @(
        Get-Content $script:DiscoveryFixture -Raw | ConvertFrom-Json |
            ForEach-Object { ConvertTo-ChaosScopedResourceRecord $_ }
    )
}

Describe 'G3 conservative local zone projection' {
    It 'uses the byte-identical live listing with no local zone or location data' {
        Get-ChaosSha256 -Path $script:DiscoveryFixture | Should -Be a5712a596f71cd5880b580e9f395ef3457024157eaa5b36f78efbc0fc66b36dc
        $script:LiveResources.Count | Should -Be 20
        @($script:LiveResources | Where-Object { $_.location -or $_.zones.Count -gt 0 }).Count | Should -Be 0
    }

    It 'retains all unknown-zone candidates and warns rather than fabricating a zone mismatch' {
        Mock Write-ChaosStudyNote {}
        $blast = New-ChaosBlastRadius -Zones @('1')
        $projected = @(Resolve-ChaosBlastRadiusResource -ScopedResources $script:LiveResources -BlastRadius $blast)
        $projected.Count | Should -Be 20
        @($projected.resourceId | Sort-Object) | Should -Be @($script:LiveResources.resourceId | Sort-Object)
        Should -Invoke Write-ChaosStudyNote -Times 1 -ParameterFilter { $Level -eq 'warn' -and $Message -match 'zone.*service' }
    }

    It 'drops known nonmatching zones but retains matching and unknown forms' {
        Mock Write-ChaosStudyNote {}
        $resources = @(
            [pscustomobject]@{ resourceId = '/known-two'; zones = @('2') }
            [pscustomobject]@{ resourceId = '/known-one'; zones = @('1') }
            [pscustomobject]@{ resourceId = '/empty'; zones = @() }
            [pscustomobject]@{ resourceId = '/null'; zones = $null }
            [pscustomobject]@{ resourceId = '/omitted' }
        )
        $result = @(Resolve-ChaosBlastRadiusResource -ScopedResources $resources -BlastRadius (New-ChaosBlastRadius -Zones @('1')))
        $result.resourceId | Should -Be @('/known-one','/empty','/null','/omitted')
    }

    It 'leaves no-filter projection unchanged without a zone warning' {
        Mock Write-ChaosStudyNote {}
        $result = @(Resolve-ChaosBlastRadiusResource -ScopedResources $script:LiveResources -BlastRadius (New-ChaosBlastRadius))
        $result.Count | Should -Be 20
        $result.resourceId | Should -Be $script:LiveResources.resourceId
        Should -Invoke Write-ChaosStudyNote -Times 0
    }

    It 'rejects unsupported zone-redundant at the scope parameter boundary' {
        $output = & pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1" `
            -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Scenario fixture -Action fixture `
            -SteadyState 'Availability >= 1' -FilterZone zone-redundant -SkipDiscovery 2>&1
        $LASTEXITCODE | Should -Be 1 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'ValidateSet|does not belong to the set'
        ($output | Out-String) | Should -Match '1,2,3'
    }
}

Describe 'G3 live-shaped discovery through preflight' {
    It 'uses authoritative target zone <TargetZone> for declared zone <FilterZone>' -ForEach @(
        @{ TargetZone = '1'; FilterZone = '1'; Expected = 0 }
        @{ TargetZone = '2'; FilterZone = '1'; Expected = 14 }
        @{ TargetZone = '1'; FilterZone = '2'; Expected = 14 }
    ) {
        $root = "$TestDrive/full-$FilterZone-$TargetZone"
        $execution = Get-Content $script:ExecutionFixture -Raw | ConvertFrom-Json
        $execution.actions.vmZoneDown.properties.targetResources[0].metadata.zones = @($TargetZone)
        $path = "$TestDrive/execution-$FilterZone-$TargetZone.json"
        $execution | ConvertTo-Json -Depth 32 | Set-Content $path
        $effective = Resolve-ChaosEffectiveLegs $execution
        $scopeHash = Get-ChaosScopeHash -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Scope @('/subscriptions/sub/resourceGroups/rg') -Region westus2
        $binding = Get-ChaosEffectiveLegsBindingHash -ScopeHash $scopeHash -ScenarioName 'ZoneDown-1.0' -EffectiveLegs $effective
        $phrase = Get-ChaosPartialScenarioPhrase -EffectiveLegs $effective -BindingHash $binding
        $output = & pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-TelemetryScopeFixture.ps1" `
            -Skills $script:Skills -StudyRoot $root -ExecutionPlanPath $path -UseLiveZoneDefinitions `
            -DiscoveredResourcesPath $script:DiscoveryFixture -TargetResourceId $script:TargetId `
            -FilterZone $FilterZone -AcceptPartialScenario $phrase -DeleteResult absent 2>&1
        $LASTEXITCODE | Should -Be $Expected -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'zone.*service'
        $calls = @(Get-Content "$root/az-calls")
        @($calls | Where-Object { $_ -like '*scenario config create *' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like '*scenario config validate *' }).Count | Should -Be 1
        $preflightBody = @(Get-Content "$root/config-bodies.jsonl" | ConvertFrom-Json)[0]
        $preflightBody.filters.zones | Should -Be @($FilterZone)
        $preflightBody.exclusions.resources.Count | Should -Be 19
        if ($Expected -eq 14) {
            @($calls | Where-Object { $_ -like '*scenario config delete *' }).Count | Should -Be 1
            @($calls | Where-Object { $_ -like '*scenario config list *' }).Count | Should -Be 1
            $ledger = @(Get-ChildItem $root -Recurse -Filter residue-ledger.json)[0]
            (Read-ChaosJsonFile $ledger.FullName).entries[0].cleanup.observation.certainty | Should -Be effective-with-service-error
            @(Get-ChildItem $root -Recurse -Filter study-plan.v4.json).Count | Should -Be 0
            return
        }
        $planFile = @(Get-ChildItem $root -Recurse -Filter study-plan.v4.json)[0]
        $plan = Read-ChaosJsonFile $planFile.FullName
        $plan.scope.projectedResourceCount | Should -Be 1
        $plan.scope.blastRadius.filters.zones | Should -Be @('1')
        $approval = Read-ChaosJsonFile (Join-Path $planFile.Directory.FullName 'approval-preview.v1.json')
        $approval.configuration.filters.zones | Should -Be @('1')
        $script:RunConfigurationBody = $null
        Mock Invoke-ChaosStudyOperation { $script:RunConfigurationBody = $Body; [pscustomobject]@{ name = 'fixture-run' } }
        New-ChaosStudyConfiguration -Plan $plan -ConfigurationName fixture-run -Adapter local-az | Out-Null
        ConvertTo-ChaosCanonicalJson $script:RunConfigurationBody | Should -Be (ConvertTo-ChaosCanonicalJson $preflightBody)
        ($output | Out-String) | Should -Match ([regex]::Escape('Declared zone filter: ["1"]'))
        $preview = & pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($preview | Out-String)
        ($preview | Out-String) | Should -Match ([regex]::Escape('Declared zone filter: ["1"]'))
    }
}
