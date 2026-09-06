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

    Every Azure operation here goes through Invoke-ChaosStudyOperation, the
    adapter seam, rather than calling a CLI directly. The seam speaks the Chaos
    Studio V2 surface - workspaces, scopes, scenarios, scenario configurations
    and scenario runs - and can either execute against ambient credentials or
    hand the operation to an authenticated host and resume when its result
    arrives. Nothing in this file assumes it holds credentials of its own.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Operation.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Residue.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ExecutionPlan.ps1')

# -- Adapter resolution ----------------------------------------------------

function Save-ChaosRunCheckpoint {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Study,
        [Parameter(Mandatory)][string]$StartedAt,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][string]$RunId,
        [AllowNull()][object]$Observation,
        [string]$Outcome = 'Failed',
        [AllowNull()][string]$Failure,
        [AllowNull()][object]$PreWindow,
        [AllowNull()][string]$ValidationStatus,
        [AllowNull()][object]$PermissionFix,
        [AllowNull()][object]$Abort,
        [AllowNull()][AllowEmptyCollection()][object[]]$Signals = @()
    )
    $record = [ordered]@{
        recordVersion = 'run-record.v3'; studyId = $Study.studyId; scopeHash = $Study.scopeHash
        planHash = $Plan.frozenConfigHash; startedAt = $StartedAt; completedAt = $null
        collectionState = 'recovery-pending'; workspace = $Plan.workspace
        configuration = @{ name = $ConfigurationName; scenario = $Plan.scenario.name; validationStatus = $ValidationStatus; permissionFix = $PermissionFix; retained = $null }
        scenarioRun = @{ runId = $RunId; outcome = $Outcome; observation = $Observation; failure = $Failure; abort = $Abort }
        windows = @{ pre = $PreWindow; during = $null; observation = $null; action = $null; post = $null }
        evidence = @{ pre = 'evidence/pre/signals.json'; during = 'evidence/during/signals.json'; post = 'evidence/post/signals.json' }
        coverage = Test-ChaosSignalCoverage -Signals $Signals
        exercise = $null; residue = Get-ChaosResidueSummary -StudyPath $Study.path
    }
    Save-ChaosStudyArtifact -StudyPath $Study.path -RelativePath (Get-ChaosArtifactFileName runRecord) -Content $record | Out-Null
}

function Get-ChaosExecutionAdapter {
    <#
    .SYNOPSIS
        Resolve the adapter a control-plane operation must run through.

    .DESCRIPTION
        Deliberately has no default. Read-only evidence collection may fall back
        to the ambient CLI because the worst case is a missing signal; creating
        a configuration or starting a run may not, because the worst case is an
        operation that silently ran somewhere the operator did not intend. An
        unresolvable adapter stops the study instead.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Plan,
        [AllowNull()][AllowEmptyString()][string]$Adapter
    )

    if (-not [string]::IsNullOrWhiteSpace($Adapter)) { return $Adapter }
    if ($null -ne $Plan -and ($Plan.PSObject.Properties.Name -contains 'adapter') -and
        -not [string]::IsNullOrWhiteSpace([string]$Plan.adapter)) {
        return [string]$Plan.adapter
    }
    throw 'AdapterUnavailable: no execution adapter was resolved for this operation, and there is no implicit fallback for control-plane work. Re-run scoping so the plan records an adapter, or pass -Adapter explicitly.'
}

function Get-ChaosConfigurationScopingArgument {
    <#
    .SYNOPSIS
        The four arguments that identify a scenario configuration.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName
    )
    return @(
        '-n', $ConfigurationName,
        '-g', $Plan.workspace.resourceGroup,
        '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name,
        '--scenario-name', $Plan.scenario.name
    )
}

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

# -- Consent ---------------------------------------------------------------

function Test-ChaosPlanLiveDiscovery {
    param([Parameter(Mandatory)][object]$Plan)
    return ($Plan.action.PSObject.Properties.Name -contains 'source' -and
        $Plan.action.source -eq 'live-discovery' -and
        $null -ne $Plan.scope.projectedResourceCount)
}

function New-ChaosApprovalPreview {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][object]$Validation,
        [AllowNull()][object]$PermissionPreview
    )
    $status = Get-ChaosValidationStatus -Validation $Validation
    $exact = Test-ChaosPermissionFixApplicable -FixResult $PermissionPreview
    $grant = if ($exact) { Get-ChaosPermissionGrantSet -Plan $Plan -ConfigurationName $ConfigurationName -FixResult $PermissionPreview } else { $null }
    $preview = [ordered]@{
        previewId = [guid]::NewGuid().ToString('N'); generatedAt = Get-ChaosUtcNow
        planHash = $Plan.frozenConfigHash; consumedAt = $null
        approvalReady = ($status -eq 'Succeeded' -or ((Test-ChaosValidationRepairable $Validation) -and $exact))
        configurationName = $ConfigurationName
        configuration = Get-ChaosStudyConfigurationBody -Plan $Plan
        projectedResources = @($Plan.scope.projectedResources)
        workspace = $Plan.workspace
        validation = @{ status = $status; errors = @(Get-ChaosValidationError -Validation $Validation) }
        permissionFix = $grant
    }
    $preview = Protect-ChaosObject -InputObject $preview
    $preview['previewHash'] = Get-ChaosDigest -InputObject $preview
    return [pscustomobject]$preview
}

function Test-ChaosApprovalPreviewReady {
    param([Parameter(Mandatory)][object]$Plan, [AllowNull()][object]$Preview)
    if ($null -eq $Preview) { return $false }
    foreach ($field in @('planHash', 'approvalReady', 'consumedAt', 'previewId', 'previewHash')) {
        if ($Preview.PSObject.Properties.Name -notcontains $field) { return $false }
    }
    if ($Preview.planHash -ne $Plan.frozenConfigHash -or $Preview.approvalReady -ne $true -or $Preview.consumedAt) { return $false }
    $copy = [ordered]@{}
    foreach ($property in $Preview.PSObject.Properties) {
        if ($property.Name -ne 'previewHash') { $copy[$property.Name] = $property.Value }
    }
    return ($Preview.previewHash -eq (Get-ChaosDigest -InputObject $copy))
}

function Get-ChaosConsentPhrase {
    <#
    .SYNOPSIS
        The exact phrase the operator must type to authorise injection.

    .DESCRIPTION
        The phrase names the action and the workspace it lands in so it cannot
        be typed without reading it, and carries the plan hash so it cannot be
        reused for a different plan.
    #>
    param([Parameter(Mandatory)][object]$Plan, [AllowNull()][object]$Preview)

    if ($null -eq $Preview) { return "inject $($Plan.action.name) into $($Plan.workspace.name) $($Plan.frozenConfigHash)" }
    return "inject $($Plan.action.name) into $($Plan.workspace.name) $($Plan.frozenConfigHash) approval $($Preview.previewHash)"
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
        [AllowNull()][object]$Preview,
        [AllowNull()][AllowEmptyString()][string]$Consent
    )

    $expected = Get-ChaosConsentPhrase -Plan $Plan -Preview $Preview
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

