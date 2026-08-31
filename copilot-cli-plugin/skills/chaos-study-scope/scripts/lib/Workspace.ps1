#Requires -Version 7.0
<#
.SYNOPSIS
    Chaos Studio V2 workspace, scope and scenario resolution for a study.

.DESCRIPTION
    In Chaos Studio V2 the workspace is the lifecycle root. It owns the set of
    ARM scopes a study is allowed to touch, it discovers the resources inside
    those scopes, it is the identity the platform acts as, and every scenario,
    scenario configuration and scenario run hangs beneath it.

    A study therefore has to answer four questions before it can plan anything,
    and this file answers them in order:

      1. Which workspace?            az chaos workspace show / create
      2. What is actually in scope?  az chaos discovered-resource list
      3. What can run here?          Microsoft.Chaos/locations/{region}/actions
      4. What will we execute?       az chaos scenario list  (recommended)

    Steps 1, 2 and 4 go through `Invoke-AzChaos`, the shipped `az chaos` seam,
    dot-sourced read-only. Step 3 has no CLI verb and stays on the REST surface
    (see ActionDiscovery.ps1).

    Two properties are load-bearing:

    Reuse over creation. Creating a workspace is a mutation with an identity
    and RBAC consequences, so it never happens implicitly. A caller that has
    not passed -CreateWorkspace gets a hard stop naming the workspace it
    expected, not a new resource it did not ask for.

    Nothing is inferred. Discovered resources, scenarios and their parameter
    specs are read from the service and recorded verbatim. When a lookup
    cannot run, these functions return $null and say why; they never
    substitute a plausible-looking default, because a plan built on a guessed
    scope is a plan that injects somewhere nobody agreed to.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')

# -- Availability ----------------------------------------------------------

function Test-ChaosCliAvailable {
    <#
    .SYNOPSIS
        Whether the `az chaos` seam can be called at all in this process.

    .DESCRIPTION
        Deliberately does not consult `az extension list`: the chaos extension
        is resolvable by `az chaos` while being absent from that query, so
        gating on it produces a false negative that blocks a working install.
        `Invoke-AzChaos` installs or updates the extension itself on first use.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command Invoke-AzChaos -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $false }
    return $true
}

function Get-ChaosWorkspaceId {
    <#
    .SYNOPSIS
        Compose the ARM id of a workspace without calling the service.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName
    )

    return "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Chaos/workspaces/$WorkspaceName"
}

# -- 1. The workspace ------------------------------------------------------

function ConvertTo-ChaosWorkspaceRecord {
    <#
    .SYNOPSIS
        Project a workspace resource into the shape the plan records.

    .DESCRIPTION
        Absent fields stay $null. A workspace with no principal id, for
        instance, has not finished provisioning its identity, and the study
        should be able to report that rather than print an empty string that
        reads like a value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workspace)

    $read = {
        param($container, $name)
        if ($null -eq $container) { return $null }
        if ($container.PSObject.Properties.Name -notcontains $name) { return $null }
        return $container.$name
    }

    $properties = & $read $Workspace 'properties'
    $identity = & $read $Workspace 'identity'

    $scopes = @()
    $rawScopes = & $read $properties 'scopes'
    foreach ($scope in @($rawScopes)) {
        if ($null -eq $scope) { continue }
        $scopes += [string]$scope
    }

    return [pscustomobject]@{
        id                = [string](& $read $Workspace 'id')
        name              = [string](& $read $Workspace 'name')
        location          = [string](& $read $Workspace 'location')
        provisioningState = [string](& $read $properties 'provisioningState')
        identityType      = [string](& $read $identity 'type')
        principalId       = [string](& $read $identity 'principalId')
        scopes            = @($scopes)
    }
}

function Get-ChaosStudyWorkspace {
    <#
    .SYNOPSIS
        Read an existing workspace. Returns $null when it does not exist.

    .DESCRIPTION
        A missing workspace is an ordinary, expected answer here - the caller
        decides whether that is a hard stop or a cue to create one - so this
        returns $null rather than throwing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId
    )

    if (-not (Test-ChaosCliAvailable)) { return $null }

    $chaosArgs = @('workspace', 'show', '--name', $WorkspaceName, '--resource-group', $ResourceGroup)
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $chaosArgs += @('--subscription', $SubscriptionId)
    }

    $response = Invoke-AzChaos -ChaosArgs $chaosArgs -AllowFailure
    if ($null -eq $response) { return $null }
    return ConvertTo-ChaosWorkspaceRecord -Workspace $response
}

