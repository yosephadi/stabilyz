# Competitive Landscape: Prosthetic Gait Stability App

Desk research on existing apps in the gait-tracking, fall-risk, and prosthetic-care space, gathered as input for MVP scoping.

---

## 1. Apple Health — Walking Steadiness

**What it is:** Built-in iOS feature (iOS 15+) that passively scores gait using the iPhone's accelerometer/gyroscope, carried at the waist.

**Features:**
- Passive, background-only — no active "session" concept
- Produces a categorical score (High / OK / Low) estimating 12-month fall risk, not a numeric trend
- Updates on a rolling weekly basis, not per-walk
- Trained on a large able-bodied dataset (Apple Heart and Movement Study)
- Notifies user if score drops to Low
- Validated in able-bodied populations across age groups; not validated for prosthetic or asymmetric gait

**Relevance:** This is the exact gap your PRD identifies — it's the passive track you already planned to read from, and its known limitations (able-bodied calibration, weekly cadence, no asymmetry-specific metrics) are your app's core differentiation.

---

## 2. OneStep (Physical Therapy by OneStep)

**What it is:** FDA-listed digital physical therapy app; smartphone-only gait analysis paired with a licensed PT and a remote care plan. Launched 2019, Tel Aviv-based.

**Features:**
- Lab-grade gait analysis from a 30-second walk with the phone in a pocket — no wearables required
- Metrics: walking speed, stride length, cadence, movement symmetry, variability, and other balance indicators
- Fall-risk detection layered on top of gait data, added in 2022 — alerts care providers when a user's walk pattern trends toward risk
- Personalized recovery/exercise plan with PT messaging and video check-ins
- Syncs with Apple HealthKit
- Has expanded into upper-extremity range-of-motion tracking (holding the phone, not just walking)
- Explicitly used in orthopedic and **prosthetics** contexts: providers use it to document objective measures for patients with prosthetics and to show payers that treatment is effective
- Peer-reviewed validity studies exist against 3D motion capture (mixed results — reliable for step length/time/speed, less reliable for step asymmetry/variability specifically)

**Relevance:** Closest existing product to your idea in mechanism (phone-only, session-based, immediate feedback), but it's a general-purpose PT platform requiring a clinician relationship — not built around prosthetic-specific asymmetry or self-directed use. Worth studying its symmetry/variability metric definitions, since they're the closest published prior art to your step-time-asymmetry algorithm.

---

## 3. ReLoad (University of Miami research app)

**What it is:** Research-stage app (Miami VA / Walter Reed pilot) purpose-built for prosthetic gait training, not commercially available.

**Features:**
- Wearable sensors placed on legs, prosthetic limb, and back — not phone-only
- Real-time audio biofeedback: music plays while walking and becomes distorted/warped when gait deviates from target, giving in-the-moment correction cues
- Designed specifically for prosthetic gait retraining, not general fall-risk

**Relevance:** Validates that prosthetic-specific gait feedback is a recognized clinical need, but it's a multi-sensor research tool, not a self-serve consumer app — supports your phone-only approach as a meaningful accessibility/cost advantage.

---

## 4. GaitPulse

**What it is:** Consumer app built by an amputee, aimed at bridging the information gap between amputee and prosthetist between clinic visits.

**Features:**
- Daily self-logging: fit, swelling, gait quality
- Prosthetist-facing dashboard so clinicians see the log without an in-person visit
- Progress tracking framed for the user ("70% improved since new parts") and for insurance documentation (helps justify liner/component upgrades)
- Planned Fitbit integration for wearable sync

**Relevance:** This is the closest thing to a direct competitor in *audience* (amputees specifically) but it's subjective self-report logging (fit, swelling, "gait quality" as a feeling), not objective motion-sensor-derived metrics. Your step-time-asymmetry/cadence-variability/trunk-sway approach is a meaningfully more rigorous, quantified layer that GaitPulse doesn't have — but its clinician-facing "show your provider" screen is a close precedent for the clinician-summary-screen you just scoped into your MVP.

---

## 5. Roliner (Unhindr) — adjacent, not a gait app

**What it is:** A smart prosthetic *liner* (hardware), not a tracking app — included because it's app-connected and shows up in the same "amputee + smartphone" space.

**Features:**
- Physical liner with microfluidic channels; app lets the user adjust liner shape/volume/stiffness in real time via smartphone
- Aimed at daily socket-fit fluctuation (swelling, weight shifts), the same problem your deferred "socket-fit context tagging" field touches

**Relevance:** Not a direct competitor (it's a hardware fit-adjustment product, not gait analysis), but confirms that "fit changes day to day and affects how you walk" is an active, funded research area — reinforces that your socket-fit-tagging stub is pointed at a real, recognized problem, just correctly out of scope for v1.

---

## 6. Academic / research-grade smartphone gait tools

Not consumer apps, but relevant prior art for your algorithm design:

- **Smartphone gait & balance validation studies** (e.g. against 3D motion capture): found step length, step time, walking speed, and periodicity index to be reliable via phone sensors, but **step length/step time *variability and asymmetry* specifically were generally not reliable** in at least one validation study — a direct warning sign for your core metric and a reason to budget real tuning time, not just implementation time.
- **WORM score (Walking Orientation Randomness Metric):** a published trunk-sway-based stability metric (figure-of-eight trunk motion) shown to strongly discriminate fallers from non-fallers (AUC 0.97) using a chest-worn accelerometer — a useful reference model for your trunk-sway-proxy metric, even though it used a dedicated wearable rather than a phone at the waist.
- General finding across this literature: gait variability and asymmetry are recognized as more sensitive fall/instability indicators than raw walking speed, which supports your PRD's choice to prioritize step-time asymmetry over a simpler metric.

---

## Summary Table

| App | Type | Session-based? | Prosthetic-specific? | Objective sensor data? | Clinician-facing? |
|---|---|---|---|---|---|
| Apple Walking Steadiness | Passive OS feature | No (weekly) | No | Yes | No |
| OneStep | Consumer + PT platform | Yes (30-sec walks) | Partial (used in prosthetics context) | Yes | Yes |
| ReLoad | Research prototype | Yes | Yes | Yes (wearables) | Research-only |
| GaitPulse | Consumer app | No (daily self-report) | Yes | No (subjective log) | Yes |
| Roliner | Hardware + app | N/A | Yes (fit, not gait) | Sensor-based (fit, not motion) | No |

**Where your app sits:** the only concept in this set that combines (1) phone-only sensing, (2) an active, on-demand session model with immediate feedback, (3) prosthetic-specific asymmetry metrics, and (4) a personal-baseline-relative score rather than an absolute or able-bodied-normed one. OneStep is the nearest analog on mechanism; GaitPulse is the nearest analog on audience; neither combines both.
