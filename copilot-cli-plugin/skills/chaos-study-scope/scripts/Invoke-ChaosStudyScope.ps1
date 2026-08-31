#Requires -Version 7.0
<#
.SYNOPSIS
    Turn a reliability question into a frozen, executable study plan.

.DESCRIPTION
    Scoping decides whether a study is worth running, and it does that before
    anything is injected. Four questions in order:

      1. What is the lifecycle root?
         A Chaos Studio workspace. Its scopes decide which resources exist as
         far as this study is concerned. Reused when it is already there,
         created only when you ask for it.

      2. What did the platform actually find in that scope?
         The workspace's discovered resources. An empty scope is a blocking
         failure, because a run against nothing succeeds and reads like proof
         of resilience.

      3. What can the platform actually do here?
         Scenarios and actions are read live from Chaos Studio for the scope's
         region. This suite ships no catalogue of faults and never falls back
         to one - if discovery fails, scoping stops.

      4. Would the result mean anything?
         A study with no numeric objective, no signal, or an action whose
         schema is unsatisfied produces a document, not evidence.

    Only when all four hold is a plan written, and the plan is hashed so the
    consent given later provably refers to it.

    Nothing here injects anything.

.EXAMPLE
    ./Invoke-ChaosStudyScope.ps1 -SubscriptionId <sub> -ResourceGroup rg `
        -WorkspaceName ws -ListScenarios

.EXAMPLE
    ./Invoke-ChaosStudyScope.ps1 -SubscriptionId <sub> -ResourceGroup rg `
        -WorkspaceName ws -Scenario 'zone-down' -Action 'shutdown' `
        -SteadyState 'successRate >= 99.5' -SignalSource 'metrics:Availability' `
        -FilterZone 1
#>

[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,

    # The resource group holding the Chaos Studio workspace.
    [Parameter(Mandatory)][string]$ResourceGroup,

    # The workspace under which this study runs. Workspaces are the lifecycle
    # root: scopes, discovered resources, scenarios and runs all hang off one.
    [Parameter(Mandatory)][string]$WorkspaceName,

    # Create the workspace when it does not exist. Without this, a missing
    # workspace is an error rather than an implicit provisioning action.
    [switch]$CreateWorkspace,

    # ARM resource ids the workspace should observe. Required with
    # -CreateWorkspace; ignored when the workspace already exists.
    [string[]]$Scope = @(),

    # Region for a workspace being created. Defaults to the region of the
    # first scoped resource id when it can be resolved.
    [string]$Location,

    # Use a user-assigned managed identity instead of a system-assigned one.
    [string]$UserAssignedIdentity,

    # Print the scenarios the workspace recommends, then exit without planning.
    [Parameter(ParameterSetName = 'ListScenarios')][switch]$ListScenarios,

    # Print the actions Chaos Studio reports for the scope's region, then exit.
    [Parameter(ParameterSetName = 'ListActions')][switch]$ListActions,

    # The scenario to configure and execute: its name or id, as returned by
    # -ListScenarios. Matched against the live list.
    [Parameter(ParameterSetName = 'Plan', Mandatory)][string]$Scenario,

    # The action this study is about: its name, canonical URN, or display name,
    # as returned by -ListActions. Matched against the live list. The scenario
    # is what executes; the action is what the study claims to have tested, and
    # the readiness gates are evaluated against it.
    [Parameter(ParameterSetName = 'Plan', Mandatory)][string]$Action,

    # The numeric objective this study tries to break, e.g. 'successRate >= 99.5'.
    [Parameter(ParameterSetName = 'Plan', Mandatory)][string]$SteadyState,

    [ValidateRange(1, 240)][int]$DurationMinutes = 10,
    [ValidateRange(1, 240)][int]$BaselineMinutes = 5,
    [ValidateRange(1, 240)][int]$RecoveryMinutes = 10,

    # Scenario parameters, keyed by the names in the scenario's live parameter
    # list. Frozen onto the plan as the {key,value} pairs the service takes.
    [hashtable]$Parameters,

    [string]$Hypothesis,

    # Signal sources: 'metrics:<name>' or 'logs:<workspaceId>#<kql>'.
    [string[]]$SignalSource = @(),

    # Blast radius. These become the scenario configuration's filters and
    # exclusions, which is the only mechanism V2 offers for bounding a run.
    [string[]]$FilterLocation = @(),
    [ValidateSet('1', '2', '3', 'zone-redundant')][string[]]$FilterZone = @(),
    [string]$FilterPhysicalZone,
    [string[]]$ExcludeResource = @(),
    [string[]]$ExcludeType = @(),
    [hashtable]$ExcludeTag,

    [string]$StudyRoot,
    [string]$StudyId,

    # Plan without probing Azure. The plan carries limitation L10 and is not
    # evidence that the study can run.
    [switch]$SkipDiscovery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'Study.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ActionDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Workspace.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Readiness.ps1')