function New-ChaosStudyWorkspace {
    <#
    .SYNOPSIS
        Create a workspace over an explicit set of ARM scopes.

    .DESCRIPTION
        Scopes are validated as ARM ids before the call. A malformed scope is
        accepted by nothing downstream and the resulting failure is opaque, so
        it is caught here where the message can name the offending string.

        The workspace is created with a system-assigned identity by default.
        That identity is what the platform later needs Reader (and action
        roles) on; `chaos-study-run` surfaces those grants explicitly rather
        than assigning them behind the operator's back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Scopes,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId,
        [AllowNull()][AllowEmptyString()][string]$UserAssignedIdentityId
    )

    if (-not (Test-ChaosCliAvailable)) {
        throw 'Cannot create a Chaos workspace: the az chaos seam is unavailable in this process.'
    }
    if (@($Scopes).Count -eq 0) {
        throw 'Cannot create a Chaos workspace with no scopes. A workspace with no scopes discovers nothing and can run nothing.'
    }

    foreach ($scope in $Scopes) {
        if ($scope -notmatch '^/subscriptions/[^/]+') {
            throw "Scope '$scope' is not an ARM resource id. Expected something starting /subscriptions/{id}/..."
        }
    }

    $chaosArgs = @(
        'workspace', 'create',
        '--resource-group', $ResourceGroup,
        '--workspace-name', $WorkspaceName,
        '--location', $Location,
        '--scopes'
    ) + @($Scopes)

    if (-not [string]::IsNullOrWhiteSpace($UserAssignedIdentityId)) {
        $chaosArgs += @('--mi-user-assigned', $UserAssignedIdentityId)
    } else {
        $chaosArgs += @('--mi-system-assigned', '')
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $chaosArgs += @('--subscription', $SubscriptionId)
    }

    $response = Invoke-AzChaos -ChaosArgs $chaosArgs
    if ($null -eq $response) {
        throw "Workspace '$WorkspaceName' creation returned no resource."
    }

    $record = ConvertTo-ChaosWorkspaceRecord -Workspace $response
    if ($record.provisioningState -and $record.provisioningState -ne 'Succeeded') {
        throw "Workspace '$WorkspaceName' finished in provisioning state '$($record.provisioningState)'."
    }
    return $record
}

function Resolve-ChaosStudyWorkspace {
    <#
    .SYNOPSIS
        Reuse a workspace, or create one only when explicitly permitted.

    .DESCRIPTION
        The default is reuse. Studies are usually run against a workspace an
        operator already governs, and silently minting a second one splits the
        scope, the identity and the run history across two resources that then
        disagree. -CreateWorkspace is the explicit opt-in to mutate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId,
        [AllowNull()][AllowEmptyString()][string]$Location,
        [AllowNull()][AllowEmptyCollection()][string[]]$Scopes,
        [AllowNull()][AllowEmptyString()][string]$UserAssignedIdentityId,
        [switch]$CreateWorkspace
    )

    $existing = Get-ChaosStudyWorkspace -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName -SubscriptionId $SubscriptionId
    if ($null -ne $existing) {
        return [pscustomobject]@{
            workspace = $existing
            created   = $false
        }
    }

    if (-not $CreateWorkspace) {
        throw "Chaos workspace '$WorkspaceName' was not found in resource group '$ResourceGroup'. Pass -CreateWorkspace with -Location and -Scopes to create it, or point the study at a workspace that already exists."
    }
    if ([string]::IsNullOrWhiteSpace($Location)) {
        throw "Cannot create workspace '$WorkspaceName': -Location is required."
    }

    $created = New-ChaosStudyWorkspace `
        -ResourceGroup $ResourceGroup `
        -WorkspaceName $WorkspaceName `
        -Location $Location `
        -Scopes @($Scopes) `
        -SubscriptionId $SubscriptionId `
        -UserAssignedIdentityId $UserAssignedIdentityId

    return [pscustomobject]@{
        workspace = $created
        created   = $true
    }
}

