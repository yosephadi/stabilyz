# 6. Persistence Architecture

## 6.1 Technology Selection

| Store | Chosen for | Contents |
|---|---|---|
| **SwiftData** | Structured, relationship-light, versioned, queryable app data | Profile, sessions (valid + invalid), baselines, preferences |
| **UserDefaults** | Trivial, non-sensitive, ephemeral prefs | Onboarding draft (resume), minor UI prefs |
| **File system (app container)** | Export archives, temp processing scratch | `.stabilyz` exports [REC extension], temp files (encrypted-only for exports) |
| **Keychain** | **Not used** | No secrets exist: passphrase is never stored [PRD OQ-2 explicitly rejected keychain-synced approach]; no accounts |
| **Codable archives** | Used *inside* SwiftData blobs and the export payload | Metrics/stats serialization |

## 6.2 Why SwiftData over the alternatives

- **vs. Core Data:** SwiftData is the native Swift-first successor with macro models, `ModelActor` concurrency, and `@Query` for SwiftUI. PRD's iOS 17 floor makes it fully available. Data complexity is low (3 entities, no deep relationships), which sits inside SwiftData's comfort zone. Trade-off acknowledged: SwiftData's migration tooling is younger than Core Data's — mitigated by (a) deliberately narrow schema with blob-based metric storage, (b) the encrypted export archive acting as a data portability escape hatch, (c) schema version discipline (§13.6).
- **vs. file/Codable-only:** History, trend, and per-mode validity counting are real queries (date-ordered, mode-filtered, validity-filtered, count-limited) — reimplementing them over flat files invites the exact cross-mode mixing bugs the PRD forbids [OQ-5].
- **vs. SQLite directly:** unnecessary boilerplate; no query needs exceed SwiftData.

## 6.3 Store Design

- Single default store under Application Support; container built at composition root.
- **Writes** (session commit, baseline creation, restore) go through a background `ModelActor`; **reads** for UI via main context/`@Query`.
- Schema carries a persistent `schemaVersion` value for migration gating [REC].
- **Uniqueness invariants:** one profile; one baseline per mode (enforced + repository-level assertion, belt and braces) — a structural guarantee of PRD OQ-5.

## 6.4 Data Volume

Raw sensor data is **not persisted long-term** [REC]: a 6-minute session at ~100 Hz ≈ 36 k samples (~0.5 MB in memory) — trivially processed in memory; persisted session rows are metrics-only (KB-scale). Raw samples exist only in the recorder buffer and a scratch temp file for the duration of a session [REC: crash-recovery scratch], deleted at commit. This keeps the store tiny and the export archive portable. [PRD never requires raw-sensor retention; export scope is metrics/scores/baselines/profile/settings.]