$ChaosStudyPlanVersion = 'study-plan.v1'

# -- Steady state ----------------------------------------------------------

function ConvertFrom-ChaosSteadyState {
    <#
    .SYNOPSIS
        Parse 'signal <op> threshold[unit]' into a structured predicate.

    .DESCRIPTION
        The predicate has to be falsifiable, which in practice means it has to
        be a comparison against a number. Free text like "the service is
        healthy" is rejected here rather than at report time, because a study
        whose objective cannot be violated cannot teach anything.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -notmatch '^\s*([A-Za-z][A-Za-z0-9_.]*)\s*(>=|<=|>|<|==)\s*(-?[0-9]+(?:\.[0-9]+)?)\s*([A-Za-z%/]*)\s*$') {
        throw "Steady state '$Text' is not parseable. Use the form 'signal >= number[unit]', for example 'successRate >= 99.5' or 'p95Latency <= 400ms'."
    }
    return [pscustomobject]@{
        raw        = $Text.Trim()
        signal     = $Matches[1]
        comparison = $Matches[2]
        threshold  = [double]$Matches[3]
        unit       = if ($Matches[4]) { $Matches[4] } else { $null }
    }
}

function ConvertTo-ChaosScenarioParameter {
    <#
    .SYNOPSIS
        Turn a parameter hashtable into the {key,value} pairs the service takes.

    .DESCRIPTION
        Sorted by key so that two plans built from the same intent hash the
        same. Without that, the consent hash would drift on hashtable
        enumeration order alone.
    #>
    param([AllowNull()][object]$Table)

    if ($null -eq $Table) { return , @() }

    $names = @()
    if ($Table -is [System.Collections.IDictionary]) {
        $names = @($Table.Keys | ForEach-Object { [string]$_ })
    }
    else {
        $names = @($Table.PSObject.Properties | ForEach-Object { $_.Name })
    }

    $pairs = @()
    foreach ($name in ($names | Sort-Object)) {
        $value = if ($Table -is [System.Collections.IDictionary]) { $Table[$name] } else { $Table.$name }
        $pairs += [ordered]@{ key = $name; value = $value }
    }
    return , @($pairs)
}

# -- Workspace -------------------------------------------------------------
#
# The workspace is the lifecycle root. Everything after this point is scoped by
# it, so it is resolved first and its absence is fatal unless the operator
# explicitly asked for one to be created.

$workspaceId = Get-ChaosWorkspaceId -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName

$workspace = $null
$workspaceCreated = $false
$scopedResources = @()
$evaluation = $null
$region = $null