$(Format-ChaosTelemetryLag -Plan $Plan)

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

    $effective = @{}
    if ($Plan.scenario.PSObject.Properties.Name -contains 'parameterSpec') {
        foreach ($spec in @($Plan.scenario.parameterSpec)) {
            if ($null -ne $spec -and $spec.PSObject.Properties.Name -contains 'default' -and $null -ne $spec.default) {
                $effective[[string]$spec.name] = $spec.default
            }
        }
    }
    if ($Plan.scenario.PSObject.Properties.Name -contains 'parameters') {
        foreach ($entry in @($Plan.scenario.parameters)) {
            if ($null -ne $entry) { $effective[[string]$entry.key] = $entry.value }
        }
    }

    $pairs = @()
    foreach ($key in ($effective.Keys | Sort-Object)) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $value = $effective[$key]
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

function Format-ChaosTelemetryLag {
    param([Parameter(Mandatory)][object]$Plan)
    $lag = Get-ChaosMember -InputObject (Get-ChaosMember -InputObject $Plan -Name discovery) -Name telemetryLag
    if ($null -eq $lag) { return 'Missing-signal tolerance: not derived; fresh live telemetry discovery is required before approval.' }
    return "Missing-signal tolerance: $($lag.unavailableIntervals) intervals of $($lag.grainSeconds) seconds; measured minimum $($lag.derivedUnavailableIntervals). Samples: $(ConvertTo-ChaosCanonicalJson -InputObject $lag.queries)"
}

function Write-ChaosStudyDryRunContract {
    param([Parameter(Mandatory)][object]$Plan, [Parameter(Mandatory)][string]$ConfigurationName)
    $effective = [ordered]@{}
    foreach ($pair in @(Get-ChaosScenarioParameterList -Plan $Plan)) { $effective[$pair.key] = $pair.value }
    $parameters = ConvertTo-ChaosCanonicalJson -InputObject $effective
    $actionType = [string]$Plan.action.actionType
    $restoration = switch ($actionType) {
        'Cancelable' { 'Cancellation requests restoration; post-recovery evidence must prove the system recovered.' }
        'Continuous' { 'Cancellation stops the continuous fault; post-recovery evidence must prove the system recovered.' }
        default { 'Cancellation does not undo a discrete or unknown action. Restoration may require operator action; post-recovery evidence must prove recovery.' }
    }
    @"
Frozen configuration hash: $($Plan.frozenConfigHash)
$(Format-ChaosTelemetryLag -Plan $Plan)
Effective scenario parameters (service defaults merged with frozen overrides): $parameters
Action type: $actionType
Restoration: $restoration
Configuration lifecycle: create (or reuse the matching preflight) -> validate -> run -> cancel -> delete.
Configuration: $ConfigurationName
Dry-run creates no configuration and changes nothing. Deletion removes configuration only, not persistent RBAC grants.
Every armed run requires fresh human approval after the exact frozen blast-radius and RBAC preview. An agent must never self-confirm.
"@
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
        $names = if ($source -is [System.Collections.IDictionary]) { @($source.Keys) } else { @($source.PSObject.Properties.Name) }
        foreach ($name in $names) {
            if ($source -is [System.Collections.IDictionary]) { $value = $source[$name] }
            else { $value = $source.$name }
            if ($null -eq $value) { continue }
            if ($value -is [string]) {
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
            } elseif ($value -is [System.Collections.IDictionary]) {
                if ($value.Count -eq 0) { continue }
            } elseif ($value -is [System.Collections.IEnumerable]) {
                if (@($value).Count -eq 0) { continue }
            }
            $projected[$name] = $value
        }
        if ($projected.Count -gt 0) { $result[$side] = [pscustomobject]$projected }
    }

    return [pscustomobject]$result
}

