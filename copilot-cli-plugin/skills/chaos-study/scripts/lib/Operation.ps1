# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    The single operation seam every Azure/Chaos/Monitor call flows through.

.DESCRIPTION
    No study script issues Azure CLI or REST calls directly. They call
    Invoke-ChaosStudyOperation with a normalised, adapter-agnostic
    request, and an explicitly-selected adapter turns that into either an
    in-process Azure call (`local-az`) or a durable pause/resume against an
    external host that owns auth (`external`). There is NEVER an implicit
    fallback between adapters: the adapter is chosen once and, if it cannot be
    initialised, the study stops before it starts.

    This file owns:
      1. The dispatcher (Invoke-ChaosStudyOperation) and adapter selection.
      2. Assert-ChaosAdapterAvailable - the hard stop with remediation.
      3. The result-schema table and Test-ChaosOperationResult, which reject a
         result that does not satisfy the expected shape rather than consuming
         part of it.

    The kind -> adapter-implementation registry (and therefore the only place
    Azure is actually touched) lives in Adapters.ps1.

    Requires Common.ps1 (exit codes, hashing) to be dot-sourced first.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command Get-ChaosStudyExitCode -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}
if (-not (Get-Command Get-ChaosArtifactReader -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Versioning.ps1')
}

# -- Result schema table (FR1) ----------------------------
# Table-driven, lightweight required-field/type checks - one entry per schema
# id an operation can expect. The style deliberately mirrors the
# parametersSchema flattening in ActionDiscovery.ps1: a flat list of
# { name; type; required } rather than a full JSON-Schema validator.
$ChaosOperationResultSchemas = @{
    'workspace.v1'        = @(
        @{ name = 'id'; type = 'string'; required = $true }
        @{ name = 'name'; type = 'string'; required = $true }
    )
    'scenarioList.v1'     = @(
        @{ name = 'value'; type = 'array'; required = $true }
    )
    'resource.v1'         = @(
        @{ name = 'id'; type = 'string'; required = $true }
    )
    'actionList.v1'       = @(
        @{ name = 'value'; type = 'array'; required = $true }
    )
    'configuration.v1'    = @(
        @{ name = 'name'; type = 'string'; required = $true }
    )
    'validation.v1'       = @(
        @{ name = 'status'; type = 'string'; required = $true }
    )
    'validation.v2'       = @(
        @{ name = 'status'; type = 'string'; required = $true }
    )
    'permissionFix.v1'    = @(
        @{ name = 'status'; type = 'string'; required = $false }
    )
    'run.v1'              = @(
        @{ name = 'name'; type = 'string'; required = $true }
    )
    'runStatus.v1'        = @(
        @{ name = 'status'; type = 'string'; required = $false }
    )
    'metrics.v1'          = @(
        @{ name = 'value'; type = 'array'; required = $true }
    )
    'logs.v1'             = @(
        @{ name = 'tables'; type = 'array'; required = $true }
    )
    'auth.v1'             = @(
        @{ name = 'id'; type = 'string'; required = $false }
    )
    # A permissive schema for operations whose result is only checked for
    # presence. It requires nothing, but it must still be a declared schema id
    # so a typo in -ExpectedSchema can never silently pass.
    'any.v1'              = @()
}

function Get-ChaosOperationResultSchema {
    <#
    .SYNOPSIS
        Resolve a result-schema definition by id. Unknown ids fail loudly so a
        typo can never silently accept an unvalidated result.
    #>
    param([Parameter(Mandatory)][string]$Schema)
    if (-not $ChaosOperationResultSchemas.ContainsKey($Schema)) {
        throw "Unknown operation result schema '$Schema'. Known: $(($ChaosOperationResultSchemas.Keys | Sort-Object) -join ', ')"
    }
    return $ChaosOperationResultSchemas[$Schema]
}

function ConvertTo-ChaosOperationResult {
    param([Parameter(Mandatory)][string]$Schema, [AllowNull()][object]$Result)
    if ($Schema -ne 'validation.v2') { return $Result }
    $normalized = [ordered]@{}
    foreach ($container in @($Result, (Get-ChaosMember -InputObject $Result -Name properties))) {
        if ($null -eq $container) { continue }
        $names = if ($container -is [System.Collections.IDictionary]) { @($container.Keys) } else { @($container.PSObject.Properties.Name) }
        foreach ($name in $names) {
            if ($name -eq 'properties') { continue }
            if ($container -is [System.Collections.IDictionary]) { $value = $container[$name] }
            else { $value = $container.$name }
            if ($name -eq 'status' -and ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value))) { continue }
            $normalized[$name] = $value
        }
    }
    if (-not $normalized.Contains('status')) {
        throw "ValidationFailed: validation.v2 requires a nonempty string status at status or properties.status. Response: $(ConvertTo-ChaosCanonicalJson -InputObject $Result)"
    }
    return [pscustomobject]$normalized
}

function Test-ChaosOperationResultType {
    <#
    .SYNOPSIS
        Loose type check for a single field value against a schema type name.
    #>
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][string]$Type)
    switch ($Type) {
        'string' { return ($Value -is [string]) }
        'number' { return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) }
        'bool'   { return ($Value -is [bool]) }
        'array'  { return (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) }
        'object' { return ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary]) }
        default  { return $true }
    }
}

