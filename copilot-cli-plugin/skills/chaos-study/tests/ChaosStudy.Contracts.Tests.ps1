<#
.SYNOPSIS
    Regression tests for the chaos-study runtime, safety, and artifact contracts.

.DESCRIPTION
    All dynamic tests are offline. Azure seams are mocked; no test authenticates,
    discovers resources, creates a configuration, or starts a scenario.
#>

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:SkillsRoot = Split-Path $script:SkillRoot -Parent
    $script:Common = Join-Path $script:SkillRoot 'scripts/lib/Common.ps1'
    $script:Study = Join-Path $script:SkillRoot 'scripts/lib/Study.ps1'
    $script:ScopeEntry = Join-Path $script:SkillsRoot 'chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1'
    $script:Workspace = Join-Path $script:SkillsRoot 'chaos-study-scope/scripts/lib/Workspace.ps1'
    $script:Readiness = Join-Path $script:SkillsRoot 'chaos-study-scope/scripts/lib/Readiness.ps1'
    $script:RunEntry = Join-Path $script:SkillsRoot 'chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1'
    $script:Signals = Join-Path $script:SkillsRoot 'chaos-study-run/scripts/lib/Signals.ps1'
    $script:Execute = Join-Path $script:SkillsRoot 'chaos-study-run/scripts/lib/Execute.ps1'
    $script:Findings = Join-Path $script:SkillsRoot 'chaos-study-report/scripts/lib/Findings.ps1'
    $script:Report = Join-Path $script:SkillsRoot 'chaos-study-report/scripts/lib/Report.ps1'
    $script:ReportEntry = Join-Path $script:SkillsRoot 'chaos-study-report/scripts/Invoke-ChaosStudyReport.ps1'
    $script:HistoryEntry = Join-Path $script:SkillsRoot 'chaos-study-history/scripts/Invoke-ChaosStudyHistory.ps1'
    $script:FrontDoor = Join-Path $script:SkillRoot 'scripts/Invoke-ChaosStudy.ps1'

    . $script:Common
    . $script:Study
    . $script:Workspace
    . $script:Readiness
    . $script:Signals
    . $script:Execute
    . $script:Findings
    . $script:Report
    . $script:HistoryEntry

    function New-LivePlan {
        return [pscustomobject]@{
            scenario = [pscustomobject]@{ source = 'live-recommendation'; name = 'zone-down' }
            action = [pscustomobject]@{ source = 'live-discovery'; name = 'stop'; actionType = 'Continuous' }
            discovery = [pscustomobject]@{ performedAt = '2026-08-30T20:00:00Z' }
            scope = [pscustomobject]@{
                projectedResourceCount = 1
                projectedResources = @([pscustomobject]@{ resourceId = '/subscriptions/sub/resourceGroups/rg/providers/type/item' })
            }
        }
    }

    function New-AbortPlan {
        return [pscustomobject]@{
            safety = [pscustomobject]@{
                abortConditions = @(
                    [pscustomobject]@{
                        id = 'steady-state-breach'
                        kind = 'predicate'
                        predicate = [pscustomobject]@{
                            raw = 'Availability >= 99'
                            signal = 'Availability'
                            comparison = '>='
                            threshold = 99
                        }
                    }
                    [pscustomobject]@{
                        id = 'signal-unavailable'
                        kind = 'missing-signal'
                        sources = @('metrics:Availability')
                        intervalSeconds = 60
                        unavailableIntervals = 2
                    }
                )
            }
        }
    }
}