if ($SkipDiscovery) {
    Write-ChaosStudyNote -Message 'Discovery skipped. The plan will record what you asked for, not what the platform confirmed, and will carry limitation L10.'
}
else {
    if (-not (Test-ChaosCliAvailable)) {
        Assert-ChaosActionDiscovery -Reason 'The az CLI (or the shared Invoke-AzChaos helper) is unavailable, so the workspace could not be resolved.' `
            -Remediation 'Install the Azure CLI and sign in with az login, then re-run scoping.'
    }

    $resolved = Resolve-ChaosStudyWorkspace -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
        -WorkspaceName $WorkspaceName -Scopes $Scope -Location $Location `
        -UserAssignedIdentityId $UserAssignedIdentity -CreateWorkspace:$CreateWorkspace
    $workspace = $resolved.workspace
    $workspaceCreated = [bool]$resolved.created

    $scopedResources = ConvertTo-ChaosList (Get-ChaosStudyScopedResource -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName)
    $evaluation = Assert-ChaosWorkspaceEvaluation -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName

    $region = Get-ChaosScopeRegion -WorkspaceLocation $workspace.location -ScopedResources $scopedResources
    if (-not $region) {
        Assert-ChaosActionDiscovery -Reason 'The workspace scope spans more than one region, so there is no single region whose action inventory applies to it.' `
            -Remediation 'Narrow the workspace scopes to one region, or pass -FilterLocation to bound the run and re-scope against that region.'
    }
}

# -- Live discovery --------------------------------------------------------
#
# This block is the reason the suite has no bundled fault list. Everything the
# plan says about the action originates here, in a response the service
# produced moments ago.

$availableActions = @()
$scenarios = @()
$discoveryPerformedAt = $null

if (-not $SkipDiscovery) {
    try {
        $availableActions = ConvertTo-ChaosList (Get-ChaosAvailableAction -SubscriptionId $SubscriptionId -Region $region)
    }
    catch {
        Assert-ChaosActionDiscovery -Reason "The live action list for region '$region' could not be read: $($_.Exception.Message)" `
            -Remediation 'Confirm the subscription is registered for Microsoft.Chaos and that you can reach management.azure.com, then re-run scoping.'
    }

    if ($availableActions.Count -eq 0) {
        Assert-ChaosActionDiscovery -Reason "Chaos Studio reports no actions for region '$region'." `
            -Remediation 'Pick a region where Chaos Studio publishes actions, or move the scoped resources.'
    }

    $scenarios = ConvertTo-ChaosList (Get-ChaosStudyScenario -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName)
    $discoveryPerformedAt = Get-ChaosUtcNow
}

# -- Listing modes ---------------------------------------------------------

if ($ListScenarios) {
    if ($SkipDiscovery) {
        Write-ChaosStudyFailure -Title 'Nothing to list' `
            -Message '-ListScenarios reads the workspace recommendations from the service, so it cannot be combined with -SkipDiscovery.'
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }

    $lines = @("Scenarios recommended for workspace '$WorkspaceName'", '')
    if ($scenarios.Count -eq 0) {
        $lines += 'The workspace has no scenarios yet. Run az chaos workspace refresh-recommendation, wait for the evaluation to finish, then list again.'
    }
    else {
        foreach ($item in $scenarios) {
            $flag = if ($item.recommendationStatus -eq 'Recommended') { 'recommended' } else { [string]$item.recommendationStatus }
            $lines += "- $($item.name)  [$flag]"
            if ($item.description) { $lines += "    $($item.description)" }
            $required = @($item.parameters | Where-Object { $_.required } | ForEach-Object { $_.name })
            if ($required.Count -gt 0) { $lines += ("    required parameters: " + ($required -join ', ')) }
        }
    }
    $lines += ''
    $lines += "Read from the workspace at $discoveryPerformedAt. Discovered resources in scope: $(@($scopedResources).Count)."

    Write-ChaosStudyCard -Title 'Live scenario recommendations' -Body ($lines -join "`n")
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

if ($ListActions) {
    if ($SkipDiscovery) {
        Write-ChaosStudyFailure -Title 'Nothing to list' `
            -Message '-ListActions reads the live action inventory from the service, so it cannot be combined with -SkipDiscovery.'
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }

    $scopeTypes = @(@($scopedResources) | ForEach-Object { [string]$_.resourceType } | Where-Object { $_ } | Select-Object -Unique)
    $shown = $availableActions
    if ($scopeTypes.Count -gt 0) {
        $narrowed = @()
        foreach ($type in $scopeTypes) {
            $narrowed += ConvertTo-ChaosList (Select-ChaosActionForResourceType -Actions $availableActions -ResourceType $type)
        }
        $narrowed = @($narrowed | Sort-Object -Property name -Unique)
        if ($narrowed.Count -gt 0) { $shown = $narrowed }
    }

    $lines = @("Actions Chaos Studio reports for region '$region'", '')
    foreach ($item in $shown) {
        $lines += "- $($item.name)  [$($item.actionType)]"
        $lines += "    $([string]$item.canonicalId)"
        if ($item.description) { $lines += "    $($item.description)" }
    }
    $lines += ''
    $lines += "$($shown.Count) of $($availableActions.Count) action(s) shown, read live at $discoveryPerformedAt."
    $lines += "Scoped resource types: $(if ($scopeTypes.Count) { $scopeTypes -join ', ' } else { 'none discovered' })."

    Write-ChaosStudyCard -Title 'Live action inventory' -Body ($lines -join "`n")
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

# -- Resolve the scenario --------------------------------------------------

$selectedScenario = $null

if ($SkipDiscovery) {
    $selectedScenario = [pscustomobject]@{
        id                   = $null
        name                 = $Scenario
        displayName          = $Scenario
        description          = $null
        version              = $null
        recommendationStatus = $null
        parameters           = @()
        discovered           = $false
    }
}
else {
    $found = Find-ChaosStudyScenario -Scenarios $scenarios -Name $Scenario
    if (-not $found) {
        $names = @($scenarios | ForEach-Object { $_.name })
        Write-ChaosStudyFailure -Title 'Scenario not recommended for this workspace' `
            -Message "The workspace does not offer a scenario matching '$Scenario'. It offers: $(if ($names.Count) { $names -join ', ' } else { 'nothing yet' })." `
            -Remediation 'Run scoping with -ListScenarios, or refresh the workspace recommendations first.'
        exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
    }
    $selectedScenario = $found | Add-Member -NotePropertyName discovered -NotePropertyValue $true -PassThru
}

# -- Resolve the action ----------------------------------------------------

$selectedAction = $null

if ($SkipDiscovery) {
    $selectedAction = [pscustomobject]@{
        name             = $Action
        canonicalId      = $null
        displayName      = $Action
        description      = $null
        actionType       = $null
        version          = $null
        parametersSchema = $null
        recommendedRoles = @()
        appliesTo        = @()
        discovered       = $false
    }
}
else {
    $match = Find-ChaosAction -Actions $availableActions -Reference $Action
    if (-not $match) {
        Write-ChaosStudyFailure -Title 'Action not available in this region' `
            -Message "Chaos Studio reports $($availableActions.Count) action(s) for region '$region', none of which match '$Action'." `
            -Remediation 'Run scoping with -ListActions to see what the service reports here.'
        exit (Get-ChaosStudyExitCode -Name 'ActionDiscoveryUnavailable')
    }
    $selectedAction = $match | Add-Member -NotePropertyName discovered -NotePropertyValue $true -PassThru
}

# -- Objective and blast radius --------------------------------------------

$predicate = ConvertFrom-ChaosSteadyState -Text $SteadyState

$blastRadius = New-ChaosBlastRadius -Location $FilterLocation -Zone $FilterZone -PhysicalZone $FilterPhysicalZone `
    -ExcludeResource $ExcludeResource -ExcludeType $ExcludeType -ExcludeTags $ExcludeTag

$projected = ConvertTo-ChaosList (Resolve-ChaosBlastRadiusResource -ScopedResources $scopedResources -BlastRadius $blastRadius)

# -- Readiness -------------------------------------------------------------

$scopeTypesForGates = @(@($projected) | ForEach-Object { [string]$_.resourceType } | Where-Object { $_ } | Select-Object -Unique)

$readiness = Invoke-ChaosReadinessGates -Action $selectedAction `
    -ScopedResourceTypes $scopeTypesForGates `
    -ScopedResources $projected `
    -Parameters $Parameters `
    -SteadyState $predicate `
    -InjectMinutes $DurationMinutes `
    -AvailableSources $SignalSource `
    -DiscoverySkipped:$SkipDiscovery

$limitationCodes = @($readiness.limitationCodes)
if ($SkipDiscovery -and $limitationCodes -notcontains 'L10') { $limitationCodes += 'L10' }

foreach ($gate in $readiness.gates) {
    $marker = switch ($gate.status) { 'pass' { 'ok' } 'fail' { 'FAIL' } default { '??' } }
    Write-ChaosStudyNote -Message "[$marker] $($gate.title)$(if ($gate.status -ne 'pass') { " - $($gate.detail)" })"
}

Assert-ChaosReadiness -Readiness $readiness

# -- Freeze the plan -------------------------------------------------------
#
# Everything above this line is discovery. Everything below is a commitment.
# frozenConfigHash is computed last, over every field that precedes it, so the
# consent captured at run time provably refers to this exact configuration.

$effectiveScopes = if ($workspace) { @($workspace.scopes) } else { @($Scope) }

$scopeHash = Get-ChaosScopeHash -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -WorkspaceName $WorkspaceName -Scope $effectiveScopes -Region $region

$plan = [ordered]@{
    planVersion = $ChaosStudyPlanVersion
    createdAt   = Get-ChaosUtcNow
    scopeHash   = $scopeHash

    question    = [ordered]@{
        hypothesis  = if ($Hypothesis) { $Hypothesis } else { "The system holds $($predicate.raw) while '$($selectedAction.name)' is injected." }
        steadyState = $predicate
    }

    workspace   = [ordered]@{
        subscriptionId      = $SubscriptionId
        resourceGroup       = $ResourceGroup
        name                = $WorkspaceName
        id                  = $workspaceId
        location            = if ($workspace) { $workspace.location } else { $Location }
        provisioningState   = if ($workspace) { $workspace.provisioningState } else { $null }
        identityType        = if ($workspace) { $workspace.identityType } else { $null }
        identityPrincipalId = if ($workspace) { $workspace.principalId } else { $null }
        scopes              = @($effectiveScopes)
        createdByThisStudy  = $workspaceCreated
    }

    scope       = [ordered]@{
        region                 = $region
        # A skipped discovery means the counts are unknown, not zero. Recording 0
        # would let the consent card, the report and the readiness gates all claim
        # a verified-empty scope that nobody ever verified.
        discoveredResourceCount = $(if ($SkipDiscovery) { $null } else { @($scopedResources).Count })
        resourceTypes          = @(@($scopedResources) | ForEach-Object { [string]$_.resourceType } | Where-Object { $_ } | Select-Object -Unique)
        resources              = @($scopedResources)
        blastRadius            = [ordered]@{
            filters    = $blastRadius.filters
            exclusions = $blastRadius.exclusions
        }
        projectedResourceCount = $(if ($SkipDiscovery) { $null } else { @($projected).Count })
        projectedResources     = @(@($projected) | ForEach-Object {
                [ordered]@{
                    resourceId   = [string]$_.resourceId
                    resourceType = [string]$_.resourceType
                    location     = [string]$_.location
                    zones        = @($_.zones)
                }
            })
    }

    scenario    = [ordered]@{
        source               = if ($selectedScenario.discovered) { 'live-recommendation' } else { 'unverified-offline' }
        id                   = $selectedScenario.id
        name                 = $selectedScenario.name
        displayName          = $selectedScenario.displayName
        description          = $selectedScenario.description
        version              = $selectedScenario.version
        recommendationStatus = $selectedScenario.recommendationStatus
        parameterSpec        = @($selectedScenario.parameters)
        parameters           = ConvertTo-ChaosList (ConvertTo-ChaosScenarioParameter -Table $Parameters)
    }

    action      = [ordered]@{
        # Every field below came from the service's own action record.
        source           = if ($selectedAction.discovered) { 'live-discovery' } else { 'unverified-offline' }
        name             = $selectedAction.name
        canonicalId      = $selectedAction.canonicalId
        displayName      = $selectedAction.displayName
        description      = $selectedAction.description
        actionType       = $selectedAction.actionType
        version          = $selectedAction.version
        appliesTo        = @($selectedAction.appliesTo)
        recommendedRoles = @($selectedAction.recommendedRoles)
        parametersSchema = $selectedAction.parametersSchema
    }

    windows     = [ordered]@{
        baselineMinutes = $BaselineMinutes
        injectMinutes   = $DurationMinutes
        recoveryMinutes = $RecoveryMinutes
        interval        = 60
    }

    safety      = [ordered]@{
        reversible      = ($selectedAction.actionType -and $selectedAction.actionType -ine 'Discrete')
        requiresConsent = $true
        abortConditions = @(
            [ordered]@{
                id          = 'steady-state-breach'
                kind        = 'predicate'
                predicate   = $predicate
                description = "Cancel the scenario run if steady state '$($predicate.raw)' is breached during injection."
            }
            if (@($SignalSource).Count -gt 0) {
                [ordered]@{
                    id                   = 'signal-unavailable'
                    kind                 = 'missing-signal'
                    sources              = @($SignalSource)
                    intervalSeconds      = 60
                    unavailableIntervals = 2
                    description          = 'Cancel the scenario run if any configured signal remains unavailable for two evidence intervals.'
                }
            }
        )
    }

    signals     = [ordered]@{
        configuredSources = @($SignalSource)
    }

    readiness   = [ordered]@{
        gates           = @($readiness.gates)
        limitationCodes = @($limitationCodes)
    }

    discovery   = [ordered]@{
        region                  = $region
        endpoint                = if ($region) { "Microsoft.Chaos/locations/$region/actions" } else { $null }
        apiVersion              = Get-ChaosApiVersion -Name 'chaosActions'
        actionsFound            = $availableActions.Count
        scenariosFound          = @($scenarios).Count
        discoveredResourceCount = $(if ($SkipDiscovery) { $null } else { @($scopedResources).Count })
        workspaceEvaluation     = $evaluation
        performedAt             = $discoveryPerformedAt
    }
}

$safePlan = Protect-ChaosObject -InputObject $plan
$safePlan['frozenConfigHash'] = Get-ChaosDigest -InputObject $safePlan
$plan = $safePlan

# -- Persist ---------------------------------------------------------------

$study = New-ChaosStudy -ScopeHash $scopeHash -StudyRoot $StudyRoot -StudyId $StudyId
Save-ChaosStudyArtifact -StudyPath $study.path -RelativePath 'study-plan.v1.json' -Content $plan -SkipRedaction | Out-Null

Add-ChaosCommandTrailEntry -StudyPath $study.path -Command 'chaos-study-scope' `
    -Arguments ([ordered]@{
        workspace     = $WorkspaceName
        scenario      = $selectedScenario.name
        action        = $selectedAction.name
        region        = $region
        skipDiscovery = [bool]$SkipDiscovery
    }) `
    -ExitCode 0 -Note "Plan frozen at $($plan['frozenConfigHash'])" | Out-Null

# -- Report ----------------------------------------------------------------

$planPath = Resolve-ChaosStudyPath -StudyRoot $study.studyRoot -ScopeHash $scopeHash -StudyId $study.studyId -Artifact 'plan'
$actionTypeText = if ($selectedAction.actionType) { $selectedAction.actionType } else { 'unknown type' }
$regionText = if ([string]::IsNullOrWhiteSpace($region)) { 'region not resolved' } else { $region }
$urnText = if ([string]::IsNullOrWhiteSpace($selectedAction.canonicalId)) { 'not resolved (discovery skipped)' } else { $selectedAction.canonicalId }
$resourceText = if ($SkipDiscovery) { 'not resolved (discovery skipped)' } else { "$(@($projected).Count) of $(@($scopedResources).Count) discovered resource(s) after filters" }

$summary = @(
    "Study       $($study.studyId)"
    "Scope       $scopeHash"
    "Workspace   $WorkspaceName ($ResourceGroup) in $regionText"
    "Resources   $resourceText"
    "Scenario    $($selectedScenario.name)"
    "Action      $($selectedAction.displayName)  [$actionTypeText]"
    "URN         $urnText"
    "Objective   $($predicate.raw)"
    "Windows     $BaselineMinutes m baseline, $DurationMinutes m inject, $RecoveryMinutes m recovery"
    "Frozen at   $($plan['frozenConfigHash'])"
    "Plan        $planPath"
) -join "`n"

Write-ChaosStudyCard -Title 'Study planned - nothing has been injected' -Body $summary

$advisories = @($readiness.gates | Where-Object { $_.status -ne 'pass' })
if ($advisories.Count -gt 0) {
    Write-Output ''
    Write-Output '### Caveats carried into this study'
    foreach ($advisory in $advisories) {
        Write-Output "- **$($advisory.title)** ($($advisory.status)): $($advisory.detail)"
    }
}

if ($limitationCodes.Count -gt 0) {
    Write-ChaosStudyNote -Message ('The report will carry limitations: ' + ($limitationCodes -join ', ') + '.')
}

Write-Output ''
Write-Output 'Next: review the plan, then run it with explicit consent.'
Write-Output "  chaos-study-run  -StudyId $($study.studyId) -DryRun:`$false -Consent '<typed consent>'"

exit (Get-ChaosStudyExitCode -Name 'Success')
