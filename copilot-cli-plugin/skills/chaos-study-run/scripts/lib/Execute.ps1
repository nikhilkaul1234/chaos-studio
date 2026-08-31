#Requires -Version 7.0
<#
.SYNOPSIS
    Consent, plan integrity, and the Chaos Studio V2 scenario lifecycle.

.DESCRIPTION
    Four ideas govern this file.

    Nothing runs without consent. Consent is a phrase the operator types, and
    the phrase names the action, the workspace it lands in and a hash of the
    plan. It cannot be given by accident, it cannot be given in advance, and it
    cannot be inherited from an environment variable - this suite deliberately
    ignores STARTCHAOS_NONINTERACTIVE, because "unattended" is not a reason to
    skip the one gate that bounds production risk.

    Consent applies to a specific plan. If the plan changed after it was shown,
    the hash no longer matches and execution stops. The thing consented to is
    provably the thing that runs.

    Nothing executes on an unvalidated configuration. Chaos Studio validates a
    scenario configuration against the live scope and the workspace identity's
    permissions. A configuration that is not `Succeeded` will start a run that
    fails within seconds with an opaque error, so this file refuses to execute
    until validation succeeds - after offering the permission fix the service
    itself recommends.

    Injection is bounded and abortable. The configuration carries the filters
    and exclusions frozen at scope time, and cancellation runs in a finally
    block so an interrupted study still cancels the run it started.

    Everything here goes through the `az chaos` seam (Invoke-AzChaos), which is
    the Chaos Studio V2 surface: workspaces, scopes, scenarios, scenario
    configurations and scenario runs.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')

# -- Plan integrity --------------------------------------------------------

