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
    func preventSleep() async {
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        #endif
    }

    func allowSleep() async {
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }
}
