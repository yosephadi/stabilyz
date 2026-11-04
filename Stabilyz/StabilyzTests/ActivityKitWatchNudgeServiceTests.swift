import ActivityKit
import Foundation
import Testing
@testable import Stabilyz

/// The launch cleanup ends a nudge of either type left by an earlier launch
/// (Task 12.5.1). Runs against ActivityKit on the simulator.
@MainActor @Suite(.serialized) struct ActivityKitWatchNudgeServiceTests {
    private let service = ActivityKitWatchNudgeService(logService: OSLogService())

    @Test func endingClearsLeftoversOfBothTypes() async throws {
        await service.end()
        try #require(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities are off on this simulator")

        // Leftovers of both kinds, as an iOS 17 launch and an iOS 18 launch
        // would each leave.
        _ = try Activity.request(
            attributes: WatchNudgeAttributes(),
            content: ActivityContent(state: .init(), staleDate: nil),
            pushType: nil
        )
        _ = try Activity.request(
            attributes: WatchNudgeSmartStackAttributes(),
            content: ActivityContent(state: .init(), staleDate: nil),
            pushType: nil
        )
        #expect(Activity<WatchNudgeAttributes>.activities.count == 1)
        #expect(Activity<WatchNudgeSmartStackAttributes>.activities.count == 1)

        await service.end()

        #expect(Activity<WatchNudgeAttributes>.activities.allSatisfy { $0.activityState != .active })
        #expect(Activity<WatchNudgeSmartStackAttributes>.activities.allSatisfy { $0.activityState != .active })
    }

    @Test func showingRequestsTheSmartStackTypeOnIOS18() async throws {
        await service.end()
        try #require(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities are off on this simulator")

        await service.show()
        await service.show()
        #expect(Activity<WatchNudgeSmartStackAttributes>.activities.filter { $0.activityState == .active }.count == 1)
        #expect(Activity<WatchNudgeAttributes>.activities.filter { $0.activityState == .active }.isEmpty)

        await service.end()
    }
}
