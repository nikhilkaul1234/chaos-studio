---
name: chaos-study-scope
description: "Discover the workspace, actions, scenarios, and telemetry; validate a bounded preflight configuration; freeze a versioned study plan and one-use approval preview. No fault is injected."
---

# chaos-study-scope

Use live service data to define what a study can test. Do not infer action
availability, target identity, permissions, or recovery from a successful API
call. Scope **can mutate Azure**: it creates a preflight configuration, and
`-CreateWorkspace` permits workspace creation. It does not inject a fault.

## Inputs

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 -ListActions `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments
# Use -ListScenarios for workspace recommendations.

./scripts/Invoke-ChaosStudyScope.ps1 -Brief '<confirmed brief path>' `
    -SubscriptionId $sub -ResourceGroup rg-prod -WorkspaceName ws-payments `
    -StudyRoot $store -Adapter local-az
```

A confirmed brief supplies the study design; explicitly supplied parameters
override it. Direct expert scoping may instead provide `-Scenario`, `-Action`,
`-SteadyState`, `-FailureMechanism`, `-MechanismEvidence`, `-MechanismProbe`,
signal sources, and exercise inputs. Readiness still applies.

| Input | Contract |
| --- | --- |
| `-Parameters @{...}` | Scenario values; service defaults are merged into the configuration |
| `-FilterLocation`, `-FilterZone`, `-FilterPhysicalZone` | Frozen filters; logical/physical zones are mutually exclusive |
| `-ExcludeResource`, `-ExcludeType`, `-ExcludeTag @{...}` | Frozen exclusions; tags keep key/value structure |
| `-SignalSource` | `metrics:<name>[@resourceId][\|aggregation]` or `logs:<workspaceId>#<query>` |
| `-BaselineMinutes`, `-DurationMinutes`, `-RecoveryMinutes` | Positive windows; live baseline must cover at least two metric grains |
| `-UnavailableIntervals` | Optional owner tolerance, never below the measured minimum |
| `-EventRatePerSecond`, `-VulnerableWindowSeconds`, `-EligibleFraction` | Exercise inputs; unknowns are not replaced with invented measurements |
| `-AcceptWeakExercise` | Explicitly accepts weak exposure; does not turn it into evidence of resilience |
| `-CreateWorkspace -Scope <ARM ids>` | Explicit creation request; only a NotFound workspace response is treated as absent |
| `-SkipDiscovery` | Offline, non-executable plan; cannot produce armed approval |

## Zones and telemetry

`-FilterZone` accepts `1`, `2`, or `3`; `zone-redundant` is unsupported.
Unknown local zones retain candidates with a warning and plan limitation `L16`.
Known nonmatching zones are excluded locally. The service-side filter and
post-validation executable-target metadata remain authoritative.

Effective `Zones` parameters/defaults and `filters.zones` define the boundary.
Every executable target must report known `metadata.zones` within it; otherwise
scope exits `14` after bounded cleanup. Without a parameter/filter declaration,
legacy names recognize case-insensitive `zoneN`, `zone-N`, `zone_N`, `zone N`,
or standalone `azN` (digits for `N`). Targetless legacy legs retain their
selector check. `ZoneDown-1.0` is a versioned service name, not a zone-1 claim.

Two readiness queries, one metric grain apart, cover the trailing baseline.
Their newest non-null bucket ages determine
`ceil((maxAge + grainSeconds) / grainSeconds)`. Scope freezes the samples and
derived/selected tolerance in `discovery.telemetryLag`. No fixed interval-count
default is invented. Missing metric data, a baseline shorter than two grains,
or an override below the derived minimum stops before preflight.

## Preflight and human review

The preflight body uses the same parameters/filters/exclusions builder as run.
Validation must return a usable status. Non-repairable service errors stop with
`17` and do not request what-if. Unreadable execution plans or unverifiable
zones stop with `14`. Partial execution stops with `20` unless the human
supplies the exact printed `-AcceptPartialScenario` phrase.

These refusal paths record bounded cleanup: one DELETE and at most one
read-only reconciliation after a delete error. An unresolved configuration is
recorded as such, not reported as removed.

Successful scope writes `study-plan.v4.json` and
`approval-preview.v1.json`. Review the exact blast radius, effective legs,
zone claim (or "none - no zone claim"), `L16` if present, telemetry samples,
restoration duties, and RBAC preview before requesting human consent.
The preview is one-use; design confirmation and partial acceptance are not
fault or permission approval.

Resume the exact plan through the front door:

```powershell
../chaos-study/scripts/Invoke-ChaosStudy.ps1 -StudyId '<studyId>' -StudyRoot $store
```

Arming additionally needs `-DryRun:$false -Consent '<fresh preview phrase>'`
and, when required, the separate `-ApprovePermissions` phrase. Never self-confirm.
External adapters allow reads only and cannot complete preflight. See the
shared [host contract and exit codes](../chaos-study/SKILL.md#host-contract-actual-outputs).
