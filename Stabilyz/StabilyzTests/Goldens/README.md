# Golden regression suite

End-to-end records of what the gait pipeline produces for synthetic sessions
with known parameters. The stage tests prove each stage in isolation; these
prove the assembly — `RawSessionBuffer` in, `GaitScoringAlgorithm` run,
`SessionAnalysisOutcome` out (docs/19 §19.1).

## What a golden file contains

- `signal` — the parameters the session is generated from. The waveform is not
  stored; it is reproducible from these numbers, and every expected value can be
  traced back to the parameter that produced it.
- `notes` — what this case pins, in words. A golden nobody can read is not
  reviewable, which defeats the point of storing it.
- `expected` — two kinds of value, deliberately mixed:
  - **Derived**: computable from `signal`. Cadence is `120 / stride`, asymmetry
    is `|Δhalf| / stride`, valid walking follows from the walking content. These
    are asserted against physics as well as against the file, so a golden that
    drifts away from the signal it describes fails twice.
  - **Recorded**: no closed form — Ad1, Ad2, step-time CV, trunk RMS. Pure
    regression anchors.

## Regeneration protocol

**Goldens are never auto-updated.** Nothing in the normal test run writes to this
directory. A failing golden has exactly two explanations, and there is no third:

1. **A regression.** The pipeline changed behaviour by accident. Fix the code.
   Do not touch the golden.
2. **An intended algorithm change.** The new behaviour is correct and the golden
   is now stale. Regenerating requires **explicit approval** and a
   **`docs/decisions.md` entry** recording what changed, why, and which values
   moved.

Regeneration is opt-in and cannot happen by accident:

```
TEST_RUNNER_STABILYZ_REGENERATE_GOLDENS=1 xcodebuild \
  -scheme Stabilyz -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:StabilyzTests/GoldenRegeneration
```

Then **read the diff before committing it.** A regenerated golden that nobody
compared against the signal's known parameters is a recording, not a golden —
it pins whatever the code happens to do, including whatever it does wrong. The
derived values exist precisely so that review has something to check against.

## Tolerances

Defined in `GoldenRegressionTests.swift` with the rationale for each. Tight
enough to catch drift, loose enough not to false-alarm on window-boundary and
floating-point jitter. Widening a tolerance to make a test pass is a
regeneration in disguise and needs the same approval.