function Get-ChaosPlanFingerprint {
    <#
    .SYNOPSIS
        Recompute the plan hash over everything except the hash itself.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $copy = [ordered]@{}
    $names = if ($Plan -is [System.Collections.IDictionary]) { @($Plan.Keys) } else { @($Plan.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($name in $names) {
        if ($name -eq 'frozenConfigHash') { continue }
        $copy["$name"] = if ($Plan -is [System.Collections.IDictionary]) { $Plan[$name] } else { $Plan.$name }
    }
    return Get-ChaosDigest -InputObject $copy
}

function Assert-ChaosPlanIntegrity {
    <#
    .SYNOPSIS
        Refuse to run a plan that was edited after it was frozen.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $declared = $Plan.frozenConfigHash
    $actual = Get-ChaosPlanFingerprint -Plan $Plan
    if ($declared -eq $actual) { return $true }

    Write-ChaosStudyFailure -Title 'The plan changed after it was frozen' -Message @"
This plan declares frozenConfigHash $declared but its current contents hash to $actual.

Consent is bound to a specific plan. Because the contents no longer match, any
consent given for this study refers to something other than what would run, so
execution stops here.
"@ -Remediation 'Re-run chaos-study-scope to produce a fresh, self-consistent plan.'
    exit (Get-ChaosStudyExitCode -Name 'ConfigurationDrift')
}

function Test-ChaosPlanLiveDiscovery {
    <#
    .SYNOPSIS
        True only when the plan has a complete, live-discovered execution scope.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    return (
        [string]$Plan.scenario.source -eq 'live-recommendation' -and
        [string]$Plan.action.source -eq 'live-discovery' -and
        -not [string]::IsNullOrWhiteSpace([string]$Plan.discovery.performedAt) -and
        $null -ne $Plan.scope.projectedResourceCount
    )
}

function Test-ChaosPlanWindows {
    param([Parameter(Mandatory)][object]$Plan)

    return (
        [int]$Plan.windows.baselineMinutes -ge 1 -and
        [int]$Plan.windows.injectMinutes -ge 1 -and
        [int]$Plan.windows.recoveryMinutes -ge 1
    )
}

function Test-ChaosApprovalPreviewReady {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [AllowNull()][object]$Preview
    )

    if ($null -eq $Preview) { return $false }
    return (
        [string]$Preview.planHash -ceq [string]$Plan.frozenConfigHash -and
        $Preview.approvalReady -eq $true -and
        [string]::IsNullOrWhiteSpace([string]$Preview.consumedAt)
    )
}

# -- Consent ---------------------------------------------------------------

function Get-ChaosConsentPhrase {
    <#
    .SYNOPSIS
        The exact phrase the operator must type to authorise injection.

    .DESCRIPTION
        The phrase names the action and the workspace it lands in so it cannot
        be typed without reading it, and carries the plan hash so it cannot be
        reused for a different plan.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $shortHash = ([string]$Plan.frozenConfigHash).Substring(0, 8)
    return "inject $($Plan.action.name) into $($Plan.workspace.name) $shortHash"
}

function Assert-ChaosConsent {
    <#
    .SYNOPSIS
        Stop unless the operator supplied the exact consent phrase.

    .DESCRIPTION
        Deliberately ignores STARTCHAOS_NONINTERACTIVE. Every other gate in
        this suite can be relaxed for automation; this one cannot, because it
        is the only thing standing between a script and a production incident.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [AllowNull()][AllowEmptyString()][string]$Consent
    )

    $expected = Get-ChaosConsentPhrase -Plan $Plan
    if ($Consent -and $Consent.Trim() -ceq $expected) { return $true }

    $reason = if ([string]::IsNullOrWhiteSpace($Consent)) {
        'No consent phrase was supplied.'
    } else {
        'The consent phrase did not match this plan exactly (comparison is case-sensitive).'
    }

    $count = $Plan.scope.projectedResourceCount
    $countText = if ($null -eq $count) { 'an unknown number of' } else { "$count" }
    $regionText = if ([string]::IsNullOrWhiteSpace($Plan.scope.region)) { '(not resolved)' } else { [string]$Plan.scope.region }

    Write-ChaosStudyFailure -Title 'Injection not authorised' -Message @"
$reason

This study would run scenario $($Plan.scenario.name) - action $($Plan.action.displayName) -
  workspace   $($Plan.workspace.name) ($($Plan.workspace.resourceGroup))
  region      $regionText
  reaching    $countText scoped resource(s) after filters and exclusions
for $($Plan.windows.injectMinutes) minutes.

To authorise it, pass this phrase exactly:

  $expected
"@ -Remediation "-DryRun:`$false -Consent '$expected'"
    exit (Get-ChaosStudyExitCode -Name 'ConsentDeclined')
}

# -- Scenario configuration ------------------------------------------------

function Get-ChaosStudyConfigurationName {
    <#
    .SYNOPSIS
        Deterministic configuration name derived from the study id.

    .DESCRIPTION
        Deriving it means an interrupted study can find and cancel the
        configuration it created, rather than leaking a resource whose name it
        no longer knows.
    #>
    param([Parameter(Mandatory)][string]$StudyId)
    $suffix = ($StudyId -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if ($suffix.Length -gt 40) { $suffix = $suffix.Substring($suffix.Length - 40) }
    return "study-$suffix"
}

function Get-ChaosScenarioParameterList {
    <#
    .SYNOPSIS
        The scenario parameters frozen at scope time, in the {key,value} shape
        `az chaos scenario config create --parameters` expects.

    .DESCRIPTION
        Scope already normalised and sorted these, so this only re-projects
        them after the JSON round-trip through the store. Values are carried as
        strings because that is what the configuration API accepts; anything
        structured is canonically JSON-encoded so the same input always
        produces the same configuration.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $frozen = $null
    if ($Plan.scenario.PSObject.Properties.Name -contains 'parameters') { $frozen = $Plan.scenario.parameters }
    if ($null -eq $frozen) { return @() }

    $pairs = @()
    foreach ($entry in @($frozen)) {
        if ($null -eq $entry) { continue }
        $key = [string]$entry.key
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $value = $entry.value
        $encoded = if ($value -is [string]) {
            $value
        } elseif ($value -is [bool]) {
            $value.ToString().ToLowerInvariant()
        } elseif ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
            ConvertTo-ChaosCanonicalJson -InputObject $value
        } else {
            [string]$value
        }
        $pairs += @{ key = $key; value = $encoded }
    }
    return $pairs
}

function Get-ChaosEffectiveScenarioParameterPreview {
    <#
    .SYNOPSIS
        Merge frozen explicit values over service-reported scenario defaults.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $explicit = [ordered]@{}
    foreach ($entry in @($Plan.scenario.parameters)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.key)) { continue }
        $explicit[[string]$entry.key] = $entry.value
    }

    $result = @()
    foreach ($spec in @($Plan.scenario.parameterSpec)) {
        if ($null -eq $spec -or [string]::IsNullOrWhiteSpace([string]$spec.name)) { continue }
        $name = [string]$spec.name
        if ($explicit.Contains($name)) {
            $result += [ordered]@{ key = $name; value = $explicit[$name]; source = 'explicit' }
            $explicit.Remove($name)
        } elseif ($spec.PSObject.Properties.Name -contains 'default' -and $null -ne $spec.default) {
            $result += [ordered]@{ key = $name; value = $spec.default; source = 'service-default' }
        }
    }
    foreach ($name in @($explicit.Keys | Sort-Object)) {
        $result += [ordered]@{ key = $name; value = $explicit[$name]; source = 'explicit' }
    }
    return @($result)
}

function Get-ChaosActionParameterPreview {
    <#
    .SYNOPSIS
        Render action parameter values without inventing omitted optional values.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $schema = $Plan.action.parametersSchema
    $values = [ordered]@{}
    $sources = [ordered]@{}
    $required = @()
    $properties = $null
    if ($null -ne $schema) {
        if ($schema.PSObject.Properties.Name -contains 'required') {
            $required = @($schema.required | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        }
        if ($schema.PSObject.Properties.Name -contains 'properties') { $properties = $schema.properties }
    }

    $explicit = [ordered]@{}
    foreach ($entry in @($Plan.scenario.parameters)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.key)) { continue }
        $explicit[[string]$entry.key] = $entry.value
    }

    if ($null -ne $properties) {
        foreach ($property in @($properties.PSObject.Properties | Sort-Object -Property Name)) {
            if ($explicit.Contains($property.Name)) {
                $values[$property.Name] = $explicit[$property.Name]
                $sources[$property.Name] = 'explicit'
            } elseif ($property.Value.PSObject.Properties.Name -contains 'default' -and $null -ne $property.Value.default) {
                $values[$property.Name] = $property.Value.default
                $sources[$property.Name] = 'service-default'
            }
        }
    }

    $semantic = if ($values.Count -gt 0) {
        'Effective action parameters are listed in values.'
    } elseif ($required.Count -eq 0) {
        'none required or supplied'
    } else {
        'required parameters are absent'
    }
    return [ordered]@{
        semantic = $semantic
        values    = $values
        sources   = $sources
        required  = @($required)
    }
}

function Get-ChaosActionEffectPreview {
    <#
    .SYNOPSIS
        Describe side effects strictly from live action identity and permissions.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $identity = "$($Plan.action.canonicalId) $($Plan.action.name) $($Plan.action.displayName)"
    $permissions = @($Plan.action.appliesTo | ForEach-Object { $_.requiredPermissions } | Where-Object { $_ })
    $isComputeShutdown = (
        $identity -match '(?i)(compute.*shutdown|shutdown.*compute)' -or
        @($permissions | Where-Object { $_ -match '(?i)Microsoft\.Compute/.*/powerOff/action' }).Count -gt 0
    )
    $sideEffect = if ($isComputeShutdown) {
        'Expected side effect: power off or shut down each exact Compute target listed below.'
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Plan.action.description)) {
        "Expected side effect from live action metadata: $($Plan.action.description)"
    } else {
        "Expected side effect: execute live-discovered action '$($Plan.action.displayName)' against only the exact targets listed below."
    }

    $recovery = if ([string]$Plan.action.actionType -ieq 'Cancelable') {
        'Cancelable action: scenario-run cancellation is expected to stop or revert the active fault. Cancellation is not proof of restoration; post-recovery evidence must prove every target returned to its steady state.'
    } elseif ([string]$Plan.action.actionType -ieq 'Continuous') {
        'Continuous action: stopping the scenario run is expected to end the active fault. Post-recovery evidence must prove restoration rather than assume it.'
    } else {
        'This action is not reported as cancelable. Its service-defined completion behavior applies, and post-recovery evidence must prove restoration rather than assume it.'
    }

    return [ordered]@{
        actionType = [string]$Plan.action.actionType
        sideEffect = $sideEffect
        recovery   = $recovery
    }
}

function New-ChaosStudyDryRunPreview {
    <#
    .SYNOPSIS
        Build the complete non-mutating run preview from one frozen plan.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$StudyId,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [Parameter(Mandatory)][object[]]$SignalPreview,
        [Parameter(Mandatory)][bool]$LiveDiscoveryVerified
    )

    $blast = Get-ChaosBlastRadiusArgument -Plan $Plan
    $scenarioParameters = @(Get-ChaosEffectiveScenarioParameterPreview -Plan $Plan)
    $actionParameters = Get-ChaosActionParameterPreview -Plan $Plan
    $effect = Get-ChaosActionEffectPreview -Plan $Plan
    $targets = @($Plan.scope.projectedResources)
    $abortDescriptions = @($Plan.safety.abortConditions | ForEach-Object {
            Get-ChaosAbortConditionDescription -Condition $_
        })
    $nextStep = if ($LiveDiscoveryVerified) {
        "chaos-study-run -StudyId $StudyId -PrepareApproval"
    } else {
        'Re-scope without -SkipDiscovery to create a fresh live-discovered plan.'
    }

    return [ordered]@{
        studyId            = $StudyId
        frozenPlanHash      = [string]$Plan.frozenConfigHash
        hypothesis          = [string]$Plan.question.hypothesis
        workspace           = [ordered]@{
            subscriptionId = [string]$Plan.workspace.subscriptionId
            resourceGroup  = [string]$Plan.workspace.resourceGroup
            name           = [string]$Plan.workspace.name
            region         = [string]$Plan.scope.region
        }
        scenario            = [ordered]@{
            name                = [string]$Plan.scenario.name
            effectiveParameters = $scenarioParameters
        }
        action              = [ordered]@{
            name                = [string]$Plan.action.displayName
            canonicalId         = [string]$Plan.action.canonicalId
            actionType          = [string]$Plan.action.actionType
            effectiveParameters = $actionParameters
            expectedSideEffect  = $effect.sideEffect
            restoration         = $effect.recovery
        }
        targets             = $targets
        blastRadius         = [ordered]@{ filters = $blast.filters; exclusions = $blast.exclusions }
        windows             = [ordered]@{
            baselineMinutes = $Plan.windows.baselineMinutes
            injectMinutes   = $Plan.windows.injectMinutes
            recoveryMinutes = $Plan.windows.recoveryMinutes
        }
        telemetry           = @($Plan.signals.configuredSources)
        abortConditions     = $abortDescriptions
        configuration       = [ordered]@{
            name      = $ConfigurationName
            lifecycle = 'Dry-run creates no configuration. PrepareApproval and armed execution create a temporary configuration only when invoked. Cleanup always requests deletion; any cleanup failure is retained in evidence/cleanup/*.json.'
        }
        consent             = 'Armed execution requires a fresh human-typed phrase bound to this frozen plan hash after PrepareApproval displays the exact RBAC changes.'
        signalPreview       = @($SignalPreview)
        nextStep            = $nextStep
    }
}

function Write-ChaosStudyDryRunPreview {
    <#
    .SYNOPSIS
        Render the complete dry-run preview and its structured JSON contract.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$StudyId,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [Parameter(Mandatory)][object[]]$SignalPreview,
        [Parameter(Mandatory)][bool]$LiveDiscoveryVerified
    )

    $preview = New-ChaosStudyDryRunPreview -Plan $Plan -StudyId $StudyId `
        -ConfigurationName $ConfigurationName -SignalPreview $SignalPreview `
        -LiveDiscoveryVerified $LiveDiscoveryVerified
    $scenarioText = if (@($preview.scenario.effectiveParameters).Count -gt 0) {
        ConvertTo-ChaosCanonicalJson -InputObject $preview.scenario.effectiveParameters
    } else {
        'none'
    }
    $actionText = if ($preview.action.effectiveParameters.values.Count -gt 0) {
        ConvertTo-ChaosCanonicalJson -InputObject $preview.action.effectiveParameters.values
    } else {
        '{} (none required or supplied)'
    }

    Write-Card -Title "Dry run - study $StudyId" -Status 'info' -Body @"
Nothing has been injected. Dry-run is non-mutating.

$($preview.hypothesis)

$($preview.action.expectedSideEffect)
$($preview.action.restoration)

Temporary configuration lifecycle: $($preview.configuration.lifecycle)
"@ -Properties ([ordered]@{
        'Frozen plan hash'    = $preview.frozenPlanHash
        'Workspace'           = "$($preview.workspace.name) ($($preview.workspace.resourceGroup))"
        'Region'              = $preview.workspace.region
        'Exact targets'       = @($preview.targets).Count
        'Scenario'            = $preview.scenario.name
        'Scenario parameters' = $scenarioText
        'Action'              = $preview.action.name
        'Action URN'          = $preview.action.canonicalId
        'Action parameters'   = $actionText
        'Injection'           = "$($preview.windows.injectMinutes) minutes"
        'Baseline'            = "$($preview.windows.baselineMinutes) minutes before injection"
        'Recovery'            = "$($preview.windows.recoveryMinutes) minutes after injection"
        'Configuration'       = $ConfigurationName
    })

    Write-Card -Title 'Exact frozen targets' -Status 'warning' -Body (
        ConvertTo-ChaosCanonicalJson -InputObject $preview.targets
    )
    Write-Table -Title 'Evidence that would be collected' -Data @(
        foreach ($signal in $SignalPreview) {
            [pscustomobject]@{
                Source = $signal.source
                Status = if ($signal.caveat) { $signal.caveat } else { 'would be collected' }
            }
        }
    )
    if (@($preview.abortConditions).Count -gt 0) {
        Write-Card -Title 'Abort if any of these happen' -Status 'warning' -Body (
            @($preview.abortConditions | ForEach-Object { "  - $_" }) -join "`n"
        )
    }
    Write-Card -Title 'Before an armed run' -Status 'info' -Body @"
