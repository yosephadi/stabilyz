import ActivityKit
import Foundation

/// The nudge as an ActivityKit Live Activity (Task 12.5.1). Its UI lives in
/// StabilyzLiveActivityExtension.
///
/// Holds no state: what is showing is whatever ActivityKit lists, so a nudge
/// left by a terminated launch is found and ended like any other.
struct ActivityKitWatchNudgeService: WatchNudgeService {
    let logService: LogService

    func show() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logService.log(.info, .session, "watch nudge: Live Activities are off")
            return
        }
        do {
            if #available(iOS 18.0, *) {
                guard Activity<WatchNudgeSmartStackAttributes>.activities.isEmpty else { return }
                _ = try Activity.request(
                    attributes: WatchNudgeSmartStackAttributes(),
                    content: ActivityContent(state: .init(), staleDate: nil),
                    pushType: nil
                )
            } else {
                guard Activity<WatchNudgeAttributes>.activities.isEmpty else { return }
                _ = try Activity.request(
                    attributes: WatchNudgeAttributes(),
                    content: ActivityContent(state: .init(), staleDate: nil),
                    pushType: nil
                )
            }
            logService.log(.info, .session, "watch nudge: shown")
        } catch {
            logService.log(.error, .session, "watch nudge: could not be shown")
        }
    }

    func end() async {
        for activity in Activity<WatchNudgeAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if #available(iOS 18.0, *) {
            for activity in Activity<WatchNudgeSmartStackAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