function Get-ChaosStudyConfigurationBody {
    param([Parameter(Mandatory)][object]$Plan)
    $body = @{}
    $parameters = @(Get-ChaosScenarioParameterList -Plan $Plan)
    if ($parameters.Count -gt 0) { $body['parameters'] = $parameters }
    $blast = Get-ChaosBlastRadiusArgument -Plan $Plan
    if ($null -ne $blast.filters) { $body['filters'] = $blast.filters }
    if ($null -ne $blast.exclusions) { $body['exclusions'] = $blast.exclusions }
    return $body
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

        Structured arguments go through Invoke-ChaosStudyAzChaos -JsonArg, which writes
        them to a temp file. On Windows `az` is a .cmd shim that mangles
        unquoted JSON braces, so passing them inline is not reliable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    $cliArgs = Get-ChaosConfigurationScopingArgument -Plan $Plan -ConfigurationName $ConfigurationName

    $jsonArg = Get-ChaosStudyConfigurationBody -Plan $Plan

    $created = Invoke-ChaosStudyOperation -Kind 'config.create' -Arguments @{ cliArgs = $cliArgs } `
        -Body $(if ($jsonArg.Count -gt 0) { $jsonArg } else { $null }) `
        -ExpectedSchema 'any.v1' -Adapter (Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter) `
        -StudyPath $StudyPath -OperationHint 'scenario config create'

    if ($null -eq $created) {
        throw "Chaos Studio did not return a scenario configuration for '$ConfigurationName'. The configuration was not created, so nothing was executed."
    }
    return $created
}

function Remove-ChaosStudyConfiguration {
    <#
    .SYNOPSIS
        Delete a scenario configuration, tolerating one that is already gone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    $cliArgs = (Get-ChaosConfigurationScopingArgument -Plan $Plan -ConfigurationName $ConfigurationName) + @('--yes')
    $selected = Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter
    $result = [ordered]@{
        effective = $true; certainty = 'delete-reported-success'; serviceError = $null
        reconciliation = $null
    }
    try {
        Invoke-ChaosStudyOperation -Kind 'config.delete' -Arguments @{ cliArgs = $cliArgs } `
            -ExpectedSchema 'any.v1' -Adapter $selected -StudyPath $StudyPath -OperationHint 'scenario config delete' | Out-Null
    } catch {
        $result.effective = $false
        $result.certainty = 'cleanup-uncertain'
        $result.serviceError = $_.Exception.Message
        $reconciliation = [ordered]@{ state = 'inconclusive'; error = $null }
        # Exactly one read after an ambiguous DELETE. Never repeat the mutation.
        try {
            $listArgs = @('-g', $Plan.workspace.resourceGroup, '--workspace-name', $Plan.workspace.name,
                '--scenario-name', $Plan.scenario.name, '--subscription', $Plan.workspace.subscriptionId)
            $listed = Invoke-ChaosStudyOperation -Kind 'config.list' -Arguments @{ cliArgs = $listArgs } `
                -ExpectedSchema 'any.v1' -Adapter $selected -StudyPath $StudyPath -OperationHint 'reconcile config delete'
            $items = $null
            if ($listed -is [array]) { $items = $listed }
            elseif ($null -ne $listed -and $listed.PSObject.Properties.Name -contains 'value' -and $listed.value -is [array] -and
                -not ($listed.PSObject.Properties.Name -contains 'nextLink' -and $listed.nextLink)) { $items = $listed.value }
            elseif ($null -ne $listed -and $listed.PSObject.Properties.Name -contains 'name') { $items = @($listed) }
            if ($null -ne $items) {
                $match = @($items | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'name' -and $_.name -eq $ConfigurationName })
                $unnamed = @($items | Where-Object { $null -eq $_ -or $_.PSObject.Properties.Name -notcontains 'name' -or -not $_.name })
                if ($match.Count) { $reconciliation.state = 'present' }
                elseif ($unnamed.Count -eq 0) {
                    $reconciliation.state = 'absent'
                    $result.effective = $true
                    $result.certainty = 'effective-with-service-error'
                }
            }
        } catch { $reconciliation.error = $_.Exception.Message }
        $result.reconciliation = [pscustomobject]$reconciliation
    }
    return [pscustomobject]$result
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
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    $cliArgs = Get-ChaosConfigurationScopingArgument -Plan $Plan -ConfigurationName $ConfigurationName
    $resolvedAdapter = Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter

    Invoke-ChaosStudyOperation -Kind 'config.validate' -Arguments @{ cliArgs = $cliArgs } `
        -ExpectedSchema 'any.v1' -Adapter $resolvedAdapter -StudyPath $StudyPath `
        -OperationHint 'scenario config validate' | Out-Null

    return Invoke-ChaosStudyOperation -Kind 'config.showValidation' -Arguments @{ cliArgs = $cliArgs } `
        -ExpectedSchema 'validation.v2' -Adapter $resolvedAdapter -StudyPath $StudyPath `
        -OperationHint 'scenario config show-validation'
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

    $pending = @()
    if ($container.PSObject.Properties.Name -contains 'errors') {
        $pending += @($container.errors | Where-Object { $null -ne $_ } | ForEach-Object { @{ item = $_; source = 'errors' } })
    }
    if ($container.PSObject.Properties.Name -contains 'validationErrors' -and $null -ne $container.validationErrors) {
        $validationErrors = $container.validationErrors
        if ($validationErrors -is [array] -or $validationErrors.PSObject.Properties.Name -contains 'errorCode') {
            $pending += @($validationErrors | ForEach-Object { @{ item = $_; source = 'validationErrors' } })
        } else {
            foreach ($property in $validationErrors.PSObject.Properties) {
                $pending += @($property.Value | Where-Object { $null -ne $_ } | ForEach-Object { @{ item = $_; source = $property.Name } })
            }
        }
    }
    foreach ($entry in $pending) {
        $item = $entry.item
        $code = if ($item.PSObject.Properties.Name -contains 'errorCode') { [string]$item.errorCode }
                elseif ($item.PSObject.Properties.Name -contains 'code') { [string]$item.code } else { '' }
        $repairable = $code -match '^(AuthorizationFailed|Forbidden|PermissionDenied|MissingPermissions|InsufficientPermissions|PermissionValidation(Error)?|MissingRoleAssignments?)$'
        if (-not $code -and $entry.source -eq 'permission') {
            $permissions = @()
            foreach ($field in @('missingPermissions', 'requiredPermissions')) {
                if ($item.PSObject.Properties.Name -contains $field) { $permissions += @($item.$field | Where-Object { $_ }) }
            }
            $roles = @(if ($item.PSObject.Properties.Name -contains 'recommendedRoles') { $item.recommendedRoles | Where-Object { $_ } })
            $code = 'PermissionValidation'
            $repairable = $permissions.Count -gt 0 -and $roles.Count -gt 0
        }
        [pscustomobject]@{
            code = $code
            category = if ($repairable) { 'permission' } else { 'system-or-unknown' }
            repairable = [bool]$repairable
            message = if ($item.PSObject.Properties.Name -contains 'errorMessage') { [string]$item.errorMessage }
                      elseif ($item.PSObject.Properties.Name -contains 'message') { [string]$item.message } else { [string]$item }
            resource = if ($item.PSObject.Properties.Name -contains 'resourceId') { [string]$item.resourceId } else { $null }
            details = $item
        }
    }
}

function Test-ChaosValidationRepairable {
    param([AllowNull()][object]$Validation)
    $errors = @(Get-ChaosValidationError -Validation $Validation)
    return ($errors.Count -gt 0 -and @($errors | Where-Object { -not $_.repairable }).Count -eq 0)
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
        [switch]$WhatIf,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    $scoping = Get-ChaosConfigurationScopingArgument -Plan $Plan -ConfigurationName $ConfigurationName
    $resolvedAdapter = Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter

    $fixArgs = if ($WhatIf) { $scoping + @('--what-if') } else { $scoping }

    Invoke-ChaosStudyOperation -Kind 'config.fixPermissions' -Arguments @{ cliArgs = $fixArgs } `
        -ExpectedSchema 'any.v1' -Adapter $resolvedAdapter -StudyPath $StudyPath `
        -OperationHint $(if ($WhatIf) { 'scenario config fix-permissions --what-if' } else { 'scenario config fix-permissions' }) | Out-Null

    return Invoke-ChaosStudyOperation -Kind 'config.showPermissionFix' -Arguments @{ cliArgs = $scoping } `
        -ExpectedSchema 'any.v1' -Adapter $resolvedAdapter -StudyPath $StudyPath `
        -OperationHint 'scenario config show-permission-fix'
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
    if ($null -eq $summary.totalRequired -or $summary.whatIfMode -ne $true -or $summary.state -ne 'WhatIfCompleted') { return $false }

    $total = 0
    if (-not [int]::TryParse([string]$summary.totalRequired, [ref]$total) -or $total -le 0) { return $false }
    $details = @(Get-ChaosPermissionGrantDetail -FixResult $FixResult | Where-Object { $null -ne $_ })
    if ($details.Count -ne $total) { return $false }
    foreach ($detail in $details) {
        foreach ($field in @('principalId', 'roleDefinitionId', 'scope')) {
            if ($detail.PSObject.Properties.Name -notcontains $field -or [string]::IsNullOrWhiteSpace([string]$detail.$field)) { return $false }
        }
    }
    return $true
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

function Get-ChaosPermissionGrantDetail {
    <#
    .SYNOPSIS
        Pull the individual grants out of a permission-fix result, when the
        service names them.

    .DESCRIPTION
        The fix-permissions contract guarantees counts, not a list. Some
        responses carry the individual assignments and some do not, so this
        looks for the collection under the property names the service has used
        and returns null - never an empty list - when it finds none. Null means
        "the service did not tell us"; an empty list would claim it told us
        there were none, and those are different facts.
    #>
    param([AllowNull()][object]$FixResult)

    if ($null -eq $FixResult) { return $null }

    $container = $FixResult
    if ($FixResult.PSObject.Properties.Name -contains 'properties' -and $null -ne $FixResult.properties) {
        $container = $FixResult.properties
    }

    foreach ($name in @('permissionAssignments', 'roleAssignments', 'assignments', 'requiredPermissions', 'permissions')) {
        if ($container.PSObject.Properties.Name -contains $name) {
            $value = $container.$name
            if ($null -ne $value) {
                $list = @($value)
                if ($list.Count -gt 0) { return $list }
            }
        }
    }
    return $null
}

function Get-ChaosPermissionGrantSet {
    <#
    .SYNOPSIS
        Normalise a permission-fix preview into the grant set an approval binds
        to, plus a hash of it.

    .DESCRIPTION
        Approval has to name what is being approved, and it has to stop being
        valid the moment that changes. Hashing the normalised grant set gives
        both: the operator sees the roles and scopes, and a preview that later
        widens produces a different hash and therefore needs a fresh approval.

        The hash covers the configuration and workspace as well as the grants,
        so an approval for one study can never be replayed against another.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][object]$FixResult
    )

    $summary = Get-ChaosPermissionFixSummary -FixResult $FixResult
    $details = Get-ChaosPermissionGrantDetail -FixResult $FixResult

    $roles = $null
    $scopes = $null
    $missingActions = $null
    if ($null -ne $details) {
        $roles = @($details | ForEach-Object {
                foreach ($p in @('roleDefinitionName', 'roleName', 'roleDefinitionId', 'role')) {
                    if ($_.PSObject.Properties.Name -contains $p -and $_.$p) { return [string]$_.$p }
                }
                $null
            } | Where-Object { $_ } | Sort-Object -Unique)
        $scopes = @($details | ForEach-Object {
                foreach ($p in @('scope', 'resourceId', 'targetResourceId')) {
                    if ($_.PSObject.Properties.Name -contains $p -and $_.$p) { return [string]$_.$p }
                }
                $null
            } | Where-Object { $_ } | Sort-Object -Unique)
        $missingActions = @($details | ForEach-Object {
                foreach ($p in @('missingActions', 'actions', 'action')) {
                    if ($_.PSObject.Properties.Name -contains $p -and $_.$p) { return @($_.$p) }
                }
                @()
            } | ForEach-Object { $_ } | Where-Object { $_ } | Sort-Object -Unique)
        if ($roles.Count -eq 0) { $roles = $null }
        if ($scopes.Count -eq 0) { $scopes = $null }
        if ($null -eq $missingActions -or $missingActions.Count -eq 0) { $missingActions = $null }
    }

    $grantSet = [ordered]@{
        workspace         = [string]$Plan.workspace.name
        resourceGroup     = [string]$Plan.workspace.resourceGroup
        configurationName = $ConfigurationName
        workspacePrincipal = if ($Plan.workspace.PSObject.Properties.Name -contains 'identityPrincipalId') { $Plan.workspace.identityPrincipalId } else { $null }
        subscriptionId    = [string]$Plan.workspace.subscriptionId
        planHash          = [string]$Plan.frozenConfigHash
        assignments       = @($details | Where-Object { $null -ne $_ } | ForEach-Object {
            [ordered]@{
                principalId = if ($_.PSObject.Properties.Name -contains 'principalId') { $_.principalId } else { $null }
                roleDefinitionId = if ($_.PSObject.Properties.Name -contains 'roleDefinitionId') { $_.roleDefinitionId } else { $null }
                scope = if ($_.PSObject.Properties.Name -contains 'scope') { $_.scope } else { $null }
            }
        } | Sort-Object { ConvertTo-ChaosCanonicalJson $_ })
        totalRequired     = if ($null -eq $summary) { $null } else { $summary.totalRequired }
        recommendedRoles  = $roles
        scopes            = $scopes
        missingActions    = $missingActions
    }

    $hash = Get-ChaosDigest -InputObject $grantSet
    return [pscustomobject]@{
        grantSet = $grantSet
        hash     = $hash
        details  = $details
    }
}

function Get-ChaosPermissionApprovalPhrase {
    <#
    .SYNOPSIS
        The exact phrase that approves widening RBAC for this study.

    .DESCRIPTION
        Deliberately different in shape from the injection phrase. Approving a
        role assignment and approving a fault are different decisions with
        different blast radii - one outlives the study - so neither phrase can
        be mistaken for, or satisfy, the other. It carries the grant-set hash so
        approving a smaller set never authorises a larger one.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$GrantSetHash
    )

    $shortGrant = ([string]$GrantSetHash).Substring(0, 8)
    return "grant access on $($Plan.workspace.name) $shortGrant"
}

function Test-ChaosPermissionApproval {
    <#
    .SYNOPSIS
        Whether the operator supplied the exact approval phrase for this grant
        set. Case-sensitive, like every other consent in this suite.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$GrantSetHash,
        [AllowNull()][AllowEmptyString()][string]$Approval
    )

    if ([string]::IsNullOrWhiteSpace($Approval)) { return $false }
    $expected = Get-ChaosPermissionApprovalPhrase -Plan $Plan -GrantSetHash $GrantSetHash
    return ($Approval.Trim() -ceq $expected)
}

function Get-ChaosRoleAssignmentSnapshot {
    <#
    .SYNOPSIS
        A read-only snapshot of the role assignments on a scope.

    .DESCRIPTION
        Taken either side of a repair so the study can report the assignments it
        actually created rather than the count the service was asked for. Read
        failures are not fatal and are not silently treated as "no assignments":
        the snapshot returns null, and a null on either side means the delta is
        unknown rather than empty.
    #>
    param(
        [Parameter(Mandatory)][string]$Scope,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    if ([string]::IsNullOrWhiteSpace($Scope)) { return $null }

    try {
        $response = Invoke-ChaosStudyOperation -Kind 'roleAssignments.list' -Arguments @{ scope = $Scope } `
            -ExpectedSchema 'any.v1' -Adapter $Adapter -StudyPath $StudyPath `
            -OperationHint 'role assignment list'
    } catch {
        return $null
    }

    if ($null -eq $response) { return $null }
    $body = if ($response.PSObject.Properties.Name -contains 'body') { $response.body } else { $response }
    if ($null -eq $body) { return $null }
    if ($body.PSObject.Properties.Name -contains 'value') { return @($body.value) }
    return @($body)
}

function Get-ChaosRoleAssignmentDelta {
    <#
    .SYNOPSIS
        The assignments present after a repair that were not present before.

    .DESCRIPTION
        Returns null when either snapshot is unknown. A repair whose effect
        could not be observed must not be reported as having granted nothing -
        that is the difference between "we checked and it was clean" and "we
        could not check", and only one of those is safe to act on.
    #>
    param(
        [AllowNull()][object]$Before,
        [AllowNull()][object]$After
    )

    if ($null -eq $Before -or $null -eq $After) { return $null }

    $beforeIds = @{}
    foreach ($item in @($Before)) {
        if ($null -ne $item -and $item.PSObject.Properties.Name -contains 'id' -and $item.id) { $beforeIds[[string]$item.id] = $true }
    }

    $new = @()
    foreach ($item in @($After)) {
        if ($null -eq $item) { continue }
        if (-not ($item.PSObject.Properties.Name -contains 'id') -or -not $item.id) { continue }
        if (-not $beforeIds.ContainsKey([string]$item.id)) { $new += $item }
    }
    return @($new)
}

function Resolve-ChaosConfigurationValidation {
    <#
    .SYNOPSIS
        Validate a scenario configuration and, when it fails for want of access,
        preview the grants it needs - applying them only under a separate,
        grant-bound approval.

    .DESCRIPTION
        Validation always runs, and it runs before any evidence is collected or
        anything is injected, because a configuration that cannot validate is a
        run that will fail in seconds - and finding that out after a baseline
        window has already elapsed wastes the window and the operator's time.

        Widening RBAC is not part of approving a fault. An injection ends when
        the run ends; a role assignment does not, and it changes who can reach
        the scoped resources long after this study is forgotten. So the two
        decisions are separated: this function previews with --what-if and, if
        grants are needed, returns approvalRequired without changing anything.
        The caller surfaces the exact approval phrase and stops. Only a
        subsequent call carrying that phrase applies the grants.

        When grants are applied, role assignments are snapshotted either side of
        the repair so the study records what was actually created rather than
        what the service was asked to create, and each new assignment is written
        to the residue ledger with the command that removes it.

        This does not decide whether to execute. Assert-ChaosConfigurationValidated
        is the gate, and Start-ChaosStudyScenarioRun applies it again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath,
        [AllowNull()][AllowEmptyString()][string]$PermissionApproval,
        [AllowNull()][AllowEmptyString()][string]$ExpectedGrantSetHash
    )

    $validation = Get-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $ConfigurationName -Adapter $Adapter -StudyPath $StudyPath
    $status = Get-ChaosValidationStatus -Validation $validation

    if ($status -eq 'Succeeded') {
        return [pscustomobject]@{
            validation       = $validation
            status           = $status
            permissionFix    = $null
            approvalRequired = $false
            approvalPhrase   = $null
            grantSet         = $null
        }
    }

    $statusText = if ($status) { $status } else { 'no status' }
    $before = [ordered]@{
        status = $status
        errors = @(Get-ChaosValidationError -Validation $validation)
    }

    if (-not (Test-ChaosValidationRepairable -Validation $validation)) {
        return [pscustomobject]@{
            validation = $validation; status = $status; permissionFix = $null
            approvalRequired = $false; approvalPhrase = $null; grantSet = $null
        }
    }

    Write-ChaosStudyNote -Message "Validation reported '$statusText'. Asking Chaos Studio which role assignments are missing." -Level 'warn'

    $preview = Repair-ChaosConfigurationPermission -Plan $Plan -ConfigurationName $ConfigurationName -WhatIf -Adapter $Adapter -StudyPath $StudyPath
    $previewSummary = Get-ChaosPermissionFixSummary -FixResult $preview
    $applicable = Test-ChaosPermissionFixApplicable -FixResult $preview
    $grant = Get-ChaosPermissionGrantSet -Plan $Plan -ConfigurationName $ConfigurationName -FixResult $preview

    $permissionFix = [ordered]@{
        attempted        = $true
        applicable       = [bool]$applicable
        preview          = $previewSummary
        grantSet         = $grant.grantSet
        grantSetHash     = if ($applicable) { $grant.hash } else { $null }
        grantDetails     = $grant.details
        approved         = $false
        approvalPhrase   = $null
        applied          = $null
        grantsObserved   = $null
        validationBefore = $before
        validationAfter  = $null
    }

    if (-not $applicable) {
        # The service named nothing to grant. Widening access on the strength of
        # a result that reported nothing would be inventing a reason to change
        # RBAC, so nothing happens and the gate below refuses the run.
        Write-ChaosStudyCard -Title 'Validation failed and no grants were named' -Body @"
Validation reported '$statusText'. Chaos Studio was asked which role assignments
are missing and named none, so nothing has been changed.

$(Format-ChaosPermissionFixSummary -Summary $previewSummary)

The validation gate will refuse this run.
"@
        $permissionFix.validationAfter = $before
        return [pscustomobject]@{
            validation       = $validation
            status           = $status
            permissionFix    = $permissionFix
            approvalRequired = $false
            approvalPhrase   = $null
            grantSet         = $grant.grantSet
        }
    }

    $phrase = Get-ChaosPermissionApprovalPhrase -Plan $Plan -GrantSetHash $grant.hash
    $permissionFix.approvalPhrase = $phrase

    if (($ExpectedGrantSetHash -and $ExpectedGrantSetHash -ne $grant.hash) -or
        -not (Test-ChaosPermissionApproval -Plan $Plan -GrantSetHash $grant.hash -Approval $PermissionApproval)) {
        # Not approved. Nothing is granted, and the caller decides how to stop.
        $permissionFix.validationAfter = $before
        return [pscustomobject]@{
            validation       = $validation
            status           = $status
            permissionFix    = $permissionFix
            approvalRequired = $true
            approvalPhrase   = $phrase
            grantSet         = $grant.grantSet
        }
    }

    Write-ChaosStudyNote -Message 'Permission approval accepted. Applying the role assignments Chaos Studio reported as missing.' -Level 'warn'

    $scope = if ($Plan.workspace.PSObject.Properties.Name -contains 'id') { [string]$Plan.workspace.id } else { $null }
    $beforeAssignments = Get-ChaosRoleAssignmentSnapshot -Scope $scope -Adapter $Adapter -StudyPath $StudyPath

    $applied = Repair-ChaosConfigurationPermission -Plan $Plan -ConfigurationName $ConfigurationName -Adapter $Adapter -StudyPath $StudyPath
    $appliedSummary = Get-ChaosPermissionFixSummary -FixResult $applied
    $permissionFix.approved = $true
    $permissionFix.applied = $appliedSummary

    if ($null -ne $appliedSummary) {
        if ($appliedSummary.whatIfMode -eq $true) {
            # The fix was requested without --what-if, so this means the service
            # previewed instead of acting and nothing was granted.
            Write-ChaosStudyNote -Message 'Chaos Studio reported whatIfMode on an applied fix, so no role assignments were actually created.' -Level 'warn'
        }
        $failedCount = 0
        if ($null -ne $appliedSummary.failed -and [int]::TryParse([string]$appliedSummary.failed, [ref]$failedCount) -and $failedCount -gt 0) {
            Write-ChaosStudyNote -Message "$failedCount role assignment(s) could not be created; the workspace identity may lack roleAssignments/write on the scope." -Level 'warn'
        }
    }

    $afterAssignments = Get-ChaosRoleAssignmentSnapshot -Scope $scope -Adapter $Adapter -StudyPath $StudyPath
    $created = Get-ChaosRoleAssignmentDelta -Before $beforeAssignments -After $afterAssignments
    # A null element here would become a grant we claim to have created but cannot
    # name - the residue ledger must never carry an entry it cannot point at.
    if ($null -ne $created) { $created = @($created | Where-Object { $null -ne $_ }) }
    $permissionFix.grantsObserved = if ($null -eq $created) { $null } else { @($created | ForEach-Object { [string]$_.id }) }

    if ($null -ne $created -and -not [string]::IsNullOrWhiteSpace($StudyPath)) {
        foreach ($assignment in @($created)) {
            $props = if ($assignment.PSObject.Properties.Name -contains 'properties') { $assignment.properties } else { $assignment }
            Add-ChaosRoleAssignmentResidueEntry -StudyPath $StudyPath -AssignmentId ([string]$assignment.id) `
                -RoleDefinitionId $(if ($props -and $props.PSObject.Properties.Name -contains 'roleDefinitionId') { [string]$props.roleDefinitionId } else { $null }) `
                -PrincipalId $(if ($props -and $props.PSObject.Properties.Name -contains 'principalId') { [string]$props.principalId } else { $null }) `
                -Scope $scope -Adapter $Adapter -ApprovalPhrase $phrase | Out-Null
        }
    }

    # Re-validation is a read. If RBAC has not propagated yet this reports a
    # failure and the gate refuses the run - which is correct. Retrying the read
    # is safe; retrying the grant would create duplicate assignments to work
    # around a delay that is not this study's to fix.
    Write-ChaosStudyNote -Message 'Re-validating the configuration after the permission repair.'
    $validation = Get-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $ConfigurationName -Adapter $Adapter -StudyPath $StudyPath
    $status = Get-ChaosValidationStatus -Validation $validation

    $permissionFix.validationAfter = [ordered]@{
        status = $status
        errors = @(Get-ChaosValidationError -Validation $validation)
    }

    return [pscustomobject]@{
        validation       = $validation
        status           = $status
        permissionFix    = $permissionFix
        approvalRequired = $false
        approvalPhrase   = $phrase
        grantSet         = $grant.grantSet
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

        PermissionFix describes operations actually attempted before this gate.
        Error messages mentioning RBAC do not prove a permission repair ran.
    #>
    param(
        [AllowNull()][object]$Validation,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][object]$PermissionFix
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

    $attempted = (Get-ChaosMember -InputObject $PermissionFix -Name attempted) -eq $true
    $authoritative = (Get-ChaosMember -InputObject $PermissionFix -Name applicable) -eq $true -and
        -not [string]::IsNullOrWhiteSpace([string](Get-ChaosMember -InputObject $PermissionFix -Name grantSetHash))
    $applied = Get-ChaosMember -InputObject $PermissionFix -Name applied
    $grantsApplied = $attempted -and $authoritative -and
        (Get-ChaosMember -InputObject $PermissionFix -Name approved) -eq $true -and
        (Get-ChaosMember -InputObject $applied -Name whatIfMode) -eq $false -and
        (Get-ChaosMember -InputObject $applied -Name succeeded) -gt 0
    $correlation = Get-ChaosMember -InputObject $Validation -Name correlationId
    if (-not $correlation) { $correlation = Get-ChaosMember -InputObject (Get-ChaosMember -InputObject $Validation -Name properties) -Name correlationId }
    $correlationText = if ($correlation) { "correlation $correlation" } else { 'the captured request diagnostics (the response did not report a correlation id)' }
    $remediation = if ($grantsApplied) {
        'Chaos Studio already previewed and applied the grants it reported as missing, and validation still failed. Role assignments can take a few minutes to propagate, so retrying often succeeds; if it does not, grant the workspace identity the roles named above manually, or ask someone with User Access Administrator on the scope to run az chaos scenario config fix-permissions.'
    } elseif (-not $attempted -and -not (Test-ChaosValidationRepairable -Validation $Validation)) {
        "Validation failed with a non-repairable service error; no permission changes were attempted. Retry later or escalate with $correlationText. Do not use permission repair to work around a service error."
    } elseif (-not $attempted) {
        'No permission changes were attempted. Obtain an authoritative permission preview and fresh human approval before applying grants.'
    } elseif (-not $authoritative) {
        'The permission preview was not authoritative; no permission changes were applied. Obtain a complete what-if result before requesting approval.'
    } elseif ((Get-ChaosMember -InputObject $PermissionFix -Name approved) -eq $true) {
        "Permission repair was attempted, but application of grants was not confirmed. Inspect the recorded permission-fix result and escalate with $correlationText."
    } else {
        'Only a permission preview was obtained; no permission changes were applied. Review the exact grants and request fresh human approval.'
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

# -- Preflight reuse + effective-plan equality (Req C) ---------------------
#
# Scope validated a deterministic preflight configuration and froze the exact
# effective plan (which legs run) into the study plan. A run must either reuse
# that same validated configuration, or - if it has to re-create one - prove the
# re-created configuration's effective plan is identical before it may start.
# Either way, what executes is provably what was scoped and consented to, not a
# configuration that quietly drifted between scope and run.

function Get-ChaosRunEffectivePlanHash {
    <#
    .SYNOPSIS
        Recompute the stable effective-plan hash from a validation result, in
        the exact shape scope froze: total legs, executable count, and the sorted
        selectors of the legs that will not run.

    .DESCRIPTION
        The hash is deliberately over the STABLE parts of the plan - counts and
        leg selectors - not the platform's free-text skip reasons, which can
        vary run to run for the same effective plan. Equality therefore means
        "the same legs execute", which is what a run must guarantee, rather than
        "the service worded its reasons identically".

        Scope and run share ExecutionPlan.ps1 for parsing, skip signals and
        selector identity, including live executionPlanJson and legacy shapes.
    #>
    param([AllowNull()][object]$Validation)

    $legs = @(Get-ChaosExecutionPlanLegs -ExecutionPlan $Validation)

    $skippedSelectors = @()
    $executable = 0
    foreach ($leg in $legs) {
        $selector = Get-ChaosLegSelectorText -Leg $leg
        $isSkipped = Test-ChaosLegSkipped -Leg $leg
        if ($isSkipped) { $skippedSelectors += $selector } else { $executable++ }
    }

    $projection = [ordered]@{
        total      = @($legs).Count
        executable = $executable
        skipped    = @(@($skippedSelectors) | Sort-Object)
    }
    return Get-ChaosDigest -InputObject $projection
}

function Assert-ChaosEffectivePlanEquality {
    <#
    .SYNOPSIS
        Refuse to run a re-created configuration whose effective plan differs
        from the one scope froze and the operator consented to.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Expected,
        [AllowNull()][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory)][string]$ConfigurationName
    )

    # Fail closed on an absent hash on either side: a missing hash is not proof
    # of equality, and two empty strings must never pass this gate vacuously.
    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) {
        Write-ChaosStudyFailure -Title 'The effective-plan equality proof is missing a hash' -Message @"
Proving the re-created configuration '$ConfigurationName' matches the scoped plan
requires both the frozen effective-plan hash and the one recomputed for this run,
but at least one is empty. Without both, equality cannot be proven, so the run
stops rather than proceeding on an unverified plan.
"@ -Remediation 'Re-run chaos-study-scope to produce a plan that carries a frozen effective-plan hash, then run against that plan.'
        exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
    }

    if ($Expected -eq $Actual) { return $true }

    Write-ChaosStudyFailure -Title 'The re-created configuration does not match the scoped plan' -Message @"
