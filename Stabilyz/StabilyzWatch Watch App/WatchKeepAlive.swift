import Foundation
import WatchKit

/// Keeps the watch app running (Task 12.4.1). A protocol so the model can be
/// tested without a watch.
protocol WatchKeepAliveControlling: AnyObject {
    /// Starts a keep-alive. `onEnded` is called if the system ends it —
    /// expiry or invalidation — but not after `end()`.
    func start(onEnded: @escaping () -> Void)
    func end()
}

/// No keep-alive: tests and the DEBUG preview.
final class NoKeepAlive: WatchKeepAliveControlling {
    func start(onEnded: @escaping () -> Void) {}
    func end() {}
}

/// A `WKExtendedRuntimeSession` keep-alive.
///
/// The session type comes from `WKBackgroundModes` in
/// `StabilyzWatch-Watch-App-Info.plist`: **physical therapy** — background,
/// up to an hour, no HealthKit. **[OPEN] PRD OQ-7a:** Apple requires the type
/// to match the app's purpose, so App Review may reject physical therapy for
/// a walk test; *self care* (10 min, foreground only, ended by the Digital
/// Crown) is the fallback. Survival through wrist-down is checked on a real
/// watch (Task 12.6.1).
///
/// A session object starts only once, so each start makes a new one.
final class ExtendedRuntimeKeepAlive: NSObject, WatchKeepAliveControlling, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?
    private var onEnded: (() -> Void)?

    func start(onEnded: @escaping () -> Void) {
        if let session, session.state == .running || session.state == .scheduled { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        self.onEnded = onEnded
        session.start()
    }

    func end() {
        let session = session
        self.session = nil
        onEnded = nil
        session?.invalidate()
    }

    // MARK: WKExtendedRuntimeSessionDelegate

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    /// Followed shortly by invalidation with reason `.expired`, handled there.
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let ended = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            // A session this object already let go of (`end()`, or replaced)
            // is nobody's concern.
            guard let session = self.session, ObjectIdentifier(session) == ended else { return }
            self.session = nil
            let onEnded = self.onEnded
            self.onEnded = nil
            onEnded?()
        }
    }
}
