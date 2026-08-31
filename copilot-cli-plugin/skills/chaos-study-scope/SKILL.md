---
name: chaos-study-scope
description: "Frame a Chaos reliability study before anything runs: resolve or create a Chaos Studio V2 workspace, read the resources the service discovered inside its scopes, discover live which actions and scenarios are actually available for that region, express a falsifiable steady-state predicate, verify the action fits what is in scope, then freeze and hash an auditable study plan."
---

# chaos-study-scope — decide what the study can prove

Most failed chaos studies fail here, not during execution. They run an action
nothing was measuring, over a scope that could not receive it, to answer a
question that could not have come back false.

This skill's job is to catch that before production is touched.

The method is portable to any shell-capable agent that can run PowerShell and
Azure CLI, preserve the returned study id and durable study store, propagate
exit codes, and hand approval to a human. Copilot CLI packaging is not part of
the execution contract. SRE Agent accepts the files, resolves uploaded paths,
and exposes PowerShell 7.6.4 through `RunInTerminal`, but its generic terminal
does not inherit brokered Azure credentials. End-to-end Azure scoping is not
supported or validated there; SRE Agent remains an integration candidate.

## Principles

**The workspace is the lifecycle root.** Scopes, discovered resources,
scenarios, configurations and runs all hang off one workspace. Scoping resolves
it first, and everything the plan records is anchored to it.

**Ask the platform; never assume.** The list of available actions is fetched
from `Microsoft.Chaos/locations/{region}/actions` for the workspace's region, on
every scope. That response is authoritative: its `canonicalId`, `actionType`,
`appliesTo` and `parametersSchema` are what the plan records. Scenarios come
from the workspace's own recommendation list.

**No bundled catalogue, no fallback.** This skill ships no action definitions.
When live discovery is requested and the actions endpoint cannot be reached —
not logged in, no permission, region unresolved — scoping stops with exit `16`
and says so. It does not degrade that attempted live plan to a stale local list.
`-SkipDiscovery` is a separate, explicit offline planning mode whose output is
marked unverified and cannot arm.

**What is in scope is read, not asserted.** The resources a run will touch come
from the workspace's discovered resources, not from the operator's mental model.
The two diverge constantly — a scope grows a resource nobody remembered, or a
resource the plan names was never onboarded and would have been silently
skipped.

**A steady state must be falsifiable.** `successRate >= 99.5` can be violated.
"the service is healthy" cannot. Scoping rejects the second kind.

**Check the fit before promising the study.** An empty scope, or an action that
applies to no resource type present in the scope, means the study cannot prove
anything. Scoping says so up front (exit `10` / `14`) instead of failing halfway
through a run.

**Parameters are validated against the service's schema.** Not against a copy of
it. Required properties, enums and types come from the live `parametersSchema`,
so validation cannot drift from the platform.

**Freeze what was approved.** The plan is written once and hashed. The run skill
re-computes that hash; if it changed, the run refuses (exit `12`). What you
reviewed is what executes.

**Discovery is read-only.** Scoping issues only reads, unless you explicitly ask
for `-CreateWorkspace`. Nothing else here mutates anything.

## Usage

**List what the platform offers** — start here; the action constrains the
question, and only the service knows what exists in that region today:

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 -ListActions `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments

./scripts/Invoke-ChaosStudyScope.ps1 -ListScenarios `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments
```

**Scope a study:**

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments `
    -Scenario '<scenario from -ListScenarios>' `
    -Action '<action from -ListActions>' `
    -SteadyState 'successRate >= 99.5' `
    -SignalSource 'metrics:Availability' `
    -DurationMinutes 10 -BaselineMinutes 5 -RecoveryMinutes 10
```

`-Action` accepts the canonical URN, the action name or the display name; a
partial match is accepted only when it is unambiguous.

Useful switches:

- `-CreateWorkspace -Scope <armId...>` — create the workspace over those scopes
  when it does not exist. Without it, a missing workspace is an error rather
  than an implicit provisioning action.
- `-Location` — region for a workspace being created
- `-Parameters @{ ... }` — scenario knobs, validated against the live schema
- `-FilterLocation` / `-FilterZone` / `-ExcludeResource` / `-ExcludeType` /
  `-ExcludeTag` — the blast radius, frozen onto the plan as the configuration's
  `filters` and `exclusions`
- `-SignalSource` — required evidence for both the verdict and live abort
  evaluation (`metrics:` / `logs:`); no defaults are invented for you
- `-Hypothesis` — what you expect to happen, recorded for honesty at report time
- `-SkipDiscovery` — plan without contacting Azure. The plan then carries
  limitation `L10` and records the scenario and action as `unverified-offline`;
  no metadata is fabricated. This plan cannot prepare approval or arm. Re-scope
  without the switch to create a fresh live-discovered plan before execution.

Output is a frozen `study-plan.v1.json` plus a study id. Nothing is executed.

## What the plan records

The plan is the contract the rest of the suite reads:

| Section | Why it matters |
| --- | --- |
| `workspace` | the lifecycle root — subscription, group, name, id, region, scopes |
| `scope` | what is actually in scope: discovered resources, types, blast radius, and how many survive it |
| `action` | live action metadata: canonical id, type, what it applies to, schema, roles |
| `scenario` | the scenario that will execute, its version and parameters |
| `discovery` | which endpoint answered, when, and how much it returned |
| `question` | the steady-state predicate, parsed and normalised |
| `windows` | baseline / inject / recovery minutes |
| `signals` | what evidence must be collected for the verdict to mean anything |
| `readiness` | gate results and any limitation codes they imply |
| `planHash` | integrity seal checked before execution |

## Choosing windows

Baseline exists to establish what "normal" looked like *today*, not last week.
Recovery exists to distinguish a transient dip from real damage — without it, a
system that never recovers looks identical to one that recovers instantly.

Injection windows of three minutes or less are recorded as limitation `L7`: too
short to distinguish resilience from luck.

## Progressive discovery

Action identifiers, parameter shapes and required permissions are **not**
documented here. They are the service's to state, and restating them locally is
exactly the drift this design removes. Use `-ListActions` and `-ListScenarios`.

What lives locally is the method:

- `../chaos-study/references/study-method.md` — the method behind the phases
- `../chaos-study/references/report-contract.md` — what a report may claim

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Plan frozen |
| `1` | Error |
| `10` | Readiness gates failed |
| `14` | Scope unverified — nothing in scope, or the action does not fit it |
| `16` | Live action discovery unavailable — there is no fallback |

## Next

Review the plan, then prepare the exact blast-radius and RBAC preview:

```powershell
chaos-study-run -StudyId <studyId> -PrepareApproval
```

After the preview, the agent stops and a human types the printed phrase in a new
armed invocation.