$($preview.consent)

Next:
  $($preview.nextStep)
"@ -JsonPreview (ConvertTo-Json -InputObject $preview -Depth 32)

}

function Get-ChaosBlastRadiusArgument {
    <#
    .SYNOPSIS
        Project the plan's frozen blast radius into --filters / --exclusions
        objects, omitting anything empty.

    .DESCRIPTION
        Empty is not the same as absent here. `--filters '{"locations":[]}'`
        means "no locations", which matches nothing; omitting locations means
        "every location in scope". Sending an empty collection would silently
        turn a real study into a no-op that still reports success, so empty
        members are dropped rather than serialised.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $result = [ordered]@{ filters = $null; exclusions = $null }
    $blast = $null
    if ($Plan.scope.PSObject.Properties.Name -contains 'blastRadius') { $blast = $Plan.scope.blastRadius }
    if ($null -eq $blast) { return [pscustomobject]$result }

    foreach ($side in @('filters', 'exclusions')) {
        if ($blast.PSObject.Properties.Name -notcontains $side) { continue }
        $source = $blast.$side
        if ($null -eq $source) { continue }

        $projected = [ordered]@{}
        foreach ($property in @($source.PSObject.Properties)) {
            $value = $property.Value
            if ($null -eq $value) { continue }
            if ($value -is [string]) {
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
            } elseif ($value -is [System.Collections.IDictionary]) {
                if ($value.Count -eq 0) { continue }
            } elseif ($value -is [System.Collections.IEnumerable]) {
                if (@($value).Count -eq 0) { continue }
            }
            $projected[$property.Name] = $value
        }
        if ($projected.Count -gt 0) { $result[$side] = [pscustomobject]$projected }
    }

    return [pscustomobject]$result
}

