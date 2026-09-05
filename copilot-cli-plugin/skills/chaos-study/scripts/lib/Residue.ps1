# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    The durable residue ledger: every Azure object a study creates, recorded so
    it can be observed and removed rather than assumed gone.

.DESCRIPTION
    A study creates real resources - a preflight configuration, an execution
    configuration, scenario runs, and (later) role assignments. If cleanup is
    attempted and never observed, a leak is invisible; if it is never recorded,
    it cannot be cleaned up by a later resume at all. The ledger is the single
    place those objects are written down, at the moment they are created, with
    a `cleanup` block that starts life unattempted and is only ever advanced to
    a real, observed outcome.

    This file owns:
      1. The on-disk ledger (`residue-ledger.json`) read/write helpers, keyed by
         the study path so there is exactly one ledger per study.
      2. `New-ChaosResidueEntry` - the entry shape (id + provenance + time +
         cleanup{attemptedAt,status,error,command}).
      3. `Add-ChaosResidueEntry` - append-or-replace by (kind,id), idempotent so
         a re-run does not double-record the same object.
      4. `Add-Chaos*ResidueEntry` - the recording callers: the preflight
         configuration, the execution configuration, each scenario run, and each
         role assignment a permission repair created.
      5. `Invoke-ChaosResidueRemoval` / `Set-ChaosResidueCleanup` - observed
         removal. A cleanup outcome is only ever written from what actually
         happened, never from the fact that a removal was attempted.
      6. `Get-ChaosUnresolvedResidue` / `Get-ChaosResidueSummary` - what the
         study cannot show it removed, which is what raises L14 in the report.

    Requires Common.ps1 (hashing, JSON, UTC) to be dot-sourced first.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command Get-ChaosUtcNow -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

$ChaosResidueLedgerVersion = 'residue-ledger.v1'

function Get-ChaosResidueLedgerPath {
    <#
    .SYNOPSIS
        The residue-ledger.json path for a study. One ledger per study path.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)
    return Join-Path $StudyPath 'residue-ledger.json'
}

function Get-ChaosResidueLedger {
    <#
    .SYNOPSIS
        Read a study's residue ledger, returning an empty ledger when none has
        been written yet.

    .DESCRIPTION
        A missing ledger is not an error: a study that has created nothing has
        nothing to record. The empty shape matches a written one so callers
        never branch on presence.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)

    $path = Get-ChaosResidueLedgerPath -StudyPath $StudyPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ ledgerVersion = $ChaosResidueLedgerVersion; entries = @() }
    }

    $ledger = Read-ChaosJsonFile -Path $path
    if ($null -eq $ledger) {
        return [pscustomobject]@{ ledgerVersion = $ChaosResidueLedgerVersion; entries = @() }
    }
    return $ledger
}

function New-ChaosResidueEntry {
    <#
    .SYNOPSIS
        Build one residue-ledger entry.

    .DESCRIPTION
        The cleanup block starts unattempted - never "succeeded" by default -
        so an entry that is never cleaned up reads as exactly that. Only an
        observed removal is allowed to change it.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('workspace', 'preflightConfiguration', 'executionConfiguration', 'scenarioRun', 'roleAssignment')]
        [string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][AllowEmptyString()][string]$Name = $null,
        [AllowNull()][object]$Provenance = $null
    )

    return [ordered]@{
        kind       = $Kind
        id         = $Id
        name       = if ([string]::IsNullOrWhiteSpace($Name)) { $null } else { $Name }
        provenance = $Provenance
        createdAt  = Get-ChaosUtcNow
        cleanup    = [ordered]@{
            attemptedAt = $null
            status      = 'unattempted'
            error       = $null
            command     = $null
        }
    }
}

