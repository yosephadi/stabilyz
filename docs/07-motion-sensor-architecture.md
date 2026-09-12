# 7. Motion & Sensor Architecture

## 7.1 Frameworks and Their Roles

| Framework | Role |
|---|---|
| **CoreMotion / CMMotionManager** | High-rate accelerometer (and device-motion attitude/gravity) streaming — the primary trunk-acceleration signal [PRD §5] |
| **CoreMotion / CMPedometer** | Steps, cadence, pace, distance — co-recorded live [PRD §5], cross-check input for segmentation & step detection |
| **CoreMotion / CMMotionActivityManager** | [REC] Coarse walking/stationary classification to assist non-walking segment exclusion [PRD §6 "user stands still"] |
| **AVFoundation** | Tones & feedback (see §10) — listed here only for completeness of the session stack |
| **CoreHaptics / UIKit feedback generators** | Countdown ticks and the stop pulse [PRD OQ-6] — behind `HapticFeedbackService` in `Services/Haptics`. Taps come from `UIImpactFeedbackGenerator` (light per numeral, heavy at Go, medium at Stop); CoreHaptics supplies only the capability probe. Silently degraded when unsupported or when System Haptics is off; listed here for completeness of the session stack |

## 7.2 Structure — Strictly Separated Stages [PRD Rule 10]

1. **Sensor collection (Service):** `MotionSensorService` and `PedometerService` protocols. Concrete implementations wrap `CMMotionManager` (accelerometer + deviceMotion updates) and `CMPedometer` (live updates). They emit typed `SensorSample { deviceTimestamp, wallClockAnchor, accelerationX/Y/Z, gravityX/Y/Z }` and `PedometerEvent { steps, cadence, pace, timestamp }` as **AsyncStreams**. Sampling rate: **[OPEN/REC: 100 Hz accelerometer]** — sufficient for autocorrelation at typical cadences and pedometer-grade step peaks, cheap on battery; must be validated empirically (§21).
2. **Recording orchestration (Actor):** `SessionRecorder` actor owns start/stop lifecycle: primes sensors (within the start-latency target), stamps a **time-anchor pair** at start, buffers samples into a bounded in-memory ring + optional temp scratch file, tracks gaps, detects suspension/resumption, exposes a `SessionRecordingEvent` stream (elapsed, gapDetected, interruption, sensorError) to the UI, and emits a `LiveStepEvent` stream (from the `LiveStepDetector`) for audio feedback. On `stop()` it flushes a frozen, immutable `RawSessionBuffer` to the processing subsystem.
3. **Signal processing:** §8 — batch, pure, off the recorder.
4. **Metric extraction / scoring:** §8 — pure functions in the Algorithms module.
**Nothing above stage 1 lives in a ViewModel, and no ViewModel contains DSP** [PRD Rule 12].

## 7.3 Start / Stop

- **Lifecycle states:** `idle → priming → primed → running → idle`. There is no distinct `stopped`: the recorder is reused across sessions (docs/12 §12.3), so the only thing a terminal state could mean is "ready for the next session" — which is `idle`. `stop()` and `abort()` both land back there.
- **Countdown (before Start) [PRD OQ-6]:** tapping Start Test does not call `begin`. It starts a 5-second countdown, and `SessionRecorder.prime(mode:audioConfig:)` runs at the tap: permission pre-flight → hardware-availability check → start sensor updates → confirm samples arriving → hold the streams → keep the screen awake → `primed`. Priming is where **every** way a session can fail to start is discovered, and it runs while the user is still watching the screen; a failure discovered at Go is a failure nobody sees. The motion service owns the latency budget and throws `sensor(.primingTimeout)` if the first sample never arrives (§7.6), so `start` returning means the sensor is genuinely delivering — the recorder does not re-time it, because one budget in two places is two budgets.
- Start: at the final countdown tick ("Go"), `SessionRecorder.begin(at: TimeAnchor)` → arm the buffer at T-0 → `running` → begin draining the held streams → signal readiness → **request** the start tone [PRD AC], which sounds at Go alongside the distinct final haptic tick. The anchor is **passed in**, stamped by the countdown at its final tick, so T-0 is the instant the user was shown and felt rather than whenever the call was scheduled. `begin` does not prime on the caller's behalf: that would put a variable, multi-hundred-millisecond spin-up *after* the instant the session claims to have started, which is the ambiguity the countdown exists to remove. Reaching it unprimed is `recording(.notPrimed)`.
- **Cancellation:** `abort()` is the countdown's exit — user Cancel, backgrounding, or an interruption; **not** screen-off. It stops the streams, discards the unarmed buffer and its scratch file, restores the screen, and returns to `idle`. No session is created and nothing is marked invalid, because nothing was recorded. It is **not** a way out of a recording: `stop()` remains the only exit past T-0 and the only place the audio session is released, so an abort while `running` is refused rather than obeyed.
- **Discard before zero [PRD OQ-6]:** samples delivered during priming carry timestamps earlier than the T-0 anchor. They are **never** admitted to `RawSessionBuffer` — the buffer's first sample is the first at or after T-0. The countdown window is outside the session entirely, not a segment recorded and later filtered.
- **The lead-in is held, not drained, during the countdown.** Both sensor streams are unbounded, so the countdown's samples accumulate and are consumed at Go, where the admission gate rejects each on its timestamp. Consuming them *during* the countdown would race the arm: a sample that is genuinely at-or-after T-0 could be read while the buffer was still unarmed and be rejected, punching a hole in the recording exactly at its start. Draining after arming lets the timestamp decide every sample's fate, which is the admission contract doing its job (decisions.md 29).
- Stop: user Stop button (always visible [PRD §5]) → disarm feedback → **request** the stop tone → stop sensor updates → drain → freeze buffer → hand off to `SessionProcessor`.
- **Audio is requested, never awaited, in both directions** (decisions.md entry 25). The tones are handed off to a separate task, so the data path — start sensors / disarm → stop sensors → drain → freeze → handoff — cannot be delayed by the audio layer. The PRD requires both behaviours (a session records; distinct start and stop tones play); it does not require the recorder to block on the second to guarantee the first. Under a wedged or dead audio layer the walk is still measured, frozen and scored, and the tone is simply lost — the same best-effort treatment every other sound gets (docs/10 §10.4).