function New-ChaosStudyConfiguration {
    <#
    .SYNOPSIS
        Create the scenario configuration this study will execute.

    .DESCRIPTION
        The configuration is the frozen plan expressed as a Chaos Studio
        resource: which scenario, with which parameters, constrained by which
        filters and exclusions. Creating it changes nothing in the target
        system - execution is a separate, separately-consented step.

        Structured arguments go through Invoke-AzChaos -JsonArg, which writes
        them to a temp file. On Windows `az` is a .cmd shim that mangles
        unquoted JSON braces, so passing them inline is not reliable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName
    )

    $chaosArgs = @(
        'scenario', 'config', 'create',
        '-n', $ConfigurationName,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name
    )

    $jsonArg = @{}

    $parameters = @(Get-ChaosScenarioParameterList -Plan $Plan)
    if ($parameters.Count -gt 0) { $jsonArg['parameters'] = $parameters }

    $blast = Get-ChaosBlastRadiusArgument -Plan $Plan
    if ($null -ne $blast.filters) { $jsonArg['filters'] = $blast.filters }
    if ($null -ne $blast.exclusions) { $jsonArg['exclusions'] = $blast.exclusions }

    $created = if ($jsonArg.Count -gt 0) {
        Invoke-AzChaos -ChaosArgs $chaosArgs -JsonArg $jsonArg
    } else {
        Invoke-AzChaos -ChaosArgs $chaosArgs
    }

    if ($null -eq $created) {
        throw "Chaos Studio did not return a scenario configuration for '$ConfigurationName'. The configuration was not created, so nothing was executed."
    }
    return $created
}

function Remove-ChaosStudyConfiguration {
    <#
    .SYNOPSIS
        Delete a scenario configuration and return durable cleanup evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName
    )

    $requestedAt = Get-ChaosUtcNow
    Invoke-AzChaos -ChaosArgs @(
        'scenario', 'config', 'delete',
        '-n', $ConfigurationName,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name,
        '--yes'
    ) | Out-Null
    return [ordered]@{
        configurationName = $ConfigurationName
        requestedAt       = $requestedAt
        deletionRequested = $true
        failure           = $null
    }
}

# -- Validation and permissions --------------------------------------------

function Get-ChaosConfigurationValidation {
    <#
    .SYNOPSIS
        Run validation and return the latest validation result.

    .DESCRIPTION
        `validate` is long-running and its own response is sometimes thinner
        than the stored result, so the stored result is read back and preferred.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName
    )

    $scoping = @(
        '-n', $ConfigurationName,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name
    )

    Invoke-AzChaos -AllowFailure -ChaosArgs (@('scenario', 'config', 'validate') + $scoping) | Out-Null
    return Invoke-AzChaos -AllowFailure -ChaosArgs (@('scenario', 'config', 'show-validation') + $scoping)
}

function Get-ChaosValidationStatus {
    <#
    .SYNOPSIS
        Read the status out of a validation result, whatever shape it arrives in.
    #>
    param([AllowNull()][object]$Validation)

    if ($null -eq $Validation) { return $null }
    if ($Validation.PSObject.Properties.Name -contains 'properties' -and $null -ne $Validation.properties) {
        if ($Validation.properties.PSObject.Properties.Name -contains 'status') { return [string]$Validation.properties.status }
    }
    if ($Validation.PSObject.Properties.Name -contains 'status') { return [string]$Validation.status }
    return $null
}