Describe 'Evidence windows and implicit metric targeting' {
    It 'uses the canonical startUtc/endUtc window fields in a metric query' {
        Mock Invoke-AzRest {
            [pscustomobject]@{
                body = [pscustomobject]@{
                    value = @([pscustomobject]@{
                        timeseries = @([pscustomobject]@{
                            data = @([pscustomobject]@{ timeStamp = '2026-08-30T20:01:00Z'; average = 1 })
                        })
                    })
                }
            }
        }
        $window = New-ChaosWindow -Name pre -Start ([datetime]'2026-08-30T20:00:00Z') -End ([datetime]'2026-08-30T20:02:00Z')
        $spec = ConvertFrom-ChaosSignalSourceSpec -Spec 'metrics:Availability'

        $result = Get-ChaosMetricSignal -Spec $spec -ResourceId '/subscriptions/sub/resource' -Window $window

        $result.caveat | Should -BeNullOrEmpty
        @($result.values).Count | Should -Be 1
        Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter {
            $Uri -match 'timespan=2026-08-30T20:00:00Z/2026-08-30T20:02:00Z'
        }
    }

    It 'uses a projected resource object as the implicit metric target' {
        Mock Get-ChaosMetricSignal {
            New-ChaosSignalResult -Source $Spec.id -Window $Window.name -Values @([ordered]@{ value = 1 })
        }
        $plan = [pscustomobject]@{
            scope = [pscustomobject]@{
                projectedResources = @([pscustomobject]@{ resourceId = '/subscriptions/sub/resource' })
            }
        }
        $window = New-ChaosWindow -Name pre -Start ([datetime]'2026-08-30T20:00:00Z') -End ([datetime]'2026-08-30T20:02:00Z')

        Invoke-ChaosSignalCollection -Plan $plan -Window $window -Sources @('metrics:Availability') | Out-Null

        Should -Invoke Get-ChaosMetricSignal -Times 1 -ParameterFilter {
            $ResourceId -eq '/subscriptions/sub/resource'
        }
    }
}

Describe 'Blast-radius exclusions' {
    It 'preserves tag key/value structure and applies matching tags locally' {
        $blast = New-ChaosBlastRadius -ExcludeTags @{ environment = 'production' }
        $resources = @(
            [pscustomobject]@{ resourceId = '/r/one'; resourceType = 'type'; location = 'westus2'; zones = @('1'); tags = @{ environment = 'production' } }
            [pscustomobject]@{ resourceId = '/r/two'; resourceType = 'type'; location = 'westus2'; zones = @('1'); tags = @{ environment = 'test' } }
        )

        $projected = @(Resolve-ChaosBlastRadiusResource -ScopedResources $resources -BlastRadius $blast)

        $blast.exclusions.tags[0].key | Should -Be 'environment'
        $blast.exclusions.tags[0].value | Should -Be 'production'
        $projected.resourceId | Should -Be '/r/two'
    }

    It 'applies wildcard tag exclusions to any value for the key' {
        $blast = New-ChaosBlastRadius -ExcludeTags @{ protected = '*' }
        $resources = @(
            [pscustomobject]@{ resourceId = '/r/one'; resourceType = 'type'; location = 'westus2'; zones = @(); tags = @{ protected = 'yes' } }
            [pscustomobject]@{ resourceId = '/r/two'; resourceType = 'type'; location = 'westus2'; zones = @(); tags = @{ other = 'value' } }
        )

        $projected = @(Resolve-ChaosBlastRadiusResource -ScopedResources $resources -BlastRadius $blast)

        $projected.resourceId | Should -Be '/r/two'
    }
}

