# Feature Backlog — Ideas from Competitive Research

Pulled from the competitive landscape doc. Organized by source app, with a priority tag. None of these are in the current 2-week MVP scope — this is the "next" list.

---

## 🌟 Flagship idea: Real-time in-session guidance (from ReLoad)

**What ReLoad does:** plays audio while the user walks and warps/distorts the sound when their gait deviates from target — giving correction feedback *during* the walk, not after it.

**Why it's interesting for your app:** your current v1 design computes everything at "Stop" — the user gets a score after the fact but can't adjust mid-session. Real-time guidance would turn a session from "recorded and graded" into "coached," which is a much stronger product hook than a post-hoc number.

**What it would take (this is the important part):**
- Your v1 algorithm is designed as **batch processing** — record the full 3-5 min window, then compute step time asymmetry/cadence variability/trunk sway once, at Stop. Real-time guidance needs a **streaming/rolling-window** version of that same math — e.g. recompute asymmetry over the last 10-15 steps continuously, not once at the end. That's a genuinely different architecture, not a tweak.
- You don't need full audio-warping sophistication to start. Two simpler v2 entry points:
  - **Haptic pulse feedback**: phone vibrates (or taps via a paired Watch) when live asymmetry crosses a threshold — much simpler than audio synthesis, still gives in-session correction.
  - **Simple audio cue** (tone/beep changes pitch or tempo based on live symmetry) before attempting anything like ReLoad's music-warping.
- Needs its own tuning pass separate from your v1 baseline algorithm, since "is this good enough to score" and "is this fast/stable enough to feed a live cue every second" are different bars.

**Suggested placement:** first big v2 feature, after v1 ships and your baseline algorithm is validated against real sessions. Trying to build both the offline scoring algorithm *and* a real-time feedback loop in the same 2-week window is what would break your MVP timeline — the streaming version depends on the batch version being trustworthy first.

---

## From OneStep

- **Published symmetry/variability metric definitions** — not a feature to copy, but worth reviewing their methodology as a validation reference for your own step-time-asymmetry math, since it's the closest peer-reviewed prior art you have.
- **Clinician messaging / care-plan loop** — beyond your scoped "single summary screen," OneStep lets a PT actually message the patient through the app. Bigger lift (needs a clinician-side portal), good v3+ idea if you ever move toward a clinical/insurance angle like GaitPulse has.

## From GaitPulse

- **Subjective daily fit/swelling log**, alongside your objective sensor metrics. Right now your app only measures *motion*; GaitPulse's insight is that a bad day's numbers are often explained by something non-motion (poor socket fit, swelling) that the sensor can't see. A lightweight "how did your fit feel today?" tag on a session would make your baseline-relative scoring much more interpretable — directly complements the socket-fit-context field you already stubbed in the data model.
- **Insurance-documentation framing** — GaitPulse explicitly positions its trend data as evidence for insurers when requesting new components. Worth keeping in mind as a future value prop once you have a session history to point to, even though it's not a v1/v2 feature per se.

## From the WORM score research (trunk-sway paper)

- Their trunk-sway metric (figure-of-eight motion of the trunk, chest-worn sensor) is a more sophisticated model than a simple variance calculation — worth revisiting as a *v2 refinement* to your trunk-sway-proxy metric once v1's simpler variance-based version is validated against real sessions.

## From Roliner / socket-fit research

- Reinforces (doesn't add a new feature) that your deferred socket-fit-tagging field is pointed at a real, active problem — no action needed now beyond what's already stubbed.

---

## Suggested backlog order (post-MVP)

1. Haptic/audio real-time feedback during sessions (ReLoad-inspired) — biggest differentiation opportunity
2. Subjective fit/swelling tag per session (GaitPulse-inspired) — cheap, high interpretability value
3. Trunk-sway metric refinement (WORM-inspired)
4. Clinician messaging loop (OneStep-inspired) — largest lift, lowest urgency
