# Feature Backlog — Ideas from Competitive Research

Pulled from the competitive landscape doc. Organized by source app, with a priority tag. None of these are in the current 2-week MVP scope — this is the "next" list.

---

## 🌟 Flagship idea: Real-time in-session guidance (from ReLoad)

**What ReLoad does:** plays audio while the user walks and warps/distorts the sound when their gait deviates from target — giving correction feedback *during* the walk, not after it.

**Why it's interesting for your app:** your current v1 design computes everything at "Stop" — the user gets a score after the fact but can't adjust mid-session. Real-time guidance would turn a session from "recorded and graded" into "coached," which is a much stronger product hook than a post-hoc number.

**What it would take (this is the important part):**
- Your v1 algorithm is designed as **batch processing** — record the full session (a 1:30 Quick Test or a 3:00 Full Test), then compute step time asymmetry/cadence variability/trunk sway once, at Stop. Real-time guidance needs a **streaming/rolling-window** version of that same math — e.g. recompute asymmetry over the last 10-15 steps continuously, not once at the end. That's a genuinely different architecture, not a tweak.
- You don't need full audio-warping sophistication to start. Two simpler v2 entry points:
  - **Haptic pulse feedback**: phone vibrates (or taps via a paired Watch) when live asymmetry crosses a threshold — much simpler than audio synthesis, still gives in-session correction.
  - **Simple audio cue** (tone/beep changes pitch or tempo based on live symmetry) before attempting anything like ReLoad's music-warping.
- Needs its own tuning pass separate from your v1 baseline algorithm, since "is this good enough to score" and "is this fast/stable enough to feed a live cue every second" are different bars.

**Suggested placement:** first big v2 feature, after v1 ships and your baseline algorithm is validated against real sessions. Trying to build both the offline scoring algorithm *and* a real-time feedback loop in the same 2-week window is what would break your MVP timeline — the streaming version depends on the batch version being trustworthy first.

---

## From OneStep

- **Metric definitions** — the OneStep validity study (Christensen et al. 2022; 20 healthy adults against Vicon; three authors are company staff) has no asymmetry or variability variables, so it is not prior art for step-time-asymmetry math. The poor variability/asymmetry result sometimes attributed to OneStep is Rashid et al. 2021 on the Gait&Balance app (30 healthy adults). OneStep is now listed as "OneStep Move" with provider-only access.
- **Clinician messaging / care-plan loop** — beyond your scoped "single summary screen," OneStep lets a PT actually message the patient through the app (unverified: not confirmed on the current listing). Bigger lift (needs a clinician-side portal), good v3+ idea if you ever move toward a clinical/insurance angle like GaitPulse has.

## From GaitPulse

- **Subjective daily fit/swelling log**, alongside your objective sensor metrics. Right now your app only measures *motion*. GaitPulse's site now describes a diary plus automatic phone capture of steps, symmetry and cadence against a 90-day baseline, and a clinic dashboard (marketing page and press article only; the app was not examined), so it is no longer only a self-report log. The idea worth borrowing is that a bad day's numbers are often explained by something non-motion (poor socket fit, swelling) that the sensor can't see. A lightweight "how did your fit feel today?" tag on a session would make your baseline-relative scoring much more interpretable — directly complements the socket-fit-context field you already stubbed in the data model.
- **Insurance-documentation framing** — GaitPulse explicitly positions its trend data as evidence for insurers when requesting new components. Worth keeping in mind as a future value prop once you have a session history to point to, even though it's not a v1/v2 feature per se.

## From the WORM score research (trunk-sway paper)

- Their trunk-sway metric (figure-of-eight motion of the trunk; Mobbs et al. 2022 pilot, 16 fallers against 16 non-fallers, IMU at the sternal angle, AUC 0.965, no amputees) is a more sophisticated model than a simple variance calculation — worth revisiting as a *v2 refinement* to your trunk-sway-proxy metric once v1's simpler variance-based version is validated against real sessions.

## From Roliner / socket-fit research

- Reinforces (doesn't add a new feature) that your deferred socket-fit-tagging field is pointed at a real, active problem — no action needed now beyond what's already stubbed.

---

## Suggested backlog order (post-MVP)

1. Haptic/audio real-time feedback during sessions (ReLoad-inspired) — biggest differentiation opportunity
2. Subjective fit/swelling tag per session (GaitPulse-inspired) — cheap, high interpretability value
3. Trunk-sway metric refinement (WORM-inspired)
4. Clinician messaging loop (OneStep-inspired) — largest lift, lowest urgency

---

## References

- Christensen et al. 2022 (OneStep validity study): https://pmc.ncbi.nlm.nih.gov/articles/PMC9476593
- Rashid et al. 2021 (Gait&Balance app): https://pmc.ncbi.nlm.nih.gov/articles/PMC8747233
- Mobbs et al. 2022 (WORM pilot): https://pmc.ncbi.nlm.nih.gov/articles/PMC8966274/
- OneStep Move listing: https://apps.apple.com/us/app/-/id6739207339
- GaitPulse site: https://gaitpulse.com/welcome ; article: https://livingwithamplitude.com/article/gaitpulse-app-helps-amputees-track-prosthetic-use/
- See also the References in competitive-landscape-gait-app.md.
