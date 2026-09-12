import SwiftUI

/// The walk in progress (Figma node 128:2591, underneath the countdown).
///
/// The ring, the clock inside it, a record of the cues this session was started
/// with, and Stop. No navigation chrome: this is a full-screen cover, and the
/// only way out is the button (docs/11 §11.2).
struct ActiveSessionView: View {
    @Bindable var model: ActiveSessionViewModel
    /// A depleting ring is motion for its own sake to a reader who has asked
    /// for less of it, so the animation is dropped and the value still steps
    /// once a second (§9).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.x6)

            timerRing

            Spacer(minLength: Space.x10)

            cuesGroup
                .padding(.horizontal, Space.screenMargin)

            Spacer(minLength: Space.x6)

            stopButton
                .padding(.horizontal, Space.screenMargin)
                .padding(.bottom, Controls.coverFooterBottomGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StabilyzColor.bgBase)
    }

    // MARK: - The ring

    private var timerRing: some View {
        ZStack {
            // The track the depleting band runs on, so the ring reads as a
            // dial that is emptying rather than an arc that is shrinking.
            Circle()
                .strokeBorder(StabilyzColor.ink200, lineWidth: Controls.timerRingWidth)

            Circle()
                // Clock-like: the gap opens at twelve and sweeps clockwise, so
                // the band's leading edge travels the way a second hand does.
                // `trim(from: 1 - progress)` is what puts the gap at the front;
                // trimming the far end instead would unwind it backwards.
                .trim(from: 1 - model.progress, to: 1)
                .stroke(
                    LinearGradient(
                        colors: [StabilyzColor.timerRingTop, StabilyzColor.timerRingBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: Controls.timerRingWidth, lineCap: .round)
                )
                // SwiftUI trims from three o'clock; the dial starts at twelve.
                .rotationEffect(.degrees(-90))
                .padding(Controls.timerRingInset)
                .animation(
                    reduceMotion ? nil : .linear(duration: Motion.ringTick),
                    value: model.progress
                )

            clock
        }
        .frame(width: Controls.timerRingDiameter, height: Controls.timerRingDiameter)
        // One element, one announcement — a ring and a clock saying the same
        // thing twice is two stops to navigate past.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.timerAccessibilityLabel)
    }

    private var clock: some View {
        VStack(spacing: Space.x4) {
            Text(model.timerText)
                .font(StabilyzFont.heading)
                .foregroundStyle(StabilyzColor.ink900)
                // The digits are the one thing on screen that must not reflow
                // as it counts down.
                .monospacedDigit()

            Text(ActiveSessionViewModel.timerCaption)
                .font(StabilyzFont.subheading2Regular)
                .foregroundStyle(StabilyzColor.ink900)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Cues, as a record rather than a control

    private var cuesGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SessionSetupViewModel.sessionCuesHeader)
                .font(StabilyzFont.subheading2Bold)
                .foregroundStyle(StabilyzColor.ink600)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Controls.sectionHeaderHeight,
                    alignment: .topLeading
                )

            VStack(spacing: 0) {
                cueRow(title: model.audioCueTitle, isOn: model.isAudioCueOn)
                Divider().overlay(StabilyzColor.ink200)
                cueRow(title: SessionSetupViewModel.hapticsTitle, isOn: true)
            }
            .background(StabilyzColor.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    /// Deliberately disabled. Changing a cue mid-walk would change the
    /// conditions being measured, so this shows what the session was started
    /// with and nothing more [PRD §5].
    private func cueRow(title: String, isOn: Bool) -> some View {
        Toggle(isOn: .constant(isOn)) {
            Text(title)
                .font(StabilyzFont.bodyRegular)
                .foregroundStyle(StabilyzColor.ink900)
        }
        .tint(StabilyzColor.primary600)
        .disabled(true)
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .frame(minHeight: Controls.rowHeight)
        .accessibilityHint("Set before the walk started, and fixed for its duration.")
    }

    // MARK: - Stop

    private var stopButton: some View {
        Button(ActiveSessionViewModel.stopTitle) { model.stop() }
            .buttonStyle(.destructiveCapsuleHero)
            .disabled(model.isStopping)
    }
}
