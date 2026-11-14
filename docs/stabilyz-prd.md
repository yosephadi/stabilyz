# Stabilyz — Product Requirements Document

*iOS app for prosthetic limb users to independently measure their own walking stability.*

---

## 1. Why (Objective)

People who use prosthetic limbs often have a *feeling* about how their walking is doing — "I think I'm more stable this week" or "something feels off today" — but no way to confirm whether that feeling reflects reality. Clinical gait labs exist, but they're expensive, infrequent, and out of reach for day-to-day use. Apple's built-in Walking Steadiness score exists, but it is not validated for prosthetic gait (Apple's own validation cohorts were older adults and younger able-bodied adults wearing a knee brace; see docs/research/competitive-landscape-gait-app.md), updates weekly, and isn't built to capture asymmetry the way a prosthetic user's gait actually needs.

**Stabilyz exists so that a prosthetic limb user can independently test and measure their own walking stability, on demand, and get back a number — not a feeling.** That number is what lets someone know whether they're actually improving, actually declining, or whether it really was just a bad day. This is the whole point of the product: turning "I think" into "I know."

---

## 2. Define "Success"

Success for this build is:

- **Deployed on TestFlight**, installable and runnable by a real tester on a real iPhone.
- **The app is functional** — meaning, concretely:
  - A user can complete onboarding, run a Gait Training session (either mode) start-to-finish, and see a score.
  - The app doesn't crash during a normal session in either mode — a 1:30 Quick Test or a 3:00 Full Test, both provisional lengths chosen from stride-count reasoning rather than validated clinical test durations (see Open Question 3 for the reasoning behind offering both).
  - The scoring algorithm returns a real, non-placeholder number derived from that session's motion data.
  - Baseline calibration works after 5 sessions, and scores are shown relative to it.
  - Session history and the clinician summary screen render real stored data.

Success at this stage is explicitly **not**: clinically validated accuracy, App Store release, or a polished/finished UI. It's "does the core loop work, end to end, on a real device."

---

## 3. Describe the Users

**Primary user: a self-directed lower-limb prosthetic user.**
- Transtibial, transfemoral, or bilateral amputation.
- Ambulatory enough to walk 1.5-3 minutes unsupervised (this app is *not* designed for acute post-op patients who require a PT present for every walk — that's an explicit boundary, not an oversight).
- Anywhere from a few months to many years post-amputation; research on this population skews a wide age range (one study of people with lower-limb loss, SMART, n=12, spanned ages 26-79, median 56; Esfandiari et al., Prosthet Orthot Int 49(3):260-267, doi 10.1097/PXR.0000000000000368 — this single study is all that "commonly span" originally rested on), so the app can't assume a tech-savvy or young user.
- Motivated by wanting objective self-verification between clinical visits, and by wanting to feel more confident and in control of their own mobility — not by wanting a clinical diagnosis.

**Secondary user: the user's prosthetist or physical therapist.**
- Doesn't use the app directly. Sees the app's output only through the single clinician summary screen the user chooses to show them, in person, during an appointment.

*Assumption flagged: this PRD assumes an individual, self-directed adult user with no account/login system, no automatic cloud sync, and no server backend for this build. Data stays on the device by default; manual export provides a user-controlled backup and device-transfer mechanism (see Open Question 2) — it does not change this core assumption.*

---

## 4. Solution (Brief)

Stabilyz is an iOS app that lets a prosthetic limb user run short, self-directed "Gait Training" sessions using nothing but their iPhone's built-in motion sensors. The user chooses between two modes, a **1:30 Quick Test** for a fast check-in, or a **3:00 Full Test** that gives a longer sample of walking and so a steadier read (both lengths are provisional product choices, not validated clinical durations; see Open Question 3). Each metric is a median across the session's analysis windows, so within-session drift such as fatigue is not captured as built. When a session ends, Stabilyz immediately computes a stability score from several independent signals — **gait consistency** (step regularity and stride regularity, computed via autocorrelation the same way for every user regardless of amputation type), **step-time/cadence variability**, and an **acceleration-based trunk-motion proxy** — plus, for unilateral users where a sound side is identifiable, a secondary limb-specific timing-asymmetry feature. The score is reported as a relative index against the user's own personal baseline for that mode, not an abstract "normal" gait and not mixed across modes. During the sessions establishing that baseline, walking is captured as undisturbed as possible by default — an optional **Step Feedback** toggle (off by default) plays a brief sound on confidently-detected steps with no target pace implied, never a metronome. Once a baseline exists, an optional **Metronome cue**, paced to the user's own baseline cadence, becomes available for in-the-moment pacing feedback — an intentional influence the user opts into, now that there's a clean reference point to influence gait relative to. Over time, a session history and trend chart let the user see whether they're actually improving, and a single shareable summary screen lets them bring objective data — not just a memory of "it's been fine, I think" — to their next appointment.

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
  • Time since amputation (optional — can be skipped)
  • Device/prosthesis type (optional — can be skipped)
  • K-level / activity level (optional — can be skipped)
  • All five questions stay in onboarding; the three optional ones can be edited later in Settings
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
[Select Test Mode] ── 1:30 Quick Test  |  3:00 Full Test
      │
      ▼
[Audio feedback selector] ── depends on whether this mode's baseline exists yet:
  • Before baseline exists (sessions 1-5): "Walk normally — there's no target pace" framing shown (the line goes once the mode's baseline exists; "Walk in as straight a line as you can" is shown for every walk); optional **Step Feedback** toggle, off by default (a brief sound on confidently-detected steps, never a tempo)
  • After baseline exists (session 6+): optional **Metronome cue** toggle, paced to this mode's baseline cadence
  • Watch indicator (Phase 3, see §8): if the Stabilyz watch app is reachable, one line —
    "Timer will show on your watch" — telling the user the timer and haptics will come
    from the watch; if it isn't, nothing is shown and nothing alarming replaces it
      │
      ▼
[Start Test] ── tapping Start Test does not begin recording; it begins a countdown
  • If Motion & Fitness access is still undetermined, the system prompt is raised here, on the tap,
    before sensor priming and the countdown (so it does not land while the phone is being stowed);
    a one-line reason is shown above Start only while the answer is undetermined. Denied or
    restricted shows the existing blocked state (see §6)
      │
      ▼
[Countdown — 5 seconds by default (provisional, tunable; see Open Question 6)]
  • On-screen numerals counting down (5, 4, 3, 2, 1, then "Go") — always shown, on every device
  • A distinct haptic tap on each tick where the hardware supports it; the tick at zero
    is perceptibly different from the five counting ticks, so a user who only feels them
    can tell "1" from "go"
  • Each numeral also triggers a VoiceOver announcement, so a user who can neither see the
    screen nor feel the haptics still has a channel before the tone at zero
  • Sensors prime during the countdown so samples are already arriving at zero; anything
    captured before zero is discarded and never part of the session
  • Cancel always available — returns to the Audio feedback selector with the selected
    mode and cue setting intact; no session is created, nothing counts toward baseline
  • Identical for Quick Test and Full Test, and identical whether Step Feedback, the
    Metronome cue, or neither is enabled — Step Feedback and the Metronome cue stay
    silent until zero
      │
      ▼
[Session In Progress] ── begins at the final countdown tick (zero), not at the tap
  • Start confirmation tone, at zero, coincident with the final tick
  • CMMotionManager + CMPedometer recording live; the session clock and the
    valid-walking-data timer both start here
  • Step Feedback (pre-baseline) or Metronome cue (post-baseline) playing, only if the user enabled it
  • Stop button always visible
      │
      ▼
[Stop] ── instant, no countdown — single haptic pulse + Stop confirmation tone
  • Approved addition (product owner, 2026-11-15; decisions.md entry 59): on a **valid** completion
    only, the completion screen plays ONE success notification haptic after Stop, on the phone only,
    and only when Start & Stop Haptics is on, with a one-shot checkmark bounce (static under Reduce
    Motion). An invalid walk gets neither. No cue of any kind was added between Go and Stop.
      │
      ▼
[Processing] ── brief, on-device only, no network call
      │
      ├── (data too noisy, or session ended short of that mode's minimum) ──► [Noisy Session Screen] ── plain-language explanation specific to the reason (too short, too much phone movement, an interruption, or the phone stopping sending motion data) with one next step, no score shown, session marked invalid, "This session won't count toward your baseline."
      │
      └── (data valid)
              │
              ▼
      [Score Screen]
        • If < 5 valid sessions exist *in this mode*: "Building your Quick Test baseline" with progress worded "Walk N of 5 toward your baseline" and "N more walks to go" (or Full Test, matching whichever mode was run; wording as built 2026-11-15, one source for every screen), no relative index yet. Sessions 1-5 instead show a **provisional 0-100 score** on its own labelled scale, derived from fixed placeholder reference values (poor/good anchors for step regularity, stride regularity, step-time variability and the two trunk-motion axes) that are **unvalidated** ([OPEN] — they exist so early sessions carry some number, and are clearly labelled provisional, never framed as a baseline-relative result); raw metrics optionally shown as "reference only". The relative index starts once the 5-session baseline exists
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

**Watch Companion alongside the session flow (Phase 3, see §8).** The phone flow above is unchanged; the watch follows it and never drives it, except for Stop:

```
Phone                                   Watch (if the user opened the app)
─────────────────────────────────────   ─────────────────────────────────────────
[Setup screen]                     ──►  [Waiting] "Start on your iPhone", mode + length
  (Live Activity nudge while the          (extended runtime session starts here)
   watch app is installed but
   not reachable)
[Countdown 5→1, Go]                ──►  [Countdown] 5→1 then Go, "Phone in pocket"
  haptic owner fixed here: watch if        ticks/Go haptics if the watch owns them;
  reachable now, else phone — for the      no Cancel, no Stop
  whole session
[Countdown cancelled]              ──►  [Waiting] (stop pulse if the watch owns haptics)
[Session In Progress]              ──►  [Running] timer from T-0, progress bar, Stop
                                        [Disconnected] when the phone is unreachable:
                                          local timer keeps running, "Keep walking.
                                          Your walk is still recording.", no Stop
                                          ──► back to [Running] on reconnect
[Stop] (phone tap, watch Stop,     ◄──  Stop on [Running] sends a stop request; the
 or clock reaching 00:00)                 phone ends the session exactly as an on-phone
                                          Stop
[Processing → Score / Noisy]       ──►  [Stopped] "Walk finished", "See your result on
                                          iPhone", Done ──► [Waiting]
```

**Out of this flow for v1** (explicitly deferred, per existing backlog): HealthKit passive track, threshold-based recommendations, turn-detection, socket-fit tagging, cohort benchmarking, and structured clinician-facing data export (e.g. a PDF report format) beyond the single summary screen — this is distinct from the personal backup export/import described above, which is in scope and exists so the user can move their own data to a new device, not to hand a report to a clinician. The Apple Watch companion is not part of v1; it is Phase 3, specified in §8.

---

## 6. Edge Cases

### Onboarding
- **Bilateral amputation selected.** Resolved (see Open Question 1): gait consistency (autocorrelation-based step/stride regularity) is computed identically for every user, bilateral included, since it never requires identifying a sound side. Bilateral users simply don't get the secondary limb-specific timing-asymmetry feature that unilateral users get when their side is reliably identifiable — nothing is fabricated in its place.
- **User skips all three optional fields** (time since amputation, device type, K-level). Onboarding must complete successfully with only the required fields (amputation level, side) filled; all three can be edited later in Settings.
- **User force-quits or backgrounds the app mid-onboarding.** On relaunch, onboarding should resume where they left off, not restart or lose partial progress — including if they quit on the final disclaimer screen before ticking the box.
- **User never ticks the disclaimer checkbox.** This is an intentional hard gate — there's no skip path to Home. The screen should make clear why they can't proceed, rather than the checkbox failing silently or the Continue button just not responding.

### Session recording
- **Motion & Fitness permission denied.** The Start button must degrade gracefully — explain why the app can't record, don't let the user tap Start into a silent failure. When authorization is still undetermined, the app asks when the user taps Start, before priming and the countdown; denied or restricted shows this blocked state. The one-line reason ("Stabilyz needs Motion & Fitness access to measure your walking. We'll ask when you tap Start.") shows above Start only while undetermined.
- **Phone call or notification interrupts a session mid-recording.** Recording should either pause/resume cleanly or the session should be flagged as noisy — it must not silently produce a corrupted "clean" score.
- **User stops a session early, or doesn't accumulate enough valid walking data, relative to their chosen mode.** Resolved (see Open Question 3): the advertised test length (1:30 for Quick Test, 3:00 for Full Test) is not the same threshold as the *valid walking data* required to produce a score — Quick Test requires 60 seconds of valid walking data, Full Test requires 2:15 (135 seconds), and invalid segments (pauses and other non-walking motion) don't count toward that requirement even if the clock ran the full advertised length. Setup is handled differently now: the start countdown (see Open Question 6) ends before recording begins, so phone-stowing is outside the session entirely rather than recorded and then filtered. Non-walking segments **after** zero — the first few steps of getting going, a pause at a crosswalk — must still be detected and excluded. Anything short of the relevant threshold, or otherwise failing data-quality checks, routes to the noisy/insufficient-data path and does not attempt a score.
- **App is backgrounded or the phone locks during a session.** iOS can suspend motion updates in the background — this needs explicit handling (either prevent backgrounding during a session with a clear message, or confirm CMMotionManager background recording is configured correctly).
- **App is backgrounded, the phone locks, or a call arrives mid-countdown.** Backgrounding or an interruption cancels the countdown rather than letting it elapse into a recording the user isn't positioned for — no session is created, and nothing is marked invalid, since nothing was recorded. This is distinct from an interruption *during* recording, which has its own pause/flag handling above. Screen-off is **not** cancellation: a user deliberately locking the phone as they pocket it is the countdown working as intended, so idle auto-lock must not end the countdown or the session.
- **User cancels mid-countdown.** The countdown screen needs an explicit, reachable Cancel. It returns to the setup screen with the mode and cue selections intact, creates no session record, and affects no baseline count. A user who instead lets it start and immediately taps Stop lands on the existing insufficient-data path — both are acceptable outcomes, and neither produces a scored session.
- **Haptics unavailable, disabled, or not perceivable by the user.** The countdown's haptic ticks are a convenience for a phone already stowed, not the mechanism — the on-screen numerals always run, so a device with System Haptics switched off, hardware without a Taptic Engine, or a user who simply can't feel them loses nothing they need. It degrades silently: no error, no blocked Start. (As built, the tick honours the System Haptics setting, while the phone's Go and Stop are sustained vibrations that play regardless of it; the app's own Start & Stop Haptics setting still governs them, and where the haptic engine cannot run they fall back to a heavy tap.) This is unrelated to the Bluetooth-audio edge case below — haptics are on-device and are never routed through an audio device. (One further haptic, approved 2026-11-15: the single success notification on a valid completion screen, after Stop, on the phone, only with Start & Stop Haptics on — decisions.md entry 59. Nothing plays between Go and Stop.)
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

### Watch Companion (Phase 3, see §8)
- **No paired watch, or the Stabilyz watch app isn't installed.** Nothing changes: no indicator, no nudge, the phone plays every haptic, exactly as in v1.
- **Watch app installed but not open.** The setup screen starts a Live Activity nudging the user to open the watch app. No notification is posted and no new permission is requested. The Live Activity ends as soon as the watch becomes reachable, when the user leaves the setup screen (it returns when they come back), or when the session ends or the countdown is cancelled. The user can always start without opening the watch; the session is unaffected.
- **Watch unreachable when the countdown starts.** The phone owns haptics for the whole session — ticks, Go and Stop — even if the watch connects later. The watch, if it connects mid-session, shows the timer and offers Stop but plays no haptics.
- **Watch drops mid-walk** (out of range, Bluetooth off, watch app terminated). The session continues on the phone, unchanged: it is not cancelled, not paused, not invalidated, and gets no gap or interruption record — the watch is not a sensor. The watch shows Disconnected: its local timer keeps running from T-0, "Keep walking. Your walk is still recording.", no Stop button, no haptic.
- **Watch reconnects mid-walk.** The watch re-syncs to the phone's state and T-0, returns to Running, and Stop reappears. If the session ended while the watch was away, the watch goes straight to Stopped.
- **Stop pressed on the watch while the phone is already stopping** (the user tapped both, the clock reached 00:00, or a late or duplicate request arrived). The phone ignores every stop request after the first; the session ends exactly once. The watch shows Stopped either way.
- **The watch owns haptics but is unreachable at Stop.** The phone plays the Stop pulse as a fallback, so the user still feels Stop. This, the lost-Stop fallback and the Go fallback below are the only exceptions to fixed haptic ownership.
- **The watch owns haptics, is unreachable, and the clock reaches 00:00.** The phone ends the session and plays the fallback Stop pulse; the watch, whose own timer also reaches the end, plays its Stop haptic locally and shows Stopped. The user may feel two buzzes, on wrist and in pocket — intended behaviour, accepted over the risk of feeling none.
- **The watch owns haptics and is reachable at Stop, but doesn't confirm the Stop message in time (750 ms).** The phone plays the Stop pulse, because the Stop buzz is how a user with the phone pocketed learns the walk ended. A watch that received the message but confirmed late has played its own, so the user may feel two — intended behaviour.
- **Countdown cancelled on the phone while the watch owns haptics.** The watch plays the stop pulse (the phone stays silent, as with every haptic it doesn't own) and returns to Waiting. The watch shows no Cancel during the countdown; cancel is phone-only.
- **Watch screen turns off or the wrist drops mid-walk.** The extended runtime session is meant to keep the watch app alive, and the timer continues. Whether haptics still play while the watch app is in the background is **unverified** (Open Question 7c); if they don't, the phone-only haptic fallback applies. Screen-off on the watch is never a disconnect and never affects the session.
- **User leaves the watch app mid-walk** (presses the Digital Crown, opens another app). The extended runtime session keeps the app running in the background; returning shows the current state. If the watch app is terminated anyway, this is a watch drop (above).

---

## 7. Acceptance Criteria

### Disclaimer & Onboarding
- [ ] The disclaimer (plain-language, non-diagnostic "not a medical device" language) appears as the final onboarding screen, with a required checkbox the user must tick before continuing.
- [ ] The user cannot reach Home/Dashboard without ticking the disclaimer checkbox — there is no skip path.
- [ ] The disclaimer text remains accessible after onboarding (e.g. Settings/About), even though the required checkbox itself is only presented once, during onboarding.
- [ ] Onboarding presents one field (or tightly grouped field-set) per screen with a visible progress indicator.
- [ ] "Why we ask" microcopy appears on the amputation level and side screens.
- [ ] A disabled Next says why on the steps that really block: "Choose an answer to continue" on the amputation level and side steps, the disclaimer line on the disclaimer step; the same words are the button's VoiceOver hint. The optional steps never block and say nothing.
- [ ] A user can complete onboarding with only required fields filled; optional fields (time since amputation, device type, K-level) can be skipped without blocking progress, and all three can be edited later in Settings.
- [ ] Onboarding progress persists across an app relaunch mid-flow, including on the final disclaimer screen if the app is quit before the box is ticked.
- [ ] Bilateral amputation is a selectable, fully supported option (not a dead end in the algorithm downstream).

### Session recording
- [ ] User selects a test mode (Quick Test — 1:30, or Full Test — 3:00) before a session starts; the selection is stored with the session.
- [ ] Tapping **Start Test** does not begin recording — it presents a countdown screen (5 seconds by default; provisional and tunable, the same category as the 60 s / 2:15 valid-walking-data floors).
- [ ] The countdown is **both visible and haptic** — not one or the other. On-screen numerals count down on every device, and a distinct haptic tap fires on each tick where the hardware supports it. The visible countdown is never suppressed in favour of the haptic one: a user who cannot perceive haptic feedback must be able to follow the countdown entirely on screen.
- [ ] The countdown shows five numerals (5, 4, 3, 2, 1) at one per second, each with its own haptic tick, followed by a sixth, perceptibly different haptic at zero — so a user relying on haptics alone can distinguish the last count from the start of recording. At zero the screen shows "Go" rather than a bare "0."
- [ ] Each numeral triggers a VoiceOver accessibility announcement, so a VoiceOver user who has already pocketed the phone is not left with neither channel until the tone at zero.
- [ ] If haptics are unavailable or disabled, the countdown runs on the visible channel alone, with no error and no blocked Start.
- [ ] CMMotionManager + CMPedometer recording, the session clock, and the valid-walking-data timer all begin at the **final countdown tick (zero)** — not when Start Test was tapped. Motion samples captured while the countdown was running are discarded and never contribute to the session. The session's stored start time is zero, not the tap.
- [ ] Sensors are primed during the countdown so that samples are already arriving at zero. If priming fails, the countdown aborts with a plain-language error **while the user is still looking at the screen** [OPEN: priming deadline before zero — the code currently uses a 2 s provisional placeholder, not a decided value], rather than failing silently after the phone has been put away.
- [ ] A distinct start tone plays at zero, coincident with the final tick. The countdown's own ticks are haptic and visual only — they do not each play a tone.
- [ ] The user can cancel during the countdown. Cancelling returns to the audio-feedback/setup screen with the selected mode and cue setting intact, creates no session record, and counts toward no mode's baseline.
- [ ] Backgrounding, or a call or comparable interruption during the countdown, cancels it and creates no session. Screen-off / idle auto-lock does not cancel it.
- [ ] The countdown is identical for Quick Test and Full Test, and identical whether Step Feedback, the Metronome cue, or neither is enabled. Neither Step Feedback nor the Metronome cue produces any sound before zero.
- [ ] Tapping Stop ends recording immediately — **no countdown** — and plays a single haptic pulse plus a distinct, different stop tone. The asymmetry with Start is deliberate: the delay at Start buys the user time to get situated, which has no equivalent at Stop, where they have already finished walking.
- [ ] A session that doesn't accumulate the required amount of **valid walking data** for its selected mode — 60 seconds for Quick Test, 2:15 (135 seconds) for Full Test — is routed to the noisy/insufficient-data path and never scored, even if the full advertised session length (1:30 / 3:00) elapsed on the clock. Pauses and other non-walking segments don't count toward this requirement. The start countdown removes phone-stowing from the recording entirely, but non-walking segments after zero must still be detected and excluded.
- [ ] When a session ends by a manual Stop (on the phone or the watch), the final 3 seconds of signal are dropped before analysis (a provisional placeholder, tunable). A session that ends on the timer keeps its tail. The end reason is **derived, not stored**: if the recorded clock reached the mode's advertised length it is a timer end, otherwise it is a manual Stop from the phone or the watch. The valid-walking floor above is evaluated **after** the trim. The 3 s is an `[OPEN]` placeholder (`manualStopTailTrim`; decisions.md entry 51). Rationale: Tura et al. 2012 report a negative effect of the last strides before stopping on regularity.
- [ ] If Motion & Fitness permission is not granted, the Start button explains why recording can't proceed instead of failing silently. If it is undetermined, tapping Start requests it before priming and the countdown, and the countdown begins only once it is answered.
- [ ] The setup screen shows "Walk normally — there's no target pace" before that mode's baseline exists, and "Walk in as straight a line as you can" always.
- [ ] While the countdown is up, the clock and Stop are hidden, and the hidden Stop is neither tappable nor reachable by VoiceOver; they appear after the countdown clears. The white countdown numeral reaches at least 4.5:1 on its scrim in light and dark mode. Under Reduce Motion the countdown overlay uses opacity only and hand-offs swap instantly.
- [ ] On a valid completion only, one success notification haptic plays after Stop, on the phone, only when Start & Stop Haptics is on; the checkmark bounces once (static under Reduce Motion). Nothing is added between Go and Stop. An invalid walk gets neither.
- [ ] The unclear-walk message states the specific reason with one next step; when the reason is too short, the figure comes from the session policy (60 seconds Quick Test, 2 minutes 15 seconds Full Test); it ends "This session won't count toward your baseline."
- [ ] Baseline progress is worded one way everywhere: "Walk N of 5 toward your baseline" and "N more walks to go".
- [ ] At Dynamic Type xxLarge and above the score numeral and labels and the recording clock sit below their rings; capsule button labels wrap rather than truncate (55 pt is a minimum height); screens with a pinned primary action scroll their content at accessibility sizes. Two-option choices use a control whose labels scale (44 pt minimum, checkmark plus fill for the selected option).
- [ ] A session with excessive noise (define threshold) is flagged automatically and shown the plain-language noisy-data screen — no score is displayed for a flagged session.

> **Not verified (2026-11-15).** The success haptic and the checkmark bounce were not felt or seen on a device; the undetermined-permission state was not captured in the simulator; VoiceOver was reviewed in code only.

### Scoring & baseline
- [ ] For a valid session, **gait consistency** — step regularity (Ad1) and stride regularity (Ad2), via autocorrelation of the trunk acceleration signal — is computed identically for every user regardless of amputation type (unilateral or bilateral), alongside step-time/cadence variability and an acceleration-based trunk-motion proxy (defined as a specific computation — e.g. RMS or variance of mediolateral and vertical acceleration during steady-state walking — not just labeled "balance"); all are stored, tagged with the session's mode.
- [ ] For unilateral users where side is reliably identifiable, a **secondary sound-vs-prosthetic step-time asymmetry** feature is also computed and stored, clearly labeled and presented as distinct from gait consistency — not merged into a single number.
- [ ] For bilateral users, no sound-side asymmetry value is fabricated or estimated in place of the missing secondary feature — the score is built from gait consistency, step-time/cadence variability, and the trunk-motion proxy only.
- [ ] Gait consistency is combined with step-time/cadence variability and the trunk-motion proxy as independent inputs to the stability score — it is never the sole basis for the score, since a highly regular gait can still be dynamically unstable.
- [ ] User-facing copy refers to this metric as **"gait consistency,"** never as "symmetry" or "asymmetry," to avoid implying a limb-to-limb comparison that isn't actually being made for all users.
- [ ] Each metric's baseline standardization applies a **minimum standard-deviation floor** before computing a relative score, so a metric with an unusually small baseline SD for a given user doesn't produce an unstable, exaggerated result from ordinary session-to-session noise.
- [ ] Before 5 valid sessions exist *in a given mode*, the Score Screen shows that mode's "building your baseline" state, not a relative score. It may show a provisional 0-100 score on its own labelled scale, derived from unvalidated placeholder anchors ([OPEN]) and clearly marked provisional; the relative index begins only once the 5-session baseline exists. The trunk-motion anchors of that provisional score are in g (mediolateral poor 0.25 / good 0.05, vertical poor 0.40 / good 0.10), `[OPEN]` placeholders (decisions.md entry 50).
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
- [ ] A session recorded with the Metronome cue on is kept and scored, but is shown as a distinct marker in the trend and left out of the trend line, because an auditory cue can lower stride-time variability (see Open Question 4).

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

### Watch Companion (Phase 3, see §8)
- [ ] The watch records no motion data, and nothing from the watch contributes to any metric, score, baseline, validity decision or stored session.
- [ ] The watch never shows a score, a metric, or whether the walk was valid.
- [ ] A session can only be started from the phone. The watch has no Start control.
- [ ] Stop on the watch ends the session exactly as an on-phone Stop does — same recording end, same pipeline, same tones.
- [ ] The phone acts on the first stop request only; any later or duplicate request (from either device, or after the clock reached 00:00) is ignored, and the session ends exactly once.
- [ ] Stop is visible on the watch only in the Running state while the phone is reachable; it is hidden in Waiting, Countdown, Disconnected and Stopped.
- [ ] If the watch app is reachable when the countdown starts, the watch plays the countdown ticks, the Go haptic and the Stop haptic, and the phone plays none of them; otherwise the phone plays them all. The choice is fixed for the whole session and does not change on reconnect or disconnect.
- [ ] "The phone plays none" covers haptics only: the start tone, the stop tone, Step Feedback and the Metronome cue still play from the phone exactly as in v1.
- [ ] If the watch owns haptics and is unreachable at Stop, the phone plays the Stop pulse. At 00:00 this may produce two Stop haptics (watch and phone); that is accepted.
- [ ] If the user turned Start & Stop Haptics off, the watch plays no haptics either; a change made mid-walk reaches the watch.
- [ ] Losing the watch at any point never cancels, pauses or invalidates a session, and never adds a gap or interruption to it.
- [ ] Disconnected shows "Phone not reachable" and "Keep walking. Your walk is still recording.", keeps the local timer running from T-0, shows no Stop, and plays no haptic. On reconnect the watch returns to the phone's current state.
- [ ] A cancelled countdown returns the watch to Waiting; if the watch owns haptics it plays the stop pulse. The watch shows no Cancel during the countdown.
- [ ] The watch's timer starts from the phone's T-0, not from the moment a message arrived, and shows the same elapsed time as the phone to within one displayed second.
- [ ] The setup screen shows one line, "Timer will show on your watch", when the watch app is reachable, and nothing when it isn't. It reads correctly in light and dark mode and has a VoiceOver label.
- [ ] A Live Activity nudge appears on the setup screen while the watch app is installed but not reachable, before any session starts, and ends when the watch becomes reachable, the user leaves the setup screen, or the session ends or is cancelled. It returns when the user comes back to the setup screen. No notification is posted and no new permission is requested.
- [ ] The watch app is opened by the user, never launched through a HealthKit workout. HealthKit is not used anywhere.
- [ ] All five watch screens use 15 pt minimum text, a dark background and the navy primary; every element has a VoiceOver label, and each countdown numeral fires a VoiceOver announcement on the watch as on the phone.
- [ ] The watch stays alive through screen-off and wrist-down for the whole walk, verified on a real Apple Watch.

### Build/deployment
- [ ] The app builds and installs via TestFlight on a physical iPhone (iOS 17+).
- [ ] A full loop — onboarding → session → score → history → clinician screen — can be completed without a crash.

---

## 8. Watch Companion (Phase 3)

### Purpose
An Apple Watch companion that shows the session timer on the wrist, so the user doesn't have to pull the phone out of a pocket mid-walk. It is **display + haptics + Stop only**. It adds no measurement, no scoring and no history; everything the PRD says above about sessions, scores and baselines is unchanged.

### Decisions (locked)
1. **The phone is the only sensor and the only source of truth.** No watch motion data is recorded or used in scoring. No score is shown on the watch.
2. **Start is phone-only. Stop works from either device; the phone is authoritative.** A watch Stop ends the session exactly like an on-phone Stop. Duplicate or late stop requests are ignored. Stop is hidden on the watch while the phone is unreachable.
3. **Haptic ownership is decided once, when the countdown starts.** If the watch is reachable at that moment, the watch plays the countdown ticks, Go and Stop, and the phone plays none of those haptics; otherwise the phone plays them. The choice is fixed for the whole session. Two clarifications:
   - "The phone plays none" means **haptics only**. The start tone, the stop tone, Step Feedback and the Metronome cue still play from the phone, as §7 requires.
   - **Stop fallback:** if the watch owns haptics but is unreachable at Stop, the phone plays the Stop pulse, so a Stop is never silent to touch. The phone also plays it if a reachable owning watch doesn't confirm the Stop message in time. When the watch's own timer reaches the end while disconnected, it shows Stopped and plays its Stop haptic locally. Either way the user may feel two — accepted.
   - **Go fallback:** if the owning watch does not confirm the Go message in time, the phone plays the Go pulse. A watch that received it but confirmed late has already played its own, so the user may feel two Go buzzes — accepted, as intended behaviour.
   - The user's Start & Stop Haptics setting governs the watch too: off means no haptics on either device.
4. **A session never depends on the watch.** Losing the watch mid-walk never cancels, pauses or invalidates the session.
5. **Keep-alive via a watchOS extended runtime session, without HealthKit.** Apple's *physical therapy* session type runs in the background for up to an hour and needs no HealthKit; it is the chosen type, and the App Review notes state the rehab/gait-assessment purpose (see Open Question 7a). HealthKit stays out of scope.

### Launch
The user opens the watch app manually. Before a session, while the watch app is installed but not reachable, the phone shows a **Live Activity** nudging the user to open it. The Live Activity ends as soon as the watch becomes reachable, when the user leaves the setup screen (it returns when they come back), or when the session ends or is cancelled. On iOS 18 and later it also appears in the watch's Smart Stack (watchOS 11); on iOS 17 it shows on the phone only. Opening the watch app from the Live Activity needs the `WKSupportsLiveActivityLaunchAttributeTypes` key in the watch Info.plist (being added). No notification is used, so no new permission is requested. There is no HealthKit workout launch. This must be verified on a real watch.

### Phone-side indicator
On the setup screen, when the watch app is reachable, one line: **"Timer will show on your watch"** — which also tells the user haptics will come from the watch. When it isn't reachable, nothing is shown, and nothing alarming takes its place: using the phone alone is the v1 experience, not an error. Light and dark mode; VoiceOver label.

### Watch screens
Dark background, navy primary, 15 pt minimum text, VoiceOver labels on every element. Non-text contrast is 3:1 or better: the progress fill on its track is 4.88:1, and the navy capsule carries a 1 pt outline (4.57:1 on black; white on navy 8.26:1), tested in `WatchContrastTests`. The progress bar fills continuously with the timer and never pulses. The Countdown keeps "Phone in pocket" with the numeral at the largest text sizes.

| Screen | Content |
|---|---|
| **Waiting** | "Start on your iPhone", selected mode and length |
| **Countdown** | "Get ready" heading, 5→1 then "Go", "Phone in pocket"; a VoiceOver announcement per numeral; no Cancel, no Stop |
| **Running** | Elapsed timer, progress bar, 55 pt Stop capsule |
| **Stopped** | "Walk finished", Done (returns to Waiting), then "See your result on iPhone" — in that order, so Done is on the first screen at large text |
| **Disconnected** | The local timer (which keeps running) and progress bar first, then "Phone not reachable" and "Keep walking. Your walk is still recording."; no Stop; no haptic |

### Sync
WatchConnectivity, phone to watch, with one message type back (the stop request). Every message is **versioned and Codable**.

- **Setup selection**: the mode and length selected on the setup screen, sent when it loads and on every change, so Waiting can show them.
- **Countdown start** (when the numerals begin, after sensor priming): mode, advertised duration, the haptic owner, the Start & Stop Haptics setting, and the **planned Go time**.
- **Started**: the actual **T-0** anchor. T-0 is stamped at the final tick, so it is not known when the countdown starts; the watch re-syncs its clock to this value. If it cannot be delivered while the watch owns haptics, the phone plays the Go pulse. If the watch has not received it 2 s after the planned Go time, it moves to Running from the planned Go time with no Go haptic, and re-syncs when it arrives.
- **State changes**: stopped, cancelled, haptics setting changed.
- **Stop request** (watch to phone): carries the session it refers to, so a late request for a finished session is ignored. After a tap the watch's Stop is disabled until the phone answers; if it doesn't, Stop re-enables after 3 seconds, or as soon as the phone is reachable again, so the user can try again.

The watch runs its own clock from T-0; it does not wait for a message per second.

**Catch-up.** When the watch app opens, or the phone becomes reachable again, the watch reads what the phone last stored and rejoins: a countdown at the numeral showing now, a running walk re-synced to T-0, a finished walk on Stopped. Nothing that already happened is replayed — no missed numerals, no late Go, no Stop buzz for a walk that ended while the watch was away — but everything after it plays as usual. A stored session counts only until 5 minutes after its planned end; after that the watch shows Waiting. While connected, the watch also catches up if what the phone stored stays ahead of it for 2 seconds — a live message was lost — with the same rules; a live message that arrives within the 2 seconds wins.

### Haptics
Candidates — **verify on device**:

| Event | `WKHapticType` |
|---|---|
| Countdown tick (per numeral) | `.click` |
| Go | `.start` |
| Stop (and countdown cancel) | `.stop` |

The Disconnected state has no haptic. Final patterns are Open Question 7c.

---

## Open Questions for Adi

A few assumptions above are worth confirming or correcting before the algorithm and data-model work goes too far, since they're expensive to change later:

1. ~~**Bilateral amputation handling**~~ — **Resolved**: adopt autocorrelation-derived step/stride regularity as the **universal gait-consistency backbone for all users**, unilateral and bilateral alike, since it's computed purely from the walking signal's own repeating structure and never requires identifying which leg is which. This is architecturally correct, not just less engineering work — it measures a property (how consistently the pattern repeats) that stays well-defined with no reference limb, unlike a direct limb-to-limb comparison.

   Two corrections to how this is labeled and scoped, worth locking in now before the algorithm task starts:
   - **Terminology.** Ad1 (step regularity) and Ad2 (stride regularity) measure how consistently the walking pattern repeats — but that's shaped by both the *repeatability* of the pattern and its underlying *periodicity/timing*, not repeatability in isolation, so step-time/cadence variability isn't a cleanly separate "different lens" so much as a complementary computation over the same underlying signal characteristics. Either way, this is a different question from "how different are the two limbs," which is what a direct sound-vs-prosthetic step-time comparison answers. Calling the autocorrelation output "symmetry" or "asymmetry" overclaims what it measures. Internally: **step regularity** and **stride regularity**. User-facing: **"gait consistency."** The term "step time asymmetry" is reserved for the literal sound-vs-prosthetic limb comparison, kept as a **secondary, optional feature for unilateral users only**, computed when side is reliably identifiable — not the foundation of the algorithm, not attempted for bilateral users, and never fabricated in its absence.
   - **Validation gap, stated explicitly.** The regularity method is validated (against plantar-pressure reference data, in unilateral transfemoral amputees: Tura et al. 2010, J NeuroEng Rehabil 7:4, n=10 men with a C-leg, sensor on the thorax) — it is not validated specifically in a bilateral amputee population. Its math doesn't have the "which leg" problem to begin with, which is why it's the right architectural choice, but that's a different claim from "proven in this subgroup." This should stay a documented research gap, not get quietly implied as settled.
   - **Regularity ≠ stability.** A highly rhythmic gait can still be dynamically unstable, so gait consistency must remain one input to the stability score alongside step-time/cadence variability and the trunk-motion proxy — never the entire score on its own. The trunk-motion proxy in particular stays an independent signal, not folded into or derived from the regularity computation, and is arguably an especially important one for bilateral users specifically, since they lack a stable stance leg to balance against.
   - **Minimum strides for reliable Ad1/Ad2 computation.** Verified directly against the source study (Tura et al. 2012, J NeuroEng Rehabil 9:11, doi 10.1186/1743-0003-9-11 — a separate paper from the 2010 plantar-pressure validation above; n=10 men, unilateral transfemoral, C-leg, thorax sensor), as mean ± SE strides needed: amputees Ad1 (anteroposterior axis) 2.21 ± 0.23 and Ad2 (vertical axis) 3.57 ± 0.44 once the first and last 15 s of the signal are excluded; 15.68 ± 2.00 and 20.81 ± 1.76 on the whole signal including the transients. These are means over ten people, on a straight 70 m hallway; the app computes both Ad1 and Ad2 from the vertical axis, so treat these as reference points for tuning, not a hard specification.

   **Estimator (revised 2026-11-14, decisions.md entry 48):** step and stride regularity use the **unbiased** autocorrelation estimator (divide by N−|m|), as in Moe-Nilssen & Helbostad 2004 (J Biomech, doi 10.1016/S0021-9290(03)00233-1) and Tura et al. 2012. The half-stride peak-splitting search used for step-time asymmetry deliberately stays on the biased estimator (its position and the entry-41 prominence floor were tuned on it). An `[OPEN]` placeholder, `maximumLagFractionOfWindow = 0.5`, discards a window when the largest stride-search lag exceeds half the window; it affects only very slow cadences in short trailing windows. The algorithm version is now `1.2.0-provisional`; 1.1.0 and 1.2.0 sessions are not comparable (docs/09 §9.6).
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
3. ~~**Minimum session duration**~~ — **Resolved, fully locked in**: two selectable modes, a **Quick Test advertised at 1:30** and a **Full Test advertised at 3:00** (revised 2026-11-14 from 2 and 6 minutes; decisions.md entry 47). Two lengths let the user trade off convenience against a longer sample of walking, rather than the app forcing one compromise. The 2MWT/6MWT literature validates walking *distance*, not gait regularity (Reid et al. 2015, J Rehabil Med, doi 10.2340/16501977-1916: in 86 people with lower-limb amputation the 2-minute walk test predicts the 6-minute walk test, a distance result), so it is no basis for either length.

   The minimum-duration floors are locked in too: **Quick Test requires 60 seconds of valid walking data; Full Test requires 2:15 (135 seconds).** The advertised lengths and the floors are all **provisional product thresholds, not research-validated clinical minima**; they are to be validated with real prosthetic users and tuned using real-world session data. When a session ends by a manual Stop (phone or watch) rather than the timer, the last 3 s are dropped before analysis (`manualStopTailTrim`, `[OPEN]` placeholder, decisions.md entry 51); the floors are evaluated after that trim. The end reason is derived from whether the recorded clock reached the advertised length, not stored. Labels: phone segments "Quick (1:30)" and "Full (3:00)"; watch "Quick Test · 1:30" and "Full Test · 3:00".

   Why these numbers (product owner, 2026-11-14; sources in decisions.md entry 47):
   - **Stride arithmetic.** At 60-100 steps/min, 60 s is 30-50 strides and 135 s is 67-112 strides.
   - **Regularity needs few strides.** Tura et al. 2012 (amputees, unilateral transfemoral, n=10): Ad1 2.21 ± 0.23 and Ad2 3.57 ± 0.44 strides with transients excluded; 15.68 ± 2.00 and 20.81 ± 1.76 on the whole signal (mean ± SE).
   - **Step-time variability is the weakest link.** Kroneberg et al. 2019 (162 healthy older adults and 31 people with movement disorders, not amputees) found about 15 strides enough for stride-time variability. König et al. 2014 (n=12 healthy) found variability reliability levelled off only after about 50 cycles and recommended at least 50. Hollman et al. 2010 (n=24 healthy adults aged 65 or older) found 10-20 strides fine for velocity and cadence means, but variability may need far more. The 60 s floor (30-50 strides) sits at or below that plateau; the 135 s floor clears it.
   - **A weak signal, not evidence.** The product owner's own self-test, without a prosthesis, found 2 and 6 minutes too long.
   - **Distance tests are not a basis.** See above: the 2MWT/6MWT literature validates distance, not gait regularity.

   One distinction worth being precise about: the **advertised test length** (1:30 / 3:00) and the **valid-walking-data requirement** (60 s / 2:15) are different things. A session can run the full advertised length on the clock and still fail to produce a score if too much of that time was pauses or other non-walking motion rather than actual walking — invalid segments don't count toward the valid-data requirement. Where the session *starts* is now defined precisely by the start countdown (see Open Question 6), so pre-walk setup sits outside the recording rather than inside it; in-session non-walking exclusion is unaffected. Anything below the relevant threshold, or otherwise failing data-quality checks, routes to the noisy/insufficient-data state and does not count toward that mode's five-session baseline requirement.
4. ~~**Metronome pre-baseline fallback**~~ — **Resolved, refined further**: the reactive-echo instinct was right, but two corrections tighten it into something more scientifically defensible. First, it's **not a metronome** — a metronome implies "here's the tempo to follow," while this feature only ever says "I detected your step." Naming it **Step Feedback** keeps that distinction visible in the spec, not just in engineering intent. Second, it's **off by default** during sessions 1-5, not on-by-default: baseline collection should capture walking as undisturbed as possible, and even a footfall-triggered sound can create a feedback loop that nudges step timing — the same caveat as before, just resolved by defaulting off instead of accepting the contamination risk. The first-ever session in a mode shows "walk normally, no target pace" framing, with Step Feedback offered as an explicit opt-in rather than presented as the expected choice.

   This also crystallizes a structural principle worth keeping across the whole product, not just this one feature: **measurement sessions (establishing or reflecting an unbiased baseline) default toward minimizing anything that could alter natural gait, while feedback/pacing (the post-baseline Metronome cue) is fine specifically because influencing gait is now an intentional, opted-into choice, made against a clean reference point that already exists.** Concretely, this doesn't require a separate "mode" in the product — it maps directly onto the existing pre-baseline/post-baseline split already in the data model: Step Feedback (reactive, no tempo, opt-in, off by default) for sessions 1-5; Metronome cue (paced to baseline cadence, opt-in) for session 6 onward. Two technical details worth locking in now: only trigger Step Feedback on confidently-detected steps, not raw signal spikes, since false positives would create their own accidental rhythm; and add a short debounce so one footfall can't register as multiple sounds. Also worth restating: the "first 5 sessions" are the first 5 *valid* sessions for that mode, not necessarily 5 consecutive attempts — consistent with how baseline counting already works elsewhere in this spec.

   **Revised 2026-11-14 (decisions.md entry 49).** *Metronome cue:* sessions recorded with the cue on are kept and scored, but are shown as a distinct marker in the trend and left out of the trend line, because an auditory cue can lower stride-time variability (Sejdić et al. 2012, PLoS One, doi 10.1371/journal.pone.0043104: n=15 healthy adults, overground, stride-interval variability reduced). The evidence is mixed: Terrier 2012 (PLoS One, n=20 healthy, treadmill) found no effect on the SD of step time, and Piergiovanni & Terrier 2024 (Sensors; 60 older and 42 young adults) found regularity barely changed. *Step Feedback:* unchanged — available from the first session and counted toward the baseline, by product-owner decision (users should hear that steps are being detected). That its sound does not alter gait is an **unverified assumption** to revisit with real users.
5. ~~**Baseline segregation by mode**~~ — **Resolved, fully locked in**: Quick Test and Full Test are completely independent. Each mode gets its own 5-session calibration requirement, its own baseline reference values and statistics, and its own subsequent scoring comparisons. **Locked-in rule: baselines are mode-specific and only accumulate from valid sessions of that same mode — Quick Test and Full Test sessions are never blended for baseline calculation or calibration, and a session that fails the minimum-duration or data-quality threshold does not count toward the five-session calibration requirement for either mode.** A Quick Test result is only ever compared against the user's Quick Test baseline, and a Full Test result only against the Full Test baseline. This keeps the interpretation of every score clean and consistent: each result means "how does this test compare with your normal performance on this same test," never a comparison across two structurally different tests. This affects the data model directly — a mode field belongs on Baseline, not just on GaitSession — and is now settled before that work is built.

6. ~~**When a session actually starts**~~ — **Resolved**: tapping "Start Test" no longer begins recording. It begins a **countdown — 5 seconds by default** — and recording, including the valid-walking-data timer, begins at the final tick.

   The countdown is deliberately **both visible and haptic, not one or the other.** Visible for the user who is still looking at the phone; haptic for the user who has already put it in a pocket. Haptic-only was rejected outright because it would fail any user who can't perceive haptic feedback — so the on-screen numerals are the necessary fallback channel, not a nice-to-have, and the countdown is never gated on haptic hardware being present or enabled. Concretely: five numerals (5, 4, 3, 2, 1) at one per second, each with its own haptic tick, then a sixth and perceptibly different haptic at zero, with the screen showing "Go" rather than a bare "0" — the distinct final tick exists so a user relying on haptics alone can tell the last count from the start of recording. Each numeral also fires a VoiceOver announcement, which closes the converse gap: a VoiceOver user with the phone already pocketed would otherwise have had neither channel until the tone at zero.

   What this buys, beyond convenience: the spec previously excluded "setup time" from valid-walking-data calculations without ever defining where setup ends. The final countdown tick now defines that boundary precisely and deterministically — everything before zero is outside the session entirely, rather than recorded and then filtered out. This does **not** remove the need for in-session non-walking detection: a user still takes a few steps to get going, still stops at crosswalks, and those segments are still excluded by the pipeline after zero.

   **Stop stays instant, and the asymmetry is intentional.** The delay at Start pays for something real — time to get situated — that has no equivalent at Stop, where the user has already finished walking. Stop keeps its single haptic pulse and its existing stop tone, unchanged.

   The **5-second value is provisional and tunable** — the same category as the 60 s / 2:15 valid-walking floors in Open Question 3, a starting point to be adjusted against real TestFlight sessions rather than a validated figure. It is a **single fixed constant** for v1: the same for Quick Test and Full Test, the same whether Step Feedback, the Metronome cue, or neither is enabled, and **not user-adjustable**. Per-mode or user-set values would add a settings surface and a second setup-time definition for no measurement benefit — the countdown is a setup affordance, not a measurement parameter. If real sessions show 5 seconds is too tight for a user who needs both hands to stow a phone, the constant moves; it doesn't become a preference.

   **Considered and rejected: proximity-sensor + accelerometer placement detection** — auto-firing the start haptic once the phone was detected as "settled" in a pocket, instead of counting down a fixed interval. Rejected because it's a heuristic with real misfire modes — phone in a bag rather than a pocket, wrong orientation, a user who carries the phone in hand, a pocket loose enough that the phone never settles — and every misfire either starts a session the user isn't ready for or hangs indefinitely without starting one. That's a new failure class and meaningful engineering risk for an uncertain payoff over a fixed countdown the user can see, feel, and count on. Not to be reintroduced.

7. **Watch Companion (Phase 3) — open**, deliberately unresolved until real-watch testing. Everything else in §8 is decided.
   - **(a) Extended runtime session type without HealthKit.** Decided 2026-11-14: keep the *physical therapy* type — background runtime, up to one hour (enough for waiting plus a 3-minute walk), no HealthKit — and state the rehab/gait-assessment purpose in the App Review notes, since Apple says to choose the type "based on the app's intended use". *Self care* (10 minutes, foreground only, ended by the Digital Crown) remains the fallback if review disagrees. A session can only start while the watch app is active. Verify on device and at review.
   - **(b) Live Activity behaviour on the watch.** Smart Stack needs iOS 18 and watchOS 11 or later; with the iOS 17 floor, an iOS 17 phone gets the nudge on the phone only. Opening the Stabilyz watch app from the Live Activity requires the `WKSupportsLiveActivityLaunchAttributeTypes` key in the watch Info.plist, which is being added. How it looks and behaves on the watch still needs a real watch.
   - **(c) Final haptic patterns.** `.click` per tick, `.start` at Go and `.stop` at Stop are candidates. Whether Go is perceptibly different from the ticks (as OQ-6 requires), and whether haptics fire reliably while the watch app runs in the background, are settled by on-device testing. **Still open pending the real-watch pass, and unverified:** Apple's `WKInterfaceDevice.play(_:)` page says haptics do not play in the background except during a workout session, while Apple's extended-runtime article says sessions can play haptics. **Phone-only haptics is the expected fallback** (decisions.md entry 46), in which case the watch keeps the timer and Stop. The real-watch checklist also covers watch-to-phone Stop delivery while the watch app is in the background.