function Test-ChaosOperationResult {
    <#
    .SYNOPSIS
        Validate an operation result against an expected schema id. A result
        that fails is REJECTED whole - never partially consumed.

    .DESCRIPTION
        Returns { ok; schema; problems }. The caller decides whether to throw;
        the seam always throws on a failed local-az result and refuses to
        ingest a failed external result, so a malformed result can never reach
        the study as if it were real evidence.
    #>
    param(
        [Parameter(Mandatory)][string]$Schema,
        [Parameter(Mandatory)][AllowNull()][object]$Result
    )
    $definition = Get-ChaosOperationResultSchema -Schema $Schema
    $problems = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Result) {
        if (@($definition | Where-Object { $_.required }).Count -gt 0) {
            $problems.Add("result is null but schema '$Schema' requires fields")
        }
        return [pscustomobject]@{ ok = ($problems.Count -eq 0); schema = $Schema; problems = @($problems) }
    }

    foreach ($field in $definition) {
        $has = $false
        $value = $null
        if ($Result -is [System.Collections.IDictionary]) {
            $has = $Result.Contains($field.name)
            if ($has) { $value = $Result[$field.name] }
        } elseif ($Result -is [pscustomobject]) {
            $has = ($Result.PSObject.Properties.Name -contains $field.name)
            if ($has) { $value = $Result.$($field.name) }
        }

        if (-not $has) {
            if ($field.required) { $problems.Add("missing required field '$($field.name)'") }
            continue
        }
        if ($null -eq $value) {
            if ($field.required) { $problems.Add("required field '$($field.name)' is null") }
            continue
        }
        if (-not (Test-ChaosOperationResultType -Value $value -Type $field.type)) {
            $problems.Add("field '$($field.name)' must be of type '$($field.type)'")
        }
    }

    return [pscustomobject]@{ ok = ($problems.Count -eq 0); schema = $Schema; problems = @($problems) }
}

# -- Adapter availability (hard stop, no fallback) --------
$ChaosStudyAdapters = @('local-az', 'external')

function Assert-ChaosAdapterAvailable {
    <#
    .SYNOPSIS
        Verify a selected adapter can be initialised. Throws a tagged
        AdapterUnavailable error (map -> exit 22) with remediation when it
        cannot. There is no fallback to the other adapter - by design a study
        must not silently change how it reaches Azure.

    .DESCRIPTION
        local-az needs the shipped Azure helpers and the Azure CLI on PATH;
        the readiness probe lives in Adapters.ps1. external needs a study path to
        persist the durable request/result exchange under. An unknown adapter
        name is itself an AdapterUnavailable condition.
    #>
    param(
        [Parameter(Mandatory)][string]$Adapter,
        [string]$StudyPath
    )
    if ($Adapter -notin $ChaosStudyAdapters) {
        $remediation = "Select a supported adapter: $($ChaosStudyAdapters -join ', ')."
        Write-ChaosStudyFailure -Title 'Adapter unavailable' -Message "Unknown operation adapter '$Adapter'." -Remediation $remediation
        throw "AdapterUnavailable: unknown adapter '$Adapter'. $remediation"
    }

    if ($Adapter -eq 'local-az') {
        $missing = @(Test-ChaosLocalAzAdapterReady)
        if ($missing.Count -gt 0) {
            $remediation = "Install the Azure CLI and sign in with az login, or select the 'external' adapter so a host can broker Azure access."
            Write-ChaosStudyFailure -Title 'Adapter unavailable' -Message "The 'local-az' adapter cannot initialise: missing $($missing -join ', ')." -Remediation $remediation
            throw "AdapterUnavailable: local-az missing $($missing -join ', '). $remediation"
        }
    }

    if ($Adapter -eq 'external') {
        if ([string]::IsNullOrWhiteSpace($StudyPath)) {
            $remediation = "Provide -StudyPath so the durable request/result exchange has somewhere to live, or select the 'local-az' adapter."
            Write-ChaosStudyFailure -Title 'Adapter unavailable' -Message "The 'external' adapter needs a study path for its durable operation exchange." -Remediation $remediation
            throw "AdapterUnavailable: external adapter needs a study path. $remediation"
        }
    }

    return $Adapter
}

function Test-ChaosOperationSeamReady {
    <#
    .SYNOPSIS
        Whether operations can be dispatched at all, as a boolean.

    .DESCRIPTION
        Assert-ChaosAdapterAvailable is the hard stop used where an unusable
        adapter must end the study. Some read-only callers instead need to
        degrade - returning an empty list and a recorded caveat rather than
        throwing - and this is the predicate they use. It answers the same
        question with the same rules; it just declines to raise.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Adapter,
        [AllowNull()][AllowEmptyString()][string]$StudyPath
    )
    if ([string]::IsNullOrWhiteSpace($Adapter)) { return $false }
    if (-not (Get-Command Invoke-ChaosStudyOperation -ErrorAction SilentlyContinue)) { return $false }
    if ($Adapter -notin $ChaosStudyAdapters) { return $false }
    if ($Adapter -eq 'external') { return (-not [string]::IsNullOrWhiteSpace($StudyPath)) }

    # local-az: the same readiness probe Assert uses, asked quietly. Assert
    # renders a failure card on its way to throwing, which is right for a hard
    # stop and wrong for a predicate, so the probe is repeated rather than
    # reused.
    return (@(Test-ChaosLocalAzAdapterReady).Count -eq 0)
}

