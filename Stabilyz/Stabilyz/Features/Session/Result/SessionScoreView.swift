import SwiftUI

/// The Score screen (Figma node 150:3209, docs/04 §4.9, [PRD §5, §7]).
///
/// The last screen of the session cover, reached from the completion gate, and
/// the detail page a History row pushes (Task 9.1.1). Every decision about what
/// may be said lives in `SessionScorePresentation`; this draws it and owns
/// nothing but layout and the disclosure state.
///
/// **Three things the node draws are deliberately absent.** Each would need
/// data or a decision the app does not have:
///
/// - The *Stability Score* card charting this session against the baseline
///   second by second. The pipeline produces one index per session, not a time
///   series, and no document asks it to.
/// - *Recent Quick Tests Trend*. That is History's chart, Task 9.1.2, and it
///   reads the store rather than this session.
/// - The per-signal `92 / 100` sub-scores. docs/08 §8.2 leaves the composite
///   formula and index scaling `[OPEN]`; there is no per-signal index to render,
///   and inventing a mapping would resolve that `[OPEN]` silently.
/// - The `info.circle` beside the score label, which opens nothing the PRD
///   specifies. §1: no icon that does not map to a real action.
struct SessionScoreView: View {
    let presentation: SessionScorePresentation
    /// Nil when the screen is pushed from History: the navigation bar's back
    /// control is the way out there, and a second one docked at the bottom
    /// would be two exits that do the same thing.
    let done: (() -> Void)?