# -- 2. What is actually in scope -----------------------------------------

function ConvertTo-ChaosScopedResourceRecord {
    <#
    .SYNOPSIS
        Project one discovered resource into the shape the plan records.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Resource)

    $read = {
        param($container, $name)
        if ($null -eq $container) { return $null }
        if ($container.PSObject.Properties.Name -notcontains $name) { return $null }
        return $container.$name
    }

    $properties = & $read $Resource 'properties'

    $zones = @()
    foreach ($zone in @(& $read $properties 'zones')) {
        if ($null -eq $zone) { continue }
        $zones += [string]$zone
    }

    $resourceId = [string](& $read $properties 'resourceId')
    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        $resourceId = [string](& $read $Resource 'id')
    }
    $tags = & $read $properties 'tags'
    if ($null -eq $tags) { $tags = & $read $Resource 'tags' }

    return [pscustomobject]@{
        name         = [string](& $read $Resource 'name')
        resourceId   = $resourceId
        resourceType = [string](& $read $properties 'type')
        location     = [string](& $read $properties 'location')
        zones        = @($zones)
        tags         = $tags
    }
}

function Get-ChaosStudyScopedResource {
    <#
    .SYNOPSIS
        Enumerate the resources the workspace has discovered inside its scopes.

    .DESCRIPTION
        This is the V2 answer to "what will this actually touch". It is read
        from the workspace rather than assembled from the operator's mental
        model, because the two diverge constantly - a scope grows a resource
        nobody remembered, or a resource the plan names is not onboarded and
        would have been silently skipped at execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId
    )

    if (-not (Test-ChaosCliAvailable)) { return , @() }

    $chaosArgs = @('discovered-resource', 'list', '--resource-group', $ResourceGroup, '--workspace-name', $WorkspaceName)
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $chaosArgs += @('--subscription', $SubscriptionId)
    }

    $response = Invoke-AzChaos -ChaosArgs $chaosArgs -AllowFailure
    if ($null -eq $response) { return , @() }

    $items = @()
    if ($response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
        $items = @($response)
    } elseif ($response.PSObject.Properties.Name -contains 'value') {
        $items = @($response.value)
    } else {
        $items = @($response)
    }

    $records = @()
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $records += ConvertTo-ChaosScopedResourceRecord -Resource $item
    }
    return , @($records)
}

function Get-ChaosScopeRegion {
    <#
    .SYNOPSIS
        The region the study should query for actions.

    .DESCRIPTION
        Preference order is deliberate: the region of the resources actually in
        scope, then the workspace's own location. A single region is required -
        the actions list is region-scoped, and a study that spans two regions
        cannot honestly claim its plan describes both.

        Returns $null when scope spans more than one region so the caller can
        say so rather than silently studying half of it.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$ScopedResources,
        [AllowNull()][AllowEmptyString()][string]$WorkspaceLocation
    )

    $regions = @(@($ScopedResources) |
        Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.location) } |
        ForEach-Object { $_.location.ToLowerInvariant() } |
        Sort-Object -Unique)

    if ($regions.Count -eq 1) { return $regions[0] }
    if ($regions.Count -gt 1) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceLocation)) {
        return $WorkspaceLocation.ToLowerInvariant()
    }
    return $null
}

# -- 3. Blast radius -------------------------------------------------------

