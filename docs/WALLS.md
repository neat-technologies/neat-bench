# Walls and the model-free certificate

A **wall** is a task whose answer is *provably absent from the source* and present only in the runtime graph. That property is what makes the without-NEAT arm fail for a principled reason — and what stops a skeptic saying "you cherry-picked an obscure task built for NEAT." The wall is a wall **by construction**, certified model-free.

## The three axes (as agent tasks)

- **data** — "this write is corrupting table T; which symbol issues it?" across an ORM / dynamic boundary.
- **dispatch** — a 500 whose cause is the concrete impl that ran behind an interface/DI, three hops from the symptom.
- **async** — a consumer breaks because a producer symbol changed an event's payload, with no static link between them.

## The certificate

A wall certifies iff **both** hold:

1. **Source-absence** — a machine-checkable predicate over the pinned source tree returns **empty**. Proof the answer is not readable from code.
2. **Runtime-carried & BLIND** — the `carrying_edge` is present as OBSERVED/INFERRED **and** `claim-classifier.mjs` puts it in the **BLIND** bucket: no static edge at any grain, not a grain-refinement, not a NEAT identity artifact.

`wall-certificate.mjs` enforces both. Point 2 is why it *refuses* the sample wall on the legible Express fixture: the carrying edge there classifies `IDENTITY_SUSPECT` (the `database:mongodb`↔`database:127.0.0.1` split), not `BLIND` — static knew the dependency, so it is not a wall. The certificate will not rubber-stamp.

## Wall spec schema

```jsonc
{
  "id": "unique-id",
  "axis": "data | dispatch | async",
  "symptom": "what the agent is told (the cause/file/fix are never shown)",
  "required_facts": [ { "type": "...", "source": "...", "target": "..." } ],
  "carrying_edge": { "type": "...", "source": "...", "target": "..." },
  "absence_predicate": { "cmd": "grep/AST predicate over src/", "expect": "empty" },
  "symptom_probe": { "healthy": "...", "buggy": "..." }
}
```

- `required_facts` feed the **sufficiency** guard: the key facts the agent must have grounded to solve it.
- `carrying_edge` is the one runtime edge the certificate checks is BLIND.
- `symptom_probe` drives the objective PASS/FAIL correctness oracle (the judge-free `verify-fix` pattern carried from `neat-agent-bench`).

## Bug-selection rule

**Found > constructed.** A real historical bug (git-revert a real fix) beats a planted one — same reason a clean target carries selection bias. When constructing, the certificate is the discipline that keeps it honest: if it can't certify, it isn't a wall, and it belongs in the smoke test, not the benchmark.
