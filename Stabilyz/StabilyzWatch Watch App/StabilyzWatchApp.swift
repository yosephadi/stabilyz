import SwiftUI

/// The watch companion (Phase 3, PRD §8): display, haptics and Stop only.
@main
struct StabilyzWatchApp: App {
    @State private var model = Self.makeModel()
    @Environment(\.scenePhase) private var scenePhase

    private static func makeModel() -> WatchSessionModel {
        #if DEBUG
        if let preview = WatchDebugPreview.requested() {
            return preview.makeModel()
        }
        #endif
        return WatchSessionModel(
            link: WatchPhoneLink(),
            haptics: DeviceWatchHaptics(),
            keepAlive: ExtendedRuntimeKeepAlive(),
            announce: { AccessibilityNotification.Announcement($0).post() }
        )
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .task {
                    model.start()
                    model.setActive(scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }
}
