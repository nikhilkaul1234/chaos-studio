<#
.SYNOPSIS
    Runs a complete Chaos reliability study: scope -> run -> report.

.DESCRIPTION
    This is the opinionated front door. It answers one question end to end:

        "Does <steady state> hold when I execute <action> across <workspace scope>?"

    It does not reimplement any phase. It chains the three focused entry points,
    each of which remains independently usable:

        chaos-study-scope   frames the question and freezes a plan
        chaos-study-run     asks for consent, injects, collects evidence
        chaos-study-report  interprets the evidence and writes the report

    Safety posture, inherited from the phase scripts rather than reinvented here:

      * -DryRun defaults to $true. Nothing is injected unless the caller both
        prepares the exact RBAC preview, then a human types the plan-bound phrase
        in a fresh run-skill invocation.
      * The plan is frozen and hashed before anything is armed. If the plan
        changes between scope and run, the run refuses.
      * Any non-zero exit from a phase stops the chain immediately. A partial
        study is left on disk, correctly stated, for inspection or resumption.

    Resumption matters: because each phase persists its own output, a chain that
    fails in `run` can be resumed by invoking `run` directly against the same
    study id. Nothing here is a transaction that must be restarted from scratch.

.EXAMPLE
    ./Invoke-ChaosStudy.ps1 -SubscriptionId $sub -ResourceGroup rg-prod `
        -WorkspaceName ws-payments `
        -Scenario 'zone-down' -Action 'urn:csci:microsoft:...' `
        -SteadyState 'successRate >= 99.5'

    Plans the study against an existing workspace and previews the run.
    Executes nothing.

.EXAMPLE
    ./Invoke-ChaosStudy.ps1 ... -DryRun:$false

    Prepares and prints the exact approval preview, then stops. A human must type
    the newly printed phrase in a direct chaos-study-run invocation.

.EXAMPLE
    ./Invoke-ChaosStudy.ps1 -ListActions -SubscriptionId $sub -ResourceGroup rg-prod `
        -WorkspaceName ws-payments

    Lists the actions Chaos Studio actually offers for that workspace's region,
    read live from the service. This suite ships no action catalogue.
#>

