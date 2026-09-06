param(
    [Parameter(Mandatory)][string]$Skills,
    [Parameter(Mandatory)][string]$StudyRoot,
    [int]$BaselineMinutes = 5,
    [Nullable[int]]$UnavailableIntervals,
    [switch]$NoBuckets,
    [string]$ExecutionPlanPath,
    [ValidateSet('success', 'absent', 'present')][string]$DeleteResult = 'success',
    [string]$ScenarioName = 'fixture',
    [string]$AcceptPartialScenario
)
$ErrorActionPreference = 'Stop'
if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must not be reachable in this fixture.' }
$global:FixtureTarget = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
$global:FixtureWorkspace = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Chaos/workspaces/ws'
$global:MetricQueries = 0
New-Item -ItemType Directory $StudyRoot -Force | Out-Null
function global:Start-Sleep {
    param([double]$Seconds)
    $Seconds | Add-Content "$StudyRoot/sleeps"
}
function global:az {
    $command = $args -join ' '
    $command | Add-Content "$StudyRoot/az-calls"
    $global:LASTEXITCODE = 0
    if ($command -like 'extension list *') { return 'chaos' }
    if ($command -like 'extension update *') { return }
    if ($command -like 'chaos workspace show *') {
        return (@{ id = $global:FixtureWorkspace; name = 'ws'; location = 'westus2'
            properties = @{ provisioningState = 'Succeeded'; scopes = @('/subscriptions/sub/resourceGroups/rg') }
            identity = @{ type = 'SystemAssigned'; principalId = 'principal' } } | ConvertTo-Json -Depth 10)
    }
    if ($command -like 'chaos discovered-resource list *') {
        return (@{ value = @(@{ name = 'vm'; fullyQualifiedIdentifier = $global:FixtureTarget; resourceType = 'microsoft.compute/virtualmachines'; location = 'westus2' }) } | ConvertTo-Json -Depth 10)
    }
    if ($command -like 'chaos workspace show-evaluation *') {
        return '{"properties":{"status":"Succeeded","numScenariosEvaluatedSucceeded":1,"numScenariosEvaluatedFailed":0}}'
    }
    if ($command -like 'chaos scenario list *') {
        return (@{ value = @(@{ id = "$global:FixtureWorkspace/scenarios/$ScenarioName"; name = $ScenarioName
            properties = @{ displayName = 'Fixture'; version = '1.0'; description = 'offline'
                recommendation = @{ recommendationStatus = 'Recommended' }; parameters = @() } }) } | ConvertTo-Json -Depth 10)
    }
    if ($command -like 'rest *' -and $command -like '*/locations/westus2/actions*') {
        return (@{ value = @(@{ name = 'fixture-action'; properties = @{
            actionName = 'fixture-action'; canonicalId = 'urn:fixture:action'; actionType = 'Continuous'
            displayName = 'Fixture'; description = 'offline'; version = '1.0'
            supportedTargetTypes = @(@{ targetType = 'Microsoft.Compute/virtualMachines'; requiredPermissions = @() })
            parametersSchema = @{ type = 'object'; required = @(); properties = @{} }; recommendedRoles = @()
        } }) } | ConvertTo-Json -Depth 12)
    }
    if ($command -like 'rest *' -and $command -like '*/Microsoft.Insights/metrics*') {
        $global:MetricQueries++
        $at = [datetime]::Parse([regex]::Match($command, 'timespan=([^/]+)/([^&]+)').Groups[2].Value).ToUniversalTime()
        $age = if ($global:MetricQueries -eq 1) { 63 } else { 67 }
        $points = @(if (-not $NoBuckets) { @{ timeStamp = $at.AddSeconds(-$age).ToString('o'); average = 1 } })
        return (@{ value = @(@{ timeseries = @(@{ data = $points }) }) } | ConvertTo-Json -Depth 10)
    }
    if ($command -like 'chaos scenario config create *') {
        $i = [array]::IndexOf($args, '-n')
        $global:FixtureConfigurationName = $args[$i + 1]
        return (@{ name = $args[$i + 1] } | ConvertTo-Json)
    }
    if ($command -like 'chaos scenario config validate *') {
        if ($ExecutionPlanPath) {
            return (@{ status = 'Succeeded'; executionPlanJson = [IO.File]::ReadAllText($ExecutionPlanPath) } | ConvertTo-Json -Depth 10)
        }
        return '{"status":"Succeeded","legs":[{"legSelector":"vm","action":"fixture-action","executable":true}]}'
    }
    if ($command -like 'chaos scenario config delete *') {
        if ($DeleteResult -ne 'success') { $global:LASTEXITCODE = 1; return 'BadRequest: Nullable object must have a value.' }
        return
    }
    if ($command -like 'chaos scenario config list *') {
        if ($DeleteResult -eq 'absent') { return '[]' }
        return (@{ value = @(@{ name = $global:FixtureConfigurationName }) } | ConvertTo-Json -Depth 10)
    }
    throw "Unexpected offline fixture operation: $command"
}
$scopeArgs = @{
    SubscriptionId = 'sub'; ResourceGroup = 'rg'; WorkspaceName = 'ws'; StudyRoot = $StudyRoot
    Scenario = $ScenarioName; Action = 'fixture-action'; SteadyState = 'Availability >= 1'
    SignalSource = @('metrics:Availability'); FailureMechanism = 'CPU pressure changes availability'
    MechanismEvidence = 'Offline fixture VM'; MechanismProbe = @{ signal = 'Availability'; expectedDirection = 'down'; resourceCorrelation = $global:FixtureTarget }
    EventRatePerSecond = 1; EligibleFraction = 1; BaselineMinutes = $BaselineMinutes
}
if ($null -ne $UnavailableIntervals) { $scopeArgs.UnavailableIntervals = $UnavailableIntervals }
if ($AcceptPartialScenario) { $scopeArgs.AcceptPartialScenario = $AcceptPartialScenario }
& "$Skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1" @scopeArgs
exit $LASTEXITCODE
