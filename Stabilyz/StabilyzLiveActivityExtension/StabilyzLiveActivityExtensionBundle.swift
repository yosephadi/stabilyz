import SwiftUI
import WidgetKit

/// The extension holds only the watch nudge Live Activity (Task 12.5.1). No
/// home-screen widget: the PRD has none.
@main
struct StabilyzLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        WatchNudgeLiveActivity()
        if #available(iOS 18.0, *) {
            WatchNudgeSmartStackLiveActivity()
        }
    }
}
