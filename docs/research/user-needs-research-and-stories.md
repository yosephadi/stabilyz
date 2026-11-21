# User Needs Research → User Stories

Desk research on what prosthetic/lower-limb-loss users actually need and want from self-tracking technology, translated into user stories for the backlog.

---

## What the research found

### 1. Balance confidence — not fall count, not fear — is what is associated with whether someone actually moves through the world
A cross-sectional survey of 435 community-living people with unilateral lower-limb amputation (Miller et al. 2001, Arch Phys Med Rehabil 82(9):1238-44) found balance confidence was the *only* factor that remained significantly *associated with* mobility capability, mobility performance, and social activity once other variables were controlled for — fear of falling and actual fall history dropped out of the model. It is an association in a survey, not evidence that balance confidence predicts or causes anything. This is a meaningful reframe: your app's job isn't just to measure instability, it's to build and protect the user's *confidence* in their own walking. A score that feels punishing or alarming works against the actual goal.

### 2. Prosthetic adherence is fragile — roughly 11 to 22 percent stop using their device at about one year
An AHRQ review (Balk et al. 2018) found about 11 to 22 percent of lower-limb amputees prescribed a prosthesis stop using it at about 1 year, with low strength of evidence. (The earlier "30-50%" figure is unsourced and removed.) Discontinuation was described as linked to pain, technical difficulty, and insufficient support — also unsourced. Anything in the app that adds friction, confusion, or discouragement is working against an already-fragile adoption curve.

