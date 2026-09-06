# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . "$script:Skills/chaos-study/scripts/lib/Study.ps1"
}

Describe 'P4 external adapter is read-only' {
    It 'refuses explicit external <Request> before <Entry> can dispatch an operation' -ForEach @(
        @{ Entry = 'chaos-study'; Request = 'armed'; Flag = '-DryRun:$false' }
        @{ Entry = 'chaos-study'; Request = 'consent'; Flag = "-Consent 'not-human-approval'" }
        @{ Entry = 'chaos-study'; Request = 'permission approval'; Flag = "-ApprovePermissions 'not-human-approval'" }
        @{ Entry = 'chaos-study-run'; Request = 'armed'; Flag = '-DryRun:$false' }
        @{ Entry = 'chaos-study-run'; Request = 'consent'; Flag = "-Consent 'not-human-approval'" }
        @{ Entry = 'chaos-study-run'; Request = 'permission approval'; Flag = "-ApprovePermissions 'not-human-approval'" }
    ) {
        $name = if ($Entry -eq 'chaos-study') { 'Invoke-ChaosStudy.ps1' } else { 'Invoke-ChaosStudyRun.ps1' }
        $root = "$TestDrive/$Entry-$Request"
        $output = & pwsh -NoProfile -NonInteractive -Command "& '$script:Skills/$Entry/scripts/$name' -StudyId frozen -StudyRoot '$root' -Adapter external $Flag; exit `$LASTEXITCODE" 2>&1
        $LASTEXITCODE | Should -Be 22 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'external adapter supports read-only phases only'
        Test-Path $root | Should -BeFalse
    }

    It 'refuses an armed request when external is frozen on the plan' {
        $root = "$TestDrive/frozen-external"
        $study = New-ChaosStudy -ScopeHash fixture -StudyRoot $root
        Save-ChaosStudyArtifact -StudyPath $study.path -RelativePath (Get-ChaosArtifactFileName plan) -Content @{ adapter = 'external' } | Out-Null
        $output = & pwsh -NoProfile -NonInteractive -Command "& '$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1' -StudyRoot '$root' -DryRun:`$false; exit `$LASTEXITCODE" 2>&1
        $LASTEXITCODE | Should -Be 22 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'external adapter supports read-only phases only'
        Test-Path (Join-Path $study.path operations) | Should -BeFalse
    }

    It 'refuses a mutating external operation instead of writing a host request' {
        $root = "$TestDrive/external-mutation"
        $command = @"
. '$script:Skills/chaos-study/scripts/lib/Operation.ps1'
Invoke-ChaosStudyOperation -Kind config.create -Arguments @{cliArgs=@('--subscription','fixture')} -ExpectedSchema any.v1 -Adapter external -StudyPath '$root'
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 22 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'external adapter supports read-only phases only'
        Test-Path (Join-Path $root operations) | Should -BeFalse
    }

    It 'still persists read-only external requests with exit 18' {
        $root = "$TestDrive/external-read"
        $command = @"
. '$script:Skills/chaos-study/scripts/lib/Operation.ps1'
Invoke-ChaosStudyOperation -Kind workspace.get -Arguments @{cliArgs=@('--subscription','fixture')} -ExpectedSchema workspace.v1 -Adapter external -StudyPath '$root'
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 18 -Because ($output | Out-String)
        @(Get-ChildItem "$root/operations" -Filter '*.request.json').Count | Should -Be 1
    }
}