function Get-ChaosValidationError {
    <#
    .SYNOPSIS
        Project validation errors into a flat, reportable list.
    #>
    param([AllowNull()][object]$Validation)

    if ($null -eq $Validation) { return @() }
    $container = if ($Validation.PSObject.Properties.Name -contains 'properties' -and $null -ne $Validation.properties) { $Validation.properties } else { $Validation }

    $errors = @()
    foreach ($field in @('validationErrors', 'errors')) {
        if ($container.PSObject.Properties.Name -notcontains $field) { continue }
        foreach ($item in @($container.$field)) {
            if ($null -eq $item) { continue }
            $errors += [ordered]@{
                code     = if ($item.PSObject.Properties.Name -contains 'errorCode') { [string]$item.errorCode } else { $null }
                message  = if ($item.PSObject.Properties.Name -contains 'errorMessage') { [string]$item.errorMessage } else { [string]$item }
                resource = if ($item.PSObject.Properties.Name -contains 'resourceId') { [string]$item.resourceId } else { $null }
            }
        }
    }
    return $errors
}

function Repair-ChaosConfigurationPermission {
    <#
    .SYNOPSIS
        Ask Chaos Studio to grant the workspace identity the roles it says the
        run needs, then report what it did.

    .DESCRIPTION
        The service decides the grants; this only requests and reports them.
        With -WhatIf nothing is created, which is how the caller learns what
        would change before any of it does.

        The result is read back with show-permission-fix because the command
        does not always echo a body of its own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [switch]$WhatIf
    )

    $scoping = @(
        '-n', $ConfigurationName,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name
    )

    $chaosArgs = @('scenario', 'config', 'fix-permissions') + $scoping
    if ($WhatIf) { $chaosArgs += '--what-if' }

    Invoke-AzChaos -AllowFailure -ChaosArgs $chaosArgs | Out-Null
    return Invoke-AzChaos -AllowFailure -ChaosArgs (@('scenario', 'config', 'show-permission-fix') + $scoping)
}

function Get-ChaosPermissionFixSummary {
    <#
    .SYNOPSIS
        Project a permission-fix result into a flat, reportable shape.

    .DESCRIPTION
        Counts the service did not report stay null. A fix that reported
        nothing is not the same as a fix that granted nothing, and writing zero
        would put a number in the study record that nobody measured.
    #>
    param([AllowNull()][object]$FixResult)

    if ($null -eq $FixResult) { return $null }

    $container = $FixResult
    if ($FixResult.PSObject.Properties.Name -contains 'properties' -and $null -ne $FixResult.properties) {
        $container = $FixResult.properties
    }

    $summary = $null
    if ($container.PSObject.Properties.Name -contains 'summary') { $summary = $container.summary }
    $hasSummary = ($null -ne $summary)

    return [ordered]@{
        state         = if ($container.PSObject.Properties.Name -contains 'state') { $container.state } else { $null }
        whatIfMode    = if ($container.PSObject.Properties.Name -contains 'whatIfMode') { $container.whatIfMode } else { $null }
        totalRequired = if ($hasSummary -and $summary.PSObject.Properties.Name -contains 'totalRequired') { $summary.totalRequired } else { $null }
        succeeded     = if ($hasSummary -and $summary.PSObject.Properties.Name -contains 'succeeded') { $summary.succeeded } else { $null }
        failed        = if ($hasSummary -and $summary.PSObject.Properties.Name -contains 'failed') { $summary.failed } else { $null }
        skipped       = if ($hasSummary -and $summary.PSObject.Properties.Name -contains 'skipped') { $summary.skipped } else { $null }
    }
}

function Test-ChaosPermissionFixApplicable {
    <#
    .SYNOPSIS
        Decide whether a --what-if preview describes grants worth applying.

    .DESCRIPTION
        Applying changes who can reach the scoped resources, so it happens only
        when the service actually named grants to make. A preview that reports
        nothing - because the call failed, returned no body, or found nothing
        to grant - is not read as permission to widen access. The validation
        gate then refuses the run and says why, which is the honest outcome.
    #>
    param([AllowNull()][object]$FixResult)

    $summary = Get-ChaosPermissionFixSummary -FixResult $FixResult
    if ($null -eq $summary) { return $false }
    if ($null -eq $summary.totalRequired) { return $false }

    $total = 0
    if ([int]::TryParse([string]$summary.totalRequired, [ref]$total)) { return ($total -gt 0) }
    return $false
}

function Format-ChaosPermissionFixSummary {
    <#
    .SYNOPSIS
        Render a permission-fix summary as operator-facing lines.
    #>
    param([AllowNull()][object]$Summary)

    if ($null -eq $Summary) { return '  (the service returned no permission-fix result)' }

    $lines = @()
    foreach ($field in @('state', 'totalRequired', 'succeeded', 'failed', 'skipped')) {
        $value = $Summary.$field
        $text = if ($null -eq $value) { 'not reported' } else { [string]$value }
        $lines += "  - $field`: $text"
    }
    return ($lines -join "`n")
}

function Get-ChaosPermissionFixApproval {
    <#
    .SYNOPSIS
        Return the exact redacted service preview and its deterministic digest.
    #>
    param([AllowNull()][object]$FixResult)

    $container = $FixResult
    if ($null -ne $FixResult -and $FixResult.PSObject.Properties.Name -contains 'properties') {
        $container = $FixResult.properties
    }
    $assignments = @()
    if ($null -ne $container -and $container.PSObject.Properties.Name -contains 'roleAssignments') {
        foreach ($assignment in @($container.roleAssignments)) {
            if ($null -eq $assignment) { continue }
            $assignments += [pscustomobject][ordered]@{
                targetResourceId  = [string]$assignment.targetResourceId
                principalId       = [string]$assignment.principalId
                roleDefinitionId  = [string]$assignment.roleDefinitionId
                roleDefinitionName = [string]$assignment.roleDefinitionName
                scope             = [string]$assignment.scope
                status            = [string]$assignment.status
            }
        }
    }
    $details = @($assignments | Sort-Object -Property targetResourceId, scope, roleDefinitionId, principalId)
    return [pscustomobject]@{
        details = $details
        digest  = Get-ChaosDigest -InputObject $details
    }
}