    /// Expanded to start, as the node draws it (its chevron points up).
    @State private var showsDetails = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                header
                ring
                if let progress = presentation.baselineProgress {
                    baselineProgress(progress)
                }
                if let note = presentation.note {
                    Text(note)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                highlights
                calculationDetails
                measurements
                thisSession
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.screenMargin)
            // The node puts its content 40pt below the status bar.
            .padding(.top, Space.x10)
            .padding(.bottom, Space.x6)
        }
        .background(StabilyzColor.bgBase)
        // Docked rather than placed after the scroll view. `safeAreaInset`
        // insets the scroll content by exactly the bar's height, so the last
        // row can always be scrolled clear of the button instead of ending
        // underneath it — which a sibling in a `VStack` gets right only while
        // the content happens to be short.
        .safeAreaInset(edge: .bottom) {
            if let done {
                doneBar(done)
            }
        }
    }

    /// The docked action bar.
    ///
    /// It carries the page's own background: content scrolls *under* an inset,
    /// and a transparent bar would show a metric row sliding behind the capsule.
    private func doneBar(_ done: @escaping () -> Void) -> some View {
        Button(SessionScorePresentation.doneLabel, action: done)
            .buttonStyle(.primaryCapsuleHero)
            // The screen margin, so the capsule's edges line up with the column
            // of content above it rather than sitting 4pt proud of it.
            .padding(.horizontal, Space.screenMargin)
            .padding(.top, Space.x4)
            .padding(.bottom, Space.x6)
            .background(StabilyzColor.bgBase)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("\(presentation.mode.displayName) Result")
                .font(StabilyzFont.subheadingBold)
                .foregroundStyle(StabilyzColor.ink900)
            Text(SessionScorePresentation.completedText(presentation.completedAt))
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The ring

    /// The one number, inside the node's 204pt band.
    ///
    /// The band wears the same gradient as the session timer ring; what the
    /// index is encodes itself in the numeral's colour instead (§2.4), because
    /// a ring redrawn per score would make the two screens read as unrelated.
    private var ring: some View {
        ZStack {
            if case .building(_, _, let provisional) = presentation.progress {
                // The band is the score, and only the score. It used to fill by
                // session count, which put two different quantities — how good
                // the walk was, and how many walks there had been — on one
                // shape. Calibration progress is the dots below instead.
                scoreBand(filling: provisional)
            } else {
                Circle().strokeBorder(bandGradient, lineWidth: Controls.scoreRingWidth)
            }
            ringContents
                .multilineTextAlignment(.center)
                .padding(.horizontal, Controls.scoreRingWidth + Space.x4)
        }
        .frame(width: Controls.scoreRingDiameter, height: Controls.scoreRingDiameter)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ringAnnouncement)
    }

    private var bandGradient: LinearGradient {
        LinearGradient(
            colors: [StabilyzColor.timerRingTop, StabilyzColor.timerRingBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// How much of the circumference a provisional score fills: 41 fills 41%.
    ///
    /// Its own function so the mapping can be asserted without rendering. The
    /// bug it replaced — the band filling by calibration count — was invisible
    /// in the arithmetic and obvious only on screen, which is exactly the kind
    /// that comes back.
    ///
    /// Nil fills nothing: no score, no arc.
    static func ringFill(forProvisional score: Int?) -> Double {
        min(max(Double(score ?? 0) / 100, 0), 1)
    }

    /// The band, filled to the score inside it.
    ///
    /// Only the pre-baseline scale gets a fill, because only it runs 0–100. The
    /// relative index does not — it is centred on 100 and open above it, so a
    /// "fraction of the ring" would be undefined at 112 and would read as a
    /// full ring at exactly average. That case keeps the plain band.
    ///
    /// The track draws underneath either way, so the ring stays a ring rather
    /// than a gap in the page.
    private func scoreBand(filling score: Int?) -> some View {
        let fraction = Self.ringFill(forProvisional: score)
        return ZStack {
            Circle()
                .strokeBorder(StabilyzColor.ink200, lineWidth: Controls.scoreRingWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    bandGradient,
                    style: StrokeStyle(lineWidth: Controls.scoreRingWidth, lineCap: .round)
                )
                // Twelve o'clock, clockwise — the direction the session ring
                // already sweeps, so the two read as the same instrument.
                .rotationEffect(.degrees(-90))
                .padding(Controls.scoreRingInset)
        }
    }

    @ViewBuilder
    private var ringContents: some View {
        switch presentation.progress {
        case .scored(let index, let delta):
            VStack(spacing: Space.x2) {
                Text("\(index)")
                    .font(StabilyzFont.heading)
                    .foregroundStyle(StabilyzColor.scoreNumeral(index))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(SessionScorePresentation.scoreLabel)
                    .font(StabilyzFont.bodyBold)
                    // Secondary text, not `primary900`: that navy is a
                    // light-mode ink and sits at barely 1.3:1 on the dark
                    // background, well under §9's 3:1 floor. `ink600` carries a
                    // dark-mode pair and clears it in both.
                    .foregroundStyle(StabilyzColor.ink600)
                deltaLine(delta)
            }

        case .building(let count, let required, let provisional):
            if let provisional {
                VStack(spacing: Space.x2) {
                    Text("\(provisional)")
                        .font(StabilyzFont.heading)
                        .foregroundStyle(StabilyzColor.scoreNumeral(provisional))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(SessionScorePresentation.scoreLabel)
                        .font(StabilyzFont.bodyBold)
                        .foregroundStyle(StabilyzColor.ink600)
                    // Sits exactly where "vs. baseline" sits on a scored
                    // session, so a reader cannot take the two for the same
                    // kind of statement [PRD §7 AC].
                    Text(SessionScorePresentation.provisionalLabel)
                        .font(StabilyzFont.smallBold)
                        .foregroundStyle(StabilyzColor.ink900)
                }
            } else {
                // The walk's metrics could not be read against the reference
                // anchors. The milestone is still true, and still progress.
                VStack(spacing: Space.x1) {
                    Text("\(count) of \(required)")
                        .font(StabilyzFont.heading)
                        .foregroundStyle(StabilyzColor.primary600)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(count == 1 ? "walk recorded" : "walks recorded")
                        .font(StabilyzFont.bodyBold)
                        .foregroundStyle(StabilyzColor.ink600)
                }
            }

        case .notComparable:
            VStack(spacing: Space.x2) {
                Text("No score")
                    .font(StabilyzFont.subheading2Bold)
                    .foregroundStyle(StabilyzColor.ink900)
                Text("This walk could not be compared")
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
            }
        }
    }

    /// "↑8 vs. baseline". The glyph carries the direction and the colour only
    /// reinforces it (§2.4, §9).
    private func deltaLine(_ delta: Int) -> some View {
        HStack(spacing: Space.x1) {
            if delta != 0 {
                Label(
                    "\(abs(delta))",
                    systemImage: delta > 0 ? "arrow.up" : "arrow.down"
                )
                .labelStyle(.titleAndIcon)
                .font(StabilyzFont.smallBold)
                .foregroundStyle(StabilyzColor.primary500)
            }
            Text(delta == 0 ? "same as baseline" : "vs. baseline")
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.timerRingTop)
        }
    }

    /// §9's wording: the numeral alone is not a sentence.
    private var ringAnnouncement: String {
        switch presentation.progress {
        case .scored(let index, let delta):
            if delta == 0 {
                return "Stability score \(index), the same as your baseline."
            }
            let direction = delta > 0 ? "above" : "below"
            return "Stability score \(index), \(abs(delta)) points \(direction) your baseline."
        case .building(let count, let required, let provisional):
            guard let provisional else {
                let walks = count == 1 ? "walk" : "walks"
                return "No score for this walk. \(count) of \(required) \(walks) recorded."
            }
            // "Provisional" first: it is the qualifier on everything after it,
            // and a listener who stops early must not be left with the number.
            // The calibration count is not repeated here — the progress block
            // below is its own stop and states it in words.
            return "Provisional stability score \(provisional) out of 100."
        case .notComparable:
            return "No score. This walk could not be compared against your baseline."
        }
    }

    /// How far calibration has got, under the ring.
    ///
    /// Three registers, centred: the count, five dots, and what the remaining
    /// walks buy. The dots are the reason this replaced a pill — a sentence
    /// about progress has to be read, whereas five dots are counted at a glance
    /// and are the only part of this block that survives being skimmed.
    ///
    /// They are not the only channel, though: the header states the same count
    /// in words directly above them, so nothing here depends on telling two
    /// fills apart (§9 — never encode by colour alone).
    private func baselineProgress(_ progress: SessionScorePresentation.BaselineProgress) -> some View {
        VStack(spacing: 0) {
            Text(progress.header)
                .font(StabilyzFont.smallBold)
                .foregroundStyle(StabilyzColor.ink900)

            Spacer().frame(height: Space.x2)

            HStack(spacing: Space.x2) {
                ForEach(0..<progress.required, id: \.self) { index in
                    Circle()
                        .fill(
                            index < progress.completed
                                ? StabilyzColor.primary600
                                : StabilyzColor.ink200
                        )
                        .frame(width: Controls.progressDotDiameter, height: Controls.progressDotDiameter)
                }
            }
            // The header says the count; the dots restate it. Two stops here
            // would read the same number twice.
            .accessibilityHidden(true)

            Spacer().frame(height: Space.x3)

            Text(progress.helper)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Highlights

    @ViewBuilder
    private var highlights: some View {
        if let highlight = presentation.highlight {
            VStack(alignment: .leading, spacing: Space.x4) {
                sectionTitle("Highlights")
                Text(highlight)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Calculation details

    @ViewBuilder
    private var calculationDetails: some View {
        if !presentation.signals.isEmpty {
            VStack(alignment: .leading, spacing: Space.x4) {
                HStack {
                    sectionTitle("Calculation Details")
                    Spacer()
                    Button {
                        showsDetails.toggle()
                    } label: {
                        Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                            .font(StabilyzFont.buttonLabel)
                            .foregroundStyle(StabilyzColor.ink900)
                            .frame(
                                width: Metrics.minimumTapTarget,
                                height: Metrics.minimumTapTarget
                            )
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsDetails ? "Hide calculation details" : "Show calculation details")
                }

                if showsDetails {
                    VStack(alignment: .leading, spacing: Space.x2) {
                        ForEach(presentation.signals) { signal in
                            signalRow(signal)
                        }
                    }
                }
            }
        }
    }

    private func signalRow(_ row: SessionScorePresentation.SignalRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x4) {
            Text(row.label)
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink900)
            Spacer(minLength: Space.x4)
            HStack(spacing: Space.x1) {
                if let direction = row.direction {
                    Image(systemName: direction.glyph)
                        .font(StabilyzFont.smallBold)
                }
                Text(row.detail)
                    .font(row.direction == nil ? StabilyzFont.smallRegular : StabilyzFont.smallBold)
            }
            .foregroundStyle(row.direction == nil ? StabilyzColor.ink600 : StabilyzColor.ink900)
            .multilineTextAlignment(.trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Raw measurements

    /// What the walk measured, for a screen with no score to show instead.
    ///
    /// §4.9's pre-baseline "raw metrics, reference only". The caption is
    /// load-bearing: without it three bare numbers invite exactly the
    /// comparison the screen cannot yet make.
    @ViewBuilder
    private var measurements: some View {
        if !presentation.measurements.isEmpty {
            VStack(alignment: .leading, spacing: Space.x4) {
                sectionTitle(SessionScorePresentation.measurementsTitle)
                VStack(alignment: .leading, spacing: Space.x2) {
                    ForEach(presentation.measurements) { row in
                        signalRow(row)
                    }
                }
                Text(SessionScorePresentation.measurementsCaption)
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - This session

    @ViewBuilder
    private var thisSession: some View {
        if let cue = presentation.cue {
            VStack(alignment: .leading, spacing: Space.x4) {
                sectionTitle("This Session")
                HStack(spacing: Space.x2) {
                    Image(systemName: cue.glyph)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                    Text(cue.text)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink900)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(StabilyzFont.subheading2Bold)
            .foregroundStyle(StabilyzColor.ink900)
    }
}
