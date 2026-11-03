import WatchKit

/// Plays the watch's session haptics (Task 12.3.1). A protocol so the model
/// can be tested without a Taptic Engine.
protocol WatchHapticPlaying {
    func play(_ haptic: WatchHaptic)
}

/// `WKInterfaceDevice` haptics [PRD §8 Haptics]. The types are candidates:
/// whether they fire reliably during a background extended runtime session is
/// the 12.6.1 exit condition (decisions.md entry 46).
struct DeviceWatchHaptics: WatchHapticPlaying {
    func play(_ haptic: WatchHaptic) {
        WKInterfaceDevice.current().play(Self.type(for: haptic))
    }

    static func type(for haptic: WatchHaptic) -> WKHapticType {
        switch haptic {
        case .click: .click
        case .start: .start
        case .stop: .stop
        }
    }
}