function Add-ChaosResidueEntry {
    <#
    .SYNOPSIS
        Append a residue entry to a study's ledger, replacing any existing entry
        with the same (kind,id) so re-recording is idempotent.

    .DESCRIPTION
        Idempotency matters because a resumed study can pass the same creation
        point twice; recording the object twice would inflate the ledger and
        misreport how much residue a run actually left. Refuses a sealed study,
        because a sealed study is immutable and its ledger describes the run it
        was sealed from.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][object]$Entry
    )

    if (Get-Command Test-ChaosStudySealed -ErrorAction SilentlyContinue) {
        if (Test-ChaosStudySealed -StudyPath $StudyPath) {
            throw "StudyAlreadySealed: '$StudyPath' is sealed and its residue ledger cannot be modified."
        }
    }

    $entryKind = if ($Entry -is [System.Collections.IDictionary]) { [string]$Entry['kind'] } else { [string]$Entry.kind }
    $entryId = if ($Entry -is [System.Collections.IDictionary]) { [string]$Entry['id'] } else { [string]$Entry.id }
    if ([string]::IsNullOrWhiteSpace($entryId)) {
        throw 'Add-ChaosResidueEntry: the entry has no id, so it cannot be tracked or later removed.'
    }

    $ledger = Get-ChaosResidueLedger -StudyPath $StudyPath
    $existing = @(@($ledger.entries) | Where-Object {
            $null -ne $_ -and -not (([string]$_.kind -eq $entryKind) -and ([string]$_.id -eq $entryId))
        })

    $updated = [ordered]@{
        ledgerVersion = $ChaosResidueLedgerVersion
        entries       = @($existing + @($Entry))
    }

    $path = Get-ChaosResidueLedgerPath -StudyPath $StudyPath
    Write-ChaosJsonFile -Path $path -InputObject $updated | Out-Null
    return $updated
}

function Add-ChaosRoleAssignmentResidueEntry {
    <#
    .SYNOPSIS
        Record a role assignment a permission repair created, so a grant this
        study made can later be found and revoked by id rather than guessed at.

    .DESCRIPTION
        Chaos Studio's fix-permissions response reports counts, not assignment
        ids, so the ids here come from diffing a read-only role-assignment
        snapshot taken either side of the repair. That diff is the only evidence
        a study has that it changed someone's RBAC, which is exactly why it is
        written to the ledger the moment it is observed.

        The removal command is recorded alongside the entry because the operator
        who has to undo this may not be the one who ran the study.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$AssignmentId,
        [AllowNull()][AllowEmptyString()][string]$RoleDefinitionId = $null,
        [AllowNull()][AllowEmptyString()][string]$PrincipalId = $null,
        [AllowNull()][AllowEmptyString()][string]$Scope = $null,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$ApprovalPhrase = $null
    )

    $provenance = [ordered]@{
        origin           = 'permissionRepair'
        adapter          = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter }
        roleDefinitionId = if ([string]::IsNullOrWhiteSpace($RoleDefinitionId)) { $null } else { $RoleDefinitionId }
        principalId      = if ([string]::IsNullOrWhiteSpace($PrincipalId)) { $null } else { $PrincipalId }
        scope            = if ([string]::IsNullOrWhiteSpace($Scope)) { $null } else { $Scope }
        approvedBy       = if ([string]::IsNullOrWhiteSpace($ApprovalPhrase)) { $null } else { $ApprovalPhrase }
        removalCommand   = "az role assignment delete --ids $AssignmentId"
    }

    $entry = New-ChaosResidueEntry -Kind 'roleAssignment' -Id $AssignmentId -Name $RoleDefinitionId -Provenance $provenance
    return Add-ChaosResidueEntry -StudyPath $StudyPath -Entry $entry
}

function Add-ChaosExecutionResidueEntry {
    <#
    .SYNOPSIS
        Record the scenario configuration a run created to execute the fault.

    .DESCRIPTION
        This is the configuration that actually ran, which makes it the object
        most likely to be left behind when a run unwinds through its finally
        block. Recording it at creation - not at cleanup - is what lets a later
        resume find it even if the process that made it never got that far.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][object]$Workspace = $null,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$Origin = 'execution'
    )

    $resourceGroup = if ($Workspace) { $Workspace.resourceGroup } else { $null }
    $workspaceName = if ($Workspace) { $Workspace.name } else { $null }
    $provenance = [ordered]@{
        origin         = if ([string]::IsNullOrWhiteSpace($Origin)) { 'execution' } else { $Origin }
        adapter        = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter }
        resourceGroup  = $resourceGroup
        workspaceName  = $workspaceName
        removalCommand = "az chaos scenario config delete --name $ConfigurationName --resource-group $resourceGroup --workspace-name $workspaceName --yes"
    }

    $entry = New-ChaosResidueEntry -Kind 'executionConfiguration' -Id $ConfigurationName -Name $ConfigurationName -Provenance $provenance
    return Add-ChaosResidueEntry -StudyPath $StudyPath -Entry $entry
}