Scope froze an effective plan hashing to $Expected, but the configuration
'$ConfigurationName' re-created for this run has an effective plan hashing to
$Actual.

Consent is bound to the legs scope validated. Because a different set of legs
would now run, executing this configuration would inject something other than
what was scoped and consented to, so the run stops here.
"@ -Remediation 'Re-run chaos-study-scope to produce a fresh plan whose effective legs match the scope you intend to run, then consent to that plan.'
    exit (Get-ChaosStudyExitCode -Name 'ScopeUnverified')
}

function Resolve-ChaosRunConfiguration {
    <#
    .SYNOPSIS
        Provide a validated configuration to run: reuse the exact validated
        preflight configuration when it still matches, otherwise re-create one
        and prove its effective plan equals the scoped one before validating it.

    .DESCRIPTION
        Reuse is preferred because the preflight configuration is the one scope
        actually validated; reusing it removes any chance of drift between scope
        and run. Reuse is allowed only when the preflight configuration still
        validates Succeeded and its effective plan still hashes to the frozen
        value. Otherwise the run re-creates its own configuration, asserts exact
        effective-plan equality against the frozen hash, and revalidates before
        returning. When the plan carries no frozen effective plan (e.g. discovery
        was skipped at scope time) this falls back to the historical create +
        validate path unchanged.

        Returns { configurationName; validation; status; permissionFix; reused;
        approvalRequired; approvalPhrase; grantSet }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath,
        [AllowNull()][AllowEmptyString()][string]$PermissionApproval,
        [AllowNull()][AllowEmptyString()][string]$ExpectedGrantSetHash
    )

    $dve = $null
    if (($Plan.PSObject.Properties.Name -contains 'declaredVsEffective') -and $null -ne $Plan.declaredVsEffective) {
        $dve = $Plan.declaredVsEffective
    }
    $frozenHash = if ($dve -and ($dve.PSObject.Properties.Name -contains 'effectivePlanHash')) { [string]$dve.effectivePlanHash } else { $null }
    $preflightName = if ($dve -and $dve.preflight -and ($dve.preflight.PSObject.Properties.Name -contains 'configurationName')) { [string]$dve.preflight.configurationName } else { $null }

    # 1. Reuse the exact validated preflight configuration when it still holds.
    if (-not [string]::IsNullOrWhiteSpace($preflightName) -and -not [string]::IsNullOrWhiteSpace($frozenHash)) {
        $preflightValidation = Get-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $preflightName -Adapter $Adapter -StudyPath $StudyPath
        $preflightStatus = Get-ChaosValidationStatus -Validation $preflightValidation
        if ($preflightStatus -eq 'Succeeded') {
            $preflightHash = Get-ChaosRunEffectivePlanHash -Validation $preflightValidation
            if ($preflightHash -eq $frozenHash) {
                Write-ChaosStudyNote -Message "Reusing the validated preflight configuration $preflightName; its effective plan still matches the scoped one."
                return [pscustomobject]@{
                    configurationName = $preflightName
                    validation        = $preflightValidation
                    status            = $preflightStatus
                    permissionFix     = $null
                    reused            = $true
                    approvalRequired  = $false
                    approvalPhrase    = $null
                    grantSet          = $null
                }
            }
            Write-ChaosStudyNote -Message "The preflight configuration $preflightName no longer matches the scoped effective plan; re-creating a fresh configuration." -Level 'warn'
        }
        else {
            Write-ChaosStudyNote -Message "The preflight configuration $preflightName is not reusable (validation '$preflightStatus'); re-creating a fresh configuration." -Level 'warn'
        }
    }

    # 2. Re-create, prove effective-plan equality when a plan was frozen, then return.
    New-ChaosStudyConfiguration -Plan $Plan -ConfigurationName $ConfigurationName -Adapter $Adapter -StudyPath $StudyPath | Out-Null
    $resolved = Resolve-ChaosConfigurationValidation -Plan $Plan -ConfigurationName $ConfigurationName -Adapter $Adapter -StudyPath $StudyPath -PermissionApproval $PermissionApproval -ExpectedGrantSetHash $ExpectedGrantSetHash

    if ($resolved.approvalRequired) {
        # Grants are needed and have not been approved. Return before proving
        # effective-plan equality: the configuration validated for want of access,
        # so its effective plan is not evidence of drift and reporting it as such
        # would bury the real reason under a misleading one.
        return [pscustomobject]@{
            configurationName = $ConfigurationName
            validation        = $resolved.validation
            status            = $resolved.status
            permissionFix     = $resolved.permissionFix
            reused            = $false
            approvalRequired  = $true
            approvalPhrase    = $resolved.approvalPhrase
            grantSet          = $resolved.grantSet
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($frozenHash)) {
        # $resolved.validation is the object equality is proved over. Equality is
        # proved here - rather than after a re-fetch - so the returned plan is
        # identical to the one the proof covered, and to avoid a redundant
        # validate/show round-trip on every re-created run. When no plan was frozen
        # (discovery skipped at scope time) this proof is skipped and the historical
        # create + validate result is returned unchanged.
        $actualHash = Get-ChaosRunEffectivePlanHash -Validation $resolved.validation
        Assert-ChaosEffectivePlanEquality -Expected $frozenHash -Actual $actualHash -ConfigurationName $ConfigurationName | Out-Null
    }

    return [pscustomobject]@{
        configurationName = $ConfigurationName
        validation        = $resolved.validation
        status            = $resolved.status
        permissionFix     = $resolved.permissionFix
        reused            = $false
        approvalRequired  = $false
        approvalPhrase    = $resolved.approvalPhrase
        grantSet          = $resolved.grantSet
    }
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
        [Parameter(Mandatory)][AllowNull()][object]$Validation,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    Assert-ChaosConfigurationValidated -Validation $Validation -ConfigurationName $ConfigurationName | Out-Null

    $started = Invoke-ChaosStudyOperation -Kind 'run.start' -Arguments @{ cliArgs = @(
        '-g', $Plan.workspace.resourceGroup, '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name, '--scenario-name', $Plan.scenario.name,
        '--config-name', $ConfigurationName
    ) } -ExpectedSchema 'run.v1' -Adapter (Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter) `
        -StudyPath $StudyPath -OperationHint 'scenario run start'

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
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    return Invoke-ChaosStudyOperation -Kind 'run.show' -Arguments @{ cliArgs = @(
        '-n', $RunId, '-g', $Plan.workspace.resourceGroup, '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name, '--scenario-name', $Plan.scenario.name
    ) } -ExpectedSchema 'any.v1' -Adapter (Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter) `
        -StudyPath $StudyPath -OperationHint 'scenario run show'
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
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    return Invoke-ChaosStudyOperation -Kind 'run.cancel' -Arguments @{ cliArgs = @(
        '-n', $RunId, '-g', $Plan.workspace.resourceGroup, '--subscription', $Plan.workspace.subscriptionId,
        '--workspace-name', $Plan.workspace.name, '--scenario-name', $Plan.scenario.name
    ) } -ExpectedSchema 'any.v1' -Adapter (Get-ChaosExecutionAdapter -Plan $Plan -Adapter $Adapter) `
        -StudyPath $StudyPath -OperationHint 'scenario run cancel'
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

function Get-ChaosActionWindow {
    <#
    .SYNOPSIS
        When was the action actually live? Not when we were watching.

    .DESCRIPTION
        The configured duration is a budget, not a measurement, and the two
        coincide only for a continuous action that ran the whole window. For a
        discrete action the fault is an instant somewhere inside the window;
        labelling the whole window "action active" would inflate the exposure
        by minutes and let a study claim a resilience it never tested.

        So the window is derived, in order of preference, from what the service
        reported:

          continuous  the run's own start/end interval, else the per-leg times,
                      else - only as a last resort - the interval we observed,
                      marked approximate.
          discrete    the per-leg action times and nothing else. With no per-leg
                      times the window is unknown, and unknown is recorded as
                      unknown. The configured duration is never substituted.

        An unrecognised actionType is treated as discrete, because that is the
        assumption that cannot overstate what was tested.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Observation,
        [AllowNull()][AllowEmptyString()][string]$ActionType,
        [AllowNull()][object]$ObservationWindow
    )

    $continuous = Test-ChaosActionIsContinuous -ActionType $ActionType

    $window = [ordered]@{
        actionType = if ([string]::IsNullOrWhiteSpace($ActionType)) { $null } else { [string]$ActionType }
        continuous = $continuous
        startUtc   = $null
        endUtc     = $null
        source     = $null
        timing     = 'unknown'
        legsTotal  = 0
        legsTimed  = 0
        detail     = $null
    }

    # -- per-leg times ---------------------------------------------------
    $legStarts = @()
    $legEnds = @()
    $legsTotal = 0
    $legsFullyTimed = 0
    $obsActions = Get-ChaosMember -InputObject $Observation -Name 'actions'
    if ($null -ne $obsActions) {
        foreach ($leg in @($obsActions | Where-Object { $null -ne $_ })) {
            if ($null -eq $leg) { continue }
            $legsTotal++
            $s = ConvertFrom-ChaosUtcIsoOrNull -Text ([string]$leg.startedAt)
            $e = ConvertFrom-ChaosUtcIsoOrNull -Text ([string]$leg.completedAt)
            if ($null -ne $s) { $legStarts += $s }
            if ($null -ne $e) { $legEnds += $e }
            if ($null -ne $s -and $null -ne $e) { $legsFullyTimed++ }
        }
    }
    $window['legsTotal'] = $legsTotal
    $window['legsTimed'] = $legsFullyTimed

    $legStart = if ($legStarts.Count -gt 0) { ($legStarts | Sort-Object)[0] } else { $null }
    $legEnd = if ($legEnds.Count -gt 0) { ($legEnds | Sort-Object)[-1] } else { $null }

    # -- run interval ----------------------------------------------------
    $runStart = $null
    $runEnd = $null
    if ($null -ne $Observation) {
        $runStart = ConvertFrom-ChaosUtcIsoOrNull -Text ([string](Get-ChaosMember -InputObject $Observation -Name 'startedAt'))
        $runEnd = ConvertFrom-ChaosUtcIsoOrNull -Text ([string](Get-ChaosMember -InputObject $Observation -Name 'completedAt'))
    }

    $set = {
        param($start, $end, $source, $timing, $detail)
        $window['startUtc'] = if ($null -ne $start) { ConvertTo-ChaosUtcIso -Instant $start } else { $null }
        $window['endUtc'] = if ($null -ne $end) { ConvertTo-ChaosUtcIso -Instant $end } else { $null }
        $window['source'] = $source
        $window['timing'] = $timing
        $window['detail'] = $detail
        return [pscustomobject]$window
    }

    if ($continuous -eq $true) {
        if ($null -ne $runStart -and $null -ne $runEnd) {
            return & $set $runStart $runEnd 'run' 'exact' "The action is continuous, so it was live for the whole scenario run interval the service reported."
        }
        if ($null -ne $legStart -and $null -ne $legEnd) {
            return & $set $legStart $legEnd 'perLeg' 'exact' "The action is continuous and the service reported per-leg start and completion times; the window spans them."
        }
        if ($null -ne $ObservationWindow) {
            return & $set (ConvertFrom-ChaosUtcIsoOrNull -Text ([string]$ObservationWindow.startUtc)) (ConvertFrom-ChaosUtcIsoOrNull -Text ([string]$ObservationWindow.endUtc)) 'observation' 'approximate' "The service reported no run or per-leg times, so the interval we observed stands in for the action window. It includes the time taken to start and cancel the run."
        }
        return & $set $null $null $null 'unknown' 'The action is continuous but neither the service nor the local observation supplied an interval.'
    }

    # Discrete, or an actionType we do not recognise. Either way the configured
    # duration is not evidence of anything, so it is not used.
    $kindText = if ($continuous -eq $false) { 'discrete' } else { "of an unrecognised type ('$ActionType'), so it is treated as discrete" }

    if ($null -ne $legStart) {
        $end = if ($null -ne $legEnd) { $legEnd } else { $legStart }
        $timing = if ($legsFullyTimed -eq $legsTotal -and $legsTotal -gt 0) { 'exact' } else { 'approximate' }
        $detail = if ($timing -eq 'exact') {
            "The action is $kindText; the window spans the per-leg start and completion times the service reported for all $legsTotal leg(s)."
        }
        else {
            "The action is $kindText; only $legsFullyTimed of $legsTotal leg(s) reported both a start and a completion, so the window is approximate."
        }
        return & $set $legStart $end 'perLeg' $timing $detail
    }

    return & $set $null $null $null 'unknown' "The action is $kindText and the service reported no per-leg times, so when it was actually applied is unknown. The configured duration is an observation budget and is deliberately not substituted for it."
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
        [ValidateRange(1, [int]::MaxValue)][int]$PollSeconds = 20,
        [scriptblock]$OnPoll,
        [scriptblock]$OnAbortCheck,
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )

    $deadline = $InjectionStartedAt.AddMinutes($Minutes)
    $last = $null
    $terminal = $false
    $abort = $null
    $abortChecks = @()
    $lookbackSeconds = $null
    if ($OnAbortCheck) {
        $lookbackSeconds = ($Plan.safety.abortConditions | Where-Object { $_.kind -eq 'missing-signal' } |
            ForEach-Object { [int]$_.intervalSeconds * [int]$_.unavailableIntervals } | Measure-Object -Maximum).Maximum
        if ($null -eq $lookbackSeconds -or $lookbackSeconds -le 0) {
            throw 'Live abort polling requires a positive frozen missing-signal window.'
        }
    }

    while ([datetime]::UtcNow -lt $deadline) {
        $last = Get-ChaosStudyScenarioRun -Plan $Plan -RunId $RunId -Adapter $Adapter -StudyPath $StudyPath
        $status = Get-ChaosScenarioRunStatus -Run $last
        if ($OnPoll) { & $OnPoll $status }
        if (Test-ChaosScenarioRunTerminal -Status $status) { $terminal = $true; break }

        $checkedAt = ConvertFrom-ChaosUtcIso -Text (Get-ChaosUtcNow)
        if ($OnAbortCheck) {
            # Poll cadence is not metric resolution. Query the frozen trailing
            # telemetry window so minute buckets and ingestion lag are included.
            $window = New-ChaosWindow -Name abort-check -Start $checkedAt.AddSeconds(-$lookbackSeconds) -End $checkedAt
            $check = & $OnAbortCheck $window
            if ($null -eq $check) { throw 'Live abort evaluation returned no result; injection cannot continue unmonitored.' }
            $abortChecks += $check
            if ($check.triggered) {
                $abort = $check.trigger
                break
            }
        }

        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Ceiling($remaining)))
    }

    if (-not $terminal -and $null -eq $last) {
        $last = Get-ChaosStudyScenarioRun -Plan $Plan -RunId $RunId -Adapter $Adapter -StudyPath $StudyPath
    }

    return [pscustomobject]@{
        run              = $last
        endedEarly       = $terminal
        observedAt       = Get-ChaosUtcNow
        abort            = $abort
        abortChecks      = $abortChecks
    }
}