function Get-ChaosStudyApprovalPreview {
    <#
    .SYNOPSIS
        Validate a temporary configuration and freeze the exact RBAC preview.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName
    )

    $validation = Get-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $ConfigurationName
    $status = Get-ChaosValidationStatus -Validation $validation
    $permissionPreview = $null
    if ($status -ne 'Succeeded') {
        $permissionPreview = Repair-ChaosConfigurationPermission -Plan $Plan -ConfigurationName $ConfigurationName -WhatIf
    }
    $approval = Get-ChaosPermissionFixApproval -FixResult $permissionPreview
    $applicable = Test-ChaosPermissionFixApplicable -FixResult $permissionPreview
    $summary = Get-ChaosPermissionFixSummary -FixResult $permissionPreview
    $reportedCount = 0
    $hasReportedCount = (
        $null -ne $summary -and
        $null -ne $summary.totalRequired -and
        [int]::TryParse([string]$summary.totalRequired, [ref]$reportedCount)
    )
    $exact = (
        -not $applicable -or
        ($hasReportedCount -and $reportedCount -gt 0 -and @($approval.details).Count -eq $reportedCount)
    )

    return [pscustomobject]@{
        validationStatus = $status
        validationErrors = @(Get-ChaosValidationError -Validation $validation)
        permissionFix    = [ordered]@{
            applicable = [bool]$applicable
            exact      = [bool]$exact
            summary    = $summary
            details    = $approval.details
            digest     = $approval.digest
        }
        approvalReady   = ($status -eq 'Succeeded' -or ($applicable -and $exact))
    }
}

function Resolve-ChaosConfigurationValidation {
    <#
    .SYNOPSIS
        Validate a scenario configuration, repair the permissions the service
        reports as missing, and return both the outcome and what was done.

    .DESCRIPTION
        Validation always runs, and it runs before any evidence is collected or
        anything is injected, because a configuration that cannot validate is a
        run that will fail in seconds - and finding that out after a baseline
        window has already elapsed wastes the window and the operator's time.

        When validation does not succeed the missing grants are previewed with
        --what-if and shown before anything changes. They are applied only if
        the service named grants to make, and the configuration is validated
        again afterwards.

        Repair is not optional here. This code path is already past the typed
        consent phrase, so the operator has approved acting on this scope; a
        switch that merely decides whether to fix the permissions that approval
        requires adds a way to fail without adding a decision worth making.
        What matters is that the change is visible, which is why the preview,
        the applied result and the validation status either side of it are all
        returned and persisted.

        This does not decide whether to execute. Assert-ChaosConfigurationValidated
        is the gate, and Start-ChaosStudyScenarioRun applies it again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [Parameter(Mandatory)][string]$ApprovedPermissionDigest
    )

    $validation = Get-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $ConfigurationName
    $status = Get-ChaosValidationStatus -Validation $validation

    if ($status -eq 'Succeeded') {
        $currentApproval = Get-ChaosPermissionFixApproval -FixResult $null
        if ($currentApproval.digest -cne $ApprovedPermissionDigest) {
            Write-ChaosStudyFailure -Title 'Permission preview changed' -Message @"
The approved preview included RBAC changes, but this configuration now validates
without them. No grants were applied and no scenario was started.
"@ -Remediation 'Run chaos-study-run -PrepareApproval again, review the current exact preview, then obtain fresh human approval.'
            exit (Get-ChaosStudyExitCode -Name 'ConsentDeclined')
        }
        return [pscustomobject]@{
            validation    = $validation
            status        = $status
            permissionFix = $null
        }
    }

    $statusText = if ($status) { $status } else { 'no status' }
    $before = [ordered]@{
        status = $status
        errors = @(Get-ChaosValidationError -Validation $validation)
    }

    Write-ChaosStudyNote -Message "Validation reported '$statusText'. Asking Chaos Studio which role assignments are missing." -Level 'warn'

    $preview = Repair-ChaosConfigurationPermission -Plan $Plan -ConfigurationName $ConfigurationName -WhatIf
    $previewSummary = Get-ChaosPermissionFixSummary -FixResult $preview
    $currentApproval = Get-ChaosPermissionFixApproval -FixResult $preview
    $applicable = Test-ChaosPermissionFixApplicable -FixResult $preview

    if ($currentApproval.digest -cne $ApprovedPermissionDigest) {
        Write-ChaosStudyFailure -Title 'Permission preview changed' -Message @"
The exact role-assignment preview returned by Chaos Studio no longer matches the
preview the human approved. No grants were applied and no scenario was started.

Approved digest: $ApprovedPermissionDigest
Current digest:  $($currentApproval.digest)
"@ -Remediation 'Run chaos-study-run -PrepareApproval again, review the current exact preview, then obtain fresh human approval.'
        exit (Get-ChaosStudyExitCode -Name 'ConsentDeclined')
    }

    $decision = if ($applicable) {
        'These grants will now be applied, and the configuration validated again.'
    } else {
        'Chaos Studio named no grants to make, so nothing will be changed. The validation gate below will refuse the run.'
    }

    Write-ChaosStudyCard -Title 'Permission repair preview - nothing has been granted yet' -Body @"
Validation reported '$statusText'. Chaos Studio checks the workspace identity's
access to every scoped resource, so this is what it says is missing.

$(Format-ChaosPermissionFixSummary -Summary $previewSummary)

$decision
"@

    $appliedSummary = $null
    if ($applicable) {
        Write-ChaosStudyNote -Message 'Applying the role assignments Chaos Studio reported as missing.' -Level 'warn'
        $applied = Repair-ChaosConfigurationPermission -Plan $Plan -ConfigurationName $ConfigurationName
        $appliedSummary = Get-ChaosPermissionFixSummary -FixResult $applied

        if ($null -ne $appliedSummary) {
            if ($appliedSummary.whatIfMode -eq $true) {
                # The fix was requested without --what-if, so this means the
                # service previewed instead of acting and nothing was granted.
                Write-ChaosStudyNote -Message 'Chaos Studio reported whatIfMode on an applied fix, so no role assignments were actually created.' -Level 'warn'
            }
            $failedCount = 0
            if ($null -ne $appliedSummary.failed -and [int]::TryParse([string]$appliedSummary.failed, [ref]$failedCount) -and $failedCount -gt 0) {
                Write-ChaosStudyNote -Message "$failedCount role assignment(s) could not be created; the workspace identity may lack roleAssignments/write on the scope." -Level 'warn'
            }
        }

        Write-ChaosStudyNote -Message 'Re-validating the configuration after the permission repair.'
        $validation = Get-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $ConfigurationName
        $status = Get-ChaosValidationStatus -Validation $validation
    }

    return [pscustomobject]@{
        validation    = $validation
        status        = $status
        permissionFix = [ordered]@{
            attempted        = $true
            applicable       = [bool]$applicable
            approvedDigest   = $ApprovedPermissionDigest
            previewDigest    = $currentApproval.digest
            previewDetails   = $currentApproval.details
            preview          = $previewSummary
            applied          = $appliedSummary
            validationBefore = $before
            validationAfter  = [ordered]@{
                status = $status
                errors = @(Get-ChaosValidationError -Validation $validation)
            }
        }
    }
}