function Add-ChaosScenarioRunResidueEntry {
    <#
    .SYNOPSIS
        Record a scenario run the study started.

    .DESCRIPTION
        A run is residue in the sense that matters here: while it is live it is
        still applying a fault. If the study dies between starting a run and
        cancelling it, the ledger is the only place the run id survives, and
        without the id nobody can stop it.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$RunId,
        [AllowNull()][object]$Workspace = $null,
        [AllowNull()][AllowEmptyString()][string]$ScenarioName = $null,
        [AllowNull()][AllowEmptyString()][string]$ConfigurationName = $null,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null
    )

    $resourceGroup = if ($Workspace) { $Workspace.resourceGroup } else { $null }
    $workspaceName = if ($Workspace) { $Workspace.name } else { $null }
    $provenance = [ordered]@{
        origin            = 'scenarioRun'
        adapter           = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter }
        resourceGroup     = $resourceGroup
        workspaceName     = $workspaceName
        scenarioName      = if ([string]::IsNullOrWhiteSpace($ScenarioName)) { $null } else { $ScenarioName }
        configurationName = if ([string]::IsNullOrWhiteSpace($ConfigurationName)) { $null } else { $ConfigurationName }
        removalCommand    = "az chaos scenario run cancel --name $RunId --resource-group $resourceGroup --workspace-name $workspaceName --scenario-name $ScenarioName"
    }

    $entry = New-ChaosResidueEntry -Kind 'scenarioRun' -Id $RunId -Name $ConfigurationName -Provenance $provenance
    return Add-ChaosResidueEntry -StudyPath $StudyPath -Entry $entry
}

function Get-ChaosResidueRemovalCommand {
    <#
    .SYNOPSIS
        The command that removes a ledger entry, from its own provenance.

    .DESCRIPTION
        The command is written down at creation because the person who has to
        undo a study is often not the one who ran it, and reconstructing an
        `az` invocation from a resource id is exactly the kind of guesswork
        that leaves resources behind.
    #>
    param([Parameter(Mandatory)][object]$Entry)

    $provenance = if ($Entry -is [System.Collections.IDictionary]) { $Entry['provenance'] } else { $Entry.provenance }
    if ($null -eq $provenance) { return $null }
    $command = if ($provenance -is [System.Collections.IDictionary]) {
        if ($provenance.Contains('removalCommand')) { $provenance['removalCommand'] } else { $null }
    } elseif ($provenance.PSObject.Properties.Name -contains 'removalCommand') {
        $provenance.removalCommand
    } else { $null }
    if ([string]::IsNullOrWhiteSpace([string]$command)) { return $null }
    return [string]$command
}

function Set-ChaosResidueCleanup {
    <#
    .SYNOPSIS
        Record the observed outcome of a cleanup attempt against one entry.

    .DESCRIPTION
        The only way an entry leaves the 'unattempted' state. It takes a real
        status - succeeded, failed, or skipped - and, when it failed, the error
        that was actually raised. Nothing here infers success from the fact
        that a removal was tried; that inference is the bug this whole ledger
        exists to make impossible.

        Returns $false when there is no such entry, rather than inventing one:
        recording cleanup for an object that was never recorded as created
        would misstate what the study touched.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed', 'skipped', 'unattempted')][string]$Status,
        [AllowNull()][AllowEmptyString()][string]$ErrorText = $null,
        [AllowNull()][AllowEmptyString()][string]$Command = $null,
        [AllowNull()][object]$Observation = $null
    )

    $ledger = Get-ChaosResidueLedger -StudyPath $StudyPath
    $entries = @(@($ledger.entries) | Where-Object { $null -ne $_ })
    $match = @($entries | Where-Object { ([string]$_.kind -eq $Kind) -and ([string]$_.id -eq $Id) })
    if ($match.Count -eq 0) { return $false }

    $rest = @($entries | Where-Object { -not (([string]$_.kind -eq $Kind) -and ([string]$_.id -eq $Id)) })
    $target = $match[0]
    $command = if ([string]::IsNullOrWhiteSpace($Command)) { Get-ChaosResidueRemovalCommand -Entry $target } else { $Command }

    $updatedEntry = [ordered]@{
        kind       = [string]$target.kind
        id         = [string]$target.id
        name       = $target.name
        provenance = $target.provenance
        createdAt  = $target.createdAt
        cleanup    = [ordered]@{
            attemptedAt = Get-ChaosUtcNow
            status      = $Status
            error       = if ([string]::IsNullOrWhiteSpace($ErrorText)) { $null } else { $ErrorText }
            command     = $command
            observation = $Observation
        }
    }

    $updated = [ordered]@{
        ledgerVersion = $ChaosResidueLedgerVersion
        entries       = @($rest + @($updatedEntry))
    }
    Write-ChaosJsonFile -Path (Get-ChaosResidueLedgerPath -StudyPath $StudyPath) -InputObject $updated | Out-Null
    return $true
}

