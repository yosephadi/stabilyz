import SwiftUI

/// The gate every finished walk lands on (docs/11 §11.3, [PRD §5]).
///
/// One screen, two states, and the fork between them is the whole point: a
/// measured walk offers its result, an unclear one says so and offers only the
/// way back. Which it is comes from `SessionCompletionContent`, so this view
/// makes no validity decision of its own.
///
/// A single-decision screen, so both capsules are `button-height-hero` (§4).
/// The unclear state draws one of them — a disabled "View Result" would promise
/// a screen that does not exist.
struct SessionCompletionView: View {
    let content: SessionCompletionContent
    /// Nil for an unclear walk, which has no result to show.
    let viewResult: (() -> Void)?
    let backToWalk: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: content.glyph)
                .font(StabilyzFont.completionGlyph)
                .foregroundStyle(glyphColor)
                // The title says what happened; the mark restates it.
                .accessibilityHidden(true)

            Spacer().frame(height: Space.x8)

            Text(content.title)
                .font(StabilyzFont.subheadingBold)
                .foregroundStyle(StabilyzColor.ink900)

            Spacer().frame(height: Space.x4)

            Text(content.body)
                .font(StabilyzFont.bodyRegular)
                .foregroundStyle(StabilyzColor.ink600)

            Spacer()

            actions
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.screenMargin)
        .padding(.bottom, Controls.footerBottomGap)
        .background(StabilyzColor.bgBase)
    }

    /// Amber for the unclear walk — §2.3 reserves it for exactly this screen —
    /// and the brand navy for a measured one. Red is not used: nothing here is
    /// destructive, and the walk was not an error.
    private var glyphColor: Color {
        switch content {
        case .measured: StabilyzColor.primary600
        case .unclear: StabilyzColor.warning
        }
    }

    private var actions: some View {
        VStack(spacing: Space.x4) {
            if let viewResult {
                Button(SessionCompletionContent.viewResultLabel, action: viewResult)
                    .buttonStyle(.primaryCapsuleHero)
            }

            Button(SessionCompletionContent.backToWalkLabel, action: backToWalk)
                // Primary when it is the only way out, secondary when it sits
                // beside one. The role follows what the screen is asking, not
                // what the label says.
                .buttonStyle(viewResult == nil ? .primaryCapsuleHero : .secondaryCapsuleHero)
        }
    }
}

#Preview("Measured") {
    SessionCompletionView(
        content: .measured(mode: .quickTest),
        viewResult: {},
        backToWalk: {}
    )
}

#Preview("Unclear") {
    SessionCompletionView(
        content: .unclear(mode: .fullTest),
        viewResult: nil,
        backToWalk: {}
    )
}
