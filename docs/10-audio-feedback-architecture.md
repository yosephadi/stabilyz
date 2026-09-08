# 10. Audio Feedback Architecture

## 10.1 Two Distinct Engines, One Service Front

| Component | Kind | Trigger | Timing model |
|---|---|---|---|
| **Step Feedback** (pre-baseline, sessions 1–5) | Reactive event sound | `LiveStepEvent` with confidence ≥ threshold, passing refractory gate | Event-driven; must **never** anticipate or imply a tempo [PRD §7, OQ-4] |
| **Metronome cue** (session 6+) | Scheduled periodic tick | Interval = 60 / `Baseline.cadenceBPM` for that mode [PRD §5] | Steady, pre-scheduled timeline [REC: audio-timeline scheduling, not `Timer`, for jitter] |
| Session tones | One-shot | Start / Stop taps | Immediate, distinct sounds [PRD AC] |

## 10.2 Audio Service Abstraction

`AudioFeedbackService` protocol: `playStartTone()`, `playStopTone()`, `playStepTick()`, `startMetronome(bpm:)` / `stopMetronome()`, `suspend()/resume()`, plus interruption/route event callbacks. Concrete implementation over **AVAudioSession + AVAudioEngine with preloaded player nodes** [REC — lowest-latency, sample-accurate scheduling; AVAudioPlayer per tick would add jitter]. Category: playback; ducking off.

## 10.3 Requirements Mapping

- **Enable/disable:** per-session opt-in captured in `SessionAudioConfig`; Step Feedback **off by default**; first-ever session in a mode shows "walk normally — no target pace" framing instead of defaulting the toggle on [PRD §5, §7, OQ-4].
- **Availability gating:** Metronome offered only when that mode's baseline exists — driven by `BaselineState` in Session Setup [PRD §5, §7].
- **Confidence gating:** only detector-confident steps fire a sound — raw spikes must never create an accidental rhythm [PRD §6, OQ-4]. Confidence threshold in versioned config [OPEN value].
- **Debounce/refractory:** a refractory window after each tick prevents double/triple beeps from one footfall [PRD §6, §7]. Typical step interval ≈ 0.5–0.7 s ⇒ refractory ≈ 300 ms, tunable [REC; value OPEN].
- **Latency:** sound-to-footfall must feel connected [PRD §7] ⇒ preloaded buffers, hardware-adjacent playback, no main-thread hops on the tick path [REC].
- **Bluetooth / route changes:** `AVAudioSession` route-change and interruption notifications → re-route to device speaker silently or stop feedback cleanly; **never crash, never freeze the session** [PRD §6].
- **Session lifecycle:** audio is torn down with the recorder; stop tone plays before teardown.

## 10.4 Separation from Scoring (hard architectural rule)

- Audio **subscribes** to the recorder's `LiveStepEvent` stream; it never writes to the sample buffer, never calls the pipeline, and holds no references into processing.
- Scoring runs on the **frozen batch buffer only** — it is mathematically impossible for the audio layer to alter it; additionally, neither Step Feedback nor the Metronome may block or delay the batch scoring computation at Stop [PRD §7 AC].
- The metronome *does* influence the user's gait — that is the PRD-sanctioned intentional influence [PRD OQ-4], and is why `SessionAudioConfig` is persisted with the session [REC: transparency/interpretation], but feedback state never enters the scoring math.
- Failure isolation: any audio error is logged, surfaced only as silent degradation, and **cannot** fail the session [PRD §6].