function Invoke-ChaosResidueRemoval {
    <#
    .SYNOPSIS
        Attempt a removal, observe what happened, and persist that outcome.

    .DESCRIPTION
        This replaces the `-AllowFailure | Out-Null` pattern, which discarded
        the one piece of information that mattered: whether the thing actually
        went away. Here the removal runs inside a try/catch, the exception (if
        any) is kept verbatim, and the ledger is advanced to 'succeeded' or
        'failed' accordingly.

        It never rethrows, because every caller is a finally block unwinding
        from some other failure and an exception here would mask that. The
        failure is not swallowed though - it is written down, and it is what
        raises L14 later.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][scriptblock]$Removal,
        [AllowNull()][AllowEmptyString()][string]$Command = $null
    )

    $status = 'succeeded'
    $errorText = $null
    $observation = $null
    try {
        $observation = & $Removal
        if ($null -ne $observation -and $observation.PSObject.Properties.Name -contains 'effective') {
            if (-not $observation.effective) { $status = 'failed' }
            $errorText = $observation.serviceError
        }
    } catch {
        $status = 'failed'
        $errorText = $_.Exception.Message
    }

    $recorded = $false
    try {
        $recorded = Set-ChaosResidueCleanup -StudyPath $StudyPath -Kind $Kind -Id $Id -Status $status -ErrorText $errorText -Command $Command -Observation $observation
    } catch {
        $recorded = $false
        $status = 'failed'
        $errorText = "$errorText Ledger persistence failed: $($_.Exception.Message)"
        Write-ChaosStudyNote -Message $errorText -Level warn
    }

    return [pscustomobject]@{
        kind     = $Kind
        id       = $Id
        status   = $status
        error    = $errorText
        recorded = [bool]$recorded
    }
}

function Get-ChaosUnresolvedResidue {
    <#
    .SYNOPSIS
        The ledger entries this study cannot show were removed.

    .DESCRIPTION
        Unresolved means anything other than an observed success: never
        attempted, attempted and failed, or deliberately skipped. All three
        leave something behind, and the report has to say so. Sealing with
        unresolved residue is allowed - an operator may well want to keep a
        workspace - but it is never hidden.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)

    $ledger = Get-ChaosResidueLedger -StudyPath $StudyPath
    $entries = @(@($ledger.entries) | Where-Object { $null -ne $_ })
    return @($entries | Where-Object {
            $hasCleanup = ($null -ne $_.PSObject.Properties['cleanup'])
            if (-not $hasCleanup) { return $true }
            $cleanup = $_.cleanup
            if ($null -eq $cleanup) { return $true }
            return ([string]$cleanup.status -ne 'succeeded')
        })
}

