# 9. Baseline Architecture

## 9.1 Entity

`Baseline` (domain) / `BaselineEntity` (SwiftData) — one per mode, unique on `mode` [PRD OQ-5: mode field on Baseline]. Contents: per-metric `BaselineMetricStat` (mean, sd, floor flag), `cadenceBPM` (metronome source), `algorithmVersion`, `establishedAt`, 5 `sourceSessionIDs`.

## 9.2 Calculation Service

`BaselineCalculationService` — **pure domain service**: input = metrics of the **first 5 valid sessions of that mode** (in chronological order); output = `Baseline`. Responsibilities: per-metric mean/SD, cadence reference aggregation [REC: mean of the 5 session cadence means], algorithm-version stamping. Unit-tested with synthetic metric sets; no persistence knowledge.

## 9.3 Repository

`BaselineRepository`: `baseline(for mode:)`, `countValidSessions(for mode:)`, `establish(baseline:)` (create-only; uniqueness on mode enforced). **All APIs require an explicit `TestMode` parameter** — there are no mode-less baseline queries, making cross-mode mixing a compile-time impossibility rather than a convention [PRD OQ-5 hard rule].

## 9.4 State & Calibration Lifecycle (per mode)

```
notStarted ──valid session #1──► building(1) ──…──► building(4)
     building(4) ──5th valid session commits──► established(Baseline)
     established: FROZEN for v1 (no recalibration, no updates from later sessions) [PRD §6]
     invalid sessions never advance the counter [PRD §6, §7]
```

- The counter is derived from persisted valid-session count per mode — recomputed, not a mutable field, so a failed/rolled-back commit cannot corrupt it [REC].
- `BaselineState` is exposed to features via a lightweight read model; Score screen, audio selector, Home, Clinician Summary all consume the same derivation — one source of truth [PRD §5, §7].

## 9.5 Scoring Coupling

- Session 5 (the establishing session) itself: metrics only, "building" presentation [PRD §5].
- Session 6+ valid: normalized against that mode's frozen baseline; score persisted on the session [PRD §7].
- A session is compared **only** with the baseline of the same mode [PRD OQ-5] — enforced by passing `TestMode` through every call chain (repository → processor → scorer).

## 9.6 Validity & Versioning

- A baseline is valid iff derived from ≥5 valid same-mode sessions and its `algorithmVersion` matches the algorithm used to produce the sessions' metrics.
- **[OPEN] algorithm-version mismatch handling** (future app updates changing the algorithm): v1 ships a single algorithm version so the case cannot arise; the data model stamps versions now so the future policy (re-baseline prompt, coexistence, migration) is a product decision, not a schema migration. Do not silently resolve.

## 9.7 Anti-Mixing Enforcement (summary of guarantees)

1. `TestMode` required parameter on baseline queries and scoring calls (compile-time).
2. Unique `mode` constraint on `BaselineEntity` (store-level).
3. Valid-session counting always filtered by mode + validity (query-level).
4. Integration test asserting: 3 valid Quick + 2 valid Full ⇒ both modes `building(3)` / `building(2)`, no baseline exists. [PRD §6 edge case]
