---
name: chaos-study-design
description: "Prepare an evidence-backed reliability-study brief, collect the customer's answers, recommend candidates, and obtain the exact design confirmation before scope."
---

# chaos-study-design

Prepare the analysis and candidates once. Read code, deployment, dependencies,
resilience behavior, persistence, workload, telemetry, and identity; cite what
was observed and state what was unavailable. Do not replace missing customer
intent, risk appetite, or measurements with agent-authored answers.

One preparation pass does **not** change the runtime interview. The CLI keeps
its state transitions and asks one unresolved question at a time. Use the
front door for the integrated workflow, or these existing direct actions:

```powershell
./scripts/Invoke-ChaosStudyDesign.ps1 -Action start -System orders-api -StudyRoot $store
./scripts/Invoke-ChaosStudyDesign.ps1 -Action analyze -BriefId '<id>' `
    -StudyRoot $store -ObservationFile ./analysis.json
./scripts/Invoke-ChaosStudyDesign.ps1 -Action candidates -BriefId '<id>' `
    -StudyRoot $store -CandidateFile ./candidates.json
./scripts/Invoke-ChaosStudyDesign.ps1 -Action interview -BriefId '<id>' -StudyRoot $store
```

At exit `26`, relay the printed question to the customer through the host's
interactive mechanism. The JSON between `CHAOS-QUESTION-BEGIN` and
`CHAOS-QUESTION-END` carries the question fields. Submit the answer verbatim:

```powershell
./scripts/Invoke-ChaosStudyDesign.ps1 -Action answer -BriefId '<id>' `
    -StudyRoot $store -QuestionId '<questionId>' -Answer '<customer answer>'
```

Do not batch unanswered questions or fall through to scope. Exit `24` leaves
the design incomplete; correct the named gap. Reuse the analysis instead of
repeating it at every pause.

After the required answers, recommend and ask the customer to select and confirm:

```powershell
./scripts/Invoke-ChaosStudyDesign.ps1 -Action recommend -BriefId '<id>' -StudyRoot $store
./scripts/Invoke-ChaosStudyDesign.ps1 -Action confirm -BriefId '<id>' -StudyRoot $store `
    -Select '<candidateId>' -ConfirmPhrase '<exact phrase printed by recommend>'
```

The confirmation phrase is `study <candidateId> on <system> <hash8>`.
Review the candidate's mechanism, evidence, probe, scope, exposure, collateral
risks, and abort criteria before confirmation. Confirmation is not injection
consent or RBAC approval. A confirmed brief cannot be edited in place.

The durable artifact is
`<studyRoot>/briefs/<briefId>/study-brief.v1.json`; it includes analysis,
candidates, interview, recommendation, confirmation, state, and `briefHash`.
Pass the confirmed file to scope with `-Brief`. Explicit scope overrides still
require review in the newly frozen plan.

Design does not create a configuration or inject a fault. Provisional discovery
is not proof the platform supports a candidate. See the shared
[exit codes and host contract](../chaos-study/SKILL.md#exit-codes);
[design-method.md](../chaos-study/references/design-method.md) provides background.
