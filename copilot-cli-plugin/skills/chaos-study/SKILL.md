---
name: chaos-study
description: "Plan, preview, run, and report a bounded Chaos Studio V2 reliability study. Use live discovery, a frozen plan, fresh human approval, signal-based abort, and persisted evidence. Dry-run by default; external adapters are read-only."
---

# chaos-study

Test one falsifiable steady-state question against a defined workspace scope.
Keep observations, assumptions, and missing evidence distinct. A successful
control-plane call is not proof that the workload was exercised or recovered.

## Prepare once; preserve the human stops

Read the available code, deployment, dependencies, resilience behavior,
persistence, workload, telemetry, and identity in **one preparation pass**.
Record citations or explicit unavailability, then prepare the observation and
candidate files. Reuse those artifacts instead of repeating the analysis at
each question.

The CLI still enforces its design sequence. Exit `26` opens one customer
question; relay it through the host's interactive mechanism and submit the
customer's answer with `-QuestionId` / `-Answer`. Exit `24` means the design is
incomplete. One preparation pass does **not** batch or bypass these questions.

```powershell
./scripts/Invoke-ChaosStudy.ps1 -System orders-api `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments `
    -StudyRoot $store -Adapter local-az
# Continue the same brief with the observation/candidate files or the requested
# QuestionId, Answer, Select, and ConfirmPhrase. Keep the workspace inputs.
```

Review the selected candidate before returning the exact `-ConfirmPhrase`
printed by design (`study <candidateId> on <system> <hash8>`). It confirms the
design, not injection or RBAC changes. Direct phase scripts remain available;
they do not enforce the front door's design interview.

## Discover, scope, and preview

Use `-ListActions` / `-ListScenarios` with the workspace inputs to read the
service's current choices. Do not substitute a bundled catalog or invent an
action, role, or parameter. A confirmed design proceeds to
[scope](../chaos-study-scope/SKILL.md), which may create a preflight
configuration and validate it; this is not a read-only Azure phase.

If the effective plan is partial, review its skipped legs before providing
`-AcceptPartialScenario 'accept partial scenario <N> of <M> <hash8>'`.
That phrase accepts reduced coverage, not injection. Refused preflights record
bounded cleanup; a failed deletion remains unresolved in the ledger.

Review the frozen parameters, filters/exclusions, declared zone boundary,
projected resources, telemetry-lag samples, abort rules, restoration duties,
configuration lifecycle, and exact RBAC preview. `L16` warns that resources with
unknown local zones were retained in the conservative projection; service
filtering and executable-target metadata govern the zone boundary.

## Resume the exact study; approve separately

```powershell
./scripts/Invoke-ChaosStudy.ps1 -StudyId '<studyId>' -StudyRoot $store
```

This resumes the recorded study without new design or scoping. The default
dry-run does not query Azure or create a configuration.

Only a human may provide the freshly reviewed injection phrase:

```powershell
./scripts/Invoke-ChaosStudy.ps1 -StudyId '<studyId>' -StudyRoot $store `
    -Adapter local-az -DryRun:$false `
    -Consent '<exact phrase from this preview>'
# If the preview requires RBAC changes, also provide:
# -ApprovePermissions '<exact grant-access phrase from this preview>'
```

Consent has the form `inject <action> into <workspace> <planHash> approval
<previewHash>`. The separate RBAC phrase is `grant access on <workspace>
<grantHash8>`. Copy the actual phrases; never construct or self-confirm them.
`approval-preview.v1.json` must match the plan, be ready, and be unconsumed.
It is consumed before the execution attempt. Re-scope for a new attempt rather
than reusing a consumed phrase; `-Force` does not bypass that boundary.

Offline plans cannot arm. Plan drift, changed signal sources, unready previews,
non-success validation, and incompatible artifact generations stop execution.
Only concrete repairable permission errors can request what-if. A backend
`InternalError` does not authorize permission repair.

## Host contract: actual outputs

There is **no universal `CHAOS-RESULT` envelope** emitted by these scripts.
Use the process exit code, printed artifact paths, and persisted JSON. Design
questions use the existing `CHAOS-QUESTION-BEGIN` / `CHAOS-QUESTION-END` block.
Do not infer success from prose or manufacture missing artifacts.