function New-ChaosBlastRadius {
    <#
    .SYNOPSIS
        Build the V2 filters and exclusions that bound what a run may touch.

    .DESCRIPTION
        V2 expresses blast radius declaratively on the scenario configuration:
        filters narrow which discovered resources participate, exclusions
        protect named resources, types or tags outright.

        Both are recorded in the plan and frozen into the plan hash, so an
        execution whose bounds differ from the ones that were reviewed is a
        detectable configuration drift rather than a surprise.

        Filters are emitted only when the caller asked for them. An empty
        filter object is not the same as no filter - `locations: []` selects
        nothing - so this returns $null for "unconstrained" instead of a
        misleading empty shape.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Locations,
        [AllowNull()][AllowEmptyCollection()][string[]]$Zones,
        [AllowNull()][AllowEmptyCollection()][string[]]$PhysicalZones,
        [AllowNull()][AllowEmptyCollection()][string[]]$ExcludeResources,
        [AllowNull()][AllowEmptyCollection()][string[]]$ExcludeTypes,
        [AllowNull()][System.Collections.IDictionary]$ExcludeTags
    )

    $zoneList = @(@($Zones) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $physicalList = @(@($PhysicalZones) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($zoneList.Count -gt 0 -and $physicalList.Count -gt 0) {
        throw 'Zones and physical zones are mutually exclusive on a scenario configuration. Pass one or the other.'
    }
    if ($physicalList.Count -gt 1) {
        throw "Only one physical zone is supported. Received $($physicalList.Count): $($physicalList -join ', ')."
    }
    foreach ($physical in $physicalList) {
        if ($physical -notmatch '^[a-z0-9]+-az[0-9]+$') {
            throw "Physical zone '$physical' is not in the expected {region}-az{n} form, for example 'westus2-az1'."
        }
    }

    $locationList = @(@($Locations) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $filters = $null
    if ($locationList.Count -gt 0 -or $zoneList.Count -gt 0 -or $physicalList.Count -gt 0) {
        $filters = [ordered]@{}
        if ($locationList.Count -gt 0) { $filters['locations'] = @($locationList) }
        if ($zoneList.Count -gt 0) { $filters['zones'] = @($zoneList) }
        if ($physicalList.Count -gt 0) { $filters['physicalZones'] = @($physicalList) }
    }

    $resourceList = @(@($ExcludeResources) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $typeList = @(@($ExcludeTypes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $tagPairs = @()
    if ($null -ne $ExcludeTags) {
        foreach ($key in @($ExcludeTags.Keys | Sort-Object)) {
            if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
            $tagPairs += [ordered]@{ key = [string]$key; value = $ExcludeTags[$key] }
        }
    }

    $exclusions = $null
    if ($resourceList.Count -gt 0 -or $typeList.Count -gt 0 -or $tagPairs.Count -gt 0) {
        $exclusions = [ordered]@{}
        if ($resourceList.Count -gt 0) { $exclusions['resources'] = @($resourceList) }
        if ($typeList.Count -gt 0) { $exclusions['types'] = @($typeList) }
        if ($tagPairs.Count -gt 0) { $exclusions['tags'] = @($tagPairs) }
    }

    return [pscustomobject]@{
        filters    = $filters
        exclusions = $exclusions
    }
}

function Get-ChaosBlastRadiusMember {
    <#
    .SYNOPSIS
        Read one key from a filters/exclusions object regardless of its shape.

    .DESCRIPTION
        Blast radius is an ordered dictionary when it is built, and a
        PSCustomObject after a plan has been written to disk and read back.
        Under Set-StrictMode the wrong accessor throws, so both shapes are
        handled here rather than at every call site.

        Returns $null when the key is absent, which callers read as "not
        constrained on this axis".
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Container,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Container) { return $null }
    if ($Container -is [System.Collections.IDictionary]) {
        if (-not $Container.Contains($Name)) { return $null }
        return $Container[$Name]
    }
    if ($Container.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Container.$Name
}

function Resolve-ChaosBlastRadiusResource {
    <#
    .SYNOPSIS
        Which discovered resources survive the configured filters/exclusions.

    .DESCRIPTION
        A local projection, not a service call: it exists so the operator can
        see the resource list a run would touch *before* consenting, instead
        of discovering it from the run summary afterwards.

        It is explicitly advisory. The service resolves physical zones and tag
        exclusions at execution time, so this cannot be exact when those are
        used; callers surface that as a limitation rather than presenting the
        projection as the final set.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$ScopedResources,
        [AllowNull()][object]$BlastRadius
    )

    $candidates = @(@($ScopedResources) | Where-Object { $null -ne $_ })
    if ($null -eq $BlastRadius) { return @($candidates) }

    $filters = Get-ChaosBlastRadiusMember -Container $BlastRadius -Name 'filters'
    if ($null -ne $filters) {
        $wantedLocations = Get-ChaosBlastRadiusMember -Container $filters -Name 'locations'
        if ($null -ne $wantedLocations) {
            $locationSet = @(@($wantedLocations) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $candidates = @($candidates | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.location) -and $locationSet -contains $_.location.ToLowerInvariant()
                })
        }

        $wantedZones = Get-ChaosBlastRadiusMember -Container $filters -Name 'zones'
        if ($null -ne $wantedZones) {
            $zoneSet = @(@($wantedZones) | ForEach-Object { [string]$_ })
            $candidates = @($candidates | Where-Object {
                    $owned = @(@($_.zones) | ForEach-Object { [string]$_ })
                    @($owned | Where-Object { $zoneSet -contains $_ }).Count -gt 0
                })
        }
    }

    $exclusions = Get-ChaosBlastRadiusMember -Container $BlastRadius -Name 'exclusions'
    if ($null -ne $exclusions) {
        $blockedResources = Get-ChaosBlastRadiusMember -Container $exclusions -Name 'resources'
        if ($null -ne $blockedResources) {
            $resourceSet = @(@($blockedResources) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $candidates = @($candidates | Where-Object {
                    [string]::IsNullOrWhiteSpace($_.resourceId) -or $resourceSet -notcontains $_.resourceId.ToLowerInvariant()
                })
        }

        $blockedTypes = Get-ChaosBlastRadiusMember -Container $exclusions -Name 'types'
        if ($null -ne $blockedTypes) {
            $typeSet = @(@($blockedTypes) | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $candidates = @($candidates | Where-Object {
                    [string]::IsNullOrWhiteSpace($_.resourceType) -or $typeSet -notcontains $_.resourceType.ToLowerInvariant()
                })
        }

        $blockedTags = Get-ChaosBlastRadiusMember -Container $exclusions -Name 'tags'
        if ($null -ne $blockedTags) {
            $candidates = @($candidates | Where-Object {
                    $resourceTags = $_.tags
                    if ($null -eq $resourceTags) { return $true }
                    foreach ($tagPair in @($blockedTags)) {
                        $tagName = if ($tagPair -is [System.Collections.IDictionary]) { [string]$tagPair['key'] } else { [string]$tagPair.key }
                        $expected = if ($tagPair -is [System.Collections.IDictionary]) { $tagPair['value'] } else { $tagPair.value }
                        $actualProperty = @($resourceTags.PSObject.Properties | Where-Object { $_.Name -ieq [string]$tagName } | Select-Object -First 1)
                        if ($resourceTags -is [System.Collections.IDictionary]) {
                            $actualKey = @($resourceTags.Keys | Where-Object { [string]$_ -ieq [string]$tagName } | Select-Object -First 1)
                            if (
                                $actualKey.Count -gt 0 -and
                                ([string]$expected -eq '*' -or [string]$resourceTags[$actualKey[0]] -ieq [string]$expected)
                            ) { return $false }
                        } elseif (
                            $actualProperty.Count -gt 0 -and
                            ([string]$expected -eq '*' -or [string]$actualProperty[0].Value -ieq [string]$expected)
                        ) {
                            return $false
                        }
                    }
                    return $true
                })
        }
    }

    return @($candidates)
}

# -- 4. Scenarios ----------------------------------------------------------

function ConvertTo-ChaosScenarioRecord {
    <#
    .SYNOPSIS
        Project one scenario into the shape the plan records.

    .DESCRIPTION
        Parameter specs are carried through verbatim - name, type, whether it
        is required, its default and its description - so `chaos-study-run` can
        validate what it is about to send without a second round trip, and so
        the report can state exactly what the run was configured with.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Scenario)

    $read = {
        param($container, $name)
        if ($null -eq $container) { return $null }
        if ($container.PSObject.Properties.Name -notcontains $name) { return $null }
        return $container.$name
    }

    $properties = & $read $Scenario 'properties'
    $recommendation = & $read $properties 'recommendation'

    $parameters = @()
    foreach ($parameter in @(& $read $properties 'parameters')) {
        if ($null -eq $parameter) { continue }
        $parameters += [pscustomobject]@{
            name        = [string](& $read $parameter 'name')
            type        = [string](& $read $parameter 'type')
            required    = [bool](& $read $parameter 'required')
            default     = & $read $parameter 'default'
            description = [string](& $read $parameter 'description')
        }
    }

    return [pscustomobject]@{
        id                   = [string](& $read $Scenario 'id')
        name                 = [string](& $read $Scenario 'name')
        displayName          = [string](& $read $properties 'displayName')
        description          = [string](& $read $properties 'description')
        version              = [string](& $read $properties 'version')
        recommendationStatus = [string](& $read $recommendation 'recommendationStatus')
        parameters           = @($parameters)
    }
}

function Get-ChaosStudyScenario {
    <#
    .SYNOPSIS
        List the scenarios the workspace offers for its discovered resources.

    .DESCRIPTION
        Scenarios are what V2 actually executes. The list is derived by the
        service from what it discovered, which is why it is queried after the
        workspace exists rather than assembled up front.

        -RecommendedOnly narrows to those the platform marked Recommended.
        That is the honest default for a first study: a recommended scenario is
        one the service believes the current scope can support, so it converts
        a class of validation failures into an empty list at plan time, where
        they cost nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId,
        [switch]$RecommendedOnly
    )

    if (-not (Test-ChaosCliAvailable)) { return , @() }

    $chaosArgs = @('scenario', 'list', '--resource-group', $ResourceGroup, '--workspace-name', $WorkspaceName)
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $chaosArgs += @('--subscription', $SubscriptionId)
    }

    $response = Invoke-AzChaos -ChaosArgs $chaosArgs -AllowFailure
    if ($null -eq $response) { return , @() }

    $items = @()
    if ($response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
        $items = @($response)
    } elseif ($response.PSObject.Properties.Name -contains 'value') {
        $items = @($response.value)
    } else {
        $items = @($response)
    }

    $records = @()
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $record = ConvertTo-ChaosScenarioRecord -Scenario $item
        if ($RecommendedOnly -and $record.recommendationStatus -ne 'Recommended') { continue }
        $records += $record
    }
    return , @($records)
}

function Find-ChaosStudyScenario {
    <#
    .SYNOPSIS
        Resolve one scenario by name or ARM id from an already-read list.

    .DESCRIPTION
        Matching is exact on name or id, then case-insensitive on name. There
        is deliberately no fuzzy match: picking the closest-looking scenario is
        how a study ends up executing something adjacent to what was reviewed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Scenarios,
        [Parameter(Mandatory)][string]$Name
    )

    $exact = @($Scenarios | Where-Object { $_.name -ceq $Name -or $_.id -ceq $Name })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($exact.Count -gt 1) { return $exact[0] }

    $insensitive = @($Scenarios | Where-Object { $_.name -eq $Name })
    if ($insensitive.Count -eq 1) { return $insensitive[0] }

    return $null
}