[CmdletBinding(DefaultParameterSetName = 'Study')]
param(
    [Parameter(ParameterSetName = 'ListActions', Mandatory)][switch]$ListActions,
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)][switch]$ListScenarios,

    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$SubscriptionId,
    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$ResourceGroup,

    # The workspace is the lifecycle root: scopes, discovered resources,
    # scenarios and runs all hang off one.
    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$WorkspaceName,

    # Create the workspace when it does not exist, over the given ARM scopes.
    [Parameter(ParameterSetName = 'Study')][switch]$CreateWorkspace,
    [Parameter(ParameterSetName = 'Study')][string[]]$Scope = @(),
    [Parameter(ParameterSetName = 'ListActions')]
    [Parameter(ParameterSetName = 'Study')][string]$Location,

    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$Scenario,
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$Action,
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$SteadyState,
    [Parameter(ParameterSetName = 'Study')][ValidateRange(1, 240)][int]$DurationMinutes = 10,
    [Parameter(ParameterSetName = 'Study')][ValidateRange(1, 240)][int]$BaselineMinutes = 5,
    [Parameter(ParameterSetName = 'Study')][ValidateRange(1, 240)][int]$RecoveryMinutes = 10,
    [Parameter(ParameterSetName = 'Study')][hashtable]$Parameters,
    [Parameter(ParameterSetName = 'Study')][string]$Hypothesis,
    [Parameter(ParameterSetName = 'Study')][string[]]$SignalSource = @(),

    # Blast radius, forwarded to the scenario configuration.
    [Parameter(ParameterSetName = 'Study')][string[]]$FilterLocation = @(),
    [Parameter(ParameterSetName = 'Study')][ValidateSet('1', '2', '3', 'zone-redundant')][string[]]$FilterZone = @(),
    [Parameter(ParameterSetName = 'Study')][string]$FilterPhysicalZone,
    [Parameter(ParameterSetName = 'Study')][string[]]$ExcludeResource = @(),
    [Parameter(ParameterSetName = 'Study')][string[]]$ExcludeType = @(),
    [Parameter(ParameterSetName = 'Study')][hashtable]$ExcludeTag,

    [Parameter(ParameterSetName = 'Study')][string]$StudyRoot,
    [Parameter(ParameterSetName = 'Study')][bool]$DryRun = $true,
    [Parameter(ParameterSetName = 'Study')][string]$Consent,
    [Parameter(ParameterSetName = 'Study')][switch]$KeepConfiguration,
    [Parameter(ParameterSetName = 'Study')][switch]$SkipDiscovery,
    [Parameter(ParameterSetName = 'Study')][switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Common.ps1')
. (Join-Path $libDir 'Study.ps1')

$skillsRoot = Join-Path $PSScriptRoot '..' '..'
$scopeScript = Join-Path $skillsRoot 'chaos-study-scope' 'scripts' 'Invoke-ChaosStudyScope.ps1'
$runScript = Join-Path $skillsRoot 'chaos-study-run' 'scripts' 'Invoke-ChaosStudyRun.ps1'
$reportScript = Join-Path $skillsRoot 'chaos-study-report' 'scripts' 'Invoke-ChaosStudyReport.ps1'

foreach ($required in @($scopeScript, $runScript, $reportScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Error-Card -Title 'Skill suite incomplete' -ErrorMessage @"
Expected phase script not found:

  $required

chaos-study chains the focused skills rather than duplicating them, so all four
skill directories must be installed together.
"@
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }
}

# ---------------------------------------------------------------------------
# Phase invocation
# ---------------------------------------------------------------------------

function Invoke-ChaosPhase {
    <#
        Runs one phase in a child pwsh so that a phase which calls `exit` cannot
        terminate this orchestrator. Output streams through to the console live;
        only the exit code is interpreted here.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $token = [guid]::NewGuid().ToString('N')
    $argumentsPath = Join-Path ([System.IO.Path]::GetTempPath()) "chaos-study-$token.clixml"
    $wrapperPath = Join-Path ([System.IO.Path]::GetTempPath()) "chaos-study-$token.ps1"
    try {
        $portableArguments = @{}
        foreach ($key in $Arguments.Keys) {
            $value = $Arguments[$key]
            $portableArguments[$key] = if ($value -is [switch]) { [bool]$value.IsPresent } else { $value }
        }
        $portableArguments | Export-Clixml -LiteralPath $argumentsPath -Depth 32
        [System.IO.File]::WriteAllText($wrapperPath, @'
param(
    [Parameter(Mandatory)][string]$PhaseScript,
    [Parameter(Mandatory)][string]$ArgumentsFile
)
$phaseArguments = Import-Clixml -LiteralPath $ArgumentsFile
& $PhaseScript @phaseArguments
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
if (-not $?) { exit 1 }
exit 0
'@, [System.Text.UTF8Encoding]::new($false))

        Write-ChaosStudyNote -Message "phase: $Name"
        & pwsh -NoProfile -File $wrapperPath -PhaseScript $Script -ArgumentsFile $argumentsPath |
            ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $argumentsPath, $wrapperPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OnPhaseFailure {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Guidance
    )
    if ($ExitCode -eq 0) { return }
    Write-Error-Card -Title "Study stopped in phase: $Name" -ErrorMessage @"
$Name exited with code $ExitCode.

$Guidance

Nothing further has run. Whatever the phase persisted is still on disk and the
study state reflects exactly how far it got, so you can inspect it or resume
from this phase without re-planning.
"@
    exit $ExitCode
}

if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# Action listing short-circuits the chain
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -in @('ListActions', 'ListScenarios')) {
    $listArgs = @{
        SubscriptionId = $SubscriptionId
        ResourceGroup  = $ResourceGroup
        WorkspaceName  = $WorkspaceName
    }
    if ($PSCmdlet.ParameterSetName -eq 'ListActions') {
        $listArgs['ListActions'] = [switch]::Present
        if ($Location) { $listArgs['Location'] = $Location }
        $phaseName = 'chaos-study-scope (list actions)'
    } else {
        $listArgs['ListScenarios'] = [switch]::Present
        $phaseName = 'chaos-study-scope (list scenarios)'
    }
    $code = Invoke-ChaosPhase -Name $phaseName -Script $scopeScript -Arguments $listArgs
    exit $code
}

# ---------------------------------------------------------------------------
# Phase 1 - scope
# ---------------------------------------------------------------------------

$plannedStudyId = New-ChaosStudyId
$scopeArgs = @{
    SubscriptionId  = $SubscriptionId
    ResourceGroup   = $ResourceGroup
    WorkspaceName   = $WorkspaceName
    Scenario        = $Scenario
    Action          = $Action
    SteadyState     = $SteadyState
    DurationMinutes = $DurationMinutes
    BaselineMinutes = $BaselineMinutes
    RecoveryMinutes = $RecoveryMinutes
    StudyId          = $plannedStudyId
}
if ($CreateWorkspace) { $scopeArgs['CreateWorkspace'] = [switch]::Present }
if ($Scope.Count -gt 0) { $scopeArgs['Scope'] = $Scope }
if ($Location) { $scopeArgs['Location'] = $Location }
if ($Hypothesis) { $scopeArgs['Hypothesis'] = $Hypothesis }
if ($StudyRoot) { $scopeArgs['StudyRoot'] = $StudyRoot }
if ($SignalSource.Count -gt 0) { $scopeArgs['SignalSource'] = $SignalSource }
if ($FilterLocation.Count -gt 0) { $scopeArgs['FilterLocation'] = $FilterLocation }
if ($FilterZone.Count -gt 0) { $scopeArgs['FilterZone'] = $FilterZone }
if ($FilterPhysicalZone) { $scopeArgs['FilterPhysicalZone'] = $FilterPhysicalZone }
if ($ExcludeResource.Count -gt 0) { $scopeArgs['ExcludeResource'] = $ExcludeResource }
if ($ExcludeType.Count -gt 0) { $scopeArgs['ExcludeType'] = $ExcludeType }
if ($ExcludeTag -and $ExcludeTag.Count -gt 0) { $scopeArgs['ExcludeTag'] = $ExcludeTag }
if ($SkipDiscovery) { $scopeArgs['SkipDiscovery'] = [switch]::Present }
if ($Parameters -and $Parameters.Count -gt 0) {
    $scopeArgs['Parameters'] = $Parameters
}

$scopeExit = Invoke-ChaosPhase -Name 'chaos-study-scope' -Script $scopeScript -Arguments $scopeArgs
Stop-OnPhaseFailure -Name 'chaos-study-scope' -ExitCode $scopeExit -Guidance @"
Scoping decides whether the study is worth running at all: it resolves the
workspace, reads what is actually in its scopes, and checks the action applies to
those resources. A failure here is a real answer, not an obstacle to work around.

  exit 10  readiness gates failed - the scope is empty or already unhealthy
  exit 14  discovery failed - the action or scenario is not offered here
"@

$store = if ($StudyRoot) { $StudyRoot } else { (Get-ChaosStudyRoot).path }
$latest = Find-ChaosStudy -StudyId $plannedStudyId -StudyRoot $store
if (-not $latest) {
    Write-Error-Card -Title 'Plan not found' -ErrorMessage 'Scoping reported success but the study it was asked to create was not recorded. Refusing to continue.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}
$studyId = $latest.studyId

if ($PlanOnly) {
    Write-Card -Title 'Plan frozen' -Status 'success' -Body @"
Study $studyId is planned and frozen. Nothing has been executed.

Review the plan, then run it when you are ready:

  chaos-study-run -StudyId $studyId -PrepareApproval
"@
    exit 0
}

# ---------------------------------------------------------------------------
# Phase 2 - run
# ---------------------------------------------------------------------------

$runArgs = @{
    StudyId = $studyId
    DryRun  = $DryRun
}
if ($StudyRoot) { $runArgs['StudyRoot'] = $StudyRoot }
if (-not $DryRun) {
    # A consent value supplied before the exact RBAC preview is not fresh. This
    # invocation prepares that preview and stops; the human then approves in a
    # new direct run-skill invocation against this exact study id.
    $runArgs['DryRun'] = $true
    $runArgs['PrepareApproval'] = [switch]::Present
} elseif ($Consent) {
    $runArgs['Consent'] = $Consent
}
if ($KeepConfiguration) { $runArgs['KeepConfiguration'] = [switch]::Present }
if ($SignalSource.Count -gt 0) { $runArgs['SignalSource'] = $SignalSource }

$runExit = Invoke-ChaosPhase -Name 'chaos-study-run' -Script $runScript -Arguments $runArgs
Stop-OnPhaseFailure -Name 'chaos-study-run' -ExitCode $runExit -Guidance @"
  exit 11  consent was not given - re-run with the exact phrase the plan printed
  exit 12  the plan changed after it was frozen - re-scope rather than force it
  exit 13  this study is already sealed - scope a new one to re-test
  exit 17  the scenario configuration did not validate - fix what it reported
"@

if (-not $DryRun) {
    Write-Card -Title 'Approval prepared - fresh human input required' -Status 'warning' -Body @"
Study $studyId has not executed. The frozen blast radius and exact RBAC changes
were displayed by the run phase. A human must review them and type the printed
phrase in a new invocation; this orchestrator will not reuse consent supplied
before that preview.

  chaos-study-run -StudyId $studyId -DryRun:`$false -Consent '<human-typed phrase>'
"@
    exit (Get-ChaosStudyExitCode -Name 'ConsentDeclined')
}

if ($DryRun) {
    Write-Card -Title 'Dry run complete' -Status 'success' -Body @"
Study $studyId was previewed end to end. Nothing was executed, so there is no
evidence to interpret and no report to write.

When the preview matches your intent, prepare the exact RBAC preview:

  chaos-study-run -StudyId $studyId -PrepareApproval
"@
    exit 0
}

# ---------------------------------------------------------------------------
# Phase 3 - report
# ---------------------------------------------------------------------------

$reportArgs = @{ StudyId = $studyId }
if ($StudyRoot) { $reportArgs['StudyRoot'] = $StudyRoot }

$reportExit = Invoke-ChaosPhase -Name 'chaos-study-report' -Script $reportScript -Arguments $reportArgs
Stop-OnPhaseFailure -Name 'chaos-study-report' -ExitCode $reportExit -Guidance @"
The injection already happened and the evidence is on disk. Reporting is a pure
read of what was collected, so it is safe to retry:

  chaos-study-report -StudyId $studyId
"@

Write-ChaosStudyNote -Message "Next: compare this study with earlier runs - chaos-study-history -Action compare"
exit 0
