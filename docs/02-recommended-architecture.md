# 2. Recommended Architecture

## 2.1 Selection

**SwiftUI + `@Observable` MVVM, feature-first, layered, with actor-isolated subsystems and a pure-Swift algorithms module.**

- **UI:** SwiftUI views, thin, rendering-only.
- **Feature/state:** one `@Observable` view model per feature, holding view state and intent methods only.
- **Domain:** pure Swift models, baseline logic, session lifecycle rules, scoring *interfaces*.
- **Algorithms:** a separate, Apple-framework-free (except Accelerate) pipeline module for DSP, feature extraction, metrics, and composite scoring — pure, synchronous, versioned, unit-testable without mocks.
- **Services:** protocol-wrapped adapters over Core Motion, CMPedometer, AVFoundation, SwiftData, CryptoKit/CommonCrypto, file system.
- **Subsystems as actors:** `SessionRecorder` (sensor lifecycle), `SessionProcessor` (batch analysis), `SecureArchiveService` (export/import).

## 2.2 Why This Fits This Product

1. **The app is sensor-pipeline-heavy, not state-graph-heavy.** The hard engineering is DSP, baseline math, and crypto — all of which want *pure, deterministic, testable modules*, not UI-coupled state machines. MVVM-`@Observable` keeps views thin while the pipeline lives in framework-free code.
2. **iOS 17 minimum [PRD §7]** makes the `@Observable` macro available: fine-grained observation (no `ObservableObject` publish storms during a live session timer), and clean constructor injection without environment-object gymnastics.
3. **The PRD demands algorithm evolvability** (composite formula open, thresholds tunable, algorithm version stamped into exports). This demands a *versioned, swappable algorithm boundary* — which is an architecture concern, not a UI concern.
4. **Minimal dependencies is an explicit PRD posture** (no backend, vetted platform crypto only). A hand-rolled DI + Apple-only stack matches it.

## 2.3 Why Alternatives Are Less Suitable

| Option | Assessment |
|---|---|
| **TCA (Composable Architecture)** | Strong fit for complex interactive state graphs and time-travel debugging. Here, the dominant complexity is *pipeline throughput and correctness*, not UI state combinatorics. TCA adds a third-party dependency, reducer boilerplate for every screen, and its effect/dependency system duplicates what protocols + actors already give us. Rejected for v1; the layered design leaves room to adopt per-feature later if UI state grows. |
| **Full Clean Architecture (Use-case layer for everything)** | The domain logic here is small in count (baseline calc, scoring, validity rules) and is already isolated as pure modules. A formal use-case-per-action layer would be ceremony without benefit at this scale. Adopted *in spirit* (algorithms/domain are framework-free), not in full onion form. |
| **VIPER / coordinator-heavy patterns** | Massive per-screen ceremony for a ~15-screen app; testability is already achieved via view-model injection. Rejected. |
| **Classic MVC / ObservableObject MVVM** | ObservableObject's objectWillChange is coarse; a live session (timer, sensor events, audio state) would invalidate views excessively. `@Observable` is strictly better on iOS 17. Rejected. |

## 2.4 How the Architecture Answers the Required Questions

- **Responsibility division:** Views render; view models adapt domain/session state for display and forward intents; actors own subsystem lifecycles; pure modules compute; repositories persist; protocols isolate Apple frameworks.
- **State flow:** Unidirectional. Sensors/services → actor events → view-model `@Observable` state → views. User intents travel the opposite direction as method calls. No view ever mutates shared state directly.
- **Business logic separation:** All gait math, baseline math, and validity rules live in `Domain` and `Algorithms`, which import neither SwiftUI nor Core Motion. View models may not contain DSP or scoring logic [PRD Rule 12].
- **Dependency injection:** Constructor injection at a single composition root (§12). No global singletons.
- **Async:** Swift Concurrency exclusively. Sensor callbacks are bridged to `AsyncStream`s; heavy work runs in actors off the main actor; UI hops are `@MainActor`-bound (§14).
- **Error propagation:** Typed error enums thrown from services/domain, translated by a single presentation mapper into plain-language strings at the view-model boundary — technical errors never reach the user raw [PRD §6].
- **Testing:** Pure modules test with plain inputs; hardware boundaries are protocols with deterministic fakes (recorded sensor fixtures, scripted pedometer, in-memory store, fake clock) (§19).
- **Scaling without complexity:** Feature folders are independent; `Algorithms`, `SecureArchive`, and `Persistence` are structured to be extractable into local Swift Packages later (§16) without rewrites.
