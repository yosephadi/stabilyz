# 21. Technical Risks & Unknowns

## 21.1 Known Requirements (locked by PRD — engineering must not alter)

Two test modes with 90 s / 240 s valid-walking minimums · per-mode 5-valid-session baselines, frozen in v1 · autocorrelation Ad1/Ad2 universal for all amputation types · multi-signal composite with SD floor · asymmetry secondary/unilateral-only/never fabricated · relative index not percentage · noisy sessions never scored/counted/exported · mode segregation everywhere · Step Feedback (off-by-default, confidence-gated, debounced, no tempo) vs. Metronome (post-baseline, baseline cadence) · encrypted export with PBKDF2/unique-salt/AES-GCM/self-describing metadata · restore-not-merge · **atomic restore** · no custom crypto · no backend/accounts/cloud · disclaimer hard gate · onboarding resume · permission degradation · TestFlight iOS 17+.

## 21.2 Technical Decisions (engineering-owned; decide before/during build)

Sensor sampling rate (rec: 100 Hz) · orientation/axis derivation for ML/VT axes · trunk-proxy formulation (RMS rec) · walking-segment detection method · live step-detector design + confidence threshold · refractory duration (rec: ~300 ms) · KDF iteration count (rec: calibrate 200–500 ms) · export file extension/UTType · onboarding-draft storage (rec: UserDefaults) · invalid-session local retention (rec: retain, exclude) · metrics-as-JSON-blob persistence · PBKDF2 via CommonCrypto (forced: CryptoKit lacks PBKDF2) · TabView layout · atomic-restore mechanism (transaction + snapshot, rec).

## 21.3 Open Questions (PRD-intentional; do not close silently)

1. **Composite formula & weights** — completely unspecified; algorithm version 1 must be built with provisional weights and stamped as such [PRD OQ-1 context].
2. **Noise threshold** — PRD literally says "(define threshold)".
3. **Priming deadline inside the countdown** — PRD placeholder "[define: priming deadline before zero]" [PRD OQ-6], replacing the old post-tap start-latency target. How long sensor priming may take within the 5-second countdown before the abort fires.
3a. **Countdown duration** — 5 seconds is provisional and tunable [PRD OQ-6], a single fixed constant (not per-mode, not user-adjustable). Needs device validation that it is long enough to stow a phone unhurried.
4. **SD floor values** — required to exist; values unspecified.
5. **Phone placement** — PRD never specifies where the phone is carried; trunk-proxy and autocorrelation quality depend on it. Recommend product-level guidance (e.g., waist-level pocket) — flagged, not assumed.
6. **"Side reliably identifiable"** definition for the asymmetry feature.
7. **Relative-index mapping/scale** (how composite deviation becomes e.g. 112).
8. **Whether the 5 calibration sessions later receive retroactive scores** in History ("History lists … with their mode-relative baseline scores (once that mode's baseline exists)" vs. "from the 6th valid session onward" — recommend *no* retroactive scoring; needs product confirmation).
9. **N for "last N sessions"** on clinician summary and encouraging-summary comparisons.
   - **Clinician summary — CLOSED (2026-09-14, product decision, Task 9.2.1):** N = 5 **scored** sessions per mode (walk 6 onward), newest first — a one-to-one match for the five walks a baseline is built from. Calibration walks never count toward it. `ClinicianSummaryPolicy.recentScoredSessionCount`.
   - **Encouraging-summary comparisons — still open.** A separate, versioned algorithm setting (`SummaryPolicy.recentSessionCount`, provisional 3); deliberately not changed by the clinician decision.
10. **Encouraging-summary copy rules** (PRD: generated from real same-mode comparisons; templates unspecified).
11. **Export-nudge cadence** beyond "after baseline is first established" ("periodically" unspecified).
   - **CLOSED (2026-09-15, product decision, Task 10.2.3):** one non-intrusive **milestone card on the Walk tab**, shown once **any** mode's baseline is first established. Dismissing it, or completing an export from any screen, retires it for good — no periodic re-prompt in v1. Both facts are device state in `UserDefaults`, never store data. `ExportNudgePolicy`; decisions.md entry 43.
12. **Algorithm-version mismatch policy for future app updates** (§9.6).

## 21.4 Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Algorithm validity on real prosthetic gait (validated for unilateral transfemoral via Tura; not bilateral; composite unvalidated) | High | Versioned algorithm; early device data collection; PRD explicitly accepts non-validated v1 [PRD §2]; documented research gap [OQ-1] |
| Walking-segment/step detection false positives creating accidental audio rhythm | High | Confidence gating + refractory + integration tests on fixtures |
| Backgrounding policy gaps on real devices | Medium-High | Gap-detection architecture; device test matrix; PRD-sanctioned instruction-first approach |
| SwiftData maturity (container rebuild after restore, migration tooling) | Medium | Transactional restore + store snapshot; narrow schema; export archive as portability hedge |
| Mostly-turn sessions producing misleading scores (no turn detection in v1) | Medium | PRD-sanctioned user instruction; quality threshold may flag; documented limitation |
| PBKDF2 UX (export/import delay) | Low-Medium | Calibrated iterations; progress UI |
| iOS 17.0 `@Observable`/SwiftData early-adopter bugs | Low-Medium | Pin to latest 17.x toolchain; regression suite |

## 21.5 Research / Validation Required (before hard-coding assumptions)

Empirical threshold tuning on real walks (noise, SD floor, valid-walking minimums — PRD says these "will be empirically validated and tuned using real-world session data" [OQ-3]) · autocorrelation reliability at variable cadence and real phone-placement orientations · pedometer/accelerometer agreement rate · audio-tick latency acceptability · stride-count sufficiency (15–20 strides reference [OQ-1]) · KDF timing on target devices. **Architectural enabler:** an internal, debug-only fixture-capture build path so real-device walks become test fixtures (§7.9).