Describe 'Plan persistence and execution gates' {
    It 'hashes the same redacted representation that is persisted' {
        $path = Join-Path $TestDrive 'study-plan.v1.json'
        $raw = [ordered]@{
            planVersion = 'study-plan.v1'
            action = [ordered]@{ tokenSchema = 'service-supplied-value'; name = 'stop' }
        }
        $safe = Protect-ChaosObject -InputObject $raw
        $safe['frozenConfigHash'] = Get-ChaosDigest -InputObject $safe
        Write-ChaosJsonFile -Path $path -InputObject $safe -SkipRedaction | Out-Null

        $persisted = Read-ChaosJsonFile -Path $path

        $persisted.action.tokenSchema | Should -Be '[REDACTED]'
        Assert-ChaosPlanIntegrity -Plan $persisted | Should -BeTrue
    }

    It 'allows only complete live discovery to become executable' {
        Test-ChaosPlanLiveDiscovery -Plan (New-LivePlan) | Should -BeTrue

        $offline = New-LivePlan
        $offline.action.source = 'unverified-offline'
        $offline.scope.projectedResourceCount = $null
        Test-ChaosPlanLiveDiscovery -Plan $offline | Should -BeFalse
    }

    It 'rejects zero-length evidence windows before execution' {
        $plan = [pscustomobject]@{
            windows = [pscustomobject]@{ baselineMinutes = 0; injectMinutes = 10; recoveryMinutes = 10 }
        }

        Test-ChaosPlanWindows -Plan $plan | Should -BeFalse
        $plan.windows.baselineMinutes = 1
        Test-ChaosPlanWindows -Plan $plan | Should -BeTrue
    }

    It 'requires a matching, ready, unconsumed approval preview' {
        $plan = [pscustomobject]@{ frozenConfigHash = 'abc' }
        $preview = [pscustomobject]@{ planHash = 'abc'; approvalReady = $true; consumedAt = $null }

        Test-ChaosApprovalPreviewReady -Plan $plan -Preview $preview | Should -BeTrue
        $preview.planHash = 'different'
        Test-ChaosApprovalPreviewReady -Plan $plan -Preview $preview | Should -BeFalse
        $preview.planHash = 'abc'
        $preview.consumedAt = '2026-08-30T20:00:00Z'
        Test-ChaosApprovalPreviewReady -Plan $plan -Preview $preview | Should -BeFalse
    }

    It 'blocks a plan whose live abort predicate has no signal source' {
        $predicate = [pscustomobject]@{ signal = 'Availability' }

        $gate = Test-ChaosObservabilityCoverage -AvailableSources @() -SteadyState $predicate

        $gate.status | Should -Be 'fail'
        $gate.severity | Should -Be 'blocking'
    }

    It 'changes the permission approval digest when the exact preview changes' {
        $first = Get-ChaosPermissionFixApproval -FixResult ([pscustomobject]@{
            properties = [pscustomobject]@{ roleAssignments = @([pscustomobject]@{
                targetResourceId = '/r/one'; principalId = 'principal'; roleDefinitionId = '/roles/reader'
                roleDefinitionName = 'Reader'; scope = '/r/one'; status = 'Pending'
            }) }
        })
        $second = Get-ChaosPermissionFixApproval -FixResult ([pscustomobject]@{
            properties = [pscustomobject]@{ roleAssignments = @([pscustomobject]@{
                targetResourceId = '/r/two'; principalId = 'principal'; roleDefinitionId = '/roles/reader'
                roleDefinitionName = 'Reader'; scope = '/r/two'; status = 'Pending'
            }) }
        })

        $first.digest | Should -Not -Be $second.digest
    }

    It 'arms approval only when every reported RBAC change is enumerated' {
        Mock Get-ChaosConfigurationValidation {
            [pscustomobject]@{ properties = [pscustomobject]@{ status = 'RequiresAttention'; validationErrors = @() } }
        }
        Mock Repair-ChaosConfigurationPermission {
            [pscustomobject]@{
                properties = [pscustomobject]@{
                    summary = [pscustomobject]@{ totalRequired = 1; succeeded = 0; failed = 0; skipped = 0 }
                    roleAssignments = @([pscustomobject]@{
                        targetResourceId = '/r/one'; principalId = 'principal'; roleDefinitionId = '/roles/reader'
                        roleDefinitionName = 'Reader'; scope = '/r/one'; status = 'Pending'
                    })
                }
            }
        }

        $preview = Get-ChaosStudyApprovalPreview -Plan (New-LivePlan) -ConfigurationName config

        $preview.approvalReady | Should -BeTrue
        $preview.permissionFix.exact | Should -BeTrue
    }

    It 'refuses approval when the service reports RBAC changes without exact assignments' {
        Mock Get-ChaosConfigurationValidation {
            [pscustomobject]@{ properties = [pscustomobject]@{ status = 'RequiresAttention'; validationErrors = @() } }
        }
        Mock Repair-ChaosConfigurationPermission {
            [pscustomobject]@{
                properties = [pscustomobject]@{
                    summary = [pscustomobject]@{ totalRequired = 1; succeeded = 0; failed = 0; skipped = 0 }
                    roleAssignments = @()
                }
            }
        }

        $preview = Get-ChaosStudyApprovalPreview -Plan (New-LivePlan) -ConfigurationName config

        $preview.approvalReady | Should -BeFalse
        $preview.permissionFix.exact | Should -BeFalse
    }

    It 'ignores permission-operation timestamps while binding exact assignments' {
        $assignment = [pscustomobject]@{
            targetResourceId = '/r/one'; principalId = 'principal'; roleDefinitionId = '/roles/reader'
            roleDefinitionName = 'Reader'; scope = '/r/one'; status = 'Pending'
        }
        $first = Get-ChaosPermissionFixApproval -FixResult ([pscustomobject]@{
            properties = [pscustomobject]@{ startedAt = '2026-08-30T20:00:00Z'; roleAssignments = @($assignment) }
        })
        $second = Get-ChaosPermissionFixApproval -FixResult ([pscustomobject]@{
            properties = [pscustomobject]@{ startedAt = '2026-08-30T20:01:00Z'; roleAssignments = @($assignment) }
        })

        $first.digest | Should -Be $second.digest
    }

    It 'pins both permission-repair calls to the frozen plan subscription' {
        Mock Invoke-AzChaos { [pscustomobject]@{ properties = [pscustomobject]@{} } }
        $plan = [pscustomobject]@{
            workspace = [pscustomobject]@{ subscriptionId = 'frozen-sub'; resourceGroup = 'rg'; name = 'ws' }
            scenario = [pscustomobject]@{ name = 'zone-down' }
        }

        Repair-ChaosConfigurationPermission -Plan $plan -ConfigurationName config -WhatIf | Out-Null

        Should -Invoke Invoke-AzChaos -Times 2 -ParameterFilter {
            $subscriptionIndex = [array]::IndexOf([object[]]$ChaosArgs, '--subscription')
            $subscriptionIndex -ge 0 -and $ChaosArgs[$subscriptionIndex + 1] -eq 'frozen-sub'
        }
    }
}

