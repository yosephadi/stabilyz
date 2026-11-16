# Competitive Landscape: Prosthetic Gait Stability App

Desk research on existing apps in the gait-tracking, fall-risk, and prosthetic-care space, gathered as input for MVP scoping. *Corrected 2026-11-14 against primary sources; links are in the References section at the end. Statements marked "unverified" or "unsourced" were in the earlier draft and could not be confirmed.*

---

## 1. Apple Health — Walking Steadiness

**What it is:** Built-in iOS feature (iOS 15+) that passively scores gait using the iPhone's accelerometer/gyroscope, carried in a pocket or held close to the body's centre (not specifically the waist).

**Features:**
- Passive, background-only — no active "session" concept
- Reports Walking Steadiness in three levels — OK, Low and Very Low (Apple iPhone User Guide; Apple newsroom; WWDC21) — while a numeric percent value is saved to HealthKit weekly
- Updates on a rolling weekly basis, not per-walk
- Apple's mobility-metrics paper describes two cohorts: cohort A, older adults (design N=359 aged 64–92; validation N=179 aged 65–95; about 80% with musculoskeletal conditions), and cohort B, N=51 younger able-bodied adults wearing a knee brace. (The earlier claim that it was trained on the Apple Heart and Movement Study is unsourced and removed.)
- Notifies user if score drops to Low
- Not validated for prosthetic gait. Apple itself notes that asymmetry from a brace may differ from asymmetry due to a prosthesis
- Apple also has a separate Walking Asymmetry metric

**Relevance:** This is the gap your PRD identifies: Apple's validation does not cover prosthetic gait, and the score is passive and reported weekly rather than per walk. Apple does have a Walking Asymmetry metric, so the differentiation is not "no asymmetry metric" but "not validated for prosthetic gait, and not an on-demand test". (HealthKit is out of scope in the PRD, so this is context, not an integration plan.)

---

## 2. OneStep (now listed as "OneStep Move")

**What it is:** Digital physical therapy app, now listed on the App Store as OneStep Move with provider-only access. The company is FDA-registered and its device is listed under product code ISD (class II, 510(k)-exempt) — that is a listing, **not an FDA clearance**; smartphone-only gait analysis paired with a licensed PT and a remote care plan. Launched 2019, Tel Aviv-based.

**Features:**
- Lab-grade gait analysis from a 30-second walk with the phone in a pocket — no wearables required
- Metrics: walking speed, stride length, cadence, movement symmetry, variability, and other balance indicators
- Fall-risk detection layered on top of gait data, added in 2022 — alerts care providers when a user's walk pattern trends toward risk
- Personalized recovery/exercise plan with PT messaging and video check-ins (unverified: not confirmed on the current listing)
- Syncs with Apple HealthKit
- Has expanded into upper-extremity range-of-motion tracking (holding the phone, not just walking)
- Explicitly used in orthopedic and **prosthetics** contexts: providers use it to document objective measures for patients with prosthetics and to show payers that treatment is effective
- The OneStep validity study is Christensen et al. 2022: 20 healthy adults against Vicon motion capture, with no asymmetry or variability variables, and three authors are company staff. The result that variability and asymmetry were generally poorly valid and reliable belongs to a different app (see section 6), not to OneStep

**Relevance:** Closest existing product to your idea in mechanism (phone-only, session-based, immediate feedback), but it's a general-purpose PT platform requiring a clinician relationship — not built around prosthetic-specific asymmetry or self-directed use. Worth studying its symmetry/variability metric definitions, since they're the closest published prior art to your step-time-asymmetry algorithm.

---

## 3. ReLoad (University of Miami research app)

**What it is:** Research-origin app purpose-built for prosthetic gait training. Since 2018 it has become the technology in the VA/DOD Mobile Device Outcomes-based Rehabilitation Program, at five VA centers plus Walter Reed (DHA article, April 2025). It is still not stated to be commercially available.

**Features:**
- Wearable sensors placed on legs, prosthetic limb, and back — not phone-only
- Real-time audio biofeedback: music plays while walking and becomes distorted/warped when gait deviates from target, giving in-the-moment correction cues
- Designed specifically for prosthetic gait retraining, not general fall-risk

**Relevance:** Validates that prosthetic-specific gait feedback is a recognized clinical need, but it's a multi-sensor research tool, not a self-serve consumer app — supports your phone-only approach as a meaningful accessibility/cost advantage.

---

## 4. GaitPulse

**What it is:** Consumer app built by an amputee, aimed at bridging the information gap between amputee and prosthetist between clinic visits. *Everything below comes from its marketing site and a press article; the app itself was not examined.*

**Features:**
- Per its site, steps, symmetry, cadence and activity are captured automatically by the phone and compared with a 90-day baseline
- A diary and a clinic dashboard so clinicians see the data without an in-person visit
- The earlier draft's "70% improved since new parts" is a hypothetical in a quotation, not a result
- Planned Fitbit integration: unverified, not found in the sources checked

**Relevance:** A close competitor in *audience* (amputees specifically), and on its own description now also in *mechanism*: automatic, phone-based capture of steps, symmetry and cadence against a personal baseline, plus a clinic dashboard. The earlier reading — subjective self-report only — no longer fits its site. What the site does not show is whether any of this is validated for prosthetic gait, or how symmetry is computed; that needs checking against the app itself. Its clinic-facing dashboard is a close precedent for the clinician summary screen in your MVP.

---