function Assert-ChaosWorkspaceEvaluation {
    <#
    .SYNOPSIS
        Report the workspace's most recent scenario evaluation.

    .DESCRIPTION
        Recommendations come from an evaluation pass. A workspace that has
        never been evaluated, or whose evaluation partly failed, will offer a
        scenario list that under-describes what is possible. That is worth
        recording as a limitation, but it is not worth blocking on: an operator
        who knows the scenario they want should not be stopped because an
        unrelated scenario failed to evaluate.

        Returns a record, never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId
    )

    if (-not (Test-ChaosCliAvailable)) {
        return [pscustomobject]@{
            available = $false
            status    = $null
            evaluated = $null
            failed    = $null
            note      = 'The az chaos seam was unavailable, so the workspace evaluation could not be read.'
        }
    }

    $chaosArgs = @('workspace', 'show-evaluation', '--name', $WorkspaceName, '--resource-group', $ResourceGroup)
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $chaosArgs += @('--subscription', $SubscriptionId)
    }

    $response = Invoke-AzChaos -ChaosArgs $chaosArgs -AllowFailure
    if ($null -eq $response) {
        return [pscustomobject]@{
            available = $false
            status    = $null
            evaluated = $null
            failed    = $null
            note      = 'The workspace has no evaluation result yet. Run az chaos workspace refresh-recommendation to produce one.'
        }
    }

    $properties = $null
    if ($response.PSObject.Properties.Name -contains 'properties') { $properties = $response.properties }
    $read = {
        param($name)
        if ($null -eq $properties) { return $null }
        if ($properties.PSObject.Properties.Name -notcontains $name) { return $null }
        return $properties.$name
    }

    return [pscustomobject]@{
        available = $true
        status    = [string](& $read 'status')
        evaluated = & $read 'numScenariosEvaluatedSucceeded'
        failed    = & $read 'numScenariosEvaluatedFailed'
        note      = $null
    }
}
