import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Production observer over `UIApplication` lifecycle notifications and the
/// audio service's own event stream (docs/07 §7.7).
///
/// Audio interruptions arrive through `AudioFeedbackService.events` rather than
/// by observing `AVAudioSession` directly, so the audio session stays owned by
/// one component (docs/10 §10.2).
actor SystemSessionInterruptionObserver: SessionInterruptionObserver {
    private let audioFeedback: AudioFeedbackService
    private let notificationCenter: NotificationCenter

    private var continuation: AsyncStream<SessionInterruption>.Continuation?
    private var notificationTasks: [Task<Void, Never>] = []
    private var audioTask: Task<Void, Never>?

    init(audioFeedback: AudioFeedbackService, notificationCenter: NotificationCenter = .default) {
        self.audioFeedback = audioFeedback
        self.notificationCenter = notificationCenter
    }

    func startObserving() async -> AsyncStream<SessionInterruption> {
        await stopObserving()

        let (stream, continuation) = AsyncStream<SessionInterruption>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        #if canImport(UIKit)
        let observed: [(Notification.Name, SessionInterruption)] = [
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive)
        ]

        for (name, interruption) in observed {
            let notifications = notificationCenter.notifications(named: name)
            notificationTasks.append(
                Task {
                    for await _ in notifications {
                        continuation.yield(interruption)
                    }
                }
            )
        }
        #endif

        let audioEvents = audioFeedback.events
        audioTask = Task {
            for await event in audioEvents {
                switch event {
                case .interrupted: continuation.yield(.audioInterrupted)
                case .routeChanged: continuation.yield(.audioRouteChanged)
                case .interruptionEnded, .degraded: break
                }
            }
        }

        return stream
    }

    func stopObserving() async {
        for task in notificationTasks { task.cancel() }
        notificationTasks.removeAll()
        audioTask?.cancel()
        audioTask = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Production `ScreenSleepController` over `UIApplication.isIdleTimerDisabled`
/// [REC — docs/07 §7.7]. No background motion mode is added in v1.
struct SystemScreenSleepController: ScreenSleepController {
    /// Where the idle timer lives. Nil means the running app.
    private let host: (@MainActor @Sendable () -> IdleTimerHost?)?

    /// - Parameter host: a stand-in for tests. The app-wide flag is shared by
    ///   every test that runs a real recorder, so asserting against it races
    ///   them; asserting against a stand-in does not.
    init(host: (@MainActor @Sendable () -> IdleTimerHost?)? = nil) {
        self.host = host
    }

    func preventSleep() async {
        await MainActor.run { resolvedHost()?.isIdleTimerDisabled = true }
    }

    func allowSleep() async {
        await MainActor.run { resolvedHost()?.isIdleTimerDisabled = false }
    }

    @MainActor
    private func resolvedHost() -> IdleTimerHost? {
        host?() ?? Self.runningApplication()
    }

    /// The running app, which is what holds the real idle timer.
    @MainActor
    static func runningApplication() -> IdleTimerHost? {
        #if canImport(UIKit)
        UIApplication.shared
        #else
        nil
        #endif
    }
}

/// Anything with an idle timer to hold down: `UIApplication` in the app.
@MainActor
protocol IdleTimerHost: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

#if canImport(UIKit)
extension UIApplication: IdleTimerHost {}
#endif
