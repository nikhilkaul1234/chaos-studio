#Requires -Version 7.0
<#
.SYNOPSIS
    Interpret an executed study and seal it with a report.

.DESCRIPTION
    This script reads only what the run already wrote. It issues no queries, so
    it cannot quietly substitute fresh data for the evidence the study actually
    collected - the report describes the run, not the present.

    Sealing makes the study immutable. From that point the report and the
    evidence it cites cannot drift apart, which is what makes the report
    citable.

.EXAMPLE
    ./Invoke-ChaosStudyReport.ps1
    Reports on the latest executed study and seals it.

.EXAMPLE
    ./Invoke-ChaosStudyReport.ps1 -StudyId 20260101T120000Z-ab12cd34 -NoSeal
    Renders a report for review without sealing.
#>

[CmdletBinding()]
param(
    [string]$StudyId = 'latest',
    [string]$StudyRoot,
    [string]$OutputPath,
    [switch]$NoSeal,
    [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
$sharedLib = Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib'
. (Join-Path $sharedLib 'Common.ps1')
. (Join-Path $sharedLib 'ApiVersions.ps1')
. (Join-Path $sharedLib 'Study.ps1')
. (Join-Path $libDir 'Findings.ps1')
. (Join-Path $libDir 'Report.ps1')

$findArgs = @{ StudyId = $StudyId }
if ($StudyRoot) { $findArgs['StudyRoot'] = $StudyRoot }
$study = Find-ChaosStudy @findArgs

if (-not $study) {
    Write-ChaosStudyFailure -Title 'No study to report on' -Message "Could not find a study matching '$StudyId'." `
        -Remediation 'Run the chaos-study-history skill to list studies, or chaos-study-scope to plan a new one.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

$studyPath = $study.path
$plan = Read-ChaosJsonFile -Path (Join-Path $studyPath 'study-plan.v1.json')
$runRecord = Read-ChaosJsonFile -Path (Join-Path $studyPath 'run-record.v1.json')

if (-not $plan -or -not $runRecord) {
    Write-ChaosStudyFailure -Title 'Study has not been executed' -Message @"
Study $($study.studyId) is in state $($study.state). A report describes a run,
and this study has no run record to describe.
"@ -Remediation 'Run the chaos-study-run skill for this study first.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

$evidence = [ordered]@{
    pre    = @(Read-ChaosJsonFile -Path (Join-Path $studyPath 'evidence' 'pre' 'signals.json'))
    during = @(Read-ChaosJsonFile -Path (Join-Path $studyPath 'evidence' 'during' 'signals.json'))
    post   = @(Read-ChaosJsonFile -Path (Join-Path $studyPath 'evidence' 'post' 'signals.json'))
}

$findings = Build-StudyFindings -Plan $plan -RunRecord $runRecord -Evidence $evidence

$commandTrail = @()
$trailPath = Join-Path $studyPath 'commands.jsonl'
if (Test-Path -LiteralPath $trailPath) {
    $commandTrail = @(
        foreach ($line in [System.IO.File]::ReadAllLines($trailPath)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $line | ConvertFrom-Json }
        }
    )
}

if ($study.state -eq 'SEALED') {
    $manifest = Read-ChaosJsonFile -Path (Join-Path $studyPath 'manifest.json')
    $html = New-ChaosStudyReportHtml -Plan $plan -RunRecord $runRecord -Findings $findings -Evidence $evidence -Manifest $manifest -CommandTrail $commandTrail
    # A sealed study is immutable, so the report is rendered beside it -- in the
    # scope directory of the study store, never in the caller's working
    # directory, which is frequently a git repository we must not pollute.
    $fallback = if ($OutputPath) { $OutputPath } else { Join-Path (Split-Path -Parent $studyPath) "report-$($study.studyId).html" }
    Write-ChaosTextFile -Path $fallback -Content $html
    Write-Card -Title 'Study already sealed' -Status 'info' -Body @"
Study $($study.studyId) is sealed, so its stored artifacts were left untouched.
A fresh render was written outside the study directory instead.
"@ -Properties ([ordered]@{ 'Report' = $fallback; 'Verdict' = $findings.verdict })
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'findings.v1.json' -Content $findings | Out-Null
Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'report' -Command 'Invoke-ChaosStudyReport' -ExitCode 0 -Note $findings.verdict | Out-Null

# Include the report command in the rendered provenance.
$commandTrail = @(
    foreach ($line in [System.IO.File]::ReadAllLines($trailPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $line | ConvertFrom-Json }
    }
)

$identity = [ordered]@{
    workspace     = [string]$plan.workspace.name
    workspaceId   = [string]$plan.workspace.id
    region        = [string]$plan.scope.region
    scenario      = [string]$plan.scenario.name
    scenarioId    = [string]$plan.scenario.id
    action        = [string]$plan.action.name
    actionUrn     = [string]$plan.action.canonicalId
    actionType    = [string]$plan.action.actionType
    scopeCount    = $plan.scope.projectedResourceCount
    predicate     = [string]$plan.question.steadyState.raw
    windows       = [ordered]@{
        baselineMinutes = $plan.windows.baselineMinutes
        injectMinutes   = $plan.windows.injectMinutes
        recoveryMinutes = $plan.windows.recoveryMinutes
    }
    planHash      = [string]$plan.frozenConfigHash
}
$manifestSummary = [ordered]@{
    verdict         = $findings.verdict
    mechanismProven = $findings.mechanismProven
    findingCount    = @($findings.findings).Count
    worstSeverity   = $(if (@($findings.findings).Count -gt 0) { @($findings.findings)[0].severity } else { 'none' })
}

$sealedAt = $null
$manifest = $null
if (-not $NoSeal) {
    $sealedAt = Get-ChaosUtcNow
    # At this point every durable input to the report exists. The preview
    # manifest supplies the exact seal timestamp and all non-report hashes; the
    # final manifest adds report.html after rendering, avoiding a self-hash cycle.
    $manifest = New-ChaosStudyManifest -StudyPath $studyPath -Identity $identity -Summary $manifestSummary -SealedAt $sealedAt -ExcludeReport
}

$html = New-ChaosStudyReportHtml -Plan $plan -RunRecord $runRecord -Findings $findings -Evidence $evidence -Manifest $manifest -CommandTrail $commandTrail
Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'report.html' -Content $html -AsText -SkipRedaction | Out-Null

$reportPath = Join-Path $studyPath 'report.html'
if ($OutputPath) {
    Write-ChaosTextFile -Path $OutputPath -Content $html
    $reportPath = $OutputPath
}

if (-not $NoSeal) {
    Complete-ChaosStudy -StudyPath $studyPath -Identity $identity -Summary $manifestSummary -SealedAt $sealedAt | Out-Null
}

$status = switch ($findings.verdict) {
    'Steady state held'      { 'success' }
    'Degraded but recovered' { 'warning' }
    'Steady state breached'  { 'error' }
    default                  { 'info' }
}

# The body states what the evidence showed. The hypothesis is what we believed
# beforehand, so it is labelled as such rather than printed as a conclusion --
# an "Inconclusive" verdict above a confident-sounding hypothesis reads as a pass.
$conclusion = switch ($findings.verdict) {
    'Steady state held' {
        'The action was proven to have landed and the steady-state objective survived it.'
    }
    'Degraded but recovered' {
        'The steady-state objective was breached while the action was live, and recovered within the recovery window.'
    }
    'Steady state breached' {
        'The steady-state objective was breached and had not recovered by the end of the recovery window.'
    }
    default {
        'The collected evidence cannot support a pass or fail. Treat the result as untested rather than passed, and review the limitations for the exact gap.'
    }
}

$cardBody = @"
$conclusion

Hypothesis stated before injection: $($plan.question.hypothesis)
"@

Write-Card -Title $findings.verdict -Status $status -Body $cardBody -Properties ([ordered]@{
    'Study'            = $study.studyId
    'Mechanism proven' = $findings.mechanismProven
    'Findings'         = @($findings.findings).Count
    'Limitations'      = (@($findings.limitations | ForEach-Object { $_.code }) -join ', ')
    'Report'           = $reportPath
    'Sealed'           = (-not $NoSeal)
})

if (@($findings.findings).Count -gt 0) {
    Write-Table -Title 'Findings' -Data @(
        foreach ($finding in $findings.findings) {
            [pscustomobject]@{
                Severity   = $finding.severity
                Confidence = $finding.confidence
                Finding    = $finding.title
            }
        }
    )
}

if ($Open -and $IsWindows) { Start-Process $reportPath }

Write-ChaosStudyNote -Message 'Next: run the chaos-study-history skill to compare this study with earlier ones.'
exit (Get-ChaosStudyExitCode -Name 'Success')
