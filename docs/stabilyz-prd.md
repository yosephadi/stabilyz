# Stabilyz — Product Requirements Document

*iOS app for prosthetic limb users to independently measure their own walking stability.*

---

## 1. Why (Objective)

People who use prosthetic limbs often have a *feeling* about how their walking is doing — "I think I'm more stable this week" or "something feels off today" — but no way to confirm whether that feeling reflects reality. Clinical gait labs exist, but they're expensive, infrequent, and out of reach for day-to-day use. Apple's built-in Walking Steadiness score exists, but it's calibrated on able-bodied gait, updates weekly, and isn't built to capture asymmetry the way a prosthetic user's gait actually needs.

**Stabilyz exists so that a prosthetic limb user can independently test and measure their own walking stability, on demand, and get back a number — not a feeling.** That number is what lets someone know whether they're actually improving, actually declining, or whether it really was just a bad day. This is the whole point of the product: turning "I think" into "I know."

---

## 2. Define "Success"

Success for this build is:

- **Deployed on TestFlight**, installable and runnable by a real tester on a real iPhone.
- **The app is functional** — meaning, concretely:
  - A user can complete onboarding, run a Gait Training session (either mode) start-to-finish, and see a score.
  - The app doesn't crash during a normal session in either mode — a 2-minute Quick Test or a 6-minute Full Test, both modeled on the validated 2MWT/6MWT clinical walk tests used in amputee research (see Open Question 3 for the full reasoning behind offering both).
  - The scoring algorithm returns a real, non-placeholder number derived from that session's motion data.
  - Baseline calibration works after 5 sessions, and scores are shown relative to it.
  - Session history and the clinician summary screen render real stored data.

Success at this stage is explicitly **not**: clinically validated accuracy, App Store release, or a polished/finished UI. It's "does the core loop work, end to end, on a real device."

---

## 3. Describe the Users

