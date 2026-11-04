import SwiftUI

/// The watch companion (Phase 3, PRD §8): display, haptics and Stop only.
@main
struct StabilyzWatchApp: App {
    @State private var model = Self.makeModel()

    private static func makeModel() -> WatchSessionModel {
        #if DEBUG
        if let preview = WatchDebugPreview.requested() {
            return preview.makeModel()
        }
        #endif
        return WatchSessionModel(
            link: WatchPhoneLink(),
            haptics: DeviceWatchHaptics(),
            announce: { AccessibilityNotification.Announcement($0).post() }
        )
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .task { model.start() }
        }
    }
}
