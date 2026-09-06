# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . "$script:Skills/chaos-study/scripts/lib/Operation.ps1"
}

Describe 'Documented external result-file exchange' {
    It 'ingests <Kind> using the documented payload and preserves one provenance record on replay' -ForEach @(
        @{ Kind = 'workspace.get'; Schema = 'workspace.v1'; Payload = '{"id":"/w","name":"ws"}' }
        @{ Kind = 'actions.list'; Schema = 'any.v1'; Payload = '{"body":{"value":[{"name":"action"}]},"headers":{}}' }
        @{ Kind = 'logs.query'; Schema = 'any.v1'; Payload = '{"tables":[{"name":"PrimaryResult","columns":[],"rows":[]}]}' }
    ) {
        $path = "$TestDrive/$Kind"
        $arguments = @{ cliArgs = @('--subscription', 'fixture') }
        $request = New-ChaosOperationRequest -Kind $Kind -Arguments $arguments -ExpectedSchema $Schema -StudyPath $path
        Save-ChaosOperationRequest -StudyPath $path -Request $request | Out-Null
        $payloadObject = ConvertFrom-Json $Payload
        Write-ChaosJsonFile -Path "$path/operations/$($request.operationId).result.json" -InputObject @{
            operationId = $request.operationId; requestHash = $request.requestHash; result = $payloadObject
        } | Out-Null
        $result = Invoke-ChaosStudyOperation -Kind $Kind -Arguments $arguments -ExpectedSchema $Schema -Adapter external -StudyPath $path
        ConvertTo-ChaosCanonicalJson $result | Should -Be (ConvertTo-ChaosCanonicalJson $payloadObject)
        Invoke-ChaosStudyOperation -Kind $Kind -Arguments $arguments -ExpectedSchema $Schema -Adapter external -StudyPath $path | Out-Null
        $provenance = @(Get-ChaosOperationProvenance -StudyPath $path)
        $provenance.Count | Should -Be 1
        $provenance[0].requestHash | Should -Be $request.requestHash
        $provenance[0].resultHash | Should -Be (Get-ChaosDigest $payloadObject)
    }

    It 'rejects a result that does not bind to the requested <Field>' -ForEach @(
        @{ Field = 'operationId' }, @{ Field = 'requestHash' }
    ) {
        $path = "$TestDrive/invalid-$Field"
        $request = New-ChaosOperationRequest -Kind workspace.get -Arguments @{} -ExpectedSchema workspace.v1 -StudyPath $path
        Save-ChaosOperationRequest -StudyPath $path -Request $request | Out-Null
        $result = @{ operationId = $request.operationId; requestHash = $request.requestHash; result = @{ id = '/w'; name = 'ws' } }
        $result[$Field] = 'wrong'
        Write-ChaosJsonFile -Path "$path/operations/$($request.operationId).result.json" -InputObject $result | Out-Null
        { Resolve-ChaosPendingOperation -StudyPath $path -RequestHash $request.requestHash -ExpectedSchema workspace.v1 } | Should -Throw "*$Field*"
    }
}

Describe 'Study guide contract references' {
    It 'keeps one shared exit table with all declared study exit codes and current artifact filenames' {
        $main = Get-Content "$script:Skills/chaos-study/SKILL.md" -Raw
        foreach ($code in $ChaosStudyExit.Values) {
            $main | Should -Match ('(?m)^\| `' + $code + '`\s*\|')
        }
        foreach ($artifact in @('plan', 'runRecord', 'findings')) {
            $main | Should -Match ([regex]::Escape((Get-ChaosArtifactFileName $artifact)))
        }
        $guides = @(Get-ChildItem "$script:Skills/chaos-study*/SKILL.md")
        $headers = @($guides | ForEach-Object { [regex]::Matches((Get-Content $_.FullName -Raw), '(?m)^## Exit codes$') })
        $headers.Count | Should -Be 1
    }
}