**Primary user: a self-directed lower-limb prosthetic user.**
- Transtibial, transfemoral, or bilateral amputation.
- Ambulatory enough to walk 2-6 minutes unsupervised (this app is *not* designed for acute post-op patients who require a PT present for every walk — that's an explicit boundary, not an oversight).
- Anywhere from a few months to many years post-amputation; research on this population skews a wide age range (studies commonly span late 20s to late 70s), so the app can't assume a tech-savvy or young user.
- Motivated by wanting objective self-verification between clinical visits, and by wanting to feel more confident and in control of their own mobility — not by wanting a clinical diagnosis.

**Secondary user: the user's prosthetist or physical therapist.**
- Doesn't use the app directly. Sees the app's output only through the single clinician summary screen the user chooses to show them, in person, during an appointment.

*Assumption flagged: this PRD assumes an individual, self-directed adult user with no account/login system, no automatic cloud sync, and no server backend for this build. Data stays on the device by default; manual export provides a user-controlled backup and device-transfer mechanism (see Open Question 2) — it does not change this core assumption.*

---

## 4. Solution (Brief)

Stabilyz is an iOS app that lets a prosthetic limb user run short, self-directed "Gait Training" sessions using nothing but their iPhone's built-in motion sensors. The user chooses between two modes, both modeled on validated clinical walk tests for this population: a **2-minute Quick Test** for a fast check-in, or a **6-minute Full Test** for a more sensitive read on subtler, fatigue-related patterns. When a session ends, Stabilyz immediately computes a stability score from several independent signals — **gait consistency** (step regularity and stride regularity, computed via autocorrelation the same way for every user regardless of amputation type), **step-time/cadence variability**, and an **acceleration-based trunk-motion proxy** — plus, for unilateral users where a sound side is identifiable, a secondary limb-specific timing-asymmetry feature. The score is reported as a relative index against the user's own personal baseline for that mode, not an abstract "normal" gait and not mixed across modes. During the sessions establishing that baseline, walking is captured as undisturbed as possible by default — an optional **Step Feedback** toggle (off by default) plays a brief sound on confidently-detected steps with no target pace implied, never a metronome. Once a baseline exists, an optional **Metronome cue**, paced to the user's own baseline cadence, becomes available for in-the-moment pacing feedback — an intentional influence the user opts into, now that there's a clean reference point to influence gait relative to. Over time, a session history and trend chart let the user see whether they're actually improving, and a single shareable summary screen lets them bring objective data — not just a memory of "it's been fine, I think" — to their next appointment.

---

## 5. Product Flow

```
[First Launch]
      │
      ▼
[New here, or restoring?]
  • "Get Started" ──► proceeds to Onboarding below
  • "Restore from a previous export" ──► user picks a file via the system file picker; prompted for the export's passphrase; validated for schema/version compatibility and decrypted; on first launch there's no existing local data yet, so a valid file restores the full archive (profile, session history, both modes' baselines, settings) and skips straight to Home; wrong passphrase, or an invalid/corrupted/incompatible file, shows a plain-language error and falls back to "Get Started" without altering anything
      │
      ▼ (Get Started path)
[Onboarding — one screen per field, progressive]
  • Amputation level (transtibial / transfemoral / bilateral)
  • Side (left / right / both)
  • Time since amputation
  • Device/prosthesis type (optional)
  • K-level / activity level (optional)
  • "Why we ask" microcopy on the level/side screens
  • Final screen: plain-language "not a medical device" disclaimer + required checkbox — user cannot proceed to Home until it's ticked
      │
      ▼
[Home / Dashboard]
  • Empty state before first session: "Run your first Gait Training session"
  • After sessions exist: latest score + trend snapshot + "Start Gait Training" button
      │
      ▼
[Start Gait Training]
      │
      ▼
[Select Test Mode] ── 2-minute Quick Test  |  6-minute Full Test
      │
      ▼
[Audio feedback selector] ── depends on whether this mode's baseline exists yet:
  • Before baseline exists (sessions 1-5): "Walk normally — there's no target pace" framing shown; optional **Step Feedback** toggle, off by default (a brief sound on confidently-detected steps, never a tempo)
  • After baseline exists (session 6+): optional **Metronome cue** toggle, paced to this mode's baseline cadence
      │
      ▼
[Session In Progress]
  • Start confirmation tone
  • CMMotionManager + CMPedometer recording live
  • Step Feedback (pre-baseline) or Metronome cue (post-baseline) playing, only if the user enabled it
  • Stop button always visible
      │
      ▼
[Stop] ── Stop confirmation tone
      │
      ▼
[Processing] ── brief, on-device only, no network call
      │
      ├── (data too noisy, or session ended short of that mode's minimum) ──► [Noisy Session Screen] ── plain-language explanation, no score shown, session marked invalid, does not count toward that mode's baseline
      │
      └── (data valid)
              │
              ▼
      [Score Screen]
        • If < 5 valid sessions exist *in this mode*: "Building your Quick Test baseline — Session X of 5" (or Full Test, matching whichever mode was run), no relative score yet, raw metrics optionally shown as "reference only"
        • If ≥ 5 valid sessions exist *in this mode*: score shown as a **relative index against that mode's baseline** (e.g. baseline = 100, this session = 112) rather than a percentage claim like "12% more stable" — the composite hasn't been calibrated to support that kind of real-world percentage interpretation in v1 — + one-line encouraging summary + tap-to-expand the underlying signals (gait consistency, step-time/cadence variability, trunk-motion proxy, plus limb-specific timing asymmetry when available for unilateral users)
              │
              ▼
      [Session saved to History, tagged with its mode]
              │
              ▼
      [Session History & Trend Screen] ── list of past sessions (mode shown per entry) + Swift Charts trend line, filterable/split by mode
              │
              ▼
      [Clinician Summary Screen] ── accessible from History or Settings
        • Current baseline(s), last N sessions' scores, trend chart, single screen, nothing else — shows both modes clearly separated, not blended
              │
              ▼
      [Settings] ── includes:
        • "Export My Data" — prompts the user to set a passphrase (with a clear, unambiguous warning that Stabilyz cannot recover a forgotten one — this is not a resettable account password), then generates an **encrypted** portable archive (profile, all valid sessions, both modes' baselines, settings/preferences, app/algorithm version, schema version, export timestamp, integrity check), shared via the standard iOS share sheet (Files, AirDrop, email, cloud drive — user's choice, not Stabilyz's)
        • "Restore from a previous export" — same picker as at First Launch, plus a passphrase prompt before any decryption is attempted; since Settings is only reachable once local data already exists, this always triggers the existing-data conflict flow below:
              │
              ▼
        [Existing data found] ── "Restoring this backup will replace the data currently stored on this device. Your current data will be deleted from this device. This cannot be undone unless you have an export of it."
              │
              ├── Cancel ──► returns to Settings, nothing changes
              ├── Export current data first ──► runs "Export My Data" (including its own passphrase prompt), then re-presents this same choice
              └── Replace with backup ──► decrypts and validates the backup using the entered passphrase, then replaces the local database atomically — a wrong passphrase or failed validation leaves the existing local database completely untouched
```

**Out of this flow for v1** (explicitly deferred, per existing backlog): HealthKit passive track, threshold-based recommendations, turn-detection, socket-fit tagging, cohort benchmarking, and structured clinician-facing data export (e.g. a PDF report format) beyond the single summary screen — this is distinct from the personal backup export/import described above, which is in scope and exists so the user can move their own data to a new device, not to hand a report to a clinician.

---

## 6. Edge Cases

### Onboarding
- **Bilateral amputation selected.** Resolved (see Open Question 1): gait consistency (autocorrelation-based step/stride regularity) is computed identically for every user, bilateral included, since it never requires identifying a sound side. Bilateral users simply don't get the secondary limb-specific timing-asymmetry feature that unilateral users get when their side is reliably identifiable — nothing is fabricated in its place.
- **User skips both optional fields** (device type, K-level). Onboarding must complete successfully with only the required fields filled.
- **User force-quits or backgrounds the app mid-onboarding.** On relaunch, onboarding should resume where they left off, not restart or lose partial progress — including if they quit on the final disclaimer screen before ticking the box.
- **User never ticks the disclaimer checkbox.** This is an intentional hard gate — there's no skip path to Home. The screen should make clear why they can't proceed, rather than the checkbox failing silently or the Continue button just not responding.

### Session recording
- **Motion & Fitness permission denied.** The Start button must degrade gracefully — explain why the app can't record, don't let the user tap Start into a silent failure.
- **Phone call or notification interrupts a session mid-recording.** Recording should either pause/resume cleanly or the session should be flagged as noisy — it must not silently produce a corrupted "clean" score.
- **User stops a session early, or doesn't accumulate enough valid walking data, relative to their chosen mode.** Resolved (see Open Question 3): the advertised test length (2 min for Quick Test, 6 min for Full Test) is not the same threshold as the *valid walking data* required to produce a score — Quick Test requires ~90 seconds of valid walking data, Full Test requires ~4 minutes, and invalid segments (pauses, setup time, non-walking motion) don't count toward that requirement even if the clock ran the full advertised length. Anything short of the relevant threshold, or otherwise failing data-quality checks, routes to the noisy/insufficient-data path and does not attempt a score.
- **App is backgrounded or the phone locks during a session.** iOS can suspend motion updates in the background — this needs explicit handling (either prevent backgrounding during a session with a clear message, or confirm CMMotionManager background recording is configured correctly).
- **User stands still mid-session** (answers the door, waits at a crosswalk). This isn't necessarily "noisy" data, but static periods shouldn't be scored as if they were walking — the algorithm needs to detect and exclude non-walking segments, or the session needs to flag it.
- **Session recorded in a small space with lots of turning.** Turn-detection is explicitly out of v1 scope, so a session that's mostly turns could produce a misleadingly bad score. Worth a short instruction to the user ("walk in as straight a line as you can") rather than a technical fix in v1.
- **Low battery / thermal throttling during recording.** Should not crash the session; at minimum, fail gracefully into the noisy-data path.

### Baseline
- **Fewer than 5 valid sessions exist for the mode just run.** No relative score can be shown yet for that mode — the Score Screen must have a defined "building your baseline" state, specific to Quick Test or Full Test (see Product Flow).
- **One of the first 5 sessions in a mode is flagged noisy.** It must not count toward that mode's 5 — baseline calibration only counts *valid* sessions within the same mode, so each mode's "X of 5" counter must track its own valid-session count independently.
- **A user with an established Quick Test baseline runs their first-ever Full Test (or vice versa).** The two modes must not share a baseline or a session count — the new mode starts its own "Session 1 of 5," even though the user already has history in the other mode. The Score Screen and History views must make it obvious which mode a given score belongs to, so this doesn't read as a bug or a reset.
- **The user's gait meaningfully changes after baseline is set** (new prosthesis, socket refit, weight change). Recalibration/re-baselining is out of v1 scope for either mode — this is a known limitation to document, not solve now, but the score screen's language should avoid implying the baseline is permanently authoritative.

### Data & storage
- **App is deleted and reinstalled, or the user gets a new phone, and the user exported beforehand — with the passphrase still known/available.** They should be able to fully restore profile, session history, and both modes' baselines via "Restore from a previous export" at first launch — this is the actual mitigation, not automatic cloud sync.
- **App is deleted and reinstalled, or the user gets a new phone, and the user did *not* export beforehand, or exported but has forgotten the passphrase.** This remains genuine, unrecoverable data loss — history, baseline, everything, with no reset path for a forgotten passphrase by design (there's no account for Stabilyz to verify identity against). The app should make "Export My Data" easy to find and periodically nudge toward it (e.g. after baseline is first established), and the passphrase warning at export time should make this consequence unambiguous upfront.
- **User forgets or mistypes the passphrase during import.** Fails gracefully with a plain-language message distinguishing "wrong passphrase" from "corrupted file" where possible, and leaves any existing local data completely untouched — never a crash.
- **User attempts to import an export file while the app already has existing local data on this device** (e.g. they already completed onboarding and have sessions logged, or are using the Settings restore path, which only exists once local data is present). Resolved: an import is a **restore, not a merge** — the user is warned that restoring will replace the device's current data, given a chance to export the current data first, and only then can deliberately replace it. Automatic merging is explicitly out of scope for v1: resolving duplicate sessions, conflicting baselines, differing settings, and differing algorithm/schema versions between two independent datasets is a data-integrity problem, not just a UI one, and isn't worth the added complexity for v1.
- **Restore fails partway through** (wrong passphrase, corrupted file, interrupted write, schema mismatch discovered mid-restore). This is treated as a hard requirement, not just an edge case: the existing local database must remain completely untouched if validation, decryption, or restoration fails at any point — a failed restore should never leave the device in a partial or corrupted state.
- **An export file is opened by a different or much newer/older app version than created it.** The export includes its own schema/version metadata specifically so this can be detected and validated (after successful decryption) before any data is touched, rather than discovered mid-restore.
- **User attempts to import a corrupted, malformed, or version-incompatible export file.** Must fail gracefully with a plain-language message and leave any existing local data untouched — never a crash, never a partial/corrupted import.
- **Clinician screen opened with zero or partial session history.** Needs a defined empty/partial state per mode — it can't assume 5+ sessions always exist in either mode, and a user might have a full baseline in one mode and none in the other.

### Step Feedback & Metronome cue
- **Sessions 1-5 in a mode (no baseline yet).** Resolved (see Open Question 4): Step Feedback, not a metronome, and off by default. The first-ever session in a mode shows "walk normally, no target pace" framing rather than presenting the toggle as an obvious default-on choice. If enabled, it must not imply or drift toward any tempo.
- **Low-confidence or false-positive step detections during Step Feedback.** A sound must only fire on steps the detector is confident are genuine — playing a sound on every raw signal spike risks creating an accidental, unintended rhythm (effectively a fake metronome the app never meant to produce), which defeats the entire point of keeping baseline sessions undisturbed.
- **A single physical step registers as multiple detection events.** A short debounce/refractory period after each triggered sound prevents one footfall from producing a rapid double- or triple-beep.
- **Bluetooth audio device disconnects mid-session** (AirPods die, connection drops). Both Step Feedback and the Metronome cue should fail silently to device speaker or stop cleanly — neither should crash or freeze the session.

---

## 7. Acceptance Criteria

### Disclaimer & Onboarding
- [ ] The disclaimer (plain-language, non-diagnostic "not a medical device" language) appears as the final onboarding screen, with a required checkbox the user must tick before continuing.
- [ ] The user cannot reach Home/Dashboard without ticking the disclaimer checkbox — there is no skip path.
- [ ] The disclaimer text remains accessible after onboarding (e.g. Settings/About), even though the required checkbox itself is only presented once, during onboarding.
- [ ] Onboarding presents one field (or tightly grouped field-set) per screen with a visible progress indicator.
- [ ] "Why we ask" microcopy appears on the amputation level and side screens.
- [ ] A user can complete onboarding with only required fields filled; optional fields (device type, K-level) can be left blank without blocking progress.
- [ ] Onboarding progress persists across an app relaunch mid-flow, including on the final disclaimer screen if the app is quit before the box is ticked.
- [ ] Bilateral amputation is a selectable, fully supported option (not a dead end in the algorithm downstream).

### Session recording
- [ ] User selects a test mode (Quick Test — 2 min, or Full Test — 6 min) before a session starts; the selection is stored with the session.
- [ ] Tapping Start begins CMMotionManager + CMPedometer recording within [define: e.g. 1 second] and plays a distinct start tone.
- [ ] Tapping Stop ends recording cleanly and plays a distinct, different stop tone.
- [ ] A session that doesn't accumulate the required amount of **valid walking data** for its selected mode — ~90 seconds for Quick Test, ~4 minutes for Full Test — is routed to the noisy/insufficient-data path and never scored, even if the full advertised session length (2 min / 6 min) elapsed on the clock. Pauses, setup time, and other non-walking segments don't count toward this requirement.
- [ ] If Motion & Fitness permission is not granted, the Start button explains why recording can't proceed instead of failing silently.
- [ ] A session with excessive noise (define threshold) is flagged automatically and shown the plain-language noisy-data screen — no score is displayed for a flagged session.

### Scoring & baseline
- [ ] For a valid session, **gait consistency** — step regularity (Ad1) and stride regularity (Ad2), via autocorrelation of the trunk acceleration signal — is computed identically for every user regardless of amputation type (unilateral or bilateral), alongside step-time/cadence variability and an acceleration-based trunk-motion proxy (defined as a specific computation — e.g. RMS or variance of mediolateral and vertical acceleration during steady-state walking — not just labeled "balance"); all are stored, tagged with the session's mode.
- [ ] For unilateral users where side is reliably identifiable, a **secondary sound-vs-prosthetic step-time asymmetry** feature is also computed and stored, clearly labeled and presented as distinct from gait consistency — not merged into a single number.
- [ ] For bilateral users, no sound-side asymmetry value is fabricated or estimated in place of the missing secondary feature — the score is built from gait consistency, step-time/cadence variability, and the trunk-motion proxy only.
- [ ] Gait consistency is combined with step-time/cadence variability and the trunk-motion proxy as independent inputs to the stability score — it is never the sole basis for the score, since a highly regular gait can still be dynamically unstable.
- [ ] User-facing copy refers to this metric as **"gait consistency,"** never as "symmetry" or "asymmetry," to avoid implying a limb-to-limb comparison that isn't actually being made for all users.
- [ ] Each metric's baseline standardization applies a **minimum standard-deviation floor** before computing a relative score, so a metric with an unusually small baseline SD for a given user doesn't produce an unstable, exaggerated result from ordinary session-to-session noise.
- [ ] Before 5 valid sessions exist *in a given mode*, the Score Screen shows that mode's "building your baseline" state, not a relative score.
- [ ] After the 5th valid session *in a given mode*, a baseline is computed and stored per metric, for that mode specifically.
- [ ] From the 6th valid session onward *in that mode*, every score is displayed as a **relative index against that mode's stored baseline** (e.g. "108, vs. your baseline of 100"), not a real-world percentage claim like "X% more stable," since the composite isn't calibrated to support that interpretation in v1.
- [ ] A mode's baseline is only treated as trustworthy — and relative scoring only begins — once its 5 valid calibration sessions are complete; scores shown before that point are explicitly framed as provisional/building, not final.
- [ ] A noisy/flagged session does not count toward its mode's 5-session baseline count.
- [ ] Quick Test and Full Test baselines, session counts, and trend data are kept fully independent — no metric or count from one mode contributes to the other's baseline.

### Step Feedback (sessions 1-5, pre-baseline)
- [ ] Off by default — the user must explicitly opt in for any audio during baseline-establishing sessions.
- [ ] The first-ever session in a mode presents "walk normally, no target pace" framing before Start, rather than surfacing the toggle as if it were expected to be on.
- [ ] When enabled, a short, unobtrusive sound plays only on steps the detector is confident are genuine — not on every raw motion event.
- [ ] A debounce/refractory period prevents a single physical step from producing more than one sound.
- [ ] Step Feedback never sets, targets, or implies a tempo — purely reactive to detected steps, nothing anticipatory.
- [ ] Sound-to-footfall latency is low enough that the feedback doesn't feel disconnected from the actual step.

### Metronome cue (session 6+, post-baseline)
- [ ] Only becomes available once that mode's baseline cadence exists — not offered during sessions 1-5.
- [ ] The user can toggle it on/off before a session starts.
- [ ] When enabled, plays at a steady interval derived from that mode's baseline cadence.
- [ ] Neither Step Feedback nor the Metronome cue alters or blocks the batch scoring computation that runs at Stop.

### History, trend, and clinician screen
- [ ] Session History lists all valid past sessions, each labeled with its mode, with their mode-relative baseline scores (once that mode's baseline exists).
- [ ] The trend chart renders from real stored session data, not placeholder values, and clearly distinguishes Quick Test from Full Test entries (e.g. filter or separate series).
- [ ] The post-session encouraging summary (one to two sentences) displays alongside the score, generated from real metric comparisons within the same mode (e.g. vs. last N sessions of that mode), not a static string.
- [ ] The clinician summary screen renders current baseline(s), last N sessions, and the trend chart from existing stored data, with modes clearly separated and defined empty/partial states when fewer than 5 sessions exist in either mode.

### Data export & import
- [ ] "Export My Data" in Settings generates a portable archive containing: profile, all valid sessions, both modes' baselines, settings/preferences, app/algorithm version, schema version, an export timestamp, and an integrity check (e.g. checksum) — not just the raw session/baseline data.
- [ ] **The archive is encrypted using a passphrase the user sets at export time** — never written to disk or shared in plaintext.
- [ ] The passphrase is run through a **proper password-based KDF** (e.g. PBKDF2, scrypt, or Argon2, via a vetted platform/crypto library like CryptoKit/CommonCrypto) with a **unique random salt generated per export** — a raw hash (e.g. plain SHA-256) of the passphrase is never used directly as the encryption key.
- [ ] Encryption uses an **authenticated cipher mode (AES-GCM)**, not a non-authenticated mode, so a corrupted or tampered file is detected as invalid rather than silently decrypting into garbage.
- [ ] The salt, nonce, KDF parameters, and a schema/crypto version identifier are stored **within the export file itself**, so a future app version can correctly decrypt and migrate an older export.
- [ ] No custom-built cryptographic primitives are used anywhere in the encryption/decryption path — only vetted, platform-provided ones.
- [ ] At export time, the user sees a clear, unambiguous warning that Stabilyz cannot recover a forgotten passphrase — this is not a resettable account password, and there is no recovery flow.
- [ ] The export is shared via the standard iOS share sheet — Stabilyz doesn't decide the destination (Files, AirDrop, email, cloud drive are all the user's choice), and export is only ever triggered by explicit user action, never automatic or silent.
- [ ] "Restore from a previous export" is offered at first launch (before onboarding) and from Settings.
- [ ] Every restore prompts for the passphrase and attempts decryption **before** schema/version/integrity validation, and validation happens **before** any local data is touched.
- [ ] **An import is a restore, not a merge.** On first launch (no existing local data), a valid, correctly-decrypted file restores the full archive and skips straight to Home. From Settings (existing local data always present), the user sees an explicit warning that restoring will replace the device's current data, with three choices: Cancel, Export current data first, or Replace with backup — never a silent overwrite and never an automatic merge attempt.
- [ ] **Restore is atomic — this is a hard requirement, not a soft preference.** If passphrase decryption, validation, or restoration fails at any point, the existing local database is left completely unchanged; there is no partially-restored or corrupted intermediate state.
- [ ] A wrong passphrase, or an invalid/corrupted/version-incompatible file, fails the import with a plain-language message and changes nothing, on either the first-launch or Settings path.

### Build/deployment
- [ ] The app builds and installs via TestFlight on a physical iPhone (iOS 17+).
- [ ] A full loop — onboarding → session → score → history → clinician screen — can be completed without a crash.

---

## Open Questions for Adi

A few assumptions above are worth confirming or correcting before the algorithm and data-model work goes too far, since they're expensive to change later:

1. ~~**Bilateral amputation handling**~~ — **Resolved**: adopt autocorrelation-derived step/stride regularity as the **universal gait-consistency backbone for all users**, unilateral and bilateral alike, since it's computed purely from the walking signal's own repeating structure and never requires identifying which leg is which. This is architecturally correct, not just less engineering work — it measures a property (how consistently the pattern repeats) that stays well-defined with no reference limb, unlike a direct limb-to-limb comparison.

   Two corrections to how this is labeled and scoped, worth locking in now before the algorithm task starts:
   - **Terminology.** Ad1 (step regularity) and Ad2 (stride regularity) measure how consistently the walking pattern repeats — but that's shaped by both the *repeatability* of the pattern and its underlying *periodicity/timing*, not repeatability in isolation, so step-time/cadence variability isn't a cleanly separate "different lens" so much as a complementary computation over the same underlying signal characteristics. Either way, this is a different question from "how different are the two limbs," which is what a direct sound-vs-prosthetic step-time comparison answers. Calling the autocorrelation output "symmetry" or "asymmetry" overclaims what it measures. Internally: **step regularity** and **stride regularity**. User-facing: **"gait consistency."** The term "step time asymmetry" is reserved for the literal sound-vs-prosthetic limb comparison, kept as a **secondary, optional feature for unilateral users only**, computed when side is reliably identifiable — not the foundation of the algorithm, not attempted for bilateral users, and never fabricated in its absence.
   - **Validation gap, stated explicitly.** The regularity method is validated (against plantar-pressure reference data, in unilateral transfemoral amputees) — it is not validated specifically in a bilateral amputee population. Its math doesn't have the "which leg" problem to begin with, which is why it's the right architectural choice, but that's a different claim from "proven in this subgroup." This should stay a documented research gap, not get quietly implied as settled.
   - **Regularity ≠ stability.** A highly rhythmic gait can still be dynamically unstable, so gait consistency must remain one input to the stability score alongside step-time/cadence variability and the trunk-motion proxy — never the entire score on its own. The trunk-motion proxy in particular stays an independent signal, not folded into or derived from the regularity computation, and is arguably an especially important one for bilateral users specifically, since they lack a stable stance leg to balance against.
   - **Minimum strides for reliable Ad1/Ad2 computation.** Verified directly against the source study (Tura et al. 2012, amputee-specific, transfemoral): ~2.2 strides (Ad1) and ~3.5 strides (Ad2) are sufficient once gait-initiation/termination transients are excluded from the signal, rising to ~15-20 strides when analyzing the whole signal including transients — this is the more realistic figure for how Stabilyz will actually process a session. This is context-dependent on the specific index and the acceptable error tolerance, so treat these as reference points for tuning, not a hard specification.
2. ~~**Data persistence**~~ — **Resolved, refined further**: local-only storage remains the default (no automatic cloud sync, no server backend). Data stays on the device by default; manual export provides a user-controlled backup and device-transfer mechanism — that's the accurate promise, not "no data loss," since it only protects users who actually export before losing their old phone.

   The import-conflict question is now resolved too: **an import is a restore, not a merge.** If existing local data is detected, the user is warned that restoring will replace it, offered a chance to export their current data first, and only then can deliberately replace it — never a silent overwrite, never an automatic merge attempt. Automatic merging is explicitly out of scope for v1, because resolving duplicate sessions, conflicting baselines, differing settings, and differing algorithm/schema versions between two independent datasets is a data-integrity problem, not just a UI one. **Restore must be atomic** — if validation or restoration fails, the existing local database is left completely untouched — treated as a hard engineering requirement, not an edge case to handle loosely.

   The export itself is scoped as a genuine portable archive, not just a session dump: profile, sessions, baselines, settings, and — importantly — its own app/algorithm version, schema version, export timestamp, and an integrity check, so a future app version can detect whether it's safe to interpret an older export before touching any local data.

   ~~**Genuinely still open, not resolved here**~~ — **Locked in, no longer open**: encrypted export by default for v1, using a user-supplied passphrase. No Stabilyz account, server, or cloud service is required. The passphrase is not stored or recoverable by Stabilyz. Users must retain the passphrase themselves; forgetting it permanently prevents restoration of that encrypted backup. The export format is self-contained and includes the metadata required for future decryption and schema migration.

   The iCloud Keychain-synced alternative (`kSecClassGenericPassword` with `kSecAttrSynchronizable`) was considered and deliberately not chosen: it depends on an invisible condition the user may not know about (iCloud Keychain enabled, same Apple ID on the new device), and a backup that exports successfully but later becomes unreadable because of Apple/iCloud state, with no warning the user could have anticipated, is a poor restore experience. The passphrase approach is more self-contained and predictable — export: user sets a passphrase, app encrypts, user saves/shares the file; import: user selects the file, enters the passphrase, app decrypts and restores. The tradeoff is explicit and understandable instead of silent.

   **Cryptographic implementation requirements, not just "use encryption":**
   - A proper password-based KDF (e.g. PBKDF2, scrypt, or Argon2, via a vetted platform/crypto library) with a **unique random salt per export** — never a naive `passphrase → SHA-256 → AES key` construction, which is not a password-based KDF and offers no meaningful resistance to offline guessing.
   - **Authenticated encryption** (AES-GCM), not a non-authenticated cipher mode, so tampering or corruption is detected rather than silently decrypted into garbage.
   - The salt, nonce, KDF parameters, and a schema/crypto version identifier are stored **within the export file itself**, so a future app version can correctly decrypt and migrate an older export rather than guessing at parameters that changed between versions.
   - Only vetted, platform-provided cryptographic primitives (e.g. Apple's CryptoKit / CommonCrypto) — no custom-built cryptographic primitives, ever.

   This adds a bounded scope item, not an open-ended one: prompt for a passphrase at export (with a clear, unambiguous warning that Stabilyz cannot recover a forgotten one), and prompt for it again before any import attempt — see the updated Product Flow and Acceptance Criteria.
3. ~~**Minimum session duration**~~ — **Resolved, fully locked in**: two selectable modes, a 2-minute **Quick Test** and a 6-minute **Full Test**, both modeled on the validated 2MWT/6MWT clinical walk tests used in amputee research. This lets the user trade off convenience against the sensitivity gap the research showed between 2- and 6-minute walks, rather than the app forcing one compromise.

   The minimum-duration floors are locked in too: **Quick Test requires ~90 seconds of valid walking data; Full Test requires ~4 minutes.** These are framed deliberately as **v1 product-quality thresholds, not research-validated clinical minima** — the literature informed the choice of 2-minute/6-minute test *lengths* (2MWT/6MWT precedent), but it doesn't establish 90 seconds or 4 minutes specifically as universal scoring minimums, and the spec shouldn't imply otherwise. These thresholds are provisional and will be empirically validated and tuned using real-world session data once the algorithm is running against actual walks.

   One distinction worth being precise about: the **advertised test length** (2 min / 6 min) and the **valid-walking-data requirement** (90 sec / 4 min) are different things. A session can run the full advertised length on the clock and still fail to produce a score if too much of that time was pauses, setup, or other non-walking motion rather than actual walking — invalid segments don't count toward the valid-data requirement. Anything below the relevant threshold, or otherwise failing data-quality checks, routes to the noisy/insufficient-data state and does not count toward that mode's five-session baseline requirement.
4. ~~**Metronome pre-baseline fallback**~~ — **Resolved, refined further**: the reactive-echo instinct was right, but two corrections tighten it into something more scientifically defensible. First, it's **not a metronome** — a metronome implies "here's the tempo to follow," while this feature only ever says "I detected your step." Naming it **Step Feedback** keeps that distinction visible in the spec, not just in engineering intent. Second, it's **off by default** during sessions 1-5, not on-by-default: baseline collection should capture walking as undisturbed as possible, and even a footfall-triggered sound can create a feedback loop that nudges step timing — the same caveat as before, just resolved by defaulting off instead of accepting the contamination risk. The first-ever session in a mode shows "walk normally, no target pace" framing, with Step Feedback offered as an explicit opt-in rather than presented as the expected choice.

   This also crystallizes a structural principle worth keeping across the whole product, not just this one feature: **measurement sessions (establishing or reflecting an unbiased baseline) default toward minimizing anything that could alter natural gait, while feedback/pacing (the post-baseline Metronome cue) is fine specifically because influencing gait is now an intentional, opted-into choice, made against a clean reference point that already exists.** Concretely, this doesn't require a separate "mode" in the product — it maps directly onto the existing pre-baseline/post-baseline split already in the data model: Step Feedback (reactive, no tempo, opt-in, off by default) for sessions 1-5; Metronome cue (paced to baseline cadence, opt-in) for session 6 onward. Two technical details worth locking in now: only trigger Step Feedback on confidently-detected steps, not raw signal spikes, since false positives would create their own accidental rhythm; and add a short debounce so one footfall can't register as multiple sounds. Also worth restating: the "first 5 sessions" are the first 5 *valid* sessions for that mode, not necessarily 5 consecutive attempts — consistent with how baseline counting already works elsewhere in this spec.
5. ~~**Baseline segregation by mode**~~ — **Resolved, fully locked in**: Quick Test and Full Test are completely independent. Each mode gets its own 5-session calibration requirement, its own baseline reference values and statistics, and its own subsequent scoring comparisons. **Locked-in rule: baselines are mode-specific and only accumulate from valid sessions of that same mode — Quick Test and Full Test sessions are never blended for baseline calculation or calibration, and a session that fails the minimum-duration or data-quality threshold does not count toward the five-session calibration requirement for either mode.** A Quick Test result is only ever compared against the user's Quick Test baseline, and a Full Test result only against the Full Test baseline. This keeps the interpretation of every score clean and consistent: each result means "how does this test compare with your normal performance on this same test," never a comparison across two structurally different tests. This affects the data model directly — a mode field belongs on Baseline, not just on GaitSession — and is now settled before that work is built.
