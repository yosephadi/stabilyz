# 1. Product & Technical Context

## 1.1 Purpose

Stabilyz is a **local-only, offline, single-user iOS app** that lets a lower-limb prosthetic user run self-directed walking tests (2-minute Quick Test / 6-minute Full Test) using iPhone motion sensors, and receive a **relative stability index against their own per-mode baseline** (baseline = 100). The product's core value is converting subjective gait perception into an objective number. [PRD §1, §4]

## 1.2 Primary & Secondary Users

| User | Interaction model |
|---|---|
| Primary: self-directed lower-limb prosthetic user (transtibial / transfemoral / bilateral; ambulatory; wide age range; not assumed tech-savvy) | Owns the device, runs all flows personally |
| Secondary: prosthetist / PT | Never uses the app; views the single Clinician Summary screen in person |

No accounts, no login, no backend, no automatic cloud sync. Data is local by default; a manual encrypted export is the only backup/transfer mechanism. [PRD §3]

## 1.3 Core Product Loop

```
Onboard (or Restore)
   → Start Gait Training → pick mode (Quick / Full) → optional audio opt-in
   → Record 2/6-min walk (CMMotionManager + CMPedometer)
   → Stop → on-device processing
   → Noisy path (invalid, no score)  OR  Score
        ├── Sessions 1–5 of mode: "Building baseline — X of 5"
        └── Session 6+: relative index vs. that mode's baseline
   → Saved to History (mode-tagged) → Trends → Clinician Summary
   → Periodic encrypted export (user-initiated) for backup / device transfer
```

## 1.4 Major Features (from PRD §5)

Onboarding wizard (resumable, disclaimer hard-gate) · First-launch Restore · Home/Dashboard · Mode selection · Step Feedback (pre-baseline, opt-in, off by default) · Metronome cue (post-baseline, baseline cadence) · Session recording with start/stop tones · On-device processing · Noisy/insufficient-data path · Relative score screen with per-signal breakdown · Per-mode 5-session baseline calibration · History + Swift Charts trend (mode-separated) · Clinician Summary · Settings · Encrypted export · Passphrase-validated atomic restore.

## 1.5 Major Technical Capabilities Required

| Capability | PRD source |
|---|---|
| High-rate accelerometer (trunk) sampling + pedometer co-recording | §5 Session In Progress |
| Real-time, confidence-gated step detection (for Step Feedback) with refractory debounce | §6 Step Feedback edge cases; OQ-4 |
| Offline batch DSP: walking-segment detection, signal-quality validation, autocorrelation (Ad1/Ad2), variability, trunk-motion proxy, optional unilateral asymmetry | §7 Scoring & baseline ACs |
| Per-mode baseline statistics with SD floor; relative index scoring | §7; OQ-5 |
| Encrypted portable archive: PBKDF2 + unique salt + AES-GCM + embedded version/KDF metadata | §5 Settings; OQ-2 |
| Atomic restore (replace, never merge) with pre-validation | §6 Data & storage; OQ-2 |
| Resumable onboarding incl. pre-checkbox quit | §6 Onboarding |
| Interruption/suspension handling that never yields a fake-clean score | §6 Session recording |
| Motion & Fitness permission degradation on Start button | §6, §7 |

## 1.6 In Scope vs. Out of Scope

**In scope [PRD §5, §7]:** everything in §1.4 above; both test modes; bilateral as fully supported (minus the unilateral secondary asymmetry feature); export nudge after first baseline; disclaimer accessible post-onboarding.

**Explicitly out of scope for v1 [PRD §5]:** HealthKit passive tracking · threshold-based recommendations · turn detection · socket-fit tagging · cohort benchmarking · structured clinician export (PDF) · automatic merge on import · recalibration/re-baselining · cloud sync / backend / accounts · clinical validation · App Store polish. **No technical architecture below should assume any of these exist.**

## 1.7 Product Constraints

- iOS 17+, physical iPhone, TestFlight distribution. [PRD §7 Build/deployment]
- All processing on-device, no network call during session processing. [PRD §5]
- No custom cryptography. [PRD §7 Data export & import]
- Composite score is **not** calibrated for real-world percentage claims — relative index only. [PRD §7]
- The composite formula, noise thresholds, and several algorithm parameters are deliberately open in the PRD and must remain swappable. [PRD OQ-1, OQ-3]

## 1.8 Edge Cases with Architectural Impact

| Edge case | Architectural implication |
|---|---|
| Backgrounding/lock mid-session | Suspension creates an un-backfillable sensor gap → gap policy + session flagging; never silent clean score [PRD §6] |
| Call/notification interruption | Pause-with-gap-exclusion or invalidate; recording must not produce corrupted "clean" data [PRD §6] |
| Standing still mid-session | Non-walking segments detected and excluded from valid-walking duration and from scoring [PRD §6] |
| Mostly-turns session | User instruction only (no turn detection v1); copy lives in session setup [PRD §6] |
| Bluetooth audio drop | Audio degrades silently to speaker or stops; session recording unaffected [PRD §6] |
| Wrong passphrase / corrupted / future-version export | Distinguish where possible; existing local DB untouched; no crash [PRD §6] |
| One mode baselined, other mode never run | Per-mode baseline state machine; "Session 1 of 5" restart per mode [PRD §6 Baseline] |
| Bilateral user | No asymmetry metric fabricated; score from the three universal signals only [PRD §7] |
| Onboarding quit on disclaimer screen | Persisted onboarding draft incl. disclaimer step [PRD §6] |

## 1.9 Acceptance Criteria with Direct Architectural Implications

These ACs are hard constraints on the architecture (full list is in PRD §7; these are the ones that shape structure):

1. **Atomic restore is a hard requirement** — failure at any stage (decrypt, validate, write) leaves local data byte-identical.
2. **Mode segregation is systemic** — baselines, session counts, and trend data never blend Quick/Full; a `mode` key exists on both session and baseline entities [PRD OQ-5].
3. **Crypto envelope is self-describing** — salt, nonce, KDF params, schema/crypto version embedded in the export file.
4. **Decryption → validation → data-touch ordering** on every restore.
5. **Relative index only post-baseline** — score presentation is baseline-state-driven, per mode.
6. **Noisy sessions never scored, never baseline-counted, never in history list, never exported.**
7. **Score is multi-signal** — gait consistency is one input, never the sole basis; trunk-motion proxy stays independent of regularity computation [PRD OQ-1].
8. **Terminology enforcement** — user-facing "gait consistency"; "asymmetry" reserved strictly for the unilateral limb comparison [PRD OQ-1].
9. **Start-button permission degradation** — Motion & Fitness state must be checkable before session start.
10. **Onboarding resumability** across relaunch.
11. **Start latency** is a PRD placeholder `[define: e.g. 1 second]` — treated as an [OPEN] tuning target, not a fixed number.