## 7.4 Timestamps

- **Primary clock:** CoreMotion sample timestamps (`CMLogItem.timestamp`, device uptime seconds) — monotonic, gap-revealing.
- **Anchor:** at **Go (T-0), not at the Start Test tap**, capture `(Date(), uptimeNow())` once; every sample's wall-clock time = anchor + (deviceTimestamp − anchorUptime). The persisted `startedAt` (docs/05, a queried scalar column) is this T-0 anchor, so a session's stored start time, its elapsed clock and its valid-walking window all share one origin and the countdown contributes to none of them. This survives wall-clock changes mid-session and makes gap detection arithmetic trivial.
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
- **Screen lock prevention [REC]:** disable the idle timer for the **countdown *and* the session** — the countdown exists so the user can stow the phone, so an idle auto-lock partway through it would defeat the feature. On backgrounding, surface a clear message per PRD ("prevent backgrounding during a session with a clear message" is one of PRD's two sanctioned options). No background motion mode is added in v1.
- **Countdown interruptions are cancellations, not gaps [PRD OQ-6]:** backgrounding or an interruption *during the countdown* cancels it outright — no session is created, so there is nothing to mark invalid and no gap machinery to run. This is deliberately unlike an interruption *during* recording, handled above. **Screen-off is excluded**: a deliberate lock as the phone goes into a pocket must not cancel the countdown or the session.
- The rule lives in `SessionBackgroundGuard` as a pure function of `(ScenePhase, CountdownCoordinator.State)`, watched by `SessionCoverView`. `.inactive` — the app switcher, a banner, the screen going off — never cancels. ⚠️ **Known gap, unverified without a device:** on hardware a deliberate lock reaches `.background` shortly after `.inactive`, so the guard as written would cancel a countdown that [PRD OQ-6] says should survive. Telling a lock from an app switch needs `UIApplication.protectedDataWillBecomeUnavailableNotification`, which the simulator cannot exercise.
- Thermal/battery throttling: sensor rate drops or gaps → same gap/quality machinery → graceful noisy failure, never a crash [PRD §6].

## 7.8 Non-Walking Periods & Noisy Classification (detection home)

- Non-walking detection is a **pipeline stage** (`WalkingSegmentDetector`, §8.3): standing still and pauses are excluded segments and do not count toward the valid-walking requirement [PRD §6, §7 AC]. Pre-walk **setup is no longer among them** — the countdown (§7.3) ends before recording starts, so phone-stowing sits outside the buffer rather than inside it awaiting exclusion. What the detector still owns is everything *after* T-0: the first few steps of getting going, a pause at a crosswalk [PRD §6].
- Noisy classification = `SignalQualityValidation` stage (§8.4): excessive noise (threshold [OPEN]) OR valid-walking duration below the mode minimum → `SessionOutcome.invalid` → noisy screen [PRD §5].
- The classification *consumes* gap/quality metadata produced by the recorder — single source of truth for validity.

## 7.9 Testability Without a Device

- `MotionSensorService`/`PedometerService` protocols + **fixture replay**: a `FixtureSensorService` streams recorded captures (JSON/binary fixture files with known gait parameters: cadence, SNR, inserted pauses, gaps).
- A **debug-only capture tool** (internal builds only, never TestFlight public builds [REC — privacy]) records real device sessions into fixtures.
- `SessionRecorder` is testable against fixtures including scripted gaps/interruptions; `LiveStepDetector` testable with synthetic footfall signals.