function Get-ChaosResidueSummary {
    <#
    .SYNOPSIS
        A report-ready view of the ledger: totals, and every unresolved entry
        with the exact command that removes it.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)

    $ledger = Get-ChaosResidueLedger -StudyPath $StudyPath
    $entries = @(@($ledger.entries) | Where-Object { $null -ne $_ })
    $unresolved = @(Get-ChaosUnresolvedResidue -StudyPath $StudyPath)

    return [pscustomobject]@{
        ledgerVersion = if ($ledger.PSObject.Properties.Name -contains 'ledgerVersion') { $ledger.ledgerVersion } else { $ChaosResidueLedgerVersion }
        total         = $entries.Count
        resolved      = ($entries.Count - $unresolved.Count)
        unresolved    = $unresolved.Count
        entries       = @($entries | ForEach-Object {
                $cleanup = if ($null -eq $_.PSObject.Properties['cleanup']) { $null } else { $_.cleanup }
                [pscustomobject]@{
                    kind        = [string]$_.kind
                    id          = [string]$_.id
                    createdAt   = $_.createdAt
                    status      = if ($null -eq $cleanup) { 'unattempted' } else { [string]$cleanup.status }
                    attemptedAt = if ($null -eq $cleanup) { $null } else { $cleanup.attemptedAt }
                    error       = if ($null -eq $cleanup) { $null } else { $cleanup.error }
                    command     = if ($null -ne $cleanup -and -not [string]::IsNullOrWhiteSpace([string]$cleanup.command)) { [string]$cleanup.command } else { Get-ChaosResidueRemovalCommand -Entry $_ }
                }
            })
    }
}

function Add-ChaosPreflightResidueEntry {
    <#
    .SYNOPSIS
        Record the deterministic preflight configuration a study created while
        validating its effective legs, so it is never a silent leak.

    .DESCRIPTION
        The preflight configuration is a real Chaos Studio resource created
        before any fault consent. Recording it here means a later run can reuse
        it, and a later cleanup can remove it, both by a name the study wrote
        down rather than one it has to guess.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][object]$Workspace = $null,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$ValidationStatus = $null,
        [AllowNull()][AllowEmptyString()][string]$EffectivePlanHash = $null
    )

    $provenance = [ordered]@{
        origin            = 'preflight'
        adapter           = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter }
        resourceGroup     = if ($Workspace) { $Workspace.resourceGroup } else { $null }
        workspaceName     = if ($Workspace) { $Workspace.name } else { $null }
        scenario          = if ($Workspace -and ($Workspace.PSObject.Properties.Name -contains 'scenario')) { $Workspace.scenario } else { $null }
        validationStatus  = if ([string]::IsNullOrWhiteSpace($ValidationStatus)) { $null } else { $ValidationStatus }
        effectivePlanHash = if ([string]::IsNullOrWhiteSpace($EffectivePlanHash)) { $null } else { $EffectivePlanHash }
        removalCommand    = if ($Workspace) { "az chaos scenario config delete --name $ConfigurationName --resource-group $($Workspace.resourceGroup) --workspace-name $($Workspace.name) --scenario-name $(if ($Workspace.PSObject.Properties.Name -contains 'scenario') { $Workspace.scenario } else { '<scenario>' }) --yes" } else { $null }
    }

    $entry = New-ChaosResidueEntry -Kind 'preflightConfiguration' -Id $ConfigurationName -Name $ConfigurationName -Provenance $provenance
    return Add-ChaosResidueEntry -StudyPath $StudyPath -Entry $entry
}

function Add-ChaosWorkspaceResidueEntry {
    <#
    .SYNOPSIS
        Record a workspace this study created, so an experiment that made its
        own container does not leave one behind.

    .DESCRIPTION
        Only call this when the study actually created the workspace. A reused
        workspace belongs to whoever made it and must never appear in this
        study's ledger as something to clean up - deleting someone else's
        workspace is a far worse outcome than leaving one of ours.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [AllowNull()][AllowEmptyString()][string]$WorkspaceId = $null,
        [AllowNull()][AllowEmptyString()][string]$SubscriptionId = $null,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null
    )

    $subscriptionArg = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { '' } else { " --subscription $SubscriptionId" }
    $provenance = [ordered]@{
        origin         = 'scope'
        adapter        = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter }
        resourceGroup  = $ResourceGroup
        workspaceName  = $WorkspaceName
        subscriptionId = if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $null } else { $SubscriptionId }
        removalCommand = "az chaos workspace delete --name $WorkspaceName --resource-group $ResourceGroup$subscriptionArg --yes"
    }

    $id = if ([string]::IsNullOrWhiteSpace($WorkspaceId)) { "$ResourceGroup/$WorkspaceName" } else { $WorkspaceId }
    $entry = New-ChaosResidueEntry -Kind 'workspace' -Id $id -Name $WorkspaceName -Provenance $provenance
    return Add-ChaosResidueEntry -StudyPath $StudyPath -Entry $entry
}
