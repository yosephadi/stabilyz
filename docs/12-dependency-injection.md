# 12. Dependency Injection

## 12.1 Strategy

**Manual constructor injection with a single composition root.** `AppDependencies` (a plain struct) is built once in the app entry point and passed to feature initializers; a thin SwiftUI `EnvironmentValue` exposes only view-facing conveniences. No third-party DI framework — the dependency graph is small (~15 nodes), fully static, and compile-time-checked; a framework would add build risk for zero leverage [PRD posture: minimal dependencies].

## 12.2 Protocol Boundaries and Implementations

| Abstraction (protocol) | Production | Test double | Preview |
|---|---|---|---|
| `MotionSensorService` | CoreMotion accelerometer/deviceMotion stream | Fixture replay service | Fixture replay |
| `PedometerService` | CMPedometer live updates | Scripted event sequence | Static values |
| `AudioFeedbackService` | AVAudioEngine player | Spy (records ticks/tones, injects route events) | Silent spy |
| `SessionRecorder` (actor) | Concrete, consuming the above | Driven by fixture services | Same |
| `GaitScoringAlgorithm` | Versioned pipeline (Algorithms module) | Deterministic stub with fixed outputs | Stub |
| `BaselineCalculation` | Pure domain service | Pure (no double needed) | — |
| `UserProfileRepository` / `GaitSessionRepository` / `BaselineRepository` | SwiftData-backed | In-memory store backing (SwiftData in-memory config) | In-memory |
| `SecureArchiveCoding` (crypto) | CryptoKit AES-GCM + CommonCrypto PBKDF2 | Deterministic KDF w/ fixed salt/iterations + real AES-GCM (still vetted — never fake crypto) | — |
| `ExportService` / `RestoreService` | File-based, share-sheet presentation | Temp-directory + fake share presenter | — |
| `Clock` | System date/uptime | Fixed clock (deterministic timestamps) | Fixed |
| `FileIO` | FileManager | Temp sandbox | — |
| `LogService` | os.Logger wrappers | Capturing log sink | — |

Randomness (salts, nonces) abstracted behind a `RandomSource` so crypto tests are deterministic [REC].

## 12.3 Wiring Rules

- Only the composition root knows concrete types.
- View models take protocols + value types; features never reach global state.
- Actor dependencies (`SessionRecorder`, `SessionProcessor`) are created once and shared; they are restarted per session via lifecycle methods, not recreated ad hoc.
