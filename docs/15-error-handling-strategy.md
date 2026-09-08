# 15. Error Handling Strategy

## 15.1 Representation

One `StabilyzError` domain enum with categories; thrown from services/domain; **translated at the view-model boundary** by a single `ErrorPresenter` mapper into plain-language, non-technical strings. Technical messages are logged, never shown [PRD Rule: "Do not expose technical errors directly to the user"].

| Category | Examples | Handled at | Logged | User sees | Recoverable | State-unchanged guarantee |
|---|---|---|---|---|---|---|
| Permission | Motion & Fitness denied | Session Setup (pre-flight) | Info | Inline explanation on Start button; link to Settings | Yes (user grants) | n/a |
| Sensor | Unavailable, priming timeout, mid-session failure | Recorder + session flow | Error | "Couldn't record — try again" | Yes | No partial session persisted |
| Recording | Interruption/gap policy outcomes | Pipeline | Warning + gap metadata | Only if invalid (noisy screen) | n/a | — |
| Processing | No walking detected, too few strides, noise | Pipeline → validity | Warning | Noisy/insufficient-data screen (plain-language, no score) [PRD] | Re-run session | Invalid session recorded, never baseline-counted |
| Persistence | Save failure, store corruption | Repositories + app-level recovery | Error | Generic retry message | Retry / relaunch | Failed commit rolled back (transactional writes) |
| Export | KDF/file/share failure | Export flow | Error | "Export didn't complete — nothing was changed" | Yes | **No temp plaintext; temp ciphertext deleted; store untouched** |
| Import/decryption | Wrong passphrase, corrupted, bad header | Restore flow | Error (no key material) | Distinct plain-language messages where possible [PRD] | Yes | **Hard: existing DB byte-identical** [PRD] |
| Schema compatibility | Future schema, unsupported envelope | Restore flow, pre-data-touch | Warning | Incompatibility message | Upgrade path suggested | **Untouched** [PRD] |
| Audio | Route loss, interruption, engine failure | Audio service (silent degradation) | Warning | Nothing (fail to speaker or stop cleanly) [PRD §6] | Automatic | Session recording unaffected |
| Crypto | Tag verification failure, RNG failure | SecureArchive service | Error | Mapped to import/export messages | No | Untouched |

## 15.2 Principles

- Every user-visible failure string is non-technical, action-oriented, and calm (PRD's plain-language posture throughout §6).
- Never log passphrases, keys, salts, raw sensor data, or metric values (§20).
- Any operation with a PRD atomicity guarantee (restore, export temp, session commit) must be implemented so the failure path is exercised in tests (§19).
