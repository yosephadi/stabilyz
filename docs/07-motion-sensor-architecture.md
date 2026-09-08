# 7. Motion & Sensor Architecture

## 7.1 Frameworks and Their Roles

| Framework | Role |
|---|---|
| **CoreMotion / CMMotionManager** | High-rate accelerometer (and device-motion attitude/gravity) streaming — the primary trunk-acceleration signal [PRD §5] |
| **CoreMotion / CMPedometer** | Steps, cadence, pace, distance — co-recorded live [PRD §5], cross-check input for segmentation & step detection |
| **CoreMotion / CMMotionActivityManager** | [REC] Coarse walking/stationary classification to assist non-walking segment exclusion [PRD §6 "user stands still"] |
| **AVFoundation** | Tones & feedback (see §10) — listed here only for completeness of the session stack |

## 7.2 Structure — Strictly Separated Stages [PRD Rule 10]

1. **Sensor collection (Service):** `MotionSensorService` and `PedometerService` protocols. Concrete implementations wrap `CMMotionManager` (accelerometer + deviceMotion updates) and `CMPedometer` (live updates). They emit typed `SensorSample { deviceTimestamp, wallClockAnchor, accelerationX/Y/Z, gravityX/Y/Z }` and `PedometerEvent { steps, cadence, pace, timestamp }` as **AsyncStreams**. Sampling rate: **[OPEN/REC: 100 Hz accelerometer]** — sufficient for autocorrelation at typical cadences and pedometer-grade step peaks, cheap on battery; must be validated empirically (§21).
2. **Recording orchestration (Actor):** `SessionRecorder` actor owns start/stop lifecycle: primes sensors (within the start-latency target), stamps a **time-anchor pair** at start, buffers samples into a bounded in-memory ring + optional temp scratch file, tracks gaps, detects suspension/resumption, exposes a `SessionRecordingEvent` stream (elapsed, gapDetected, interruption, sensorError) to the UI, and emits a `LiveStepEvent` stream (from the `LiveStepDetector`) for audio feedback. On `stop()` it flushes a frozen, immutable `RawSessionBuffer` to the processing subsystem.
3. **Signal processing:** §8 — batch, pure, off the recorder.
4. **Metric extraction / scoring:** §8 — pure functions in the Algorithms module.
**Nothing above stage 1 lives in a ViewModel, and no ViewModel contains DSP** [PRD Rule 12].

## 7.3 Start / Stop

- Start: `SessionRecorder.begin(mode:audioConfig:)` → start accelerometer + deviceMotion + pedometer updates → confirm first samples arriving → signal readiness → play start tone [PRD AC]. If priming exceeds the latency target, fail fast into a plain-language error (no silent failure [PRD §6 permission analog]).
- Stop: user Stop button (always visible [PRD §5]) → stop tone → stop sensor updates → freeze buffer → hand off to `SessionProcessor`.

## 7.4 Timestamps

- **Primary clock:** CoreMotion sample timestamps (`CMLogItem.timestamp`, device uptime seconds) — monotonic, gap-revealing.
- **Anchor:** at start, capture `(Date(), uptimeNow())` once; every sample's wall-clock time = anchor + (deviceTimestamp − anchorUptime). This survives wall-clock changes mid-session and makes gap detection arithmetic trivial.
- Pedometer events mapped onto the same timeline.
- All durations (`validWalkingDuration`, elapsed) computed from device timestamps, never from Date arithmetic [REC].

## 7.5 Sampling / Configuration Abstraction

A `MotionAcquisitionPolicy` value (rate, axes, deviceMotion on/off) and a `SessionPolicy`/`DataQualityPolicy` (thresholds: valid-walking minimums 90 s / 240 s [PRD OQ-3], noise threshold [OPEN], confidence thresholds, refractory) live in a **versioned configuration** owned by the Algorithms module so tuning never touches call sites.

## 7.6 Availability & Permissions

- `CMAuthorizationRequirement`/`CMPedometer.authorization` checked in Session Setup before Start; state drives the degraded Start button copy [PRD AC].
- Sensor availability (accelerometer exists) verified on device at launch of the session flow; simulator absence → deterministic mock in dev.

## 7.7 Interruptions & Backgrounding

- App observes `UIApplication` lifecycle (will-resign-active / did-enter-background / suspend) and `AVAudioSession` interruption events during a session.
- **Policy [REC within PRD's allowed space]:** any suspension produces a sensor gap (CMMotionManager delivers nothing while suspended). The recorder marks the gap; walking analysis excludes it; the session carries an `interruptionCount`/gap record; validity is then determined by the normal pipeline (if remaining valid walking ≥ mode threshold → still scoreable — this is PRD-permitted "pause/resume cleanly"; else → invalid/noisy path). A CMPedometer historical query across the gap verifies continuity context [REC].
- **Never:** continue as if nothing happened and emit a clean score [PRD §6 — "must not silently produce a corrupted 'clean' score"].
- **Screen lock prevention [REC]:** disable idle timer during a session; on backgrounding, surface a clear message per PRD ("prevent backgrounding during a session with a clear message" is one of PRD's two sanctioned options). No background motion mode is added in v1.
- Thermal/battery throttling: sensor rate drops or gaps → same gap/quality machinery → graceful noisy failure, never a crash [PRD §6].

## 7.8 Non-Walking Periods & Noisy Classification (detection home)

- Non-walking detection is a **pipeline stage** (`WalkingSegmentDetector`, §8.3): standing still, pauses, setup time are excluded segments and do not count toward the valid-walking requirement [PRD §6, §7 AC].
- Noisy classification = `SignalQualityValidation` stage (§8.4): excessive noise (threshold [OPEN]) OR valid-walking duration below the mode minimum → `SessionOutcome.invalid` → noisy screen [PRD §5].
- The classification *consumes* gap/quality metadata produced by the recorder — single source of truth for validity.

## 7.9 Testability Without a Device

- `MotionSensorService`/`PedometerService` protocols + **fixture replay**: a `FixtureSensorService` streams recorded captures (JSON/binary fixture files with known gait parameters: cadence, SNR, inserted pauses, gaps).
- A **debug-only capture tool** (internal builds only, never TestFlight public builds [REC — privacy]) records real device sessions into fixtures.
- `SessionRecorder` is testable against fixtures including scripted gaps/interruptions; `LiveStepDetector` testable with synthetic footfall signals.
