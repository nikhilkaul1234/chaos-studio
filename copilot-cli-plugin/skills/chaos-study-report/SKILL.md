---
name: chaos-study-report
description: "Interpret persisted Chaos study evidence, render HTML and findings, and seal the study. No Azure queries; missing observations remain unknown."
---

# chaos-study-report

Read the run's persisted evidence, not fresh telemetry. This phase makes no
Azure calls; it writes local findings, reports, and optionally the study seal.

```powershell
./scripts/Invoke-ChaosStudyReport.ps1 -StudyId '<studyId>' -StudyRoot $store
# -NoSeal renders for review without sealing.
# -OutputPath must be outside the study directory.
```

An unexecuted plan has no run to report and is refused. A failed run with a null
observation can still produce an Inconclusive report. Absent measurements are
not zeros; absent recovery does not mean recovery.

Read both verdicts in `findings.v2.json`: `predicateVerdict` describes the
declared objective, while `studyVerdict` also accounts for exercise, mechanism
proof, and collateral findings. Do not collapse those into a stronger statement
than the evidence supports.

## Artifacts and seal

The first render writes `findings.v2.json` and `report.html` into the study.
Sealing writes `manifest.json` and `SEALED`. The final hash-bearing view is then
rendered **beside** the sealed directory as `report-<studyId>.html`, unless an
external `-OutputPath` is supplied. This lets it show the manifest hashes
without changing any sealed bytes. Re-reporting a sealed study also writes
outside it.

The report includes the frozen question/configuration, observed run outcome,
signal tables, findings, limitations, remediation, operation provenance, command
trail, and artifact hashes. `L16` preserves the conservative unknown-zone
projection warning. A seal records evidence integrity, not successful cleanup or
general resilience.

Use the renderer; do not fabricate evidence or a replacement report to get past
missing artifacts. Inspect unresolved residue and recorded service diagnostics.
See the shared [artifact contract and exit codes](../chaos-study/SKILL.md#host-contract-actual-outputs).
Compare studies through [history](../chaos-study-history/SKILL.md).