### 3. Self-directed education plus peer support was associated with improved walking confidence in a small study
SMART (Esfandiari et al., Prosthet Orthot Int 49(3):260-267, doi 10.1097/PXR.0000000000000368) was a single-group pre-post study with n=12, ages 26-79 (median 56) and 100% retention. Effect sizes were 0.86 for walking confidence and 0.51 for walking capacity. The intervention was online education modules plus peer mentoring — **not sensor-based** — so it says little about self-tracking technology as such. With no control group and twelve people, treat it as a feasibility signal: confidence moved more than capability, and a simple self-directed format was workable. (The earlier draft's "all participants trained in under 15 minutes" is not confirmed and is not repeated here.)

### 4. mHealth can become "disciplinary" instead of empowering if it's framed around deviations and compliance
Stampe et al. 2021 (JMIR, PMID 34128817) is an ethnographic study of 6 consultations with children and adolescents with juvenile arthritis; its finding concerns how those consultations were structured, not amputees or self-tracking at large. It suggests that even well-designed, user-centered tools can end up structuring the user's relationship to their own body around "compliance" and "deviation from normal" — which undermines the empowerment the tool was meant to provide. This is a real design risk for a gait app specifically: presenting every session as a pass/fail against a number can easily read as judgment rather than support.

### 5. Psychological adjustment after limb loss includes body image concerns and social anxiety
Adjustment to prosthesis use is described in the literature as involving anxiety, body image disturbance, and social stigma concerns tied to visibility/exposure of the limb difference. This matters for tone and privacy — data and language around the user's body and walking should never feel exposing.

### 6. Real-time, active coaching is a recognized need, not just retrospective scoring
This confirms what we already scoped for the metronome cue and flagged for the ReLoad-style v2 feature: vibrotactile and audio biofeedback systems for amputee gait training (trunk-angle vibration, foot-pressure haptics) are an active clinical research area specifically because in-the-moment correction works better than a report card after the fact.

### 7. Objective data fills a real gap between infrequent clinical visits
Consistent across GaitPulse, OneStep, and the general mHealth literature: patients want a way to know how they're doing *between* appointments, and clinicians want objective evidence rather than relying on the patient's memory of "it's been fine, I think."

### 8. Data privacy is a recurring, explicit concern
A review of 33 articles (Alhammad et al. 2024, doi 10.2196/50715) found patients expressed diverse views on privacy — so privacy is a concern worth designing for, but the review does not show that every user wants the same assurance. Treating it as table stakes trust remains a product judgment, not a finding.

### 9. Low digital literacy and low-friction onboarding matter for real-world adoption
The SMART study's 100% retention (n=12) is a weak signal, not a strong one: this population is not necessarily tech-native, particularly given the wide age range (26-79, median 56, in that n=12 study). The earlier sub-15-minute training claim is not confirmed. Onboarding friction is a bigger dropout risk here than in a general fitness-app audience.

---

## User Stories

Grouped by theme, each mapped loosely to where it lands relative to your current MVP scope.

### Confidence & framing (cuts across the whole app — mostly a copy/tone requirement, not a new feature)

- **As a prosthetic limb user**, I want my session results framed around my own progress rather than a pass/fail judgment, so that a bad session doesn't feel like I'm failing at walking.
- **As a prosthetic limb user**, I want encouraging, plain-language feedback rather than clinical or alarming language, so that using the app doesn't add anxiety to something I already feel self-conscious about.
- **As a prosthetic limb user**, I want to see how I'm improving relative to my own baseline, not compared to an abstract "normal" gait, so that my progress feels achievable and personally relevant. *(Already covered — this is your existing baseline-relative scoring design.)*

### In-session guidance (already in progress)

- **As a prosthetic limb user**, I want audio pacing cues while I walk, so that I get help adjusting in the moment instead of only finding out afterward that my session went poorly. *(Covered — the metronome cue.)*
- **As a prosthetic limb user**, I want to be able to turn session cues on or off, so that I can choose a quiet session when I don't want audio feedback. *(Covered — the mode selector design task.)*

### Trust, privacy, and honesty about uncertainty

- **As a prosthetic limb user**, I want a clear, simple explanation of what happens to my walking data, so that I trust the app enough to use it regularly.
- **As a prosthetic limb user**, I want to be told plainly when a session's data wasn't good enough to score, rather than shown a number I can't trust, so that I don't make decisions based on misleading information. *(Covered — noisy-data handling.)*

### Low-friction onboarding for a non-tech-native, wide-age-range audience

- **As a prosthetic limb user**, I want to complete setup in a few minutes with one simple step at a time, so that getting started doesn't feel like a barrier on top of everything else I'm already managing. *(Covered — progressive-disclosure onboarding.)*
- **As a new user**, I want to understand *why* the app is asking for my amputation level and side before I answer, so that I don't feel like I'm filling out a form for no reason. *(New — a one-line "why we ask" note on the onboarding screen; cheap addition to the existing design task.)*

### Bridging the gap between clinical visits

- **As a prosthetic limb user**, I want a simple way to show my prosthetist how I've been doing since my last visit, so that I don't have to rely on memory during a short appointment. *(Covered — clinician summary screen.)*
- **As a prosthetic limb user**, I want to see my trend over weeks, not just a single session's number, so that I can tell whether I'm actually improving or just having a good or bad day. *(Covered — session history + trend chart.)*

### New idea surfaced by this research (not yet in your backlog)

- **As a prosthetic limb user**, I want a short, encouraging summary after each session (not just a number), so that the app feels like it's supporting me rather than grading me. *(New — a one- or two-sentence generated summary alongside the score, e.g. "Your cadence was steadier than your last 3 sessions." Low-tech: this can be simple templated logic off existing metrics, not ML — worth a design + code task pair if you want it in v1, otherwise a strong v1.1 candidate given how directly it addresses the "disciplinary vs. empowering" risk above.)*

---

## Net takeaway for your build

Nothing here changes your MVP's feature list — the confidence-framing and privacy findings are mostly about **tone, copy, and how results are presented**, which your design tasks already touch (baseline-relative scoring, plain-language noisy-data messaging). The one concrete new idea worth a decision is the **short encouraging post-session summary** — it directly targets the single biggest risk this research surfaced (a self-tracking tool unintentionally feeling disciplinary rather than empowering) and it's cheap to build since it only needs the metrics you're already computing.

---

## References

- Miller et al. 2001: cross-sectional survey, n=435 community-living people with unilateral lower-limb amputation. Arch Phys Med Rehabil 82(9):1238-44. doi 10.1053/apmr.2001.25079 — https://doi.org/10.1053/apmr.2001.25079
- Balk et al. 2018, AHRQ review (about 11 to 22 percent of prescribed lower-limb prosthesis users stop at about 1 year; low strength of evidence). PMID 30285344 — https://europepmc.org/article/MED/30285344
- Esfandiari et al. (SMART). Prosthet Orthot Int 49(3):260-267. doi 10.1097/PXR.0000000000000368 — https://doi.org/10.1097/PXR.0000000000000368
- Stampe et al. 2021, JMIR. PMID 34128817 — https://europepmc.org/article/MED/34128817
- Alhammad et al. 2024. doi 10.2196/50715 — https://doi.org/10.2196/50715
