import ActivityKit
import SwiftUI
import WidgetKit

/// The watch nudge's UI (Task 12.5.1, PRD §8): Lock Screen, Dynamic Island,
/// and on iOS 18 the watch's Smart Stack. The types and words are shared with
/// the app, from `Services/LiveActivity/WatchNudgeAttributes.swift`.

/// iOS 17: phone only.
struct WatchNudgeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatchNudgeAttributes.self) { _ in
            WatchNudgeLockScreenView()
        } dynamicIsland: { _ in
            WatchNudgeIsland.make()
        }
    }
}

/// iOS 18 and later: the same, plus the watch's Smart Stack on watchOS 11.
@available(iOS 18.0, *)
struct WatchNudgeSmartStackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WatchNudgeSmartStackAttributes.self) { _ in
            WatchNudgeFamilyView()
        } dynamicIsland: { _ in
            WatchNudgeIsland.make()
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen banner: what to do, and why.
struct WatchNudgeLockScreenView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch")
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(WatchNudgeCopy.title)
                    .font(.headline)
                Text(WatchNudgeCopy.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

/// On iOS 18 one view serves the Lock Screen and the watch: the watch's
/// Smart Stack is the small family.
@available(iOS 18.0, *)
struct WatchNudgeFamilyView: View {
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            Label(WatchNudgeCopy.smartStack, systemImage: "applewatch")
                .font(.headline)
                .padding()
        default:
            WatchNudgeLockScreenView()
        }
    }
}

enum WatchNudgeIsland {
    static func make() -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.center) {
                WatchNudgeLockScreenView()
            }
        } compactLeading: {
            Image(systemName: "applewatch")
                .accessibilityHidden(true)
        } compactTrailing: {
            Text(WatchNudgeCopy.dynamicIsland)
                .font(.caption)
        } minimal: {
            Image(systemName: "applewatch")
                .accessibilityLabel(WatchNudgeCopy.dynamicIsland)
        }
    }
}
