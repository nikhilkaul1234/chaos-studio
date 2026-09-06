# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Regressions for the three blockers found on c439866. All operations are offline.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Shared = Join-Path $script:Skills 'chaos-study/scripts/lib'
    $script:ScopeEntry = Join-Path $script:Skills 'chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1'
    . "$script:Shared/Common.ps1"
    . "$script:Shared/Study.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Signals.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . "$script:Skills/chaos-study-report/scripts/lib/Findings.ps1"

    function New-ReviewPlan {
        @{
            adapter = 'local-az'
            workspace = @{ subscriptionId = 'sub'; resourceGroup = 'rg'; name = 'ws' }
            scenario = @{ name = 'scenario'; parameters = @() }
            scope = @{ blastRadius = @{ filters = $null; exclusions = $null } }
            safety = @{ abortConditions = @(
                @{ id = 'steady-state-breach'; kind = 'predicate'; predicate = @{ raw = 'Availability >= 99'; signal = 'Availability'; comparison = '>='; threshold = 99 } }
                @{ id = 'signal-unavailable'; kind = 'missing-signal'; sources = @('metrics:Availability'); intervalSeconds = 60; unavailableIntervals = 2 }
            ) }
        } | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    }

    function New-FrontDoorFixture([string]$Root) {
        New-Item -ItemType Directory "$Root/skills" -Force | Out-Null
        Copy-Item "$script:Skills/chaos-study*" "$Root/skills" -Recurse
        $log = "$Root/phases.jsonl"
        foreach ($phase in @('scope', 'design')) {
            @"
'$phase' | Add-Content '$Root/unexpected-phase'
throw 'Approval must not re-scope or redesign'
"@ | Set-Content "$Root/skills/chaos-study-$phase/scripts/Invoke-ChaosStudy$((Get-Culture).TextInfo.ToTitleCase($phase)).ps1"
        }
        @"
param([string]`$StudyId,[bool]`$DryRun,[string]`$Consent,[string]`$ApprovePermissions,[string]`$StudyRoot)
@{phase='run';studyId=`$StudyId;dryRun=`$DryRun;consent=`$Consent;permissions=`$ApprovePermissions;root=`$StudyRoot} | ConvertTo-Json -Compress | Add-Content '$log'
exit 0
"@ | Set-Content "$Root/skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1"
        @"
param([string]`$StudyId,[string]`$StudyRoot)
@{phase='report';studyId=`$StudyId} | ConvertTo-Json -Compress | Add-Content '$log'
exit 0
"@ | Set-Content "$Root/skills/chaos-study-report/scripts/Invoke-ChaosStudyReport.ps1"
        return "$Root/skills/chaos-study/scripts/Invoke-ChaosStudy.ps1"
    }
}

Describe 'B1 approval resumes the exact study' {
    It 'dispatches <Approval> straight to run and report without design or scope' -ForEach @(
        @{ Approval = 'Consent'; FullInputs = $false }
        @{ Approval = 'ApprovePermissions'; FullInputs = $true }
    ) {
        $root = "$TestDrive/front-$Approval"
        $front = New-FrontDoorFixture $root
        $inputs = if ($FullInputs) { '-SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -System synthetic' } else { '' }
        $output = & pwsh -NoProfile -NonInteractive -Command "& '$front' -StudyId frozen-study -StudyRoot '$root/store' -DryRun:`$false -$Approval 'reviewed-phrase' $inputs" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        Test-Path "$root/unexpected-phase" | Should -BeFalse
        $phases = @(Get-Content "$root/phases.jsonl" | ConvertFrom-Json)
        $phases.Count | Should -Be 2
        $phases[0].phase | Should -Be run
        $phases[0].studyId | Should -Be frozen-study
        $phases[0].dryRun | Should -BeFalse
        $phases[1].phase | Should -Be report
        $phases[1].studyId | Should -Be frozen-study
        if ($Approval -eq 'Consent') { $phases[0].consent | Should -Be reviewed-phrase }
        else { $phases[0].permissions | Should -Be reviewed-phrase }
    }

    It 'refuses approval without an explicit study id before any phase runs' {
        $root = "$TestDrive/missing-id"
        $front = New-FrontDoorFixture $root
        $output = & pwsh -NoProfile -NonInteractive -File $front -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -System synthetic -Consent old-phrase 2>&1
        $LASTEXITCODE | Should -Be 11 -Because ($output | Out-String)
        Test-Path "$root/unexpected-phase" | Should -BeFalse
        Test-Path "$root/phases.jsonl" | Should -BeFalse
    }

    It 'still dispatches a new study with system inputs to the design phase' {
        $root = "$TestDrive/new-study"
        $front = New-FrontDoorFixture $root
        $output = & pwsh -NoProfile -NonInteractive -File $front -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -System synthetic 2>&1
        $LASTEXITCODE | Should -Be 1 -Because 'the fixture design phase deliberately throws before discovery'
        (Get-Content "$root/unexpected-phase" -Raw).Trim() | Should -Be design
        Test-Path "$root/phases.jsonl" | Should -BeFalse
    }

    It 'freezes different hashes for identical scopes a second apart' {
        $argsPath = "$TestDrive/scope-args.clixml"
        $scopeArgs = @{
            SubscriptionId = '00000000-0000-0000-0000-000000000001'; ResourceGroup = 'rg-x'; WorkspaceName = 'ws-x'
            Scenario = 'zone-down'; Action = 'urn:csci:microsoft:virtualMachine:shutdown/1.0'; SteadyState = 'availability >= 99'
            SkipDiscovery = $true; StudyRoot = "$TestDrive/scopes"
            FailureMechanism = 'VM loses zone'; MechanismEvidence = 'offline fixture zone=1'
            MechanismProbe = @{ signal = 'availability'; expectedDirection = 'down'; resourceCorrelation = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-x/providers/Microsoft.Compute/virtualMachines/vm1' }
            SignalSource = @('metrics:availability'); EventRatePerSecond = 5; VulnerableWindowSeconds = 600; EligibleFraction = 1
            BaselineMinutes = 1; RecoveryMinutes = 1
        }
        $scopeArgs | Export-Clixml $argsPath
        $command = "`$a = Import-Clixml '$argsPath'; & '$script:ScopeEntry' @a"
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $first = Find-ChaosStudy -StudyRoot $scopeArgs.StudyRoot -StudyId latest
        $firstPlan = Read-ChaosJsonFile (Join-Path $first.path (Get-ChaosArtifactFileName plan))
        Start-Sleep -Seconds 1
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $second = Find-ChaosStudy -StudyRoot $scopeArgs.StudyRoot -StudyId latest
        $secondPlan = Read-ChaosJsonFile (Join-Path $second.path (Get-ChaosArtifactFileName plan))
        $secondPlan.createdAt | Should -Not -Be $firstPlan.createdAt
        $secondPlan.frozenConfigHash | Should -Not -Be $firstPlan.frozenConfigHash
    }
}

Describe 'B2 Azure Monitor missing telemetry' {
    It 'evaluates missing telemetry in a standalone run-side process without loading report code' {
        $planPath = "$TestDrive/abort-plan.json"
        New-ReviewPlan | ConvertTo-Json -Depth 12 | Set-Content $planPath
        $command = @"
`$ErrorActionPreference = 'Stop'
. '$script:Skills/chaos-study-run/scripts/lib/Signals.ps1'
`$start = [datetime]'2026-09-05T20:00:00Z'
`$result = Invoke-ChaosAbortEvaluation -Plan (Read-ChaosJsonFile '$planPath') -Signals @() -Window (New-ChaosWindow abort-check `$start `$start.AddMinutes(2)) -InjectionStartedAt `$start -State ([ordered]@{})
`$result | ConvertTo-Json -Depth 12
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        (($output | Out-String) | ConvertFrom-Json).trigger.kind | Should -Be missing-signal
    }
    It 'does not substitute another aggregation or count null buckets as measurements' {
        Mock Invoke-ChaosStudyOperation {
            [pscustomobject]@{ body = [pscustomobject]@{ value = @([pscustomobject]@{ timeseries = @([pscustomobject]@{
                data = @(
                    [pscustomobject]@{ timeStamp = '2026-09-05T20:01:00Z'; average = $null; count = 0 }
                    [pscustomobject]@{ timeStamp = '2026-09-05T20:02:00Z'; average = $null }
                )
            }) }) } }
        }
        $start = [datetime]'2026-09-05T20:00:00Z'
        $window = New-ChaosWindow abort-check $start $start.AddMinutes(2)
        $signal = Get-ChaosMetricSignal -Spec (ConvertFrom-ChaosSignalSourceSpec 'metrics:Availability|Average') -ResourceId /r/one -Window $window -Adapter local-az
        $result = Invoke-ChaosAbortEvaluation -Plan (New-ReviewPlan) -Signals @($signal) -Window $window -InjectionStartedAt $start -State ([ordered]@{})
        $signal.values | Should -BeNullOrEmpty
        $result.triggered | Should -BeTrue
        $result.trigger.kind | Should -Be missing-signal
        ($result.evaluations | Where-Object kind -eq predicate).status | Should -Be not-measured
    }

    It 'trips on raw null-valued buckets rather than marking them present' {
        $start = [datetime]'2026-09-05T20:00:00Z'
        $window = New-ChaosWindow abort-check $start $start.AddMinutes(2)
        $signal = New-ChaosSignalResult -Source metrics:Availability -Window abort-check -Values @(
            [ordered]@{ timestamp = '2026-09-05T20:01:00Z'; value = $null }
            [ordered]@{ timestamp = '2026-09-05T20:02:00Z'; value = $null }
        )
        $result = Invoke-ChaosAbortEvaluation -Plan (New-ReviewPlan) -Signals @($signal) -Window $window -InjectionStartedAt $start -State ([ordered]@{})
        $result.trigger.kind | Should -Be missing-signal
        ($result.evaluations | Where-Object kind -eq predicate).status | Should -Be not-measured
    }

    It 'uses the frozen trailing window on successive 20-second polls so lagged minute data remains visible' {
        $plan = New-ReviewPlan
        $script:Poll = 0
        $script:QueryCount = 0
        $script:CheckWindows = [System.Collections.Generic.List[object]]::new()
        $script:Injection = [datetime]::UtcNow.AddSeconds(-160)
        $script:FirstCheck = $script:Injection.AddSeconds(140)
        $state = [ordered]@{}
        Mock Get-ChaosStudyScenarioRun {
            $script:Poll++
            [pscustomobject]@{ status = if ($script:Poll -gt 2) { 'Succeeded' } else { 'Running' } }
        }
        Mock Get-ChaosUtcNow { ConvertTo-ChaosUtcIso $script:FirstCheck.AddSeconds(20 * ($script:Poll - 1)) }
        Mock Start-Sleep {}
        Mock Invoke-ChaosStudyOperation {
            $script:QueryCount++
            $timestamp = $script:FirstCheck.AddSeconds(-80)
            $startText = [regex]::Match($Arguments.uri, 'timespan=([^/]+)/').Groups[1].Value
            $start = ConvertFrom-ChaosUtcIso $startText
            $data = @(if ($timestamp -ge $start) {
                [pscustomobject]@{ timeStamp = ConvertTo-ChaosUtcIso $timestamp; average = 100 }
            })
            [pscustomobject]@{ body = [pscustomobject]@{ value = @([pscustomobject]@{ timeseries = @([pscustomobject]@{ data = $data }) }) } }
        }
        $waited = Wait-ChaosScenarioRunWindow -Plan $plan -RunId synthetic -Minutes 10 -InjectionStartedAt $script:Injection -PollSeconds 20 -OnAbortCheck {
            param($window)
            $script:CheckWindows.Add($window)
            $signal = Get-ChaosMetricSignal -Spec (ConvertFrom-ChaosSignalSourceSpec 'metrics:Availability') -ResourceId /r/one -Window $window -Adapter local-az
            Invoke-ChaosAbortEvaluation -Plan $plan -Signals @($signal) -Window $window -InjectionStartedAt $script:Injection -State $state
        }
        $script:CheckWindows.Count | Should -Be 2
        foreach ($window in $script:CheckWindows) { $window.durationSeconds | Should -Be 120 }
        $script:QueryCount | Should -Be 2
        $waited.abort | Should -BeNullOrEmpty
        $state.lastSeen['metrics:Availability'] | Should -Be (ConvertFrom-ChaosUtcIso (ConvertTo-ChaosUtcIso $script:FirstCheck.AddSeconds(-80)))
        foreach ($check in $waited.abortChecks) {
            ($check.evaluations | Where-Object kind -eq predicate).status | Should -Be clear
            ($check.evaluations | Where-Object kind -eq missing-signal).status | Should -Be clear
        }
    }
}

Describe 'B3 preflight failure cleanup' {
    It 'records creation before validation and makes exactly one delete on InternalError (<DeleteResult>)' -ForEach @(
        @{ DeleteResult = 'success'; Expected = 'succeeded'; Lists = 0 }
        @{ DeleteResult = 'absent'; Expected = 'succeeded'; Lists = 1 }
        @{ DeleteResult = 'present'; Expected = 'failed'; Lists = 1 }
    ) {
        $root = "$TestDrive/preflight-$DeleteResult"
        New-Item -ItemType Directory $root -Force | Out-Null
        $planPath = "$root/plan.json"
        New-ReviewPlan | ConvertTo-Json -Depth 12 | Set-Content $planPath
        $child = @"
`$ErrorActionPreference = 'Stop'
. '$script:Skills/chaos-study-run/scripts/lib/Execute.ps1'
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$script:ScopeEntry',[ref]`$null,[ref]`$null)
foreach (`$node in `$ast.EndBlock.Statements) {
    if (`$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -match '^(New-ChaosPreflightConfiguration|Get-ChaosPreflightConfigurationName|Get-ChaosPreflightValidationStatus)$') { . ([scriptblock]::Create(`$node.Extent.Text)) }
}
function Invoke-ChaosStudyOperation {
    param(`$Kind,`$Arguments,`$Body,`$ExpectedSchema,`$Adapter,`$StudyPath,`$OperationHint)
    `$Kind | Add-Content '$root/calls'
    switch (`$Kind) {
        config.create { return [pscustomobject]@{name='preflight-test'} }
        config.validate {
            (Get-ChaosResidueLedger -StudyPath '$root').entries.Count | Set-Content '$root/entries-before-validation'
            return [pscustomobject]@{status='RequiresAttention';errors=@([pscustomobject]@{errorCode='InternalError';errorMessage='backend RBAC failure'})}
        }
        config.delete { if ('$DeleteResult' -ne 'success') { throw 'BadRequest delete service error' }; return }
        config.list { if ('$DeleteResult' -eq 'absent') { return ,@() }; return [pscustomobject]@{name='preflight-test'} }
        default { throw "Unexpected operation `$Kind" }
    }
}
New-ChaosPreflightConfiguration -StudyId test -Plan (Read-ChaosJsonFile '$planPath') -Adapter local-az -StudyPath '$root'
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        (Get-Content "$root/entries-before-validation" -Raw).Trim() | Should -Be '1'
        $ledger = Read-ChaosJsonFile "$root/residue-ledger.json"
        $ledger.entries.Count | Should -Be 1
        $ledger.entries[0].id | Should -Be preflight-test
        $ledger.entries[0].cleanup.status | Should -Be $Expected
        $calls = @(Get-Content "$root/calls")
        @($calls | Where-Object { $_ -eq 'config.delete' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -eq 'config.list' }).Count | Should -Be $Lists
        $calls | Should -Not -Contain config.fixPermissions
        (Read-ChaosJsonFile "$root/evidence/preflight/validation.json").errors[0].errorCode | Should -Be InternalError
    }
}
