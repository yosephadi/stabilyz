# 14. Concurrency & Async Architecture

## 14.1 Model

Swift Concurrency end-to-end: `async/await`, actors, structured tasks, AsyncStreams. No completion-handler bridges except where Apple APIs force them (CoreMotion/AVFoundation callbacks → stream continuation bridging).

## 14.2 Placement Rules

| Component | Isolation | Rationale |
|---|---|---|
| All SwiftUI views & view models | `@MainActor` | UI state |
| `SessionRecorder` | Actor | Serializes sensor lifecycle; owns streams |
| `SessionProcessor` (pipeline stages 2–8) | Actor + CPU-bound work in nonisolated pure functions invoked from actor context | Keeps heavy math off the main actor; pure functions parallelizable if needed |
| Live step detection | Runs in recorder actor on the sample stream | Must be cheap per-sample; audio reacts via main-actor hop for state only |
| SwiftData writes | Background `ModelActor` | Session commit/baseline creation/restore never block UI |
| SwiftData reads for `@Query` | Main context | SwiftUI integration |
| Audio render/scheduling | AVAudioEngine's own threads; events hop to main | Latency-critical, never main |
| Export/import tasks | Structured `Task`s (userInitiated) with cancellation | Long-ish, observable, cancellable |
| `SecureArchiveService` | Actor | Serializes crypto operations; KDF (~300 ms) explicitly off-main |

## 14.3 Data Volume & Non-Blocking Guarantees

- 6-min @ ~100 Hz ≈ 36 k samples — memory-trivial, but autocorrelation over lags × windows is the heaviest compute in the app: it runs entirely in the processor actor with **chunked progress reporting** to the Processing screen; the UI thread never executes DSP [PRD Rule 12; PRD: processing is "brief"].
- Bounded recorder buffer: if live consumers lag, the buffer flushes to the scratch file — recording (the irreplaceable data) is never dropped due to slow consumers [REC].
- Backpressure: the pipeline only runs at Stop (batch) — live load is limited to step detection, by design.
- Cancellation: Stop-button and view dismissal cancel dependent tasks cleanly; a cancelled processing run marks the session invalid rather than half-processed.
