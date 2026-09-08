# 24. Architecture Decision Records

**ADR-001 — Architecture Pattern**
Context: SwiftUI app, iOS 17+, sensor-heavy, ~15 screens, PRD demands testability and algorithm evolvability.
Options: TCA · full Clean Architecture · VIPER · classic MVC/ObservableObject MVVM · **SwiftUI + @Observable MVVM with layered feature-first modules**.
Chosen: the last.
Why: dominant complexity is pipeline correctness, not UI state graphs; `@Observable` (iOS 17) removes ObservableObject drawbacks; keeps third-party dependency count at zero.
Trade-offs: no built-in time-travel/state replay (mitigated by view-model unit tests); discipline required to keep logic out of view models (enforced by layer import rules).

**ADR-002 — State Management**
Context: live session state, baseline states, multi-screen derived state.
Options: single global store · per-feature `@Observable` view models + actor-owned subsystem state.
Chosen: per-feature `@Observable` + actors; derived read models (e.g., `BaselineState`) computed from repositories.
Why: state locality matches feature boundaries; actors serialize the truly shared, concurrent things (recorder, processor, restore).
Trade-offs: cross-feature consistency relies on repository-derived reads + explicit invalidation events rather than one reactive store — accepted at this scale.

**ADR-003 — Navigation**
Context: state-dependent root (first launch / onboarding / main), modal session flow, restore flows.
Options: ad-hoc NavigationStack paths · **enum-driven router + coordinator**.
Chosen: `AppRouter` phase machine + `SessionFlowCoordinator` enum path + TabView root + full-screen session cover.
Why: PRD routing is inherently state-dependent (baseline existence, restore outcomes, disclaimer gate); enums make it a total, unit-testable function.
Trade-offs: slightly more boilerplate per destination than free-form NavigationLink.

**ADR-004 — Persistence**
Options: Core Data · SwiftData · Codable files · raw SQLite.
Chosen: **SwiftData** (+ UserDefaults for onboarding draft; files for exports).
Why: iOS 17 floor; native Swift models and ModelActor concurrency; query needs (mode/validity/date/count) exceed flat files; Core Data offers more maturity but more boilerplate for the same result at this schema size.
Trade-offs: younger migration tooling — mitigated by narrow schema, JSON metric blobs, and the export archive as the cross-version data contract.

**ADR-005 — Dependency Injection**
Options: third-party DI (Resolver/Swinject) · SwiftUI environment-only · **manual constructor injection + composition root**.
Chosen: manual.
Why: ~15-node static graph; compile-time safety; zero dependencies [PRD posture].
Trade-offs: manual wiring churn as features are added — acceptable; one file to touch.

**ADR-006 — Motion Data Collection**
Options: business logic in a ViewModel recording sensor callbacks · **protocol-wrapped CoreMotion services streaming into a SessionRecorder actor**.
Chosen: the latter.
Why: PRD demands suspension/gap/interruption correctness and testability without hardware; actor serializes lifecycle; fixtures replace sensors deterministically.
Trade-offs: stream-bridging boilerplate; live detector must be kept cheap.

**ADR-007 — Processing Architecture**
Options: process inside the recording flow / on main · **frozen batch buffer → staged pure pipeline in a versioned Algorithms module executed by a SessionProcessor actor off-main**.
Chosen: batch, pure, staged, versioned.
Why: PRD keeps the formula and thresholds open and tunable — a pure, config-driven, versioned module is the only shape that supports empirical tuning and evolution; testable without mocks.
Trade-offs: no live score (not required); pipeline contract must stay stable while algorithm evolves (hence the single `GaitScoringAlgorithm` contract).

**ADR-008 — Baseline Architecture**
Options: rolling/updated baseline · baseline-as-query · **frozen per-mode baseline created from exactly the first 5 valid same-mode sessions, mode-keyed entities and mode-required APIs**.
Chosen: frozen, mode-keyed.
Why: PRD: no recalibration in v1; modes never blend [OQ-5]; "X of 5" counters are per-mode valid counts.
Trade-offs: gait drift after refit is unhandled (documented PRD limitation, not solved); frozen baselines make the future re-baseline UX a v2 product decision.

**ADR-009 — Export/Import Architecture**
Options: merge on import · direct store overwrite · **self-describing encrypted envelope + DTO payload + staged validation + transactional atomic replace with store snapshot**.
Chosen: the latter.
Why: PRD hard requirements: restore-not-merge; decrypt → validate → touch ordering; atomicity under all failures; future-version detection before data is touched.
Trade-offs: full archive rewrite per export (trivial at v1 data volume); no partial restores by design.

**ADR-010 — Encryption Strategy**
Options: custom crypto · plain SHA-256 key · third-party crypto libs · **PBKDF2-HMAC-SHA256 (CommonCrypto) + AES-256-GCM (CryptoKit), per-export salt/nonce, all params embedded**.
Chosen: platform vetted pair.
Why: PRD mandates a real KDF, authenticated encryption, embedded parameters, and no custom primitives; CryptoKit provides AEAD but not PBKDF2, hence CommonCrypto for the KDF — both Apple-vetted.
Trade-offs: PBKDF2 is weaker than Argon2 against GPU attacks (no native Apple Argon2 — adding a dependency is rejected); mitigated by calibrated iterations, high-entropy requirement being user-passphrase reality, and the local threat model (offline guessing by whoever obtains the file, which the KDF slows).
