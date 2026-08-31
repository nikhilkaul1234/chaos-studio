---
name: chaos-study-run
description: "Prepare and execute a frozen Chaos study plan against Azure using Chaos Studio V2: verify integrity and live discovery, display the exact frozen blast radius and RBAC what-if changes, require fresh human plan-bound consent, evaluate automatic abort conditions against live evidence, collect baseline/during/recovery evidence, and always clean up. Dry-run by default."
---

# chaos-study-run — approval preparation and bounded execution

Scoping is read-only unless `-CreateWorkspace` was explicitly requested.
This skill can create and delete a temporary configuration while preparing
approval; only its armed path can grant the previewed RBAC changes or execute a
real Chaos Studio scenario.

## Principles

**Dry run is the default.** `-DryRun` defaults to `$true`. A dry run walks the
entire sequence — plan verification, the configuration it would create, the
consent phrase — and executes nothing. Read it before arming anything.

**Consent is fresh and human-originated.** `-PrepareApproval` displays the exact
frozen blast radius and exact redacted RBAC what-if response, then deletes its
temporary configuration. The agent must stop. A human must type the printed
plan-hash-bound phrase in a new invocation with `-DryRun:$false`. A wrong,
pre-preview, reused, or agent-supplied phrase is not approval and exits `11`.

**The plan is verified, not trusted.** The plan hash is recomputed before
execution. Any drift since scoping exits `12`. If the blast radius changed after
you approved it, this refuses rather than running something you did not review.

**Validation is a gate, not advice.** Approval preparation validates a temporary
configuration and freezes the service's exact permission preview. The armed run
recreates and revalidates it. If that preview changed, nothing is granted or
started and fresh approval is required. Only the exact approved preview may be
applied before validation is repeated. Each preview entry identifies the target
resource, principal, role definition, and assignment scope. Applying it requires
the caller to hold `Microsoft.Authorization/roleAssignments/write` on those
scopes (normally Owner or User Access Administrator).

**Offline plans never arm.** `-SkipDiscovery` plans remain useful planning
artifacts, but `-PrepareApproval`, `-Force`, and `-Consent` cannot make one
executable. Scope again with live discovery first.

**Abort is live, not cleanup.** During injection the frozen predicate and
telemetry-availability conditions are evaluated against live signal queries. A
trip calls the supported scenario-run cancel operation immediately and persists
the checks, reason, timestamp, and cancellation response. Missing telemetry
cannot become a successful recovery verdict.

**Evidence is collected around the run, not just during it.** Baseline, during,
and post windows are all collected. Without baseline there is no "normal" to
compare to; without post there is no way to tell degradation from damage.

**Missing evidence stays missing.** A collector that fails records `null` and a
reason. Nothing is interpolated, averaged, or inferred to fill a gap — the report
would rather say *not measured* than mislead.

**Cleanup is unconditional.** The scenario configuration is deleted in a
`finally` block, so a crash, a Ctrl-C, or a failed collection still tears it
down. A run still in flight is cancelled. `-KeepConfiguration` is rejected;
cleanup failures are retained in `evidence/cleanup/*.json` instead of being
hidden or treated as successful cleanup.

**Sealed studies are immutable.** Re-running a sealed study exits `13`. Re-test
by scoping a new one, so history stays comparable.

## Usage

**Preview** (this is the default, and executes nothing):

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId latest
```

**Prepare approval** (temporary configuration only; no grants or scenario run):

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId <studyId> -PrepareApproval
```

**Stop for a human**, then arm with the phrase that human types after reviewing
the exact previews:

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId <studyId> -DryRun:$false `
    -Consent '<human-typed phrase>'
```

Switches worth knowing:

- `-SignalSource` — add evidence sources beyond the plan's (`metrics:` / `logs:`)
- `-PollSeconds` — scenario run status poll interval
- `-PrepareApproval` — freeze the exact blast-radius/RBAC preview required before consent

## What actually happens

1. Load the plan, re-verify its hash, and refuse offline/unverified plans
2. Require an unconsumed approval preview for this exact plan and fresh human consent
3. Recreate the scenario configuration on the workspace, carrying the plan's
   frozen parameters, filters and exclusions
4. Validate it; compare the exact missing-grant preview with the approved one,
   apply only an exact match, and validate again
5. Refuse to continue unless validation now says `Succeeded`
6. Collect the **baseline** window
7. Execute the configuration; poll the scenario run and live signals until it
   reaches a terminal state, an abort condition trips, or the window closes
8. Collect the **during** window while the run is live
9. Wait out recovery, then collect the **post** window
10. Cancel any in-flight run and delete the configuration (always), then write
    `run-record.v1.json` and evidence

Steps 3–5 run before step 6 deliberately. A configuration that cannot validate
is a run that fails within seconds, and finding that out after a baseline window
has already elapsed wastes the window and the study. `Start-ChaosStudyScenarioRun`
takes the validation result as a required argument and asserts it again as the
last thing before `run start`, so the guarantee belongs to the function that
starts the run rather than to the order of statements in one caller.

## Portable shell-agent contract

The host must run PowerShell 7.4+ and Azure CLI 2.75+, preserve
`CHAOS_STUDY_ROOT` and the study id across invocations, display all preview and
failure output, propagate exit codes, and stop after `-PrepareApproval`. Copilot
CLI is one packaging host, not a runtime dependency. SRE Agent accepts the files,
resolves uploaded paths, and exposes PowerShell 7.6.4 through `RunInTerminal`,
but its generic terminal does not inherit brokered Azure credentials. End-to-end
approval and execution are not supported or validated there; SRE Agent remains
an integration candidate.

The configuration is built from what the plan captured live at scope time: the
scenario, its parameters as the `{key,value}` pairs the service takes, and the
blast radius as `filters` and `exclusions`. An empty blast-radius member is
omitted rather than sent — `{"locations":[]}` means *no locations*, which would
silently turn a real study into a no-op that still reports success.

## Implementation note

Execution uses Chaos Studio **V2** exclusively: workspaces are the lifecycle
root, resource selection comes from workspace scopes and the resources the
service discovered inside them, and the run is a scenario run against a
validated scenario configuration. There is no V1 path and no fallback to one.
Api-versions are pinned centrally so a service-side default change cannot
silently alter behaviour.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (including a completed dry run) |
| `1` | Error |
| `11` | Consent declined or phrase mismatch |
| `12` | Plan changed after it was frozen |
| `13` | Study already sealed |
| `17` | Scenario configuration failed validation |

## If it fails partway

The study state on disk reflects exactly how far it got, and whatever evidence
was collected is kept. Because reporting is a pure read of that evidence, a
partial run can still be reported — the report will simply carry the gaps as
explicit limitations rather than hiding them.

## Next

```powershell
chaos-study-report -StudyId <studyId>
```

See `../chaos-study/references/study-method.md` for how the windows are chosen.
Per-action blast radius is not documented locally: it comes from the live action
metadata frozen into the plan, which the dry run prints in full.