## 5. Roliner (Unhindr) — adjacent, not a gait app

**What it is:** A smart prosthetic *liner* (hardware), not a tracking app. Per Unhindr's FAQ it is a clinic-fitted product, offered through partner clinics in a UK Pioneer Programme that ran until 31/08/2026.

**Features:**
- Physical liner with "millifluidic" channels that are pneumatically pressurised (per the FAQ). The earlier claim that the user adjusts shape, volume and stiffness in real time by smartphone was not confirmed
- Aimed at daily socket-fit fluctuation (swelling, weight shifts), the same problem your deferred "socket-fit context tagging" field touches

**Relevance:** Not a direct competitor (it's a hardware fit-adjustment product, not gait analysis), but confirms that "fit changes day to day and affects how you walk" is an active, funded research area — reinforces that your socket-fit-tagging stub is pointed at a real, recognized problem, just correctly out of scope for v1.

---

## 6. Academic / research-grade smartphone gait tools

Not consumer apps, but relevant prior art for your algorithm design:

- **Rashid et al. 2021** (Gait&Balance app; 30 healthy adults, phone at the lower back): variability and asymmetry generally showed poor validity and reliability — a direct warning sign for your core metric and a reason to budget real tuning time, not just implementation time. This is the source of the "variability and asymmetry" result; it is not a result about OneStep.
- **WORM score (Walking Orientation Randomness Metric):** Mobbs et al. 2022 pilot — 16 fallers against 16 non-fallers, an IMU at the sternal angle, AUC 0.965, no amputees. A useful reference model for your trunk-sway-proxy metric, even though it used a dedicated wearable rather than a phone, and a pilot in people who are not prosthesis users.
- "Gait variability and asymmetry are more sensitive fall/instability indicators than raw walking speed" was stated in the earlier draft **without a source**. Treat it as unsourced; it does not by itself support prioritizing step-time asymmetry.

---

## Summary Table

| App | Type | Session-based? | Prosthetic-specific? | Objective sensor data? | Clinician-facing? |
|---|---|---|---|---|---|
| Apple Walking Steadiness | Passive OS feature | No (weekly) | No | Yes | No |
| OneStep (OneStep Move) | Provider-only PT platform | Yes (30-sec walks, per earlier draft) | Partial (used in prosthetics context) | Yes | Yes |
| ReLoad | Research-origin; VA/DOD rehab program | Yes | Yes | Yes (wearables) | Clinical programme use; not stated to be commercial |
| GaitPulse | Consumer app | Automatic capture per its site (app not examined) | Yes | Per its site, yes (steps, symmetry, cadence); not examined | Yes (clinic dashboard) |
| Roliner | Hardware + app | N/A | Yes (fit, not gait) | Sensor-based (fit, not motion) | No |

**Where your app sits:** an app that combines (1) phone-only sensing, (2) an active, on-demand session model with immediate feedback, (3) prosthetic-specific asymmetry metrics, and (4) a personal-baseline-relative score rather than an absolute or able-bodied-normed one. The earlier claim that it is the *only* concept in this set to do so no longer holds: GaitPulse's site now describes automatic phone capture of steps, symmetry and cadence against a 90-day baseline, so it is a close competitor on both mechanism and audience (marketing page only; the app was not examined). OneStep Move is provider-only. Whether GaitPulse's metrics are validated, and whether any competitor offers an on-demand session, was not established.

---

## References

- Apple, iPhone User Guide, Walking Steadiness levels (OK / Low / Very Low); Apple newsroom, "Apple advances personal health by introducing secure sharing and new insights", June 2021: https://www.apple.com/newsroom/2021/06/apple-advances-personal-health-by-introducing-secure-sharing-and-new-insights/
- WWDC21 session 10287: https://developer.apple.com/videos/play/wwdc2021/10287/
- Apple, "Measuring Walking Quality Through iPhone Mobility Metrics" (cohorts A and B, Walking Asymmetry): https://www.apple.com/healthcare/docs/site/Measuring_Walking_Quality_Through_iPhone_Mobility_Metrics.pdf
- OneStep Move, App Store listing (provider-only access): https://apps.apple.com/us/app/-/id6739207339
- FDA establishment registration and listing (celloscope): https://www.accessdata.fda.gov/scripts/cdrh/cfdocs/cfRL/rl.cfm?start_search=1&establishmentName=celloscope
- FDA product classification, product code ISD: https://www.accessdata.fda.gov/scripts/cdrh/cfdocs/cfPCD/classification.cfm?start_search=1&ProductCode=ISD
- Christensen et al. 2022, OneStep validity study: https://pmc.ncbi.nlm.nih.gov/articles/PMC9476593
- Rashid et al. 2021, Gait&Balance app: https://pmc.ncbi.nlm.nih.gov/articles/PMC8747233
- GaitPulse site: https://gaitpulse.com/welcome ; article: https://livingwithamplitude.com/article/gaitpulse-app-helps-amputees-track-prosthetic-use/
- DHA, "Revolutionizing rehab: mobile technology helps service members and veterans walk with confidence" (ReLoad), 10 April 2025: https://dha.mil/News/2025/04/10/15/03/Revolutionizing-rehab-mobile-technology-helps-service-members-and-veterans-walk-with-confidence
- Unhindr FAQ (Roliner, Pioneer Programme): https://unhindr.com/faq/
- Mobbs et al. 2022, WORM pilot: https://pmc.ncbi.nlm.nih.gov/articles/PMC8966274/
