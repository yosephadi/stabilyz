# 19. Testing Strategy

## 19.1 Unit Tests

| Area | Approach |
|---|---|
| Domain | `TestMode` thresholds; `SessionOutcome` rules; profile validation; baseline-state machine transitions |
| Algorithms (bulk of effort) | Synthetic signals with known parameters: generated footfall waveforms at known cadence/SNR → assert Ad1/Ad2 values, step-time CV, trunk RMS within tolerance; injected pauses/gaps → segmentation excludes; noise-injected → quality stage flags; too-short → invalid. Golden-file regression per algorithm version |
| Baseline calculation | Mean/SD correctness; **mode-segregation invariant tests** (3 Quick + 2 valid Full ⇒ no baseline anywhere) [PRD §6]; SD-floor behavior; frozen-after-5 rule; invalid-session exclusion |
| Scoring | Direction handling per metric; floor clamp; relative index centers baseline at 100; multi-signal requirement (composite never reducible to Ad1/Ad2 alone — a test asserting the input set) |
| Crypto/archive | Export→import round-trip; tampered ciphertext rejected (GCM); mutated header → corrupted-file error; wrong passphrase → passphrase error (key-check value); future-schema payload → incompatibility error; salt/nonce uniqueness across exports; params embedded correctly; DTO schema migration chain N→N+1 |

## 19.2 Integration Tests

- **Session pipeline end-to-end:** fixture sensor stream → recorder → processor → repository → baseline at 5th valid → score at 6th → history query correctness (valid-only, mode-tagged).
- **Persistence:** in-memory SwiftData container; entity↔domain mapping; unique-mode baseline constraint; transactional commit rollback on injected failure.
- **Restore flow:** export → import on populated store → conflict decision matrix (cancel / export-first / replace) → **kill-point injection during restore** (fail at decrypt, validate, mid-transaction) asserting the store is byte-identical after failure [PRD hard requirement — this test is mandatory].
- **State invalidation:** post-restore, no stale in-memory session/baseline data observable.

## 19.3 UI Tests (XCUITest, deterministic doubles injected)

Onboarding completion incl. hard disclaimer gate and optional-field skipping; relaunch-mid-onboarding resume; permission-denied Start degradation (simulator state); full session flow with fixture recorder (valid → score; noisy → noisy screen; building-baseline "X of 5"); history rendering & mode filtering; Settings restore conflict dialog's three outcomes; export wizard happy path.

## 19.4 Hardware-Dependent (physical iPhone only)

Simulators cannot produce realistic prosthetic-gait motion. Must be validated on device:
- Real-world noise levels vs. quality thresholds (drives the [OPEN] threshold tuning)
- Walking-segment detection robustness on actual amputee-gait captures
- CMPedometer vs. accelerometer step-detection agreement
- Suspension/lock behavior during recording (gap policy reality)
- Audio: step-tick latency perception, Bluetooth route drops, interruption during call
- Thermal/battery throttling behavior
- PBKDF2 iteration calibration on target devices
- Export → Files/AirDrop → restore round-trip

**Determinism for hardware services:** every hardware boundary is a protocol (§12); fixtures replay recorded captures; the fake clock fixes timestamps; scripted pedometer drives interruption tests; the audio spy asserts refractory/confidence gating without producing sound.
