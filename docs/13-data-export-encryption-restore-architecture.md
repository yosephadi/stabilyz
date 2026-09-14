# 13. Data Export, Encryption & Restore Architecture

All items marked **[PRD]** in this section are hard requirements from PRD §5/§6/§7 and OQ-2 — not recommendations.

## 13.1 Export Format & Archive Structure

**[PRD]** archive contents: profile, **all valid sessions** (both modes, mode-tagged), **both modes' baselines**, settings/preferences, app version, algorithm version, schema version, export timestamp, integrity check.

```
Stabilyz Export File (.stabilyz [REC extension])
┌───────────────────────────────────────────────┐
│ HEADER (plaintext, needed to decrypt):        │
│  magic "STBLYZ" + envelope format version     │
│  crypto suite id (e.g. PBKDF2-SHA256+AESGCM)  │
│  KDF params: salt (≥16 B random, per export), │
│              PRF id, iteration count          │
│  nonce (12 B random)                          │
│  key-check value [REC — see 13.4]             │
├───────────────────────────────────────────────┤
│ CIPHERTEXT (AES-GCM, tag appended):           │
│  JSON payload:                                │
│   schemaVersion, appVersion, algorithmVersion │
│   exportedAt, payload SHA-256 digest          │
│   profile, validSessions[], baselines[≤2],    │
│   preferences                                 │
└───────────────────────────────────────────────┘
```

- **Serialization [PRD]**: metadata + data in one archive; JSON chosen [REC] for debuggability and migration simplicity; payload is small (metrics-only sessions).
- **Salt/nonce/KDF params/version stored within the file [PRD]** — the header is the self-describing envelope.
- **Integrity [PRD]**: AES-GCM authentication tag + inner payload digest [REC double-check, satisfying "integrity check (e.g. checksum)"].

## 13.2 Encryption Flow (Export)

1. User sets + confirms passphrase in the Export wizard; the **unrecoverable-passphrase warning is shown before generation [PRD]**.
2. Passphrase canonicalized (leading/trailing whitespace trimmed, then Unicode NFC — §13.3), converted to bytes, held only in memory for the operation [PRD: never written to disk; no recovery].
3. **KDF [PRD]:** PBKDF2-HMAC-SHA256 via CommonCrypto `CCKeyDerivationPBKDF` (Apple's vetted implementation; CryptoKit does not provide PBKDF2), **unique 16-byte random salt per export [PRD]** (SecRandomCopyBytes), iteration count calibrated on-device (~200–500 ms; starting point ~300k [REC], stored in header so old exports stay decryptable).
4. **AEAD [PRD]:** AES-256-GCM via CryptoKit, random 12-byte nonce, seal the serialized payload.
5. Write **ciphertext only** to a temp file (no plaintext temp file ever exists [REC — serialize in memory]), present via the **system share sheet [PRD]** (destination is the user's choice; explicit user action only, never automatic), then delete the temp file.
6. **No custom cryptographic primitives anywhere [PRD]** — CryptoKit + CommonCrypto only.

## 13.3 Passphrase & Secure Memory

- Never stored, never logged, never sent anywhere [PRD OQ-2].
- Held as a mutable byte buffer during KDF and cleared after key derivation where possible [REC — Swift `String` cannot be zeroed; the byte-buffer approach bounds exposure; realistic residual risk accepted and documented].
- **Minimum length — decided 2026-09-15 (Task 10.2.1):** 8 characters, counted as a person sees them (an emoji is one), after leading and trailing whitespace is removed. Empty and whitespace-only passphrases are refused. The export wizard requires a matching confirmation and an acknowledged unrecoverable-passphrase warning before anything is generated.
- **Canonical form — decided 2026-09-15:** before a passphrase becomes key material it is **trimmed of leading and trailing whitespace, then Unicode NFC-normalized**, at export and at restore alike (`PassphrasePolicy.canonical`). Trimming means a space a keyboard adds can never lock someone out of their own backup; spaces inside the passphrase are part of it. NFC means an accented letter typed as one code point or as a letter plus a combining mark derives the same key. **This is a file-format contract:** changing either rule would stop existing exports opening.

## 13.4 Import Flow & Validation Order

**[PRD] order is fixed:** passphrase prompt → **decrypt before schema/version/integrity validation** → validate **before any local data is touched**.

1. Pick file (system document picker, both first-launch and Settings paths [PRD]).
2. Parse envelope header. Unknown magic/envelope version → "file isn't a Stabilyz export" plain-language error; nothing touched.
3. Derive key from entered passphrase + header params; attempt AES-GCM decrypt. **Key-check value [REC]:** a small GCM-sealed known constant inside the envelope lets the app distinguish "wrong passphrase" (check fails) from "corrupted data" (check passes, payload/tag fails) — satisfying the PRD's "distinguishing … where possible" requirement. Without it, both collapse into one message.
4. Post-decrypt validation [PRD]: payload digest; `schemaVersion` vs. supported range — older ⇒ run DTO migration chain; newer than supported ⇒ plain-language incompatibility error, nothing touched [PRD §6]; log app/algorithm versions; verify archive completeness (profile, disclaimer accepted, both baseline entries mode-distinct).
5. Only after full validation does any local data path begin.

## 13.5 Atomic Restore (hard requirement [PRD])

**Design [REC implementation of a PRD hard requirement]:**

1. All decryption/validation completes **before** any local mutation (per 13.4) — the primary guarantee.
2. Snapshot the current store file(s) (copy).
3. Perform the replace inside the live SwiftData container as a **single background-context transaction** (delete all entities → insert migrated domain objects → one atomic save). Failure ⇒ transaction rollback ⇒ store unchanged.
4. Catastrophe net: if the container is left inconsistent (process kill mid-save), the pre-restore snapshot replaces the store on next launch; snapshot deleted only after verified success.
5. On success: publish the **state-invalidation event** (§11.4), rebuild in-memory view models, navigate.
6. **Import is a restore, not a merge [PRD OQ-2]** — no duplicate resolution, no baseline merging, ever in v1.

Failure-recovery matrix:

| Failure | Result |
|---|---|
| Wrong passphrase | Plain-language message; nothing changed [PRD] |
| Corrupted / tampered file | Detected via GCM tag/digest; nothing changed [PRD] |
| Incompatible (future) schema | Plain-language incompatibility message; nothing changed [PRD] |
| Interruption mid-restore | Transaction rollback or snapshot recovery; store consistent [PRD: "no partially-restored or corrupted intermediate state"] |

## 13.6 Versioning & Migration Strategy

- **Envelope format version** (crypto structure) and **payload schemaVersion** are independent; both live in the file [PRD embeds version identifiers].
- v1 supports schemaVersion 1 (and only envelope v1); the DTO layer has a sequential migration pattern (`schema N → N+1`) so future versions can read old exports [PRD: "so a future app version can correctly decrypt and migrate an older export"].
- SwiftData store schema versioning is tracked separately (§6) with lightweight-migration intent; the export archive is the cross-version data contract.
