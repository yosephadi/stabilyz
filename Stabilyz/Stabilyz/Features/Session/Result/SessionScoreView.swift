import SwiftUI

/// The Score screen (Figma node 150:3209, docs/04 §4.9, [PRD §5, §7]).
///
/// The last screen of the session cover, reached from the completion gate. Every
/// decision about what may be said lives in `SessionScorePresentation`; this
/// draws it and owns nothing but layout and the disclosure state.
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
    let done: () -> Void

    /// Expanded to start, as the node draws it (its chevron points up).
    @State private var showsDetails = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    header
                    ring
                    if let note = presentation.note {
                        Text(note)
                            .font(StabilyzFont.smallRegular)
                            .foregroundStyle(StabilyzColor.ink600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    highlights
                    calculationDetails
                    thisSession
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.screenMargin)
                // The node puts its content 40pt below the status bar.
                .padding(.top, Space.x10)
                .padding(.bottom, Space.x6)
            }

            Button(SessionScorePresentation.doneLabel, action: done)
                .buttonStyle(.primaryCapsuleHero)
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.x4)
                // The no-tab-bar clearance. Not `coverFooterBottomGap`, which
                // exists to keep Stop where Start was; nothing on this screen
                // is continuous with the screen behind it.
                .padding(.bottom, Controls.footerBottomGap)
        }
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
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [StabilyzColor.timerRingTop, StabilyzColor.timerRingBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: Controls.scoreRingWidth
                )
            ringContents
                .multilineTextAlignment(.center)
                .padding(.horizontal, Controls.scoreRingWidth + Space.x4)
        }
        .frame(width: Controls.scoreRingDiameter, height: Controls.scoreRingDiameter)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ringAnnouncement)
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
                Text("Stability Score")
                    .font(StabilyzFont.bodyBold)
                    .foregroundStyle(StabilyzColor.primary900)
                deltaLine(delta)
            }

        case .building(let count, let required):
            VStack(spacing: Space.x2) {
                Text("Session \(count) of \(required)")
                    .font(StabilyzFont.subheading2Bold)
                    .foregroundStyle(StabilyzColor.ink900)
                    .minimumScaleFactor(0.6)
                Text("Building your \(presentation.mode.displayName) baseline")
                    .font(StabilyzFont.smallRegular)
                    .foregroundStyle(StabilyzColor.ink600)
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
        case .building(let count, let required):
            return """
            Building your \(presentation.mode.displayName) baseline. \
            Session \(count) of \(required). No score yet.
            """
        case .notComparable:
            return "No score. This walk could not be compared against your baseline."
        }
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
