import SwiftUI

/// The watch companion (Phase 3, PRD §8): display, haptics and Stop only.
@main
struct StabilyzWatchApp: App {
    @State private var model = WatchSessionModel(
        link: WatchPhoneLink(),
        announce: { AccessibilityNotification.Announcement($0).post() }
    )

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .task { model.start() }
        }
    }
}
