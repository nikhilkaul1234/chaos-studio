---
name: chaos-study-run
description: "Preview or execute a frozen Chaos Studio study. Require fresh plan-bound human consent, separate RBAC approval, successful validation, live signal-based abort, and recorded cleanup. Dry-run by default; external execution is refused."
---

# chaos-study-run

Preview the exact study before requesting approval:

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId '<studyId>' -StudyRoot $store
```

Default dry-run renders the frozen hash, effective parameters, zone boundary,
telemetry tolerance, configuration lifecycle, restoration expectations, and
approval preview. It issues no Azure query or mutation.

Only after fresh human review:

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId '<studyId>' -StudyRoot $store `
    -Adapter local-az -DryRun:$false -Consent '<exact preview phrase>'
# Add -ApprovePermissions '<exact grant-access phrase>' only when required.
```

Never construct or self-confirm either phrase. The injection phrase binds the
full plan hash and preview hash; the permission phrase binds the exact grant
set. Missing, changed, unready, or consumed previews cannot arm, including with
`-Force`. A consumed preview requires a fresh live scope and approval.

## Execution boundaries

Offline plans, old read-only generations, plan drift, nonpositive windows,
changed signal sources, or unusable abort rules stop execution. `-SignalSource`
is not a way to append unapproved sources to an armed plan.

The run resolves a preflight or creates a configuration with the frozen body,
then requires successful validation and matching effective legs. What-if is
requested only for concrete repairable permission errors. Incomplete permission
details cannot authorize grants; `InternalError` does not justify RBAC repair.
Error remediation describes the permission operations actually recorded.

Baseline evidence precedes the scenario start. During injection, the frozen
predicate and missing-signal rules are evaluated using the frozen trailing
telemetry window. A trigger requests immediate adapter cancellation and writes
`evidence/during/abort-checks.json` and `abort-cancellation.json`.

Cleanup requests cancellation/deletion and records observed outcomes in the
residue ledger. DELETE is not retried; an error permits one read reconciliation.
`-KeepConfiguration` deliberately retains the configuration and records that
choice. Cleanup is not guaranteed by a `finally` block after process termination
or service failure; inspect unresolved residue.

A run checkpoint is persisted before recovery wait, then updated after
post-window collection. `run-record.v3.json` records failure/abort, evidence,
coverage, and residue. Missing telemetry or recovery is not reported as measured
success. Reporting can consume a failed run with null observation.

## External adapter restriction

The external adapter supports read-only phases only. Selecting it explicitly or
through the plan refuses armed mode, `-Consent`, and `-ApprovePermissions` with
exit `22`, before execution. Mutating external operation requests are also
blocked. Do not instruct a host to execute a pending scenario start or permission
repair; the D4 external armed/resume path is not supported.

See the shared [exit codes](../chaos-study/SKILL.md#exit-codes) and
[external result-file contract](../chaos-study/SKILL.md#external-result-file-exchange-and-sre-agent).
After an execution attempt, report the persisted evidence with
`chaos-study-report -StudyId <studyId>`; do not hand-write a success result.
