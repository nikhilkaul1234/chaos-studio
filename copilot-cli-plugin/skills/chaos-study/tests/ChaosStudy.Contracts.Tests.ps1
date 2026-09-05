# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Offline behavioral contracts. No test is allowed to reach an Azure executable.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Shared = Join-Path $script:Skills 'chaos-study/scripts/lib'
    $script:ScopeEntry = Join-Path $script:Skills 'chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1'
    $script:RunEntry = Join-Path $script:Skills 'chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1'
    $script:FrontDoor = Join-Path $script:Skills 'chaos-study/scripts/Invoke-ChaosStudy.ps1'
    $script:HistoryEntry = Join-Path $script:Skills 'chaos-study-history/scripts/Invoke-ChaosStudyHistory.ps1'
    . "$script:Shared/Common.ps1"
    . "$script:Shared/Study.ps1"
    . "$script:Shared/Operation.ps1"
    . "$script:Shared/Adapters.ps1"
    . "$script:Skills/chaos-study-scope/scripts/lib/Workspace.ps1"
    . "$script:Skills/chaos-study-scope/scripts/lib/ActionDiscovery.ps1"
    . "$script:Skills/chaos-study-scope/scripts/lib/Readiness.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Signals.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . "$script:Skills/chaos-study-report/scripts/lib/Findings.ps1"
    . "$script:Skills/chaos-study-report/scripts/lib/Report.ps1"

    # Load entry-point helpers without executing their CLI or interview bodies.
    function Import-EntryFunction([string]$Path) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        foreach ($node in $ast.EndBlock.Statements) {
            if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                Set-Item "Function:script:$($node.Name)" ([scriptblock]::Create($node.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
            }
        }
    }
    Import-EntryFunction $script:ScopeEntry
    Import-EntryFunction $script:FrontDoor
    Import-EntryFunction $script:HistoryEntry

    function New-Plan {
        @{
            adapter = 'local-az'; frozenConfigHash = '0123456789abcdef'
            workspace = @{ id = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Chaos/workspaces/ws'; subscriptionId = 'sub'; resourceGroup = 'rg'; name = 'ws'; identityPrincipalId = 'principal' }
            scenario = @{ name = 'scenario'; source = 'live-recommendation'; parameters = @(); parameterSpec = @() }
            action = @{ source = 'live-discovery'; name = 'shutdown'; actionType = 'Cancelable' }
            discovery = @{ performedAt = '2026-08-30T20:00:00Z' }
            scope = @{ region = 'westus2'; projectedResourceCount = 1; projectedResources = @(@{ resourceId = '/r/one' }); blastRadius = @{ filters = @{ locations = @('westus2') }; exclusions = @{ resources = @('/r/excluded') } } }
            windows = @{ baselineMinutes = 1; injectMinutes = 1; recoveryMinutes = 1 }
        } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    }
    function New-Validation([string]$Code = 'AuthorizationFailed') {
        [pscustomobject]@{ status = 'RequiresAttention'; errors = @([pscustomobject]@{ errorCode = $Code; errorMessage = 'RBAC validation diagnostic' }) }
    }
    function New-Fix([int]$Total = 1, [bool]$Details = $true) {
        @{
            state = 'WhatIfCompleted'; whatIfMode = $true
            summary = @{ totalRequired = $Total; succeeded = 0; failed = 0; skipped = 0 }
            roleAssignments = @(if ($Details) { @{ principalId = 'principal'; roleDefinitionId = '/roles/reader'; scope = '/r/one'; targetResourceId = '/r/one' } })
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }
    function New-AbortPlan {
        @{
            safety = @{ abortConditions = @(
                @{ id = 'steady-state-breach'; kind = 'predicate'; predicate = @{ raw = 'Availability >= 99'; signal = 'Availability'; comparison = '>='; threshold = 99 } }
                @{ id = 'signal-unavailable'; kind = 'missing-signal'; sources = @('metrics:Availability'); intervalSeconds = 60; unavailableIntervals = 2 }
            ) }
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }
}

Describe 'Evidence and discovery' {
    It 'propagates non-NotFound workspace failures' {
        Mock Test-ChaosCliAvailable { $true }
        Mock Invoke-ChaosStudyOperation { throw 'AuthorizationFailed: cannot read workspace' }
        { Get-ChaosStudyWorkspace -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Adapter local-az } | Should -Throw '*AuthorizationFailed*'
    }
    It 'returns absent only on explicit workspace NotFound' {
        Mock Test-ChaosCliAvailable { $true }
        Mock Invoke-ChaosStudyOperation { throw '(ResourceNotFound) workspace does not exist' }
        Get-ChaosStudyWorkspace -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Adapter local-az | Should -BeNullOrEmpty
    }
    It 'does not treat an empty workspace response as absence' {
        Mock Test-ChaosCliAvailable { $true }
        Mock Invoke-ChaosStudyOperation { $null }
        { Get-ChaosStudyWorkspace -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Adapter local-az } | Should -Throw '*creation is not authorized*'
    }
    It 'uses canonical window bounds at the metric operation seam' {
        Mock Test-ChaosOperationSeamReady { $true }
        Mock Invoke-ChaosStudyOperation { [pscustomobject]@{ body = [pscustomobject]@{ value = @() } } }
        $window = New-ChaosWindow pre ([datetime]'2026-08-30T20:00:00Z') ([datetime]'2026-08-30T20:02:00Z')
        Get-ChaosMetricSignal -Spec (ConvertFrom-ChaosSignalSourceSpec 'metrics:Availability') -ResourceId /r/one -Window $window -Adapter local-az | Out-Null
        Should -Invoke Invoke-ChaosStudyOperation -Times 1 -ParameterFilter { $Kind -eq 'metrics.query' -and $Arguments.uri -match 'timespan=2026-08-30T20:00:00Z/2026-08-30T20:02:00Z' }
    }
    It 'uses a projected object as the implicit metric target' {
        Mock Get-ChaosMetricSignal { New-ChaosSignalResult -Source $Spec.id -Window $Window.name -Values @(@{ value = 1 }) }
        $window = New-ChaosWindow pre ([datetime]'2026-08-30T20:00:00Z') ([datetime]'2026-08-30T20:02:00Z')
        Invoke-ChaosSignalCollection -Plan (New-Plan) -Window $window -Sources metrics:Availability | Out-Null
        Should -Invoke Get-ChaosMetricSignal -Times 1 -ParameterFilter { $ResourceId -eq '/r/one' }
    }
    It 'normalizes <Shape> workspace state and scopes' -ForEach @(@{ Shape = 'flat' }, @{ Shape = 'nested' }) {
        $raw = @{ id = '/w'; name = 'ws'; location = 'westus2'; identity = @{ type = 'SystemAssigned'; principalId = 'p' } }
        $props = @{ provisioningState = 'Succeeded'; scopes = @('/r') }
        if ($Shape -eq 'flat') { $raw += $props } else { $raw.properties = $props }
        $record = ConvertTo-ChaosWorkspaceRecord ($raw | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $record.provisioningState | Should -Be Succeeded
        $record.scopes[0] | Should -Be /r
    }
    It 'normalizes <Shape> discovered target without using the envelope id' -ForEach @(@{ Shape = 'flat' }, @{ Shape = 'nested' }) {
        $raw = @{ id = '/chaos/discovered/child'; name = 'child' }
        $props = @{ fullyQualifiedIdentifier = '/r/target'; resourceType = 'microsoft.compute/virtualmachines'; location = 'westus2' }
        if ($Shape -eq 'flat') { $raw += $props } else { $raw.properties = $props }
        $record = ConvertTo-ChaosScopedResourceRecord ($raw | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $record.resourceId | Should -Be /r/target
        $record.resourceType | Should -Be microsoft.compute/virtualmachines
        $record.location | Should -Be westus2
    }
    It 'does not fabricate missing target identity or location' {
        $record = ConvertTo-ChaosScopedResourceRecord ([pscustomobject]@{ id = '/chaos/discovered/child'; name = 'child' })
        $record.resourceId | Should -BeNullOrEmpty
        $record.location | Should -BeNullOrEmpty
    }
    It 'keeps the approved Actions_List pin and subscription' {
        Mock Test-ChaosOperationSeamReady { $true }
        Mock Invoke-ChaosStudyOperation { [pscustomobject]@{ body = [pscustomobject]@{ value = @() } } }
        Get-ChaosAvailableAction -SubscriptionId sub -Region westus2 -Adapter local-az | Out-Null
        Should -Invoke Invoke-ChaosStudyOperation -Times 1 -ParameterFilter { $Kind -eq 'actions.list' -and $Arguments.uri -eq '/subscriptions/sub/providers/Microsoft.Chaos/locations/westus2/actions' }
        Get-ChaosApiVersion chaosActions | Should -Be '2026-05-01-preview'
    }
}

Describe 'Frozen scope and transport' {
    It 'applies <Value> tag exclusions as key/value records' -ForEach @(@{ Value = 'production' }, @{ Value = '*' }) {
        $blast = New-ChaosBlastRadius -ExcludeTags @{ env = $Value }
        $resources = @(
            [pscustomobject]@{ resourceId = '/r/one'; resourceType = 'type'; location = 'westus2'; zones = @(); tags = @{ env = 'production' } }
            [pscustomobject]@{ resourceId = '/r/two'; resourceType = 'type'; location = 'westus2'; zones = @(); tags = @{ other = 'test' } }
        )
        $blast.exclusions.tags[0].key | Should -Be env
        $blast.exclusions.tags[0].value | Should -Be $Value
        $actual = @(Resolve-ChaosBlastRadiusResource -ScopedResources $resources -BlastRadius $blast)
        $actual.Count | Should -Be 1
        $actual[0].resourceId | Should -Be /r/two
    }
    It 'sends the identical blast radius for preflight and execution configurations' {
        $script:bodies = @()
        Mock Invoke-ChaosStudyOperation {
            if ($Kind -eq 'config.create') { $script:bodies += $Body; return [pscustomobject]@{ name = 'cfg' } }
            [pscustomobject]@{ status = 'Succeeded' }
        }
        $plan = New-Plan
        $preflightPlan = New-Plan
        $preflightPlan.scope.blastRadius = New-ChaosBlastRadius -Locations westus2 -ExcludeResources /r/excluded
        New-ChaosPreflightConfiguration -StudyId test -Plan $preflightPlan -Adapter local-az -StudyPath $TestDrive | Out-Null
        New-ChaosStudyConfiguration -Plan $plan -ConfigurationName cfg | Out-Null
        $script:bodies.Count | Should -Be 2
        foreach ($body in $script:bodies) {
            ConvertTo-ChaosCanonicalJson $body.filters | Should -Be (ConvertTo-ChaosCanonicalJson $plan.scope.blastRadius.filters)
            ConvertTo-ChaosCanonicalJson $body.exclusions | Should -Be (ConvertTo-ChaosCanonicalJson $plan.scope.blastRadius.exclusions)
        }
    }
    It 'pins configuration and permission calls to the frozen subscription' {
        Mock Invoke-ChaosStudyOperation { [pscustomobject]@{ status = 'Succeeded'; name = 'cfg' } }
        $plan = New-Plan
        New-ChaosStudyConfiguration -Plan $plan -ConfigurationName cfg | Out-Null
        Get-ChaosConfigurationValidation -Plan $plan -ConfigurationName cfg | Out-Null
        Repair-ChaosConfigurationPermission -Plan $plan -ConfigurationName cfg -WhatIf | Out-Null
        Should -Invoke Invoke-ChaosStudyOperation -Times 0 -ParameterFilter {
            $i = [array]::IndexOf([object[]]$Arguments.cliArgs, '--subscription')
            $i -lt 0 -or $Arguments.cliArgs[$i + 1] -ne 'sub'
        }
    }
    It 'records a subscription on every preflight and run CLI command' {
            $script:RecordedChaosCommands = @()
            Mock Test-ChaosLocalAzAdapterReady { @() }
            Mock Invoke-ChaosStudyAzChaos {
                $script:RecordedChaosCommands += ,$ChaosArgs
                [pscustomobject]@{ name = 'run-1'; status = 'Succeeded' }
            }
            $plan = New-Plan
            New-ChaosPreflightConfiguration -StudyId test -Plan $plan -Adapter local-az -StudyPath $TestDrive | Out-Null
            New-ChaosStudyConfiguration -Plan $plan -ConfigurationName cfg | Out-Null
            Get-ChaosConfigurationValidation -Plan $plan -ConfigurationName cfg | Out-Null
            Repair-ChaosConfigurationPermission -Plan $plan -ConfigurationName cfg -WhatIf | Out-Null
            Start-ChaosStudyScenarioRun -Plan $plan -ConfigurationName cfg -Validation ([pscustomobject]@{ status = 'Succeeded' }) | Out-Null
            Get-ChaosStudyScenarioRun -Plan $plan -RunId run-1 | Out-Null
            Stop-ChaosStudyScenarioRun -Plan $plan -RunId run-1 | Out-Null
            Remove-ChaosStudyConfiguration -Plan $plan -ConfigurationName cfg | Out-Null
            foreach ($command in $script:RecordedChaosCommands) {
                $i = [array]::IndexOf([object[]]$command, '--subscription')
                $i | Should -BeGreaterOrEqual 0
                $command[$i + 1] | Should -Be sub
            }
            @($script:RecordedChaosCommands | ForEach-Object { $_ -join ' ' }) -join "`n" | Should -Match 'scenario run start'
    }
    It 'hashes the exact persisted redacted configuration' {
        $plan = New-Plan
        $plan.action | Add-Member certificateName 'sensitive'
        $frozen = Protect-ChaosObject $plan
        $frozen.frozenConfigHash = Get-ChaosPlanFingerprint $frozen
        Write-ChaosJsonFile "$TestDrive/plan.json" $frozen | Out-Null
        $roundtrip = Read-ChaosJsonFile "$TestDrive/plan.json"
        $roundtrip.action.certificateName | Should -Be '[REDACTED]'
        Get-ChaosPlanFingerprint $roundtrip | Should -Be $roundtrip.frozenConfigHash
        (Get-Content $script:ScopeEntry -Raw) | Should -Match 'Protect-ChaosObject -InputObject \$plan'
    }
    It 'requires live discovery and a known projection without a Force bypass' {
        $plan = New-Plan
        Test-ChaosPlanLiveDiscovery $plan | Should -BeTrue
        $plan.action.source = 'unverified-offline'
        Test-ChaosPlanLiveDiscovery $plan | Should -BeFalse
        $plan.action.source = 'live-discovery'; $plan.scope.projectedResourceCount = $null
        Test-ChaosPlanLiveDiscovery $plan | Should -BeFalse
        (Get-Content $script:RunEntry -Raw) | Should -Match 'Test-ChaosPlanLiveDiscovery -Plan \$plan'
    }
    It 'rejects zero baseline and recovery on both entry points' {
        foreach ($entry in @($script:ScopeEntry, $script:FrontDoor)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($entry, [ref]$null, [ref]$null)
            foreach ($name in @('BaselineMinutes', 'RecoveryMinutes')) {
                ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }).Extent.Text | Should -Match 'ValidateRange\(1,'
            }
        }
    }
    It 'requires matching ready unconsumed approval' {
        $plan = New-Plan
        $preview = New-ChaosApprovalPreview -Plan $plan -ConfigurationName cfg -Validation ([pscustomobject]@{ status = 'Succeeded' })
        Test-ChaosApprovalPreviewReady -Plan $plan -Preview $preview | Should -BeTrue
        $preview.planHash = 'different'
        Test-ChaosApprovalPreviewReady -Plan $plan -Preview $preview | Should -BeFalse
        $preview.planHash = $plan.frozenConfigHash; $preview.consumedAt = 'used'
        Test-ChaosApprovalPreviewReady -Plan $plan -Preview $preview | Should -BeFalse
        $fresh = New-ChaosApprovalPreview -Plan $plan -ConfigurationName cfg -Validation ([pscustomobject]@{ status = 'Succeeded' })
        $fresh.previewHash | Should -Not -Be $preview.previewHash
    }
    It 'blocks an unobservable abort predicate' {
        $gate = Test-ChaosObservabilityCoverage -AvailableSources @() -SteadyState ([pscustomobject]@{ signal = 'Availability' })
        $gate.status | Should -Be fail
        $gate.severity | Should -Be blocking
    }
}

Describe 'Permission authority' {
    It 'does not apply newly previewed grants under an older approval snapshot' {
        Mock Get-ChaosConfigurationValidation { New-Validation }
        Mock Repair-ChaosConfigurationPermission { New-Fix }
        $plan = New-Plan
        $grant = Get-ChaosPermissionGrantSet -Plan $plan -ConfigurationName cfg -FixResult (New-Fix)
        $phrase = Get-ChaosPermissionApprovalPhrase -Plan $plan -GrantSetHash $grant.hash
        $result = Resolve-ChaosConfigurationValidation -Plan $plan -ConfigurationName cfg -ExpectedGrantSetHash old-preview -PermissionApproval $phrase
        $result.approvalRequired | Should -BeTrue
        Should -Invoke Repair-ChaosConfigurationPermission -Times 0 -ParameterFilter { -not $WhatIf }
    }
    It 'preserves a preflight InternalError and exits 17 without what-if' {
        $child = @"
`$ErrorActionPreference = 'Stop'
. '$script:Skills/chaos-study-run/scripts/lib/Execute.ps1'
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$script:ScopeEntry',[ref]`$null,[ref]`$null)
foreach (`$node in `$ast.EndBlock.Statements) {
    if (`$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -match '^(New-ChaosPreflightConfiguration|Get-ChaosPreflightConfigurationName|Get-ChaosPreflightValidationStatus)$') { . ([scriptblock]::Create(`$node.Extent.Text)) }
}
function Invoke-ChaosStudyOperation {
    param(`$Kind,`$Arguments,`$Body,`$ExpectedSchema,`$Adapter,`$StudyPath,`$OperationHint)
    if (`$Kind -eq 'config.create') { return [pscustomobject]@{name='cfg'} }
    if (`$Kind -eq 'config.validate') { return [pscustomobject]@{status='RequiresAttention';errors=@([pscustomobject]@{errorCode='InternalError';errorMessage='backend RBAC fault'})} }
    throw "UNEXPECTED WHATIF: `$Kind"
}
`$plan = '$(ConvertTo-ChaosCanonicalJson (New-Plan))' | ConvertFrom-Json
New-ChaosPreflightConfiguration -StudyId test -Plan `$plan -Adapter local-az -StudyPath '$TestDrive'
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        ($output | Out-String) | Should -Not -Match 'UNEXPECTED WHATIF'
        (Get-Content "$TestDrive/evidence/preflight/validation.json" -Raw) | Should -Match InternalError
    }
    It 'binds the exact principal-role-scope assignments, not only sets of roles and scopes' {
        $fix = New-Fix
        $a = Get-ChaosPermissionGrantSet -Plan (New-Plan) -ConfigurationName cfg -FixResult $fix
        $fix.roleAssignments[0].principalId = 'another-principal'
        $b = Get-ChaosPermissionGrantSet -Plan (New-Plan) -ConfigurationName cfg -FixResult $fix
        $a.hash | Should -Not -Be $b.hash
    }
    It 'ignores operation timestamps in approval bindings' {
        $fix = New-Fix
        $a = Get-ChaosPermissionGrantSet -Plan (New-Plan) -ConfigurationName cfg -FixResult $fix
        $fix | Add-Member startedAt '2026-08-30T20:01:00Z'
        $b = Get-ChaosPermissionGrantSet -Plan (New-Plan) -ConfigurationName cfg -FixResult $fix
        $a.hash | Should -Be $b.hash
    }
    It 'requests approval only for a complete what-if assignment set' {
        Mock Get-ChaosConfigurationValidation { New-Validation }
        Mock Repair-ChaosConfigurationPermission { New-Fix }
        $result = Resolve-ChaosConfigurationValidation -Plan (New-Plan) -ConfigurationName cfg
        $result.approvalRequired | Should -BeTrue
        $result.approvalPhrase | Should -Not -BeNullOrEmpty
        Should -Invoke Repair-ChaosConfigurationPermission -Times 1 -ParameterFilter { $WhatIf }
    }
    It 'refuses an incomplete what-if result' {
        Mock Get-ChaosConfigurationValidation { New-Validation }
        Mock Repair-ChaosConfigurationPermission { New-Fix -Details $false }
        $result = Resolve-ChaosConfigurationValidation -Plan (New-Plan) -ConfigurationName cfg
        $result.approvalRequired | Should -BeFalse
        $result.approvalPhrase | Should -BeNullOrEmpty
        $result.status | Should -Be RequiresAttention
    }
    It 'preserves <Code> without asking for a repair' -ForEach @(@{ Code = 'InternalError' }, @{ Code = 'ResourceNotFound' }) {
        Mock Get-ChaosConfigurationValidation { New-Validation $Code }
        Mock Repair-ChaosConfigurationPermission { throw 'not a repairable permission failure' }
        $result = Resolve-ChaosConfigurationValidation -Plan (New-Plan) -ConfigurationName cfg -PermissionApproval unused
        $result.status | Should -Be RequiresAttention
        $result.validation.errors[0].errorCode | Should -Be $Code
        $result.approvalPhrase | Should -BeNullOrEmpty
        Should -Invoke Repair-ChaosConfigurationPermission -Times 0
    }
    It 'does not promote non-applicable permission preview into success' {
        Mock Get-ChaosConfigurationValidation { New-Validation }
        Mock Repair-ChaosConfigurationPermission { New-Fix -Total 0 -Details $false }
        $result = Resolve-ChaosConfigurationValidation -Plan (New-Plan) -ConfigurationName cfg
        $result.status | Should -Be RequiresAttention
        $result.approvalRequired | Should -BeFalse
    }
    It 'refuses repair when permission and system errors are mixed' {
        Mock Get-ChaosConfigurationValidation {
            $v = New-Validation
            $v.errors += (New-Validation InternalError).errors
            $v
        }
        Mock Repair-ChaosConfigurationPermission { throw 'mixed errors must not repair' }
        $result = Resolve-ChaosConfigurationValidation -Plan (New-Plan) -ConfigurationName cfg
        $result.status | Should -Be RequiresAttention
        Should -Invoke Repair-ChaosConfigurationPermission -Times 0
    }
    It 'accepts successful validation without repair' {
        Mock Get-ChaosConfigurationValidation { [pscustomobject]@{ status = 'Succeeded' } }
        Mock Repair-ChaosConfigurationPermission { throw 'no repair needed' }
        (Resolve-ChaosConfigurationValidation -Plan (New-Plan) -ConfigurationName cfg).status | Should -Be Succeeded
        Should -Invoke Repair-ChaosConfigurationPermission -Times 0
    }
    It 'rejects a non-what-if result even when assignment counts match' {
        $fix = New-Fix
        $fix.whatIfMode = $false
        Test-ChaosPermissionFixApplicable $fix | Should -BeFalse
    }
}

Describe 'Live abort' {
    It 'evaluates a predicate value <Value> as triggered=<Triggered>' -ForEach @(@{ Value = 95; Triggered = $true }, @{ Value = 100; Triggered = $false }) {
        $start = [datetime]'2026-08-30T20:00:00Z'
        $window = New-ChaosWindow abort-check $start $start.AddMinutes(1)
        $signals = @(New-ChaosSignalResult -Source metrics:Availability -Window abort-check -Values @([ordered]@{ value = $Value }))
        (Invoke-ChaosAbortEvaluation -Plan (New-AbortPlan) -Signals $signals -Window $window -InjectionStartedAt $start -State ([ordered]@{})).triggered | Should -Be $Triggered
    }
    It 'trips on two frozen intervals without telemetry' {
        $start = [datetime]'2026-08-30T20:00:00Z'
        $window = New-ChaosWindow abort-check $start $start.AddMinutes(2)
        $signals = @(New-ChaosSignalResult -Source metrics:Availability -Window abort-check -Caveat 'missing')
        $result = Invoke-ChaosAbortEvaluation -Plan (New-AbortPlan) -Signals $signals -Window $window -InjectionStartedAt $start -State ([ordered]@{})
        $result.trigger.conditionId | Should -Be signal-unavailable
    }
    It 'cancels through the operation adapter with the frozen subscription' {
        Mock Invoke-ChaosStudyOperation { [pscustomobject]@{ status = 'Cancelling' } }
        Stop-ChaosStudyScenarioRun -Plan (New-Plan) -RunId run-1 | Out-Null
        Should -Invoke Invoke-ChaosStudyOperation -Times 1 -ParameterFilter {
            $Kind -eq 'run.cancel' -and $Arguments.cliArgs -contains 'sub' -and $Arguments.cliArgs -contains '--subscription'
        }
    }
    It 'wires live checks and durable evidence before cancellation' {
        $source = Get-Content $script:RunEntry -Raw
        $source | Should -Match '-OnAbortCheck'
        $source | Should -Match 'Invoke-ChaosAbortEvaluation'
        $source | Should -Match 'evidence/during/abort-checks.json'
    }
    It 'never treats unknown recovery as held' {
        $predicate = Get-ChaosPredicateVerdict -PredicateDuring $false
        $predicate | Should -Be Breached
        Get-ChaosStudyVerdict -Findings @() -PredicateVerdict $predicate -MechanismProven $true | Should -Not -Be 'Degraded but recovered'
    }
}

Describe 'Cleanup and CLI collection boundaries' {
    BeforeEach { $script:ChaosStudyExtensionEnsured = $true }
    It 'initializes the extension only once across separate operations' {
        $lib = "$script:Shared/Operation.ps1"
        $child = @"
`$ErrorActionPreference = 'Stop'
`$script:ExtensionChecks = 0
function global:az {
    `$global:LASTEXITCODE = 0
    if (`$args[0] -eq 'extension') {
        if (`$args[1] -eq 'list') { `$script:ExtensionChecks++; 'chaos' }
    } else { '{"name":"ws","id":"/w"}' }
}
. '$lib'
Invoke-ChaosStudyOperation -Kind workspace.get -Arguments @{cliArgs=@('--subscription','sub')} -ExpectedSchema any.v1 -Adapter local-az | Out-Null
Invoke-ChaosStudyOperation -Kind workspace.get -Arguments @{cliArgs=@('--subscription','sub')} -ExpectedSchema any.v1 -Adapter local-az | Out-Null
Write-Output "CHECKS=`$script:ExtensionChecks"
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'CHECKS=1\b'
    }
    It 'reconciles one failed delete with one list: <State>' -ForEach @(
        @{ State = 'absent'; Payload = '[]'; Effective = $true }
        @{ State = 'present'; Payload = '[{"name":"cfg"}]'; Effective = $false }
        @{ State = 'inconclusive'; Payload = ''; Effective = $false }
    ) {
        Mock Invoke-ChaosStudyOperation {
            if ($Kind -eq 'config.delete') { throw 'BadRequest request-id=delete-request' }
            ConvertFrom-ChaosStudyAzJson $Payload
        }
        $result = Remove-ChaosStudyConfiguration -Plan (New-Plan) -ConfigurationName cfg
        $result.effective | Should -Be $Effective
        $result.reconciliation.state | Should -Be $State
        $result.serviceError | Should -Match delete-request
        Should -Invoke Invoke-ChaosStudyOperation -Times 1 -ParameterFilter { $Kind -eq 'config.delete' }
        Should -Invoke Invoke-ChaosStudyOperation -Times 1 -ParameterFilter { $Kind -eq 'config.list' }
    }
    It 'does not reconcile a successful delete' {
        Mock Invoke-ChaosStudyOperation { $null }
        (Remove-ChaosStudyConfiguration -Plan (New-Plan) -ConfigurationName cfg).effective | Should -BeTrue
        Should -Invoke Invoke-ChaosStudyOperation -Times 1
    }
    It 'preserves an empty CLI JSON list' {
        $parsed = ConvertFrom-ChaosStudyAzJson '[]'
        ($null -eq $parsed) | Should -BeFalse
        @($parsed).Count | Should -Be 0
    }
    It 'preserves an empty collection through the full adapter' {
        function global:az { $global:LASTEXITCODE = 0; '[]' }
        try {
            $result = Invoke-ChaosStudyOperation -Kind config.list -Arguments @{ cliArgs = @('--subscription', 'sub') } -ExpectedSchema any.v1 -Adapter local-az
            ($null -eq $result) | Should -BeFalse
            @($result).Count | Should -Be 0
        } finally { Remove-Item Function:\global:az }
    }
    It 'streams nonempty CLI arrays for filtering and sorting' {
        function global:az { $global:LASTEXITCODE = 0; '[{"name":"b"},{"name":"a"}]' }
        try {
            $items = @(Invoke-ChaosStudyAzChaos -ChaosArgs @('scenario', 'run', 'list') | Sort-Object name)
            $items.Count | Should -Be 2
            $items[0].name | Should -Be a
        } finally { Remove-Item Function:\global:az }
    }
    It 'distinguishes scalar, malformed, object and absent CLI output' {
        (ConvertFrom-ChaosStudyAzJson '{"name":"object"}').name | Should -Be object
        ConvertFrom-ChaosStudyAzJson '42' | Should -Be 42
        ConvertFrom-ChaosStudyAzJson 'not-json' | Should -Be not-json
        ConvertFrom-ChaosStudyAzJson '' | Should -BeNullOrEmpty
    }
    It 'records failed cleanup rather than successful residue on a mutation error' {
        Mock Invoke-ChaosStudyOperation { throw 'BadRequest' }
        Add-ChaosExecutionResidueEntry -StudyPath $TestDrive -ConfigurationName cfg -Workspace (New-Plan).workspace -Adapter local-az | Out-Null
        $result = Invoke-ChaosResidueRemoval -StudyPath $TestDrive -Kind executionConfiguration -Id cfg -Removal { Remove-ChaosStudyConfiguration -Plan (New-Plan) -ConfigurationName cfg }
        $result.status | Should -Be failed
        $result.recorded | Should -BeTrue
        (Get-ChaosResidueSummary -StudyPath $TestDrive).unresolved | Should -Be 1
    }
    It 'propagates a real CLI error for <Kind>' -ForEach @(
        @{ Kind = 'config.delete' }, @{ Kind = 'run.cancel' }, @{ Kind = 'config.validate' },
        @{ Kind = 'config.fixPermissions' }, @{ Kind = 'workspace.refreshRecommendations' }
    ) {
        function global:az { $global:LASTEXITCODE = 1; 'BadRequest: service rejected mutation' }
        try {
            { Invoke-ChaosStudyOperation -Kind $Kind -Arguments @{ cliArgs = @('--subscription', 'sub') } -ExpectedSchema any.v1 -Adapter local-az } | Should -Throw '*service rejected mutation*'
        } finally { Remove-Item Function:\global:az }
    }
    It 'preserves empty lists through the public plugin wrapper too' {
        . "$script:Skills/../scripts/Invoke-AzChaos.ps1"
        $script:ChaosExtensionEnsured = $true
        function global:az { $global:LASTEXITCODE = 0; '[]' }
        try {
            $result = Invoke-AzChaos -ChaosArgs @('scenario', 'config', 'list')
            ($null -eq $result) | Should -BeFalse
            @($result).Count | Should -Be 0
        } finally { Remove-Item Function:\global:az }
    }
}

Describe 'Portable front door and artifacts' {
    It 'renders a null-observation failed run with sealed artifact hashes and no changed sealed bytes' {
        $root = "$TestDrive/report-studies"
        $study = New-ChaosStudy -ScopeHash scope -StudyRoot $root
        $plan = New-Plan
        $plan | Add-Member question ([pscustomobject]@{ hypothesis = 'offline fixture'; steadyState = (ConvertFrom-ChaosSteadyState 'Availability >= 99') })
        $plan | Add-Member readiness ([pscustomobject]@{ limitationCodes = @() })
        $plan | Add-Member safety ([pscustomobject]@{ abortConditions = @() })
        $plan.scope | Add-Member resourceTypes @('type')
        $plan.scope | Add-Member discoveredResourceCount 1
        $plan.workspace | Add-Member scopes @('/r')
        $plan.scenario | Add-Member id /scenario
        $plan.action | Add-Member canonicalId urn:shutdown
        $plan.action | Add-Member displayName Shutdown
        $plan.frozenConfigHash = Get-ChaosPlanFingerprint $plan
        Save-ChaosStudyArtifact -StudyPath $study.path -RelativePath (Get-ChaosArtifactFileName plan) -Content $plan | Out-Null
        Save-ChaosRunCheckpoint -Plan $plan -Study $study -StartedAt '2026-08-30T20:00:00Z' -ConfigurationName cfg -Outcome Failed -Failure 'Synthetic offline failure'
        $output = & pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-report/scripts/Invoke-ChaosStudyReport.ps1" -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $manifest = Read-ChaosJsonFile "$($study.path)/manifest.json"
        $html = Get-Content "$root/scope/report-$($study.studyId).html" -Raw
        $html | Should -Match Inconclusive
        $html | Should -Match 'Synthetic offline failure'
        $html | Should -Match $manifest.contentHash
        $html | Should -Match $manifest.files.'run-record.v3.json'
        foreach ($file in $manifest.files.PSObject.Properties) {
            Get-ChaosSha256 -Path (Join-Path $study.path $file.Name) | Should -Be $file.Value
        }
    }
    It 'persists a reportable run checkpoint before recovery can be interrupted' {
        $study = New-ChaosStudy -ScopeHash scope -StudyRoot "$TestDrive/checkpoints"
        Save-ChaosRunCheckpoint -Plan (New-Plan) -Study $study -StartedAt '2026-08-30T20:00:00Z' -ConfigurationName cfg -RunId run-1 -Outcome Failed -Failure 'signal collection failed'
        $record = Read-ChaosJsonFile (Join-Path $study.path (Get-ChaosArtifactFileName runRecord))
        $record.scenarioRun.runId | Should -Be run-1
        $record.scenarioRun.failure | Should -Be 'signal collection failed'
        $record.collectionState | Should -Be recovery-pending
        $record.windows.post | Should -BeNullOrEmpty
        $source = Get-Content $script:RunEntry -Raw
        $source.IndexOf('Save-ChaosRunCheckpoint -Plan') | Should -BeLessThan $source.IndexOf('Start-Sleep -Seconds ($plan.windows.recoveryMinutes')
    }
    It 'runs the default dry-run from a skills-only install without plugin scripts' {
        $install = "$TestDrive/install"
        New-Item -ItemType Directory "$install/skills" -Force | Out-Null
        Copy-Item "$script:Skills/chaos-study*" "$install/skills" -Recurse
        $study = New-ChaosStudy -ScopeHash scope -StudyRoot "$TestDrive/studies"
        $plan = New-Plan
        $plan | Add-Member question ([pscustomobject]@{ hypothesis = 'availability remains healthy' })
        $plan | Add-Member signals ([pscustomobject]@{ configuredSources = @() })
        $plan | Add-Member safety ([pscustomobject]@{ abortConditions = @() })
        $plan.scope | Add-Member discoveredResourceCount 1
        $plan.action | Add-Member displayName Shutdown
        $plan.action | Add-Member canonicalId urn:shutdown
        $plan.frozenConfigHash = Get-ChaosPlanFingerprint $plan
        Save-ChaosStudyArtifact -StudyPath $study.path -RelativePath (Get-ChaosArtifactFileName plan) -Content $plan | Out-Null
        $output = & pwsh -NoProfile -NonInteractive -File "$install/skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -StudyRoot "$TestDrive/studies" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'Dry run complete'
        Test-Path "$install/scripts" | Should -BeFalse
        Get-ChaosStudyState -StudyPath $study.path | Should -Be PLANNED
    }
    It 'transports arrays, tags, booleans and delimiter-containing values losslessly' {
        $phase = "$TestDrive/phase.ps1"
        'param([string[]]$Values,[hashtable]$Tags,[bool]$DryRun,[string]$Out) @{values=$Values;tags=$Tags;dry=$DryRun}|ConvertTo-Json|Set-Content $Out' | Set-Content $phase
        Invoke-ChaosPhase -Name test -Script $phase -Arguments @{ Values = @('a,b', "q'uote", 'two'); Tags = @{ env = 'production' }; DryRun = $false; Out = "$TestDrive/output.json" } | Should -Be 0
        $result = Get-Content "$TestDrive/output.json" -Raw | ConvertFrom-Json
        @($result.values).Count | Should -Be 3
        $result.values[0] | Should -Be 'a,b'
        $result.tags.env | Should -Be production
        $result.dry | Should -BeFalse
    }
    It 'preserves child exit codes' {
        'exit 14' | Set-Content "$TestDrive/exit.ps1"
        Invoke-ChaosPhase -Name test -Script "$TestDrive/exit.ps1" -Arguments @{} | Should -Be 14
    }
    It 'forwards every axis and binds to the newly planned study rather than global latest' {
        $source = Get-Content $script:FrontDoor -Raw
        foreach ($axis in @('ExcludeTag', 'FilterZone', 'FilterPhysicalZone')) { $source | Should -Match "\['$axis'\]" }
        $source | Should -Match 'Find-ChaosStudy -StudyId \$plannedStudyId'
        $source | Should -Not -Match 'Write-Error-Card[^\r\n]*-Body'
    }
    It 'keeps artifact filenames and payload versions coherent' {
        Get-ChaosArtifactFileName plan | Should -Be 'study-plan.v3.json'
        Get-ChaosArtifactFileName runRecord | Should -Be 'run-record.v3.json'
        (Get-Content $script:ScopeEntry -Raw) | Should -Match "study-plan.v3"
        (Get-Content $script:RunEntry -Raw) | Should -Match "run-record.v3"
    }
    It 'renders effective defaults and the full frozen dry-run contract' {
        $plan = New-Plan
        $plan.scenario.parameterSpec = @([pscustomobject]@{ name = 'duration'; default = 'PT15M' })
        $plan.scenario.parameterSpec += [pscustomobject]@{ name = 'mode'; default = 'default-mode' }
        $plan.scenario.parameters = @([pscustomobject]@{ key = 'mode'; value = 'explicit-mode' })
        $text = Write-ChaosStudyDryRunContract -Plan $plan -ConfigurationName cfg | Out-String
        $text | Should -Match $plan.frozenConfigHash
        $text | Should -Match PT15M
        $text | Should -Match explicit-mode
        $text | Should -Not -Match default-mode
        $text | Should -Match 'Cancelable'
        $text | Should -Match 'delete'
        $text | Should -Match 'fresh human'
        (Write-ChaosStudyDryRunContract -Plan (New-Plan) -ConfigurationName cfg | Out-String) | Should -Match '\{\}'
    }
    It 'replays plural blast-radius keys and renders tags as a hashtable' {
        $source = Get-Content $script:HistoryEntry -Raw
        foreach ($key in @('locations', 'zones', 'physicalZones', 'resources', 'types', 'tags')) {
            $source | Should -Match "'$key'"
        }
        $table = ConvertTo-ChaosTagTable @([pscustomobject]@{ key = 'env'; value = 'prod' }, [pscustomobject]@{ key = 'protected'; value = '*' })
        $table | Should -BeOfType ([hashtable])
        $table.protected | Should -Be '*'
        $table["owner's tag"] = "value with 'quote'"
        $literal = Format-RerunLiteral $table
        $bound = & ([scriptblock]::Create("& { param([hashtable]`$ExcludeTag) `$ExcludeTag } -ExcludeTag $literal"))
        $bound["owner's tag"] | Should -Be "value with 'quote'"
    }
    It 'seals before loading the report manifest' {
        $source = Get-Content "$script:Skills/chaos-study-report/scripts/Invoke-ChaosStudyReport.ps1" -Raw
        $source.IndexOf('Complete-ChaosStudy -StudyPath') | Should -BeLessThan $source.IndexOf('$manifest =')
    }
}
