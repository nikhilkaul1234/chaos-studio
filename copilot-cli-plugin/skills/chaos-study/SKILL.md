---
name: chaos-study
description: "Run a complete Chaos reliability study against an Azure workspace scope: frame a falsifiable steady-state question, discover the actions Chaos Studio actually offers for that region live, freeze a plan, execute a validated scenario configuration with explicit consent, collect before/during/after evidence, and produce a self-contained HTML report. Start here for 'is my service actually resilient to X?' questions."
---

# chaos-study — reliability studies, end to end

Chaos engineering is an experiment in the scientific sense, not a stunt. This
skill runs it: it asks a question that can be proven **wrong**, executes a real
action against real resources, and reports what the evidence actually showed.

## The question this suite answers

> Does **`<steady state>`** hold when I execute **`<action>`** across
> **`<workspace scope>`**?

If you cannot phrase the goal that way, stop and reframe it. "Test resilience"
is not a study — there is no way for it to fail, so it cannot teach you anything.

## Principles

**A study is a falsifiable claim.** Every study needs a steady-state predicate
that is measurable beforehand and could plausibly break during the run.

**The platform decides what is possible, not this plugin.** Every armable plan
reads the available actions live from Chaos Studio for the workspace's region.
This suite ships **no** action catalogue. `-SkipDiscovery` can capture an
offline, explicitly unverified planning draft, but that draft cannot prepare
approval or arm; a fresh live-discovered plan is required first.

**What is in scope is read from the service.** The resources a run will touch
come from the workspace's discovered resources, not from an assertion in the
plan. If the scope is empty, or the action applies to nothing in it, the study
is refused before anything runs.

**Evidence beats vibes.** A verdict is only as good as the signals behind it. If
a signal was not collected, the report says *not measured* — never `0`, never a
plausible-looking guess. Absent evidence is reported as absent.

**Nothing runs without fresh human consent.** `-DryRun` defaults to `$true`.
Next, `chaos-study-run -PrepareApproval` creates and validates a temporary
configuration, prints the exact frozen resource list and the exact redacted RBAC
what-if response, and deletes the configuration. The agent must stop. Only a
human may type the printed, plan-hash-bound phrase in a new invocation with
`-DryRun:$false`; an agent may not copy or self-confirm it.

**Blast radius is bounded before it is armed.** Workspace, scope, filters,
exclusions, action, parameters and duration are frozen into the plan and hashed.
If the plan changed after you approved it, the run refuses rather than executing
something you did not review.

**A clean result is not automatically good news.** If the action never actually
reached the resources, "steady state held" means nothing. The report says
*Inconclusive* rather than claiming a pass it cannot support.

## The five skills

This is a suite, not a monolith. Use the front door unless you need one phase.

| Skill | Owns |
| --- | --- |
| **chaos-study** | chains the phases below; the default entry point |
| **chaos-study-scope** | workspace, scope, live action discovery, freezing the plan |
| **chaos-study-run** | configuration, validation, consent, execution, evidence |
| **chaos-study-report** | interpretation, findings, the HTML report |
| **chaos-study-history** | list, compare, and re-run past studies |

Each phase persists its own output, so a chain that fails partway can be resumed
from that phase — you never have to restart from scratch.

## Portable shell-agent contract

The method is host-neutral. Any shell-capable agent may use it if the host can
run PowerShell 7.4+ and Azure CLI 2.75+, preserve `CHAOS_STUDY_ROOT` and the
study id across turns, display cards and stderr without suppression, propagate
the documented exit codes, and halt for the human-origin approval boundary.
Copilot CLI supplies plugin installation and discovery only. SRE Agent is the
strongest intended integrated target, but this PR has not yet validated its
skill-loading or invocation path.

## Usage

**1. Ask the platform what it can do here.** The answer depends on the region and
what is in scope, and it changes as Chaos Studio ships new actions:

```powershell
./scripts/Invoke-ChaosStudy.ps1 -ListActions `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments

./scripts/Invoke-ChaosStudy.ps1 -ListScenarios `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments
```

