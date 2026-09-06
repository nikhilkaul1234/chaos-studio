# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Execute = "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . $script:Execute
}

Describe 'P1 validation remediation reports actual permission operations' {
    It 'reports <Case> without inventing permission repair' -ForEach @(
        @{ Case = 'not-attempted'; Attempted = $false; Applied = $false; Authoritative = $false; Code = 'InternalError'; Expected = 'non-repairable service error.*no permission changes were attempted' }
        @{ Case = 'applied'; Attempted = $true; Applied = $true; Authoritative = $true; Code = 'AuthorizationFailed'; Expected = 'already previewed and applied the grants' }
        @{ Case = 'preview-only'; Attempted = $true; Applied = $false; Authoritative = $true; Code = 'AuthorizationFailed'; Expected = 'preview.*no permission changes were applied' }
        @{ Case = 'incomplete-preview'; Attempted = $true; Applied = $false; Authoritative = $false; Code = 'AuthorizationFailed'; Expected = 'not authoritative.*no permission changes were applied' }
    ) {
        $inputPath = "$TestDrive/$Case.json"
        @{
            validation = @{ status = 'RequiresAttention'; correlationId = 'fixture-correlation'; errors = @(@{ errorCode = $Code; errorMessage = 'Operation: performing RBAC validation.' }) }
            permissionFix = @{
                attempted = $Attempted; approved = $Applied; applicable = $Authoritative
                grantSetHash = if ($Authoritative) { 'exact-grants' } else { $null }
                applied = if ($Applied) { @{ whatIfMode = $false; succeeded = 1 } } else { $null }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content $inputPath
        $command = @"
. '$script:Execute'
`$data = Read-ChaosJsonFile '$inputPath'
`$args = @{ Validation = `$data.validation; ConfigurationName = 'fixture' }
if ((Get-Command Assert-ChaosConfigurationValidated).Parameters.ContainsKey('PermissionFix')) { `$args.PermissionFix = `$data.permissionFix }
Assert-ChaosConfigurationValidated @args | Out-Null
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 17 -Because ($output | Out-String)
        $text = ($output | Out-String) -replace '\s+', ' '
        $text | Should -Match $Expected
        if (-not $Applied) { $text | Should -Not -Match 'already previewed and applied' }
        if (-not $Attempted) { $text | Should -Match 'correlation fixture-correlation' }
    }
}
