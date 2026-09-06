---
name: chaos-study-history
description: "List, inspect, compare, and print rerun commands for persisted Chaos studies. No Azure operations; reruns create a new study rather than overwrite evidence."
---

# chaos-study-history

Read the dated study store to inspect prior evidence and compare compatible
studies. This phase does not query Azure, execute a printed rerun command, or
grant permission to repeat an injection.

```powershell
./scripts/Invoke-ChaosStudyHistory.ps1 -Action list -StudyRoot $store -Json
./scripts/Invoke-ChaosStudyHistory.ps1 -Action show -StudyRoot $store -StudyId '<id>'
./scripts/Invoke-ChaosStudyHistory.ps1 -Action compare -StudyRoot $store `
    -StudyId '<candidate>' -Against '<baseline>'
./scripts/Invoke-ChaosStudyHistory.ps1 -Action rerun -StudyRoot $store -StudyId '<id>'
```

Comparison checks compatibility and refuses unlike studies with exit `15`.
Read the reasons instead of treating incomparable outcomes as improvement.
Findings are matched by stable keys; both predicate and study verdicts matter.

`rerun` prints a scope command with frozen scenario parameters, blast-radius
axes, tag hashtables, windows, and selected telemetry tolerance. If an input
cannot be reproduced, exit `25` refuses to print a silently widened command.
The new scope performs fresh discovery and may reject an old tolerance that is
below its newly measured minimum. It needs new human approval before injection.

Use an explicit `-StudyRoot` when coordinating hosts. Studies live under
`<root>/<scopeHash>/<studyId>/`; the index is a cache of artifacts, not a source
of evidence. Legacy plans remain readable but cannot acquire a new execution
contract in place. Sealed studies remain unchanged.

See the shared [artifact contract and exit codes](../chaos-study/SKILL.md#host-contract-actual-outputs).