function Assert-ChaosConfigurationValidated {
    <#
    .SYNOPSIS
        Refuse to execute a configuration that did not validate cleanly.

    .DESCRIPTION
        This is a hard gate, not a warning. A configuration in any state other
        than Succeeded produces a run that fails in seconds with an error that
        names neither the resource nor the missing permission, which is far
        harder to diagnose than a refusal here.

        By the time this runs, Resolve-ChaosConfigurationValidation has already
        previewed and applied whatever grants the service reported as missing.
        So reaching this gate means repair was either impossible or
        insufficient, and the remediation says so rather than suggesting a
        switch that would repeat what already happened.
    #>
    param(
        [AllowNull()][object]$Validation,
        [Parameter(Mandatory)][string]$ConfigurationName
    )

    $status = Get-ChaosValidationStatus -Validation $Validation
    if ($status -eq 'Succeeded') { return $true }

    $errors = @(Get-ChaosValidationError -Validation $Validation)
    $detail = if ($errors.Count -gt 0) {
        ($errors | ForEach-Object {
            $where = if ($_.resource) { " on $($_.resource)" } else { '' }
            "  - $($_.code)$where`: $($_.message)"
        }) -join "`n"
    } else {
        '  (the service reported no error detail)'
    }

    $looksLikePermissions = @($errors | Where-Object {
        "$($_.code) $($_.message)" -match '(?i)(permission|authoriz|forbidden|rbac|roleassignment)'
    }).Count -gt 0

    $remediation = if ($looksLikePermissions) {
        'Chaos Studio already previewed and applied the grants it reported as missing, and validation still failed. Role assignments can take a few minutes to propagate, so retrying often succeeds; if it does not, grant the workspace identity the roles named above manually, or ask someone with User Access Administrator on the scope to run az chaos scenario config fix-permissions.'
    } else {
        'Re-run chaos-study-scope against a scope the workspace can actually reach, then plan again.'
    }

    Write-ChaosStudyFailure -Title 'Scenario configuration did not validate' -Message @"
Configuration '$ConfigurationName' validated as $(if ($status) { $status } else { 'an unreported status' }).

$detail

Chaos Studio validates a configuration against the live scope and the workspace
identity's permissions. Executing an unvalidated configuration produces a run
that fails within seconds without naming the cause, so this study stops here
instead.
"@ -Remediation $remediation
    exit (Get-ChaosStudyExitCode -Name 'ValidationFailed')
}

# -- Scenario run ----------------------------------------------------------

function Start-ChaosStudyScenarioRun {
    <#
    .SYNOPSIS
        Execute a validated configuration and return the run id.

    .DESCRIPTION
        The validation result is a required argument, and it is asserted here as
        the last thing before the run starts. The caller has already applied the
        same gate; this repeats it so that the guarantee belongs to the function
        that starts the run rather than to the order of statements in one
        caller. A future caller that reorders the sequence, or forgets the gate
        entirely, still cannot execute an unvalidated configuration.

        The run id is read from the response, falling back to the resource id,
        because everything afterwards - polling, cancelling, evidence
        correlation - is keyed on it, and a run that started but cannot be
        identified is a run that cannot be stopped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [Parameter(Mandatory)][AllowNull()][object]$Validation
    )

    Assert-ChaosConfigurationValidated -Validation $Validation -ConfigurationName $ConfigurationName | Out-Null

    $started = Invoke-AzChaos -ChaosArgs @(
        'scenario', 'run', 'start',
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name,
        '--config-name', $ConfigurationName
    )

    if ($null -eq $started) {
        throw "Chaos Studio did not return a scenario run for configuration '$ConfigurationName'."
    }

    $runId = $null
    if ($started.PSObject.Properties.Name -contains 'name' -and $started.name) {
        $runId = [string]$started.name
    } elseif ($started.PSObject.Properties.Name -contains 'id' -and $started.id -match '/runs/([^/?]+)') {
        $runId = $Matches[1]
    }

    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw 'A scenario run was started but Chaos Studio returned no run id, so it cannot be tracked or cancelled. Cancel it from the portal.'
    }

    return [pscustomobject]@{
        runId    = $runId
        response = $started
    }
}

function Get-ChaosStudyScenarioRun {
    <#
    .SYNOPSIS
        Read the current state of a scenario run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$RunId
    )

    return Invoke-AzChaos -AllowFailure -ChaosArgs @(
        'scenario', 'run', 'show',
        '-n', $RunId,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name
    )
}

function Stop-ChaosStudyScenarioRun {
    <#
    .SYNOPSIS
        Cancel a scenario run, tolerating one that already finished.

    .DESCRIPTION
        Called from a finally block, so it must never throw: an exception here
        would mask whatever caused the study to unwind in the first place.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$RunId
    )

    $requestedAt = Get-ChaosUtcNow
    $response = Invoke-AzChaos -AllowFailure -ChaosArgs @(
        'scenario', 'run', 'cancel',
        '-n', $RunId,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name
    )
    return [pscustomobject]@{
        requestedAt     = $requestedAt
        responseReceived = ($null -ne $response)
        response         = Protect-ChaosObject -InputObject $response
    }
}