Describe 'Automatic abort behavior' {
    It 'trips when the frozen steady-state predicate is breached' {
        $plan = New-AbortPlan
        $window = New-ChaosWindow -Name abort-check -Start ([datetime]'2026-08-30T20:00:00Z') -End ([datetime]'2026-08-30T20:01:00Z')
        $signals = @(
            New-ChaosSignalResult -Source 'metrics:Availability' -Window abort-check `
                -Values @([ordered]@{ timestamp = '2026-08-30T20:01:00Z'; value = 95 })
        )

        $result = Invoke-ChaosAbortEvaluation -Plan $plan -Signals $signals -Window $window `
            -InjectionStartedAt ([datetime]'2026-08-30T20:00:00Z') -State ([ordered]@{})

        $result.triggered | Should -BeTrue
        $result.trigger.conditionId | Should -Be 'steady-state-breach'
    }

    It 'does not abort while the predicate holds and telemetry is present' {
        $plan = New-AbortPlan
        $window = New-ChaosWindow -Name abort-check -Start ([datetime]'2026-08-30T20:00:00Z') -End ([datetime]'2026-08-30T20:01:00Z')
        $signals = @(
            New-ChaosSignalResult -Source 'metrics:Availability' -Window abort-check `
                -Values @([ordered]@{ timestamp = '2026-08-30T20:01:00Z'; value = 100 })
        )

        $result = Invoke-ChaosAbortEvaluation -Plan $plan -Signals $signals -Window $window `
            -InjectionStartedAt ([datetime]'2026-08-30T20:00:00Z') -State ([ordered]@{})

        $result.triggered | Should -BeFalse
    }

    It 'trips after telemetry is missing for the frozen two-interval contract' {
        $plan = New-AbortPlan
        $window = New-ChaosWindow -Name abort-check -Start ([datetime]'2026-08-30T20:00:00Z') -End ([datetime]'2026-08-30T20:02:00Z')
        $signals = @(
            New-ChaosSignalResult -Source 'metrics:Availability' -Window abort-check -Caveat 'No data.'
        )

        $result = Invoke-ChaosAbortEvaluation -Plan $plan -Signals $signals -Window $window `
            -InjectionStartedAt ([datetime]'2026-08-30T20:00:00Z') -State ([ordered]@{})

        $result.triggered | Should -BeTrue
        $result.trigger.conditionId | Should -Be 'signal-unavailable'
    }

    It 'cancels through the supported scenario run API path and subscription' {
        Mock Invoke-AzChaos { [pscustomobject]@{ status = 'Cancelling' } }
        $plan = [pscustomobject]@{
            workspace = [pscustomobject]@{ subscriptionId = 'sub'; resourceGroup = 'rg'; name = 'ws' }
            scenario = [pscustomobject]@{ name = 'zone-down' }
        }

        $result = Stop-ChaosStudyScenarioRun -Plan $plan -RunId 'run-1'

        $result.responseReceived | Should -BeTrue
        Should -Invoke Invoke-AzChaos -Times 1 -ParameterFilter {
            ($ChaosArgs -join ' ') -eq 'scenario run cancel -n run-1 -g rg --subscription sub --workspace-name ws --scenario-name zone-down'
        }
    }

    It 'wires live abort evaluation to immediate cancellation in the run path' {
        $source = Get-Content -LiteralPath $script:RunEntry -Raw

        $source | Should -Match '-OnAbortCheck'
        $source | Should -Match 'if \(\$null -ne \$waited\.abort\)'
        $source | Should -Match 'Stop-ChaosStudyScenarioRun -Plan \$plan -RunId \$runId'
        $source | Should -Match 'evidence/during/abort-checks\.json'
    }

    It 'never reports missing recovery or a telemetry abort as recovered' {
        $finding = [pscustomobject]@{ severity = 'high' }
        Get-ChaosVerdict -Findings @($finding) -MechanismProven $true -PredicateMeasured $false -RecoveryMeasured $null |
            Should -Be 'Inconclusive'

        $abort = [pscustomobject]@{ triggered = $true; kind = 'missing-signal' }
        Get-ChaosVerdict -Findings @([pscustomobject]@{ severity = 'medium' }) `
            -MechanismProven $true -PredicateMeasured $true -RecoveryMeasured $true -Abort $abort |
            Should -Be 'Inconclusive'

        Get-ChaosVerdict -Findings @([pscustomobject]@{ severity = 'medium' }) `
            -MechanismProven $true -PredicateMeasured $null -RecoveryMeasured $true |
            Should -Be 'Inconclusive'
    }
}

Describe 'Front-door forwarding and exit contracts' {
    BeforeAll {
        . $script:FrontDoor -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws `
            -Scenario scenario -Action action -SteadyState 'Availability >= 99'
    }

    It 'preserves arrays and hashtables across the child PowerShell boundary' {
        $phase = Join-Path $TestDrive 'phase.ps1'
        $output = Join-Path $TestDrive 'phase-output.json'
        @'
param([string[]]$Values, [hashtable]$Tags, [string]$OutputPath)
[ordered]@{ values = @($Values); tags = $Tags } |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $OutputPath
'@ | Set-Content -LiteralPath $phase

        $code = Invoke-ChaosPhase -Name test -Script $phase -Arguments @{
            Values = @('one', 'two')
            Tags = @{ environment = 'production' }
            OutputPath = $output
        }
        $captured = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json

        $code | Should -Be 0
        (@($captured.values) -join ',') | Should -Be 'one,two'
        $captured.tags.environment | Should -Be 'production'
    }

    It 'returns a child phase exit code unchanged' {
        $phase = Join-Path $TestDrive 'exit.ps1'
        'exit 14' | Set-Content -LiteralPath $phase

        Invoke-ChaosPhase -Name test -Script $phase -Arguments @{} | Should -Be 14
    }

    It 'uses the renderer error parameter and binds to the newly created study id' {
        $source = Get-Content -LiteralPath $script:FrontDoor -Raw

        $source | Should -Not -Match 'Write-Error-Card[^\r\n]*-Body'
        $source | Should -Match 'Export-Clixml'
        $source.Contains('Find-ChaosStudy -StudyId $plannedStudyId') | Should -BeTrue
        $source | Should -Match '\[''FilterZone''\]'
        $source | Should -Match '\[''FilterPhysicalZone''\]'
        $source | Should -Match '\[''ExcludeTag''\]'
    }
}

Describe 'Cross-file artifact and replay contracts' {
    It 'keeps v1 filenames and payload versions coherent' {
        (Get-Content -LiteralPath $script:ScopeEntry -Raw) | Should -Match '\$ChaosStudyPlanVersion = ''study-plan\.v1'''
        (Get-Content -LiteralPath $script:RunEntry -Raw) | Should -Match "recordVersion = 'run-record.v1'"
    }

    It 'pins all scope reads to the explicit subscription and rejects zero windows' {
        $source = Get-Content -LiteralPath $script:ScopeEntry -Raw

        $source | Should -Match 'Get-ChaosStudyScopedResource -SubscriptionId \$SubscriptionId'
        $source | Should -Match 'Assert-ChaosWorkspaceEvaluation -SubscriptionId \$SubscriptionId'
        $source | Should -Match 'Get-ChaosStudyScenario -SubscriptionId \$SubscriptionId'
        $source | Should -Match 'projectedResources\s+=\s+@\(@\(\$projected\)'
        $source | Should -Not -Match 'projectedResources\s+=\s+@\(@\(\$projected\).*?\[string\]\$_\.resourceId\)'
        ([regex]::Matches($source, 'ValidateRange\(1, 240\)')).Count | Should -BeGreaterOrEqual 3
    }

    It 'replays frozen scenario parameters and every blast-radius axis' {
        $source = Get-Content -LiteralPath $script:HistoryEntry -Raw

        foreach ($parameter in @('Parameters', 'FilterLocation', 'FilterZone', 'FilterPhysicalZone', 'ExcludeResource', 'ExcludeType', 'ExcludeTag')) {
            $source | Should -Match "-$parameter"
        }
    }

    It 'renders one and multiple tag exclusions as bindable hashtables' {
        $cases = @(
            @([pscustomobject]@{ key = 'environment'; value = 'production' })
            @(
                [pscustomobject]@{ key = 'environment'; value = 'production' }
                [pscustomobject]@{ key = 'protected'; value = '*' }
            )
        )
        $binder = [scriptblock]::Create('param([hashtable]$ExcludeTag) $ExcludeTag')

        foreach ($pairs in $cases) {
            $table = ConvertTo-ChaosTagTable -Tags @($pairs)
            $literal = ConvertTo-ChaosPowerShellLiteral -Value $table
            $bound = & $binder (Invoke-Expression $literal)

            $bound | Should -BeOfType ([hashtable])
            $bound.Count | Should -Be @($pairs).Count
            foreach ($pair in @($pairs)) {
                $bound[[string]$pair.key] | Should -Be $pair.value
            }
        }
    }

    It 'builds manifest file hashes for the report appendix before sealing' {
        $studyPath = Join-Path $TestDrive 'scope/study'
        New-Item -ItemType Directory -Path $studyPath -Force | Out-Null
        Write-ChaosTextFile -Path (Join-Path $studyPath 'study-plan.v1.json') -Content '{}' | Out-Null
        Write-ChaosTextFile -Path (Join-Path $studyPath 'report.html') -Content 'old report' | Out-Null
        $manifest = New-ChaosStudyManifest -StudyPath $studyPath -Identity @{ workspace = 'ws' } `
            -SealedAt '2026-08-30T20:00:00Z' -ExcludeReport

        $manifest.sealedAt | Should -Be '2026-08-30T20:00:00Z'
        $manifest.files.Contains('study-plan.v1.json') | Should -BeTrue
        $manifest.files.Contains('report.html') | Should -BeFalse

        $reportSource = Get-Content -LiteralPath $script:Report -Raw
        $reportSource | Should -Match "Properties.Name -contains 'files'"
        $reportSource | Should -Not -Match "Properties.Name -contains 'artifacts'"
        (Get-Content -LiteralPath $script:ReportEntry -Raw) | Should -Match 'New-ChaosStudyManifest'
    }
}
