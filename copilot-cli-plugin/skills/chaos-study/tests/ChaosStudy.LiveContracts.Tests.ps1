# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Captured service responses are fixtures only. No Azure executable is invoked.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Shared = "$script:Skills/chaos-study/scripts/lib"
    $script:ScopeEntry = "$script:Skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1"
    $script:ValidationFixture = "$PSScriptRoot/fixtures/live-validation-internal-error.json"
    . "$script:Shared/Operation.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . "$script:Skills/chaos-study-run/scripts/lib/Signals.ps1"
}

Describe 'L1 captured ARM validation contract' {
    It 'normalizes <Shape> validation through the operation seam without losing errors or execution plan' -ForEach @(
        @{ Shape = 'nested' }, @{ Shape = 'flattened' }
    ) {
        $script:CapturedValidation = Read-ChaosJsonFile $script:ValidationFixture
        if ($Shape -eq 'flattened') { $script:CapturedValidation = $script:CapturedValidation.properties }
        Mock Test-ChaosLocalAzAdapterReady { @() }
        Mock Invoke-ChaosStudyAzChaos { $script:CapturedValidation }
        $result = Invoke-ChaosStudyOperation -Kind config.validate -Arguments @{ cliArgs = @('--subscription', 'sub') } -ExpectedSchema validation.v2 -Adapter local-az
        $result.status | Should -Be RequiresAttention
        $result.errors[0].errorCode | Should -Be InternalError
        ($result.errors -is [object[]]) | Should -BeTrue
        $result.executionPlanJson | Should -Not -BeNullOrEmpty
        $error = @(Get-ChaosValidationError $result)[0]
        $error.repairable | Should -BeFalse
        $error.category | Should -Match system
    }

    It 'cleans up and exits 17 for <Shape> through the real operation seam' -ForEach @(
        @{ Shape = 'nested' }, @{ Shape = 'flattened' }, @{ Shape = 'missing-status' }
    ) {
        $root = "$TestDrive/$Shape"
        New-Item -ItemType Directory $root -Force | Out-Null
        $child = @"
`$ErrorActionPreference = 'Stop'
. '$script:Skills/chaos-study-run/scripts/lib/Execute.ps1'
`$ast = [System.Management.Automation.Language.Parser]::ParseFile('$script:ScopeEntry',[ref]`$null,[ref]`$null)
foreach (`$node in `$ast.EndBlock.Statements) {
    if (`$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -match '^(New-ChaosPreflightConfiguration|Get-ChaosPreflightConfigurationName|Get-ChaosPreflightValidationStatus)$') { . ([scriptblock]::Create(`$node.Extent.Text)) }
}
function global:az { throw 'Azure is prohibited' }
function Invoke-ChaosStudyAzChaos {
    param(`$ChaosArgs,`$JsonArg,`$AllowFailure)
    `$ChaosArgs[2] | Add-Content '$root/calls'
    switch (`$ChaosArgs[2]) {
        create { [pscustomobject]@{name='preflight-test'} }
        validate {
            `$raw = Read-ChaosJsonFile '$script:ValidationFixture'
            if ('$Shape' -eq 'flattened') { `$raw.properties }
            elseif ('$Shape' -eq 'missing-status') { [pscustomobject]@{name='cfg';properties=[pscustomobject]@{errors=`$raw.properties.errors}} }
            else { `$raw }
        }
        delete { throw 'BadRequest: Nullable object must have a value.' }
        list { return ,@() }
        default { throw "Unexpected operation: `$ChaosArgs" }
    }
}
`$plan = [pscustomobject]@{
    workspace=[pscustomobject]@{subscriptionId='sub';resourceGroup='rg';name='ws'}
    scenario=[pscustomobject]@{name='scenario';parameters=@()}
    scope=[pscustomobject]@{blastRadius=`$null}
}
New-ChaosPreflightConfiguration -StudyId test -Plan `$plan -Adapter local-az -StudyPath '$root'
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $child 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        $calls = @(Get-Content "$root/calls")
        @($calls | Where-Object { $_ -eq 'delete' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -eq 'list' }).Count | Should -Be 1
        $entry = (Read-ChaosJsonFile "$root/residue-ledger.json").entries[0]
        $entry.cleanup.status | Should -Be succeeded
        $entry.cleanup.observation.certainty | Should -Be effective-with-service-error
        $validation = Get-Content "$root/evidence/preflight/validation.json" -Raw
        if ($Shape -eq 'missing-status') { $validation | Should -Match 'ValidationFailed.*status' }
        else { $validation | Should -Match InternalError }
        ($output | Out-String) | Should -Not -Match 'null-valued expression'
    }

    It 'propagates a failed scope exit before reading an empty study id' {
        $root = "$TestDrive/front"
        New-Item -ItemType Directory "$root/skills" -Force | Out-Null
        Copy-Item "$script:Skills/chaos-study*" "$root/skills" -Recurse
        "param([Parameter(ValueFromRemainingArguments)]`$Rest); exit 17" | Set-Content "$root/skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1"
        $output = & pwsh -NoProfile -NonInteractive -File "$root/skills/chaos-study/scripts/Invoke-ChaosStudy.ps1" -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -Brief unused 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        ($output | Out-String) | Should -Not -Match 'null-valued expression'
    }
}