Each action is printed with its canonical id, its type, what it applies to and
its parameter schema — all as the service reported them.

**2. Plan and preview.** This executes nothing:

```powershell
./scripts/Invoke-ChaosStudy.ps1 `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments `
    -Scenario '<scenario from -ListScenarios>' `
    -Action '<action from -ListActions>' `
    -SteadyState 'successRate >= 99.5' -SignalSource 'metrics:Availability'
```

Read the preview. It shows what is in scope after filters and exclusions, the
windows, and the configuration that would be created.

**3. Prepare the approval boundary.** This creates and deletes a temporary
configuration but does not grant roles or start a scenario:

```powershell
../chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1 `
    -StudyId <studyId> -PrepareApproval
```

**4. Stop for the human.** Show the exact frozen blast radius and exact RBAC
preview. A human—not the agent—types the printed phrase in a new invocation:

```powershell
../chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1 `
    -StudyId <studyId> -DryRun:$false -Consent '<human-typed phrase>'
```

The run revalidates that the RBAC preview has not changed, applies only those
approved grants, collects baseline, executes with live abort evaluation,
collects during and recovery evidence, then can be reported and sealed.

## Reading the verdict

| Verdict | Means |
| --- | --- |
| **Steady state held** | The action landed and the objective survived it |
| **Degraded but recovered** | Breached during the run, recovered afterwards |
| **Steady state breached** | Breached and still breached after recovery |
| **Inconclusive** | The action could not be proven to have landed |

Severity follows recovery, not drama: a breach that never recovers is `critical`;
the same breach that self-heals is `medium`.

## Choosing signals

The suite collects only what you name, because what counts as evidence depends
on the system under study. Two forms:

- `metrics:<name>` — an Azure Monitor metric on the single scoped resource, or
  `@<resourceId>` to pin one, `|<aggregation>` to override the aggregation. A
  scope holding several resources has no implied metric target, so pin it.
- `logs:<workspaceId>#<kql>` — a Log Analytics query

Name at least one signal that would be expected to *move* under the action. That
is what separates "resilient" from "the action never landed".

## Before you run against production

Scoping checks readiness first. A study whose objective cannot be measured, or
whose parameters do not satisfy the live schema, teaches nothing — so readiness
failure (exit `10`) is a real answer, not a gate to bypass. Exit `14` means
nothing is in scope or the action does not apply to what is; running anyway
would produce a false pass. Exit `16` means the platform could not be asked what
it offers, and the suite refuses to substitute its own list.

## Progressive discovery

Action identifiers, parameters and required permissions are **not** documented
here, because they are the service's to state and this plugin's to relay. Get
them from `-ListActions`. What lives here is the method:

- **`references/study-method.md`** — the five-phase method and why it is split
- **`references/report-contract.md`** — what the report may and may not claim

Kubernetes/AKS-specific guidance is deliberately absent: those actions are not
available from the actions endpoint yet. When they ship, they appear in
`-ListActions` automatically, with no change to this suite.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Error |
| `10` | Readiness gates failed |
| `11` | Consent declined or phrase mismatch |
| `12` | Plan changed after it was frozen |
| `13` | Study already sealed |
| `14` | Scope unverified — nothing in scope, or the action does not fit it |
| `15` | Studies not comparable |
| `16` | Live action discovery unavailable — there is no fallback |
| `17` | Scenario configuration failed validation |

## Notes

- Chaos Studio **V2** only: workspaces are the lifecycle root and resource
  selection flows through workspace scopes. There is no V1 path and no fallback.
- Core is `pwsh`, `az`, and Azure Resource Manager. There is no required SRE
  Agent or MCP dependency.
- Studies persist under a dated store, so later chats can list, compare, and
  re-run them. Sealed studies are immutable — re-testing scopes a **new** study
  rather than overwriting the record.
- Scope may create a workspace only with explicit `-CreateWorkspace`; approval
  preparation creates and deletes a temporary scenario configuration. The
  scenario run and any approved RBAC grants occur only in the armed run phase.
