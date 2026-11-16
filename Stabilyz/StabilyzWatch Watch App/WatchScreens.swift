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
        // The first that fits: full size; then the big numbers smaller, then
        // smaller again, so the words stay on screen; then scrolling. Each
        // state also puts its essential element first (the timer, the numeral
        // with "Phone in pocket", Done), so it is on the first screen even
        // where the rest scrolls. Nothing is ever truncated or clipped.
        ViewThatFits(in: .vertical) {
            screen(numberScale: 1)
            screen(numberScale: WatchTheme.compactNumberScale)
            screen(numberScale: WatchTheme.tightNumberScale)
            ScrollView { screen(numberScale: WatchTheme.tightNumberScale) }
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
                // Done before the detail, so it is on the first screen at the
                // largest text size on the smallest watch.
                Button(WatchCopy.done, action: model.tapDone)
                    .buttonStyle(.watchPrimaryCapsule)
                Text(WatchCopy.stoppedDetail)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
                    .wrapping()
            }

        case .disconnected(let timer):
            VStack(spacing: WatchTheme.spacing) {
                // The timer first: it is what the walker is looking for, and
                // the message follows it.
                TimerBlock(timer: timer, size: timerSize, scale: numberScale)
                Text(WatchCopy.disconnectedTitle)
                    .font(WatchTheme.heading)
                    .wrapping()
                Text(WatchCopy.disconnectedDetail)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
                    .wrapping()
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
            ProgressBar(progress: timer.progress)
                .accessibilityElement()
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((timer.progress * 100).rounded())) percent")
        }
    }
}

/// The walk's progress: a light fill on a lighter-than-black track, 3:1 or
/// better between the two (`WatchTheme`). It only ever grows with the timer —
/// no pulsing, and no animation of its own.
private struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(WatchTheme.track)
                Capsule()
                    .fill(WatchTheme.progressFill)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: WatchTheme.progressBarHeight)
    }
}
