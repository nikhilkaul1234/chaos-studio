#Requires -Version 7.0
<#
.SYNOPSIS
    Execute a frozen chaos study plan as a Chaos Studio V2 scenario run, and
    record what happened.

.DESCRIPTION
    This is the only script in the suite that injects a fault. Approval
    preparation creates and deletes a temporary scenario configuration; the
    armed path may apply the exact RBAC changes a human reviewed. It is therefore
    the most conservative script:

      * It refuses to run a plan that changed after it was frozen.
      * It starts no scenario and applies no RBAC without an explicit,
        plan-specific human consent phrase.
      * It defaults to a dry run, so the unarmed path is the default path.
      * It refuses to execute a scenario configuration that did not validate.
      * It cancels the scenario run and deletes the configuration it created,
        even on failure.

    Evidence is collected in three windows - before, during and after - and
    written verbatim. A signal that could not be read is recorded as null with
    a reason. Nothing is inferred, interpolated or filled in.

.EXAMPLE
    ./Invoke-ChaosStudyRun.ps1
    Previews the latest planned study without touching anything.

.EXAMPLE
    ./Invoke-ChaosStudyRun.ps1 -StudyId <id> -PrepareApproval
    Displays the exact frozen plan, blast radius, and RBAC changes.

.EXAMPLE
    ./Invoke-ChaosStudyRun.ps1 -StudyId <id> -DryRun:$false -Consent '<human-typed phrase>'
    Runs it after the fresh human approval handoff.
#>

