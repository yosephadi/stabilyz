import SwiftUI

/// The walk in progress (Figma node 128:2591, underneath the countdown).
///
/// The ring, the clock inside it, the session's cues, and Stop. No navigation
/// chrome: this is a full-screen cover, and the only way out is the button
/// (docs/11 §11.2).
///
/// The two cue rows behave differently on purpose. Haptics fire at T-0 and at
/// Stop, so toggling one mid-walk cannot touch the measurement and it is free
/// in both directions. The audio cue **can be silenced but never started**: a
/// walk that was unpaced and then paced would produce one set of metrics
/// spanning two conditions, compared against a baseline established under one
/// [PRD §5, OQ-5]. Silencing only ever removes influence, and the alternative
/// for a user with failing earphones is abandoning the walk.
struct ActiveSessionView: View {
    @Bindable var model: ActiveSessionViewModel
    /// True while the countdown is up and for the beat after it clears: the
    /// clock and Stop are not drawn until the countdown's own controls have
    /// gone, so Cancel is never over Stop and the timer never competes with
    /// the numeral (the cover reveals them, in sequence, after T-0).
    var isReadoutHidden = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A depleting ring is motion for its own sake to a reader who has asked
    /// for less of it, so the animation is dropped and the value still steps
    /// once a second (§9).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dynamicTypeSize.usesStackedRing {
                stackedBody
            } else {
                regularBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StabilyzColor.bgBase)
    }

    private var regularBody: some View {
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
    }

    /// At accessibility sizes the clock leaves the ring and sits under it, and
    /// the middle scrolls so Stop stays pinned and reachable. Static: no
    /// motion is added by the layout.
    private var stackedBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Space.x6) {
                    timerRing
                    cuesGroup
                        .padding(.horizontal, Space.screenMargin)
                }
                .padding(.top, Space.x6)
            }
            .scrollBounceBehavior(.basedOnSize)

            stopButton
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.x4)
                .padding(.bottom, Controls.resultFooterBottomGap)
        }
    }

    // MARK: - The ring

    private var timerRing: some View {
        Group {
            if dynamicTypeSize.usesStackedRing {
                VStack(spacing: Space.x4) {
                    ringDial
                    clock
                }
            } else {
                ringDial.overlay { clock }
            }
        }
        // One element, one announcement — a ring and a clock saying the same
        // thing twice is two stops to navigate past.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.timerAccessibilityLabel)
    }

    /// The dial alone: track and depleting band.
    private var ringDial: some View {
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
        }
        .frame(width: Controls.timerRingDiameter, height: Controls.timerRingDiameter)
        .anchorPreference(key: CountdownRingAnchorKey.self, value: .bounds) { $0 }
    }

    private var clock: some View {
        VStack(spacing: Space.x4) {
            Text(model.timerText)
                .font(StabilyzFont.heading)
                .foregroundStyle(StabilyzColor.ink900)
                // The digits are the one thing on screen that must not reflow
                // as it counts down.
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(Motion.countdownNumeralMinimumScale)

            Text(ActiveSessionViewModel.timerCaption)
                .font(StabilyzFont.subheading2Regular)
                .foregroundStyle(StabilyzColor.ink900)
        }
        .multilineTextAlignment(.center)
        .opacity(isReadoutHidden ? 0 : 1)
    }

    // MARK: - Cues

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
                audioCueRow
                Divider().overlay(StabilyzColor.ink200)
                hapticsRow
            }
            .background(StabilyzColor.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    /// One way. The binding accepts `false` and ignores `true`, so the cue can
    /// be silenced but never started mid-walk — a walk that was unpaced and
    /// then paced would produce one score spanning two conditions [PRD §5].
    private var audioCueRow: some View {
        cueRow(
            title: model.audioCueTitle,
            status: model.audioCueStatus,
            hint: ActiveSessionViewModel.audioCueSilenceHint,
            isEnabled: model.canSilenceAudioCue,
            isOn: Binding(
                get: { model.isAudioCueOn },
                set: { isOn in if !isOn { model.silenceAudioCue() } }
            )
        )
    }

    /// Free in both directions: these fire at T-0 and at Stop, so changing one
    /// mid-walk cannot touch the measurement [PRD OQ-6].
    private var hapticsRow: some View {
        cueRow(
            title: SessionSetupViewModel.hapticsTitle,
            status: nil,
            hint: ActiveSessionViewModel.hapticsHint,
            isEnabled: true,
            isOn: $model.isHapticsOn
        )
    }

    private func cueRow(
        title: String,
        status: String?,
        hint: String,
        isEnabled: Bool,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(title)
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.ink900)
                if let status {
                    Text(status)
                        .font(StabilyzFont.smallRegular)
                        .foregroundStyle(StabilyzColor.ink600)
                }
            }
            // Wrap, never truncate: at accessibility sizes "Start & Stop
            // Haptics" takes two lines and the row grows to fit.
            .fixedSize(horizontal: false, vertical: true)
        }
        .tint(StabilyzColor.primary600)
        .disabled(!isEnabled)
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        .frame(minHeight: Controls.rowHeight)
        .accessibilityHint(hint)
    }

    // MARK: - Stop

    private var stopButton: some View {
        Button(ActiveSessionViewModel.stopTitle) { model.stop() }
            .buttonStyle(.destructiveCapsuleHero)
            .disabled(model.isStopping)
            .opacity(isReadoutHidden ? 0 : 1)
            // An invisible Stop must not be tappable or reachable by VoiceOver:
            // while the countdown is clearing, Cancel is the only control.
            .allowsHitTesting(!isReadoutHidden)
            .accessibilityHidden(isReadoutHidden)
            .accessibilityIdentifier("session.stop")
    }
}