| Artifact | Fields the host reads |
| --- | --- |
| `briefs/<briefId>/study-brief.v1.json` | `briefVersion`, `state`, `analysis`, `candidates`, `interview`, `confirmation`, `briefHash` |
| `<scopeHash>/<studyId>/study-plan.v4.json` | `planVersion`, `workspace`, `scope`, `scenario`, `action`, `windows`, `signals`, `safety.abortConditions`, `discovery.telemetryLag`, `readiness`, `frozenConfigHash` |
| `approval-preview.v1.json` | `previewId`, `previewHash`, `planHash`, `approvalReady`, `consumedAt`, `configuration`, `projectedResources`, `validation`, `permissionFix` |
| `run-record.v3.json` | `recordVersion`, `planHash`, `collectionState`, `scenarioRun` (including failure/abort), `windows`, `evidence`, `coverage`, `residue` |
| `residue-ledger.json` | `ledgerVersion`, `entries[].kind/id`, `entries[].cleanup.status/error/observation` |
| `evidence/` and `commands.jsonl` | collected signals, preflight failures, live abort checks/cancellation, command trail |
| `findings.v2.json` | `predicateVerdict`, `studyVerdict`, `findings`, `limitations` |
| `manifest.json`, `SEALED` | seal identity, `files` hashes, `contentHash`; a final hash-bearing `report-<studyId>.html` is rendered beside the sealed directory |

The store may contain incomplete or failed studies. A checkpoint with
`collectionState: recovery-pending` is not a completed run. Report missing
observations as unknown; do not equate absent recovery with recovery.

## External result-file exchange and SRE Agent

SRE Agent accepts the skill files and exposes PowerShell through
`RunInTerminal`, but its terminal does **not** inherit brokered Azure
credentials. Read-only listing and the discovery portion of scope before
preflight may be usable with an external executor. History/report read local
artifacts and need neither Azure credentials nor an adapter argument. This is
not an end-to-end armed-host claim.

`-Adapter external` supports **read-only phases only**. Armed mode, `-Consent`,
`-ApprovePermissions`, and mutating operation kinds are refused with exit `22`.
Full live scope cannot complete externally because preflight creates and
validates a configuration. Offline scope is non-executable. External armed
runs remain unsupported until the D4 execution/resume work is implemented.

For an allowed read, exit `18` leaves
`operations/<operationId>.request.json` under the printed study/staging path.
Read its `kind`, `tool`, `method`, `args`, `body`, `expectedResultSchema`,
`operationId`, and `requestHash`. Execute that exact read with authorized
credentials, then write `operations/<operationId>.result.json`:

```json
{
  "operationId": "<copied from request>",
  "requestHash": "<copied from request>",
  "result": "<actual operation payload, not a summary>"
}
```

The `result` placeholder represents JSON, not a required string:

- Chaos CLI reads and `auth.probe`: raw parsed CLI JSON, preserving `[]`.
- ARM REST reads (`actions.list`, `resource.get`, `metrics.query`,
  `roleAssignments.list`): `{ "body": <response JSON>, "headers": {} }`;
  include headers only if actually captured.
- `logs.query`: raw Log Analytics JSON (including `tables`), not that wrapper.
- `validation.v2`: flattened or ARM `properties` validation fields are
  normalized by the receiver.

Re-run the same read command after writing its result. The receiver checks
request identity and schema and records a result digest in
`operations/provenance.jsonl`. Identical requests reuse stored results; do not
describe that cache as fresh polling. If the host read fails, surface the
failure rather than storing invented/null success.

## Exit codes

This is the shared table for the six study skills; phase guides link here.

| Code | Meaning / required response |
| --- | --- |
| `0` | Phase completed, including dry-run; inspect its artifacts |
| `1` | Error; stop and inspect diagnostics |
| `4` | Broad permission change lacks consent (shared exit contract) |
| `10` | Readiness failed; correct the reported input/evidence gap |
| `11` | Missing, mismatched, unready, or consumed consent/preview |
| `12` | Frozen plan or execution inputs drifted |
| `13` | Study/brief already sealed or confirmed |
| `14` | Execution scope cannot be verified, including zone mismatch |
| `15` | Studies are not comparable |
| `16` | Live action discovery unavailable; do not substitute a catalog |
| `17` | Configuration validation failed; preserve the service error |
| `18` | Read-only host operation pending; satisfy its exact request |
| `19` | Separate permission approval required; inspect the exact grants |
| `20` | Partial scenario not accepted; review the skipped legs |
| `21` | Insufficient exercise exposure; revise inputs or explicitly accept the weak exercise |
| `22` | Adapter unavailable or external operation unsupported |
| `23` | Incompatible/read-only artifact generation; create a new study |
| `24` | Design incomplete or answer rejected |
| `25` | Rerun cannot reproduce the frozen inputs |
| `26` | Customer input required; ask the printed question or confirmation |

No nonzero exit authorizes falling through to the next phase. A pause is still
a stop. The hard-stop and artifact regressions live in
[tests](tests/), with effective-leg coverage in the scope/run test directories.