[CmdletBinding()]
param(
    [string]$StudyId = 'latest',
    [string]$StudyRoot,
    [bool]$DryRun = $true,
    [string]$Consent,
    [string[]]$SignalSource = @(),
    [int]$PollSeconds = 20,
    [switch]$PrepareApproval,
    [switch]$KeepConfiguration,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
$sharedLib = Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib'
. (Join-Path $sharedLib 'Common.ps1')
. (Join-Path $sharedLib 'ApiVersions.ps1')
. (Join-Path $sharedLib 'Study.ps1')
. (Join-Path $libDir 'Signals.ps1')
. (Join-Path $libDir 'Execute.ps1')

# -- Locate the study ------------------------------------------------------

$findArgs = @{ StudyId = $StudyId }
if ($StudyRoot) { $findArgs['StudyRoot'] = $StudyRoot }
$study = Find-ChaosStudy @findArgs

if (-not $study) {
    Write-ChaosStudyFailure -Title 'No study to run' -Message @"
Could not find a study matching '$StudyId'.
"@ -Remediation 'Run the chaos-study-scope skill first to plan a study.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

$studyPath = $study.path
$plan = Read-ChaosJsonFile -Path (Join-Path $studyPath 'study-plan.v1.json')

if (-not $plan) {
    Write-ChaosStudyFailure -Title 'Study has no plan' -Message @"
Study $($study.studyId) exists but contains no study plan, so there is nothing
to execute.
"@ -Remediation 'Re-run the chaos-study-scope skill for this workspace.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

if ($study.state -eq 'SEALED') {
    Write-ChaosStudyFailure -Title 'Study is sealed' -Message @"
Study $($study.studyId) has already been reported and sealed. Sealed studies are
immutable so that a report always describes the run it was generated from.
"@ -Remediation 'Run the chaos-study-scope skill to plan a fresh study, then run that one.'
    exit (Get-ChaosStudyExitCode -Name 'StudyAlreadySealed')
}

if ($study.state -eq 'EXECUTED' -and -not $Force -and -not $DryRun) {
    Write-ChaosStudyFailure -Title 'Study has already been executed' -Message @"
Study $($study.studyId) already holds a run record. Running it again would
overwrite evidence from the first execution.
"@ -Remediation 'Plan a new study, or pass -Force if you intend to overwrite this one.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

Assert-ChaosPlanIntegrity -Plan $plan | Out-Null

if ($KeepConfiguration) {
    Write-ChaosStudyFailure -Title 'Configuration retention is not supported' -Message @"
Study configurations are temporary safety artifacts and are deleted after
PrepareApproval and armed execution. Retaining one would make the cleanup
statement in the frozen preview false.
"@ -Remediation 'Remove -KeepConfiguration. Cleanup failures are retained as evidence instead.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

$configurationName = Get-ChaosStudyConfigurationName -StudyId $study.studyId
$sources = @($SignalSource)
if ($sources.Count -eq 0 -and $plan.signals.configuredSources) {
    $sources = @($plan.signals.configuredSources)
}

if (-not (Test-ChaosPlanWindows -Plan $plan)) {
    Write-ChaosStudyFailure -Title 'Plan windows are not executable' -Message @"
Baseline, injection, and recovery windows must each be at least one minute.
This plan contains baseline=$($plan.windows.baselineMinutes),
injection=$($plan.windows.injectMinutes), recovery=$($plan.windows.recoveryMinutes).
"@ -Remediation 'Re-run chaos-study-scope with non-zero windows. The plan was rejected before consent or Azure mutation.'
    exit (Get-ChaosStudyExitCode -Name 'ConfigurationDrift')
}

$liveDiscoveryVerified = Test-ChaosPlanLiveDiscovery -Plan $plan

$blast = Get-ChaosBlastRadiusArgument -Plan $plan

# -- Human approval preparation --------------------------------------------

if ($PrepareApproval) {
    if (-not $liveDiscoveryVerified) {
        Write-ChaosStudyFailure -Title 'Live discovery is required before approval' -Message @"
This plan was created without a complete live discovery result. Offline planning
is supported, but an offline or otherwise unverified plan cannot produce an
approval preview and can never arm.
"@ -Remediation 'Re-run chaos-study-scope without -SkipDiscovery, then prepare approval for the new study id.'
        exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
    }

    $approvalConfigurationName = "$configurationName-approval"
    $configurationCreated = $false
    $approvalCleanup = $null
    try {
        Write-ChaosStudyNote -Message "Creating temporary scenario configuration $approvalConfigurationName for approval preparation."
        New-ChaosStudyConfiguration -Plan $plan -ConfigurationName $approvalConfigurationName | Out-Null
        $configurationCreated = $true
        $prepared = Get-ChaosStudyApprovalPreview -Plan $plan -ConfigurationName $approvalConfigurationName

        $approvalPreview = [ordered]@{
            approvalPreviewVersion = 'approval-preview.v1'
            studyId                = $study.studyId
            planHash               = $plan.frozenConfigHash
            generatedAt            = Get-ChaosUtcNow
            consumedAt             = $null
            approvalReady          = [bool]$prepared.approvalReady
            blastRadius            = [ordered]@{
                workspacePrincipalId = $plan.workspace.identityPrincipalId
                filters              = $blast.filters
                exclusions           = $blast.exclusions
                projectedResources   = @($plan.scope.projectedResources)
            }
            validation             = [ordered]@{
                status = $prepared.validationStatus
                errors = @($prepared.validationErrors)
            }
            permissionFix          = $prepared.permissionFix
        }
        Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'approval-preview.v1.json' -Content $approvalPreview | Out-Null
        $previewCommand = if ($prepared.permissionFix.attempted) {
            'az chaos scenario config fix-permissions --what-if'
        } else {
            'az chaos scenario config validate'
        }
        $previewNote = if ($prepared.permissionFix.attempted) {
            "RBAC preview digest $($prepared.permissionFix.digest)"
        } else {
            "Validation $($prepared.validationStatus); permission repair not attempted"
        }
        Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'approval' -Command $previewCommand `
            -Arguments @($approvalConfigurationName) -ExitCode 0 -Note $previewNote | Out-Null
    } finally {
        if ($configurationCreated) {
            try {
                $approvalCleanup = Remove-ChaosStudyConfiguration -Plan $plan -ConfigurationName $approvalConfigurationName
            } catch {
                $approvalCleanup = [ordered]@{
                    configurationName = $approvalConfigurationName
                    resourceId        = "$($plan.workspace.id)/scenarios/$($plan.scenario.name)/configurations/$approvalConfigurationName"
                    attemptedAt       = Get-ChaosUtcNow
                    deletionRequested = $true
                    effective         = $false
                    certainty         = 'cleanup-uncertain'
                    serviceError      = Protect-ChaosSecret -Text $_.Exception.Message
                    reconciliation    = $null
                }
            }
        }
    }
    $approvalPreview['cleanup'] = $approvalCleanup
    Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'approval-preview.v1.json' -Content $approvalPreview | Out-Null
    if ($null -ne $approvalCleanup -and ($null -ne $approvalCleanup.serviceError -or -not $approvalCleanup.effective)) {
        Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/cleanup/approval-configuration.json' `
            -Content $approvalCleanup | Out-Null
    }
    if ($null -eq $approvalCleanup -or -not $approvalCleanup.effective) {
        $cleanupStatus = Format-ChaosCleanupStatus -Cleanup $approvalCleanup
        Write-ChaosStudyFailure -Title 'Temporary approval configuration cleanup uncertain' -Message @"
Deletion of '$approvalConfigurationName' was not confirmed. The exact resource
identity and reconciliation evidence are retained at
evidence/cleanup/approval-configuration.json. Approval cannot proceed while the
temporary configuration may still exist.

$cleanupStatus

Validation status: $($approvalPreview.validation.status)
Permission repair attempted: $($approvalPreview.permissionFix.attempted)
"@ -Remediation 'Verify the exact configuration resource is absent, then run -PrepareApproval again.'
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }
    if ($null -ne $approvalCleanup.serviceError) {
        Write-ChaosStudyCard -Title 'Cleanup effective despite service error' -Body @"
The delete command reported a service/LRO error, retained at
evidence/cleanup/approval-configuration.json. One read-only reconciliation found
the exact configuration absent, so cleanup is effective. No second DELETE was
issued.

$(Format-ChaosCleanupStatus -Cleanup $approvalCleanup)
"@
    }

    $permissionText = Format-ChaosApprovalPermissionStatus -ApprovalPreview $prepared
    Write-ChaosStudyCard -Title 'Frozen plan requiring human approval' -Body (
        ConvertTo-ChaosCanonicalJson -InputObject $plan
    )
    Write-ChaosStudyCard -Title 'Frozen blast radius requiring human approval' -Body (
        ConvertTo-ChaosCanonicalJson -InputObject $approvalPreview.blastRadius
    )
    Write-ChaosStudyCard -Title 'Exact RBAC changes requiring human approval' -Body $permissionText

    if (-not $approvalPreview.approvalReady) {
        $approvalFailure = if (-not $approvalPreview.permissionFix.attempted) {
            'Validation failed with backend, resource-state, metadata, unknown, or otherwise non-repairable errors. Permission repair was not attempted.'
        } elseif (-not $approvalPreview.permissionFix.exact) {
            'Permission what-if did not return an authoritative complete assignment set.'
        } else {
            'Permission what-if returned no applicable assignments, and validation did not succeed.'
        }
        Write-ChaosStudyFailure -Title 'Configuration is not ready for approval' -Message @"
Validation reported '$($approvalPreview.validation.status)'.

$approvalFailure

The validation errors, permission decision, and cleanup result are stored in
approval-preview.v1.json. No role assignment or scenario run was created.
"@ -Remediation 'Correct the validation errors, re-scope if needed, and prepare approval again.'
        exit (Get-ChaosStudyExitCode -Name 'ValidationFailed')
    }

    $phrase = Get-ChaosConsentPhrase -Plan $plan
    Write-ChaosStudyCard -Title 'Fresh human approval required' -Body @"
The temporary configuration has been deleted. No role assignment was created and
no scenario was started.

A human must now review all exact previews above and type this plan-hash-bound
phrase in a new invocation. An agent must not copy or self-confirm it:

  $phrase

Then run:

  chaos-study-run -StudyId $($study.studyId) -DryRun:`$false -Consent '<human-typed phrase>'
"@
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

# -- Dry run ---------------------------------------------------------------

if ($DryRun) {
    $previewWindow = New-ChaosWindow -Name 'preview' -Start (ConvertTo-ChaosUtcIso -Instant (Get-Date).ToUniversalTime().AddMinutes(-1)) -End (Get-ChaosUtcNow)
    $preview = Invoke-ChaosSignalCollection -Plan $plan -Window $previewWindow -Sources $sources -DryRun
    Write-ChaosStudyDryRunPreview -Plan $plan -StudyId $study.studyId `
        -ConfigurationName $configurationName -SignalPreview $preview `
        -LiveDiscoveryVerified $liveDiscoveryVerified

    Write-ChaosStudyNote -Message 'Dry run complete. Nothing was changed.'
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

# -- Armed path ------------------------------------------------------------

if (-not $liveDiscoveryVerified) {
    Write-ChaosStudyFailure -Title 'Offline plan cannot arm' -Message @"
This plan does not contain a complete live discovery result. -SkipDiscovery is
for offline planning only; neither -Force nor a consent string can arm it.
"@ -Remediation 'Re-run chaos-study-scope without -SkipDiscovery, review the new frozen plan, then run -PrepareApproval.'
    exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
}

$approvalPreview = Read-ChaosJsonFile -Path (Join-Path $studyPath 'approval-preview.v1.json')
if (-not (Test-ChaosApprovalPreviewReady -Plan $plan -Preview $approvalPreview)) {
    Write-ChaosStudyFailure -Title 'Fresh approval preview required' -Message @"
No unconsumed approval preview matching this frozen plan is available. Armed
execution is split deliberately: first display the frozen resource list and
Chaos Studio's exact RBAC what-if result, then obtain fresh human approval.
"@ -Remediation "Run chaos-study-run -StudyId $($study.studyId) -PrepareApproval."
    exit (Get-ChaosStudyExitCode -Name 'ConsentDeclined')
}

Assert-ChaosConsent -Plan $plan -Consent $Consent | Out-Null

if ($plan.discovery.region -and $plan.scope.region -and -not $Force) {
    # Discovery and the resolved scope must agree, or the action list this plan
    # was chosen from describes a different region than the one that will run.
    if ($plan.discovery.region -ne $plan.scope.region) {
        Write-ChaosStudyFailure -Title 'Plan region is inconsistent' -Message @"
This plan discovered actions in region '$($plan.discovery.region)' but its scope
resolves to '$($plan.scope.region)'. The action chosen may not exist in the
region that would actually run.
"@ -Remediation 'Re-run chaos-study-scope so discovery and scope agree, or pass -Force to proceed anyway.'
        exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
    }
}

if ($plan.scope.projectedResourceCount -eq 0 -and -not $Force) {
    Write-ChaosStudyFailure -Title 'Nothing is in scope' -Message @"
After filters and exclusions this plan reaches zero resources. A scenario run
against an empty scope succeeds without touching anything, which would produce a
report claiming resilience that was never tested.
"@ -Remediation 'Re-run chaos-study-scope with a wider scope or fewer exclusions, or pass -Force to record the empty run deliberately.'
    exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
}

$approvalPreview.consumedAt = Get-ChaosUtcNow
Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'approval-preview.v1.json' -Content $approvalPreview | Out-Null

if (Get-Command Ensure-AzLogin -ErrorAction SilentlyContinue) { Ensure-AzLogin | Out-Null }

$startedAt = Get-ChaosUtcNow
Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'Invoke-ChaosStudyRun' `
    -Note "consented; configuration $configurationName in workspace $($plan.workspace.name)" | Out-Null

# The baseline window is fixed here, but read later. It covers the minutes
# immediately before anything was touched, so bounding it now keeps it honest
# even though configuration and validation happen first.
$preWindow = New-ChaosWindow -Name 'pre' -Start (ConvertTo-ChaosUtcIso -Instant (Get-Date).ToUniversalTime().AddMinutes(-1 * $plan.windows.baselineMinutes)) -End $startedAt

$injectStart = $null
$injectEnd = $null
$injectStartInstant = $null
$injectEndInstant = $null
$duringWindow = $null
$configurationCreated = $false
$runId = $null
$runObservation = $null
$validationStatus = $null
$permissionFix = $null
$abortRecord = $null
$abortChecks = @()
$cancellation = $null
$configurationCleanup = $null
$outcome = 'unknown'
$failureMessage = $null
# Seeded because the run record is written even when the try block fails part
# way through, and an unassigned variable would fault under Set-StrictMode
# while reporting a failure - hiding the failure behind a scripting error.
$preEvidence = @()
$duringEvidence = @()

try {
    # Configuration and validation come first. A configuration that cannot
    # validate is a run that fails within seconds, and discovering that after a
    # baseline window has already elapsed wastes the window and leaves a study
    # that has to be planned again from scratch.
    Write-ChaosStudyNote -Message "Creating scenario configuration $configurationName."
    New-ChaosStudyConfiguration -Plan $plan -ConfigurationName $configurationName | Out-Null
    $configurationCreated = $true
    Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'az chaos scenario config create' `
        -Arguments @($configurationName) -ExitCode 0 | Out-Null

    Write-ChaosStudyNote -Message 'Validating the configuration against the live scope.'
    $validated = Resolve-ChaosConfigurationValidation -Plan $plan -ConfigurationName $configurationName `
        -ApprovedPermissionDigest ([string]$approvalPreview.permissionFix.digest)
    $validation = $validated.validation
    $validationStatus = $validated.status
    $permissionFix = $validated.permissionFix

    if ($null -ne $permissionFix -and $permissionFix.attempted) {
        Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'az chaos scenario config fix-permissions' `
            -Arguments @($configurationName, "applicable=$($permissionFix.applicable)") -ExitCode 0 | Out-Null
    }

    Assert-ChaosConfigurationValidated -Validation $validation -ConfigurationName $configurationName | Out-Null

    Write-ChaosStudyNote -Message "Collecting baseline evidence over the $($plan.windows.baselineMinutes) minutes before this run began."
    $preEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $preWindow -Sources $sources
    Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/pre/signals.json' -Content $preEvidence | Out-Null

    Write-ChaosStudyNote -Message 'Starting the scenario run.'
    $injectStartInstant = [datetime]::UtcNow
    $injectStart = ConvertTo-ChaosUtcIso -Instant $injectStartInstant
    $started = Start-ChaosStudyScenarioRun -Plan $plan -ConfigurationName $configurationName -Validation $validation
    $runId = $started.runId
    Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'az chaos scenario run start' `
        -Arguments @($configurationName, $runId) -ExitCode 0 | Out-Null

    $abortState = [ordered]@{ missingSince = [ordered]@{} }
    $waited = Wait-ChaosScenarioRunWindow -Plan $plan -RunId $runId -Minutes $plan.windows.injectMinutes `
        -InjectionStartedAt $injectStartInstant -PollSeconds $PollSeconds `
        -OnPoll { param($status) Write-ChaosStudyNote -Message "Scenario run $runId is $status." } `
        -OnAbortCheck {
            param($window)
            $liveSignals = Invoke-ChaosSignalCollection -Plan $plan -Window $window -Sources $sources
            Invoke-ChaosAbortEvaluation -Plan $plan -Signals $liveSignals -Window $window `
                -InjectionStartedAt $injectStartInstant -State $abortState
        }

    $injectEndInstant = [datetime]::UtcNow
    $injectEnd = ConvertTo-ChaosUtcIso -Instant $injectEndInstant
    $duringWindow = New-ChaosWindow -Name 'during' -Start $injectStartInstant -End $injectEndInstant
    $abortChecks = @($waited.abortChecks)
    if ($abortChecks.Count -gt 0) {
        Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/during/abort-checks.json' -Content $abortChecks | Out-Null
    }

    if ($null -ne $waited.abort) {
        Write-ChaosStudyNote -Message "Automatic abort triggered: $($waited.abort.reason)" -Level 'warn'
        $cancellation = Stop-ChaosStudyScenarioRun -Plan $plan -RunId $runId
        $abortRecord = [ordered]@{
            triggered    = $true
            conditionId  = $waited.abort.conditionId
            kind         = $waited.abort.kind
            source       = $waited.abort.source
            reason       = $waited.abort.reason
            observedAt   = $waited.abort.observedAt
            cancellation = $cancellation
            evidence     = 'evidence/during/abort-checks.json'
        }
        $afterCancellation = Get-ChaosStudyScenarioRun -Plan $plan -RunId $runId
        $runObservation = Get-ChaosScenarioRunObservation -Run $(if ($null -ne $afterCancellation) { $afterCancellation } else { $waited.run })
        $outcome = 'Aborted'
    } else {
        $runObservation = Get-ChaosScenarioRunObservation -Run $waited.run
        $outcome = if ($runObservation.status) { $runObservation.status } else { 'unknown' }
    }

    if ($waited.endedEarly -and $outcome -ne 'Succeeded') {
        Write-ChaosStudyNote -Message "The scenario run reached '$outcome' before the injection window elapsed." -Level 'warn'
    }

    Write-ChaosStudyNote -Message 'Collecting evidence from the injection window.'
    $duringEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $duringWindow -Sources $sources
    Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/during/signals.json' -Content $duringEvidence | Out-Null
} catch {
    $failureMessage = $_.Exception.Message
    $outcome = 'Failed'
    Write-ChaosStudyNote -Message "Injection failed: $failureMessage" -Level 'warn'
} finally {
    if ($runId -and $null -eq $cancellation) {
        Write-ChaosStudyNote -Message "Cancelling scenario run $runId."
        $cancellation = Stop-ChaosStudyScenarioRun -Plan $plan -RunId $runId
    }
    if ($configurationCreated) {
        try {
            $configurationCleanup = Remove-ChaosStudyConfiguration -Plan $plan -ConfigurationName $configurationName
        } catch {
            $configurationCleanup = [ordered]@{
                configurationName = $configurationName
                attemptedAt       = Get-ChaosUtcNow
                deletionRequested = $true
                effective         = $false
                certainty         = 'cleanup-uncertain'
                serviceError      = Protect-ChaosSecret -Text $_.Exception.Message
                reconciliation    = $null
            }
        }
        if ($null -ne $configurationCleanup -and ($null -ne $configurationCleanup.serviceError -or -not $configurationCleanup.effective)) {
            Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/cleanup/run-configuration.json' `
                -Content $configurationCleanup | Out-Null
        }
        if ($null -eq $configurationCleanup -or -not $configurationCleanup.effective) {
            if (-not $failureMessage) { $failureMessage = 'Scenario configuration cleanup is uncertain; see evidence/cleanup/run-configuration.json.' }
            $outcome = 'Failed'
        }
    }
}

if ($null -eq $injectStartInstant) {
    $injectStartInstant = ConvertFrom-ChaosUtcIso -Text $startedAt
    $injectStart = ConvertTo-ChaosUtcIso -Instant $injectStartInstant
}
if ($null -eq $injectEndInstant) {
    $injectEndInstant = [datetime]::UtcNow
    if ($injectEndInstant -le $injectStartInstant) { $injectEndInstant = $injectStartInstant.AddTicks(1) }
    $injectEnd = ConvertTo-ChaosUtcIso -Instant $injectEndInstant
}
if ($null -eq $duringWindow) {
    $duringWindow = New-ChaosWindow -Name 'during' -Start $injectStartInstant -End $injectEndInstant
}
if (-not (Test-Path -LiteralPath (Join-Path $studyPath 'evidence' 'during' 'signals.json'))) {
    $duringEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $duringWindow -Sources $sources -DryRun
    Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/during/signals.json' -Content $duringEvidence | Out-Null
}

Write-ChaosStudyNote -Message "Waiting $($plan.windows.recoveryMinutes) minutes for recovery."
Start-Sleep -Seconds ($plan.windows.recoveryMinutes * 60)
$postWindow = New-ChaosWindow -Name 'post' -Start $injectEnd -End (Get-ChaosUtcNow)
$postEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $postWindow -Sources $sources
Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/post/signals.json' -Content $postEvidence | Out-Null

# -- Run record ------------------------------------------------------------

$allSignals = @($preEvidence) + @($duringEvidence) + @($postEvidence)
$coverage = Test-ChaosSignalCoverage -Signals $allSignals

$runRecord = [ordered]@{
    recordVersion = 'run-record.v1'
    studyId       = $study.studyId
    scopeHash     = $study.scopeHash
    planHash      = $plan.frozenConfigHash
    startedAt     = $startedAt
    completedAt   = Get-ChaosUtcNow
    workspace     = [ordered]@{
        subscriptionId = $plan.workspace.subscriptionId
        resourceGroup  = $plan.workspace.resourceGroup
        name           = $plan.workspace.name
        id             = $plan.workspace.id
    }
    configuration = [ordered]@{
        name             = $configurationName
        scenario         = $plan.scenario.name
        scenarioId       = $plan.scenario.id
        validationStatus = $validationStatus
        permissionFix    = $permissionFix
        cleanup          = $configurationCleanup
        retained         = ($null -eq $configurationCleanup -or -not $configurationCleanup.effective)
    }
    scenarioRun   = [ordered]@{
        runId       = $runId
        outcome     = $outcome
        observation = $runObservation
        abort       = $abortRecord
        cancellation = $cancellation
        failure     = $failureMessage
    }
    windows       = [ordered]@{
        pre    = $preWindow
        during = $duringWindow
        post   = $postWindow
    }
    evidence      = [ordered]@{
        pre    = 'evidence/pre/signals.json'
        during = 'evidence/during/signals.json'
        post   = 'evidence/post/signals.json'
    }
    coverage      = $coverage
}

Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'run-record.v1.json' -Content $runRecord | Out-Null

$status = if ($failureMessage) { 'error' } elseif ($coverage.missing -gt 0) { 'warning' } else { 'success' }
$touched = if ($null -ne $runObservation -and $null -ne $runObservation.resourcesTouched) { $runObservation.resourcesTouched } else { 'not reported' }
$completionBody = if ($null -eq $configurationCleanup -or -not $configurationCleanup.effective) {
    'The scenario run has stopped, but configuration cleanup is uncertain. The exact resource identity, original service error, and reconciliation result are retained in evidence/cleanup/run-configuration.json. Evidence is recorded; it has not yet been interpreted.'
} elseif ($null -ne $configurationCleanup.serviceError) {
    'The scenario run has stopped. The delete command reported a service/LRO error, but one read-only reconciliation found the exact configuration absent. Cleanup is effective and the original error is retained in evidence/cleanup/run-configuration.json.'
} else {
    'The scenario run has stopped and the temporary configuration has been cleaned up. Evidence is recorded; it has not yet been interpreted.'
}

Write-Card -Title "Run complete - study $($study.studyId)" -Status $status -Body $completionBody -Properties ([ordered]@{
    'Scenario run'      = if ($runId) { $runId } else { '(never started)' }
    'Outcome'           = $outcome
    'Resources touched' = $touched
    'Signals measured'  = "$($coverage.measured) of $($coverage.total)"
    'Study directory'   = $studyPath
})

if ($coverage.missing -gt 0) {
    Write-Card -Title 'Some evidence is missing' -Status 'warning' -Body (
        @($coverage.caveats | ForEach-Object { "  - $_" }) -join "`n"
    )
}

Write-ChaosStudyNote -Message 'Next: run the chaos-study-report skill to interpret this run.'

if ($failureMessage) { exit (Get-ChaosStudyExitCode -Name 'Error') }
exit (Get-ChaosStudyExitCode -Name 'Success')
