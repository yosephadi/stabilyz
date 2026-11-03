import SwiftUI

/// The five watch screens [PRD §8], drawn from `WatchScreen`. No rules here:
/// what each shows is decided in `WatchScreenContent.swift`.
struct WatchRootView: View {
    let model: WatchSessionModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WatchTheme.background)
            .foregroundStyle(WatchTheme.text)
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .waiting(let selection, let selectionLabel):
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.waitingTitle)
                    .font(WatchTheme.title)
                    .multilineTextAlignment(.center)
                if let selection {
                    Text(selection)
                        .font(WatchTheme.body)
                        .foregroundStyle(WatchTheme.secondaryText)
                        .accessibilityLabel(selectionLabel ?? selection)
                }
            }
            .accessibilityElement(children: .combine)

        case .countdown(let numeral):
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.countdownHeading).font(WatchTheme.heading)
                Text(numeral)
                    .font(WatchTheme.numeral)
                    .accessibilityLabel(numeral)
                Text(WatchCopy.countdownFooter)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
            }

        case .running(let timer, let stopEnabled):
            VStack(spacing: WatchTheme.spacing) {
                TimerBlock(timer: timer)
                Button(action: model.tapStop) {
                    Text(WatchCopy.stop)
                        .font(WatchTheme.heading)
                        .foregroundStyle(WatchTheme.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: WatchTheme.stopHeight)
                        .background(Capsule().fill(WatchTheme.primary))
                }
                .buttonStyle(.plain)
                .disabled(!stopEnabled)
                .opacity(stopEnabled ? 1 : 0.5)
                .accessibilityLabel(WatchCopy.stop)
            }

        case .stopped:
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.stoppedTitle).font(WatchTheme.title)
                Text(WatchCopy.stoppedDetail)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
                    .multilineTextAlignment(.center)
                Button(WatchCopy.done, action: model.tapDone)
                    .tint(WatchTheme.primary)
            }

        case .disconnected(let timer):
            VStack(spacing: WatchTheme.spacing) {
                Text(WatchCopy.disconnectedTitle).font(WatchTheme.heading)
                TimerBlock(timer: timer)
                Text(WatchCopy.disconnectedDetail)
                    .font(WatchTheme.body)
                    .foregroundStyle(WatchTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Elapsed time and the progress bar, shared by Running and Disconnected.
private struct TimerBlock: View {
    let timer: WatchTimer

    var body: some View {
        VStack(spacing: WatchTheme.spacing) {
            Text(timer.text)
                .font(WatchTheme.timer)
                .accessibilityLabel(timer.accessibilityLabel)
            ProgressView(value: timer.progress)
                .tint(WatchTheme.primary)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((timer.progress * 100).rounded())) percent")
        }
    }
}