function Get-ChaosScenarioRunStatus {
    <#
    .SYNOPSIS
        Read the run status, whatever shape the response arrives in.
    #>
    param([AllowNull()][object]$Run)

    if ($null -eq $Run) { return $null }
    if ($Run.PSObject.Properties.Name -contains 'properties' -and $null -ne $Run.properties) {
        if ($Run.properties.PSObject.Properties.Name -contains 'status') { return [string]$Run.properties.status }
    }
    if ($Run.PSObject.Properties.Name -contains 'status') { return [string]$Run.status }
    return $null
}

function Test-ChaosScenarioRunTerminal {
    <#
    .SYNOPSIS
        True when a run has reached a state it will not leave.
    #>
    param([AllowNull()][string]$Status)
    return ($Status -in @('Succeeded', 'Failed', 'Canceled', 'Cancelled'))
}

function Get-ChaosScenarioRunObservation {
    <#
    .SYNOPSIS
        Flatten a scenario run into what the report needs: which actions ran,
        against which resources, and what went wrong.

    .DESCRIPTION
        Absent detail is recorded as null rather than as an empty success. A
        report that cannot say what happened must say so.
    #>
    param([AllowNull()][object]$Run)

    $observation = [ordered]@{
        status          = Get-ChaosScenarioRunStatus -Run $Run
        startedAt       = $null
        completedAt     = $null
        actions         = @()
        errors          = @()
        resourcesTouched = $null
    }
    if ($null -eq $Run) { return $observation }

    $props = if ($Run.PSObject.Properties.Name -contains 'properties' -and $null -ne $Run.properties) { $Run.properties } else { $Run }

    if ($props.PSObject.Properties.Name -contains 'startTime') { $observation['startedAt'] = [string]$props.startTime }
    if ($props.PSObject.Properties.Name -contains 'endTime') { $observation['completedAt'] = [string]$props.endTime }

    $resourceCount = 0
    $sawResources = $false
    if ($props.PSObject.Properties.Name -contains 'scenarioRunSummary') {
        foreach ($entry in @($props.scenarioRunSummary)) {
            if ($null -eq $entry) { continue }
            $resources = @()
            if ($entry.PSObject.Properties.Name -contains 'resources' -and $null -ne $entry.resources) {
                $sawResources = $true
                $resources = @($entry.resources | ForEach-Object { [string]$_ })
                $resourceCount += $resources.Count
            }
            $observation['actions'] += [ordered]@{
                actionUrn   = if ($entry.PSObject.Properties.Name -contains 'actionUrn') { [string]$entry.actionUrn } else { $null }
                state       = if ($entry.PSObject.Properties.Name -contains 'state') { [string]$entry.state } else { $null }
                startedAt   = if ($entry.PSObject.Properties.Name -contains 'startedAt') { [string]$entry.startedAt } else { $null }
                completedAt = if ($entry.PSObject.Properties.Name -contains 'completedAt') { [string]$entry.completedAt } else { $null }
                resources   = $resources
            }
        }
    }
    if ($sawResources) { $observation['resourcesTouched'] = $resourceCount }

    if ($props.PSObject.Properties.Name -contains 'errors') {
        foreach ($item in @($props.errors)) {
            if ($null -eq $item) { continue }
            $observation['errors'] += [ordered]@{
                code    = if ($item.PSObject.Properties.Name -contains 'errorCode') { [string]$item.errorCode } else { $null }
                message = if ($item.PSObject.Properties.Name -contains 'errorMessage') { [string]$item.errorMessage } else { [string]$item }
            }
        }
    }

    if ($props.PSObject.Properties.Name -contains 'executionErrors' -and $null -ne $props.executionErrors) {
        foreach ($kind in @('permission', 'resource')) {
            if ($props.executionErrors.PSObject.Properties.Name -notcontains $kind) { continue }
            foreach ($item in @($props.executionErrors.$kind)) {
                if ($null -eq $item) { continue }
                $observation['errors'] += [ordered]@{
                    code    = $kind
                    message = ConvertTo-ChaosCanonicalJson -InputObject $item
                }
            }
        }
    }

    return $observation
}

function Wait-ChaosScenarioRunWindow {
    <#
    .SYNOPSIS
        Hold for the injection window, polling the run and returning early if
        it reaches a terminal state.

    .DESCRIPTION
        Returning early matters: a run that failed on the first resource should
        not be reported as "injected for ten minutes". The last observed run is
        returned so the caller records what actually happened rather than what
        was planned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$Minutes,
        [Parameter(Mandatory)][datetime]$InjectionStartedAt,
        [int]$PollSeconds = 20,
        [scriptblock]$OnPoll,
        [scriptblock]$OnAbortCheck
    )

    $deadline = [datetime]::UtcNow.AddMinutes($Minutes)
    $last = $null
    $terminal = $false
    $abortChecks = @()
    $abort = $null

    while ([datetime]::UtcNow -lt $deadline) {
        $last = Get-ChaosStudyScenarioRun -Plan $Plan -RunId $RunId
        $status = Get-ChaosScenarioRunStatus -Run $last
        if ($OnPoll) { & $OnPoll $status }
        if (Test-ChaosScenarioRunTerminal -Status $status) { $terminal = $true; break }

        $checkedAt = [datetime]::UtcNow
        if ($OnAbortCheck -and $checkedAt -gt $InjectionStartedAt) {
            $window = New-ChaosWindow -Name 'abort-check' -Start $InjectionStartedAt -End $checkedAt
            $check = & $OnAbortCheck $window
            if ($null -ne $check) {
                $abortChecks += $check
                if ($check.triggered) {
                    $abort = $check.trigger
                    $abort['observedAt'] = $check.observedAt
                    break
                }
            }
        }

        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Ceiling($remaining)))
    }

    if (-not $terminal -and $null -eq $last) {
        $last = Get-ChaosStudyScenarioRun -Plan $Plan -RunId $RunId
    }

    return [pscustomobject]@{
        run              = $last
        endedEarly       = $terminal
        abort            = $abort
        abortChecks      = @($abortChecks)
        observedAt       = Get-ChaosUtcNow
    }
}
