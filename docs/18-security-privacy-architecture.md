# 18. Security & Privacy Architecture

| Requirement | Design |
|---|---|
| Local-only, no backend, no auto cloud sync [PRD §3, OQ-2] | No networking code exists; no push/background-transfer entitlements; the app itself performs zero network requests. Share-sheet destinations are OS-level, user-chosen [PRD §5] |
| Sensitive health/mobility data | Data minimization: store only profile fields the PRD collects, per-session derived metrics, and provenance metadata. No raw sensor retention (§6.4) |
| Permissions | Motion & Fitness only; no other permission prompts anywhere in v1. Pre-flight check + degraded Start [PRD AC] |
| Export security | Passphrase + PBKDF2 + AES-GCM per §13 [PRD] — the export is protected independently of device state (deliberate PRD design: no iCloud dependency [OQ-2]) |
| Passphrase handling | Memory-only during the operation; never persisted, logged, or transmitted; clear warnings at export [PRD]; unrecoverable by design |
| Temporary files | Export temp file contains ciphertext only; deleted after share; session scratch deleted at commit [REC]; all files use iOS data protection (.complete default) |
| Logging | No sensor payloads, metric values, profile fields, or crypto material in logs; counts/durations/status only (§20) |
| Crash reporting | No third-party crash SDK [PRD posture]; TestFlight's Apple-provided crash reports (metadata-level) are the only crash signal in v1 [REC] |
| Data deletion | App deletion removes all local data (local-only store). **[OPEN/REC]:** an explicit "Erase all data" control in Settings is *not* specified by the PRD — recommend raising as a product decision; architecture reserves a repository `wipeAll()` for it |
| Device-level protections | Standard iOS sandbox + file data protection; nothing extra to do; documented so no one "adds" a cloud backup of the store |
