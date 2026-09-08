# 20. Observability, Logging & Diagnostics

**Tooling:** `os.Logger` with per-subsystem categories (`app`, `session`, `motion`, `processing`, `baseline`, `audio`, `backup`, `persistence`) + `OSSignposter` intervals for pipeline stages.

| Event | Level | Logged content |
|---|---|---|
| Session start/stop | Info | mode, advertised vs. valid-walking duration, sample counts, gap count |
| Validity outcome | Info | valid/invalid + reason category (no data) |
| Processing stage timings | Debug + signposts | stage durations, window/stride counts |
| Baseline established | Info | mode, algorithm version (no metric values) |
| Audio degradation | Warning | route/interruption category |
| Export/import outcomes | Info | envelope/schema versions, success/failure category (no key material) |
| Errors | Error | category + technical message |

**Never logged:** passphrases, keys, salts, nonces, raw sensor samples, metric values, profile fields. Metric *values* are treated as sensitive health data — counts and statuses only [REC consistent with PRD sensitivity].

**Production debugging without sensitive data:** signpost-based performance traces; validity reasons recorded *on the session record* (structured, local) so a tester's "bad session" is self-explanatory in History-adjacent diagnostics; TestFlight feedback channel for qualitative reports. No analytics infrastructure — the PRD contains no analytics requirement, and none is added [PRD Rule: no invented backend/analytics].
