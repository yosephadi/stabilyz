import SwiftUI

/// The five watch screens [PRD §8], drawn from `WatchScreen`. No rules here:
/// what each shows is decided in `WatchScreenContent.swift`.
struct WatchRootView: View {
    let model: WatchSessionModel

    /// The big numbers' sizes, following Dynamic Type from the design's base
    /// sizes. Capped in `WatchTheme`.
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize = WatchTheme.numeralBaseSize
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = WatchTheme.timerBaseSize

    var body: some View {
        // The first that fits: full size; then the big numbers smaller, so the
        // words stay on screen; then full size again, scrolling. Nothing is
        // ever truncated or clipped.
        ViewThatFits(in: .vertical) {
            screen(numberScale: 1)
            screen(numberScale: WatchTheme.compactNumberScale)
            ScrollView { screen(numberScale: 1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchTheme.background)
        .foregroundStyle(WatchTheme.text)
    }

    private func screen(numberScale: CGFloat) -> some View {
        content(numberScale: numberScale)
            .multilineTextAlignment(.center)
            .padding(.horizontal, WatchTheme.screenMargin)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func content(numberScale: CGFloat) -> some View {
        switch model.screen {
        case .waiting(let selection, let selectionLabel):
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.waitingTitle)
                    .font(WatchTheme.title)
                    .wrapping()
                if let selection {
                    Text(selection)
                        .font(WatchTheme.body)
                        .wrapping()
                        .foregroundStyle(WatchTheme.secondaryText)
                        .accessibilityLabel(selectionLabel ?? selection)
                }
            }
            .accessibilityElement(children: .combine)

        case .countdown(let numeral):
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.countdownHeading)
                    .font(WatchTheme.heading)
                    .wrapping()
                Text(numeral)
                    .font(WatchTheme.numeral(size: numeralSize, scale: numberScale))
                    .bigNumber()
                    .accessibilityLabel(numeral)
                Text(WatchCopy.countdownFooter)
                    .font(WatchTheme.body)
                    .wrapping()
                    .foregroundStyle(WatchTheme.secondaryText)
            }

        case .running(let timer, let stopEnabled):
            VStack(spacing: WatchTheme.spacing) {
                TimerBlock(timer: timer, size: timerSize, scale: numberScale)
                Button(WatchCopy.stop, action: model.tapStop)
                    .buttonStyle(.watchPrimaryCapsule)
                    .disabled(!stopEnabled)
                    .accessibilityLabel(WatchCopy.stop)
            }

        case .stopped:
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.stoppedTitle)
                    .font(WatchTheme.title)
                    .wrapping()
                Text(WatchCopy.stoppedDetail)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
                    .wrapping()
                Button(WatchCopy.done, action: model.tapDone)
                    .buttonStyle(.watchPrimaryCapsule)
            }

        case .disconnected(let timer):
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.disconnectedTitle)
                    .font(WatchTheme.heading)
                    .wrapping()
                // The reassurance before the timer, so it is the part that
                // stays in view on a small watch.
                Text(WatchCopy.disconnectedDetail)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
                    .wrapping()
                TimerBlock(timer: timer, size: timerSize, scale: numberScale)
            }
        }
    }
}

/// Elapsed time and the progress bar, shared by Running and Disconnected.
private struct TimerBlock: View {
    let timer: WatchTimer
    let size: CGFloat
    let scale: CGFloat

    var body: some View {
        VStack(spacing: WatchTheme.spacing) {
            Text(timer.text)
                .font(WatchTheme.timer(size: size, scale: scale))
                .bigNumber()
                .accessibilityLabel(timer.accessibilityLabel)
            ProgressView(value: timer.progress)
                .tint(WatchTheme.primary)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((timer.progress * 100).rounded())) percent")
        }
    }
}