function Resolve-ChaosStudyAdapter {
    <#
    .SYNOPSIS
        Resolve the adapter to use: explicit -Adapter, then -AdapterConfig,
        then the plan-frozen adapter. NEVER an implicit default.
    #>
    param(
        [string]$Adapter,
        [AllowNull()][object]$AdapterConfig,
        [string]$StudyPath
    )
    if (-not [string]::IsNullOrWhiteSpace($Adapter)) { return $Adapter }

    if ($AdapterConfig) {
        $fromConfig = $null
        if ($AdapterConfig -is [System.Collections.IDictionary] -and $AdapterConfig.Contains('adapter')) {
            $fromConfig = [string]$AdapterConfig['adapter']
        } elseif ($AdapterConfig -is [pscustomobject] -and ($AdapterConfig.PSObject.Properties.Name -contains 'adapter')) {
            $fromConfig = [string]$AdapterConfig.adapter
        }
        if (-not [string]::IsNullOrWhiteSpace($fromConfig)) { return $fromConfig }
    }

    if (-not [string]::IsNullOrWhiteSpace($StudyPath)) {
        $reader = Get-ChaosArtifactReader -StudyPath $StudyPath -Artifact 'plan'
        if ($reader.found) {
            $plan = Read-ChaosJsonFile -Path $reader.path
            if ($plan -and ($plan.PSObject.Properties.Name -contains 'adapter') -and $plan.adapter) {
                return [string]$plan.adapter
            }
        }
    }

    return $null
}

# -- Dispatcher -------------------------------------------
function Invoke-ChaosStudyOperation {
    <#
    .SYNOPSIS
        Dispatch a normalised operation through the selected adapter.

    .DESCRIPTION
        -Kind names a registered operation; -Arguments and -Body are the
        adapter-agnostic request; -ExpectedSchema is the result shape the
        caller relies on. The adapter is resolved explicitly (never guessed)
        and asserted available before any work. local-az runs the call in
        process and validates the result; external either returns a previously
        ingested, schema-validated result or pauses the study (exit 18) with a
        durable request for a host to satisfy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Alias('Args')][hashtable]$Arguments = @{},
        [AllowNull()][object]$Body = $null,
        [Parameter(Mandatory)][string]$ExpectedSchema,
        [ValidateSet('local-az', 'external')][string]$Adapter,
        [AllowNull()][object]$AdapterConfig = $null,
        [string]$StudyPath,
        [string]$OperationHint
    )

    $registry = Get-ChaosOperationRegistry
    if (-not $registry.ContainsKey($Kind)) {
        throw "Unknown operation kind '$Kind'. Known: $(($registry.Keys | Sort-Object) -join ', ')"
    }
    # Fail fast on an unknown schema id before any adapter work.
    Get-ChaosOperationResultSchema -Schema $ExpectedSchema | Out-Null

    $selected = Resolve-ChaosStudyAdapter -Adapter $Adapter -AdapterConfig $AdapterConfig -StudyPath $StudyPath
    if ([string]::IsNullOrWhiteSpace($selected)) {
        $remediation = "Pass -Adapter, an -AdapterConfig with an 'adapter' field, or freeze 'adapter' on the study plan."
        Write-ChaosStudyFailure -Title 'Adapter unavailable' -Message "No operation adapter was selected for kind '$Kind'." -Remediation $remediation
        throw "AdapterUnavailable: no adapter selected for kind '$Kind'. $remediation"
    }

    Assert-ChaosAdapterAvailable -Adapter $selected -StudyPath $StudyPath | Out-Null

    switch ($selected) {
        'local-az' {
            $raw = Invoke-ChaosLocalAzOperation -Kind $Kind -Arguments $Arguments -Body $Body
            if ($ExpectedSchema -eq 'validation.v2') { $raw = ConvertTo-ChaosOperationResult -Schema $ExpectedSchema -Result $raw }
            $check = Test-ChaosOperationResult -Schema $ExpectedSchema -Result $raw
            if (-not $check.ok) {
                throw "Operation '$Kind' returned a result that does not satisfy schema '$ExpectedSchema': $($check.problems -join '; ')"
            }
            if ($raw -is [array] -and $raw.Count -eq 0) { return ,$raw }
            return $raw
        }
        'external' {
            return (Invoke-ChaosExternalOperation -Kind $Kind -Arguments $Arguments -Body $Body `
                    -ExpectedSchema $ExpectedSchema -StudyPath $StudyPath -OperationHint $OperationHint)
        }
    }

}

# Load once in the caller's script scope, never inside a dispatch function.
if (-not (Get-Command Get-ChaosOperationRegistry -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Adapters.ps1')
}
