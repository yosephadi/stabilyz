import Foundation
import Testing
@testable import Stabilyz

/// The phone's side of the watch companion (Task 12.1.1, docs/04 §4.18).
///
/// `WatchConnectivityService` itself cannot run here — `WCSession` cannot be
/// paired on a simulator — so its decisions are tested through the static
/// functions it delegates to, and the rest waits for a real watch
/// (Task 12.6.1).

private let sessionA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let sessionB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

/// The first `count` values of a stream, or fewer if it finishes first.
private func first<Value>(_ count: Int, of stream: AsyncStream<Value>) async -> [Value] {
    var values: [Value] = []
    for await value in stream {
        values.append(value)
        if values.count == count { break }
    }
    return values
}

// MARK: - Broadcast

@Suite struct WatchEventBroadcastTests {
    @Test func aReplayingBroadcastGivesANewSubscriberTheLatestValue() async {
        let broadcast = WatchEventBroadcast<WatchReachability>(initial: .unavailable, replaysLatest: true)
        #expect(await first(1, of: broadcast.subscribe()) == [.unavailable])

        broadcast.publish(.reachable)
        #expect(await first(1, of: broadcast.subscribe()) == [.reachable])
    }

    @Test func everySubscriberReceivesEveryValue() async {
        let broadcast = WatchEventBroadcast<WatchReachability>(initial: .unavailable, replaysLatest: true)
        let one = broadcast.subscribe()
        let two = broadcast.subscribe()

        broadcast.publish(.installedNotReachable)
        broadcast.publish(.reachable)

        let expected: [WatchReachability] = [.unavailable, .installedNotReachable, .reachable]
        #expect(await first(3, of: one) == expected)
        #expect(await first(3, of: two) == expected)
    }

    /// A Stop that arrived before anyone listened must never reach a listener
    /// that arrived later — it would stop the wrong walk.
    @Test func aNonReplayingBroadcastNeverDeliversAPastValue() async {
        let broadcast = WatchEventBroadcast<WatchStopRequest>(replaysLatest: false)
        broadcast.publish(WatchStopRequest(sessionID: sessionA))

        let late = broadcast.subscribe()
        broadcast.publish(WatchStopRequest(sessionID: sessionB))
        #expect(await first(1, of: late) == [WatchStopRequest(sessionID: sessionB)])
    }

    @Test func finishingEndsCurrentAndFutureStreams() async {
        let broadcast = WatchEventBroadcast<WatchReachability>(initial: .reachable, replaysLatest: true)
        let current = broadcast.subscribe()
        broadcast.finish()

        #expect(await first(5, of: current) == [.reachable])
        #expect(await first(5, of: broadcast.subscribe()) == [.reachable])
        #expect(broadcast.subscriberCount == 0)
    }

    @Test func aCancelledSubscriberIsForgotten() async {
        let broadcast = WatchEventBroadcast<WatchStopRequest>(replaysLatest: false)
        let task = Task { for await _ in broadcast.subscribe() {} }
        while broadcast.subscriberCount == 0 { await Task.yield() }

        task.cancel()
        await task.value
        #expect(broadcast.subscriberCount == 0)
    }
}

// MARK: - Doubles

@Suite struct WatchSessionDoubleTests {
    @Test func theMockRecordsSendsInOrder() async {
        let mock = MockWatchSessionService()
        let messages: [PhoneToWatchMessage] = [
            .countdownStarted(sessionID: sessionA, mode: .quick, durationSeconds: 120,
                              plannedGoAt: Date(timeIntervalSince1970: 10), hapticOwner: .watch, hapticsEnabled: true),
            .started(sessionID: sessionA, t0: Date(timeIntervalSince1970: 10.01)),
            .hapticsChanged(enabled: false),
            .stopped(sessionID: sessionA),
        ]
        for message in messages { await mock.send(message) }
        #expect(mock.sentMessages == messages)
    }

    @Test func theMockDrivesReachabilityForEveryListener() async {
        let mock = MockWatchSessionService(reachability: .installedNotReachable)
        let indicator = mock.reachability()
        let countdown = mock.reachability()
        mock.setReachability(.reachable)

        #expect(await first(2, of: indicator) == [.installedNotReachable, .reachable])
        #expect(await first(2, of: countdown) == [.installedNotReachable, .reachable])
    }

    @Test func theMockDeliversStopRequests() async {
        let mock = MockWatchSessionService()
        let stops = mock.stopRequests()
        mock.deliverStopRequest(sessionID: sessionA)
        #expect(await first(1, of: stops) == [WatchStopRequest(sessionID: sessionA)])
    }

    @Test func theSilentDoubleIsThePhoneOnlyExperience() async {
        let silent = SilentWatchSessionService()
        await silent.send(.stopped(sessionID: sessionA))
        #expect(await first(5, of: silent.reachability()) == [.unavailable])
        #expect(await first(5, of: silent.stopRequests()).isEmpty)
    }
}

// MARK: - Live service decisions

@Suite struct WatchConnectivityDecisionTests {
    @Test func reachabilityNeedsAnActivatedPairedInstalledWatch() {
        typealias S = WatchConnectivityService
        #expect(S.reachability(isActivated: true, isPaired: true, isWatchAppInstalled: true, isReachable: true) == .reachable)
        #expect(S.reachability(isActivated: true, isPaired: true, isWatchAppInstalled: true, isReachable: false) == .installedNotReachable)
        #expect(S.reachability(isActivated: true, isPaired: true, isWatchAppInstalled: false, isReachable: false) == .unavailable)
        #expect(S.reachability(isActivated: true, isPaired: false, isWatchAppInstalled: false, isReachable: false) == .unavailable)
        // Reachable means nothing before activation completes.
        #expect(S.reachability(isActivated: false, isPaired: true, isWatchAppInstalled: true, isReachable: true) == .unavailable)
    }

    @Test func aStopRequestIsReadFromALiveMessage() throws {
        let data = try WatchSyncCoder.encode(WatchToPhoneMessage.stopRequest(sessionID: sessionA))
        #expect(WatchConnectivityService.stopRequest(from: [WatchSyncKeys.message: data]) == WatchStopRequest(sessionID: sessionA))
    }

    @Test func anythingElseIsNotAStopRequest() throws {
        let phoneDirection = try WatchSyncCoder.encode(PhoneToWatchMessage.stopped(sessionID: sessionA))
        let otherVersion = try WatchSyncCoder.encode(WatchToPhoneMessage.stopRequest(sessionID: sessionA), version: 2)
        let valid = try WatchSyncCoder.encode(WatchToPhoneMessage.stopRequest(sessionID: sessionA))

        #expect(WatchConnectivityService.stopRequest(from: [:]) == nil)
        #expect(WatchConnectivityService.stopRequest(from: [WatchSyncKeys.message: "stop"]) == nil)
        #expect(WatchConnectivityService.stopRequest(from: ["other": valid]) == nil)
        #expect(WatchConnectivityService.stopRequest(from: [WatchSyncKeys.message: phoneDirection]) == nil)
        #expect(WatchConnectivityService.stopRequest(from: [WatchSyncKeys.message: otherVersion]) == nil)
    }
}

// MARK: - Application context

@Suite struct WatchSyncContextTests {
    private func record(_ messages: [PhoneToWatchMessage]) throws -> WatchSyncContext {
        var context = WatchSyncContext()
        for message in messages {
            context.record(message, encoded: try WatchSyncCoder.encode(message))
        }
        return context
    }

    private func decoded(_ context: WatchSyncContext) -> (state: PhoneToWatchMessage?, haptics: PhoneToWatchMessage?) {
        let dictionary = context.dictionary
        return (
            (dictionary[WatchSyncKeys.sessionState] as? Data).flatMap(WatchSyncCoder.decodePhoneToWatch),
            (dictionary[WatchSyncKeys.haptics] as? Data).flatMap(WatchSyncCoder.decodePhoneToWatch)
        )
    }

    private let countdown = PhoneToWatchMessage.countdownStarted(
        sessionID: sessionA, mode: .full, durationSeconds: 360,
        plannedGoAt: Date(timeIntervalSince1970: 100), hapticOwner: .watch, hapticsEnabled: true
    )

    @Test func anEmptyContextIsAnEmptyDictionary() {
        #expect(WatchSyncContext().dictionary.isEmpty)
    }

    @Test func theLatestSessionStateWins() throws {
        let started = PhoneToWatchMessage.started(sessionID: sessionA, t0: Date(timeIntervalSince1970: 100.002))
        let context = try record([countdown, started])
        #expect(decoded(context).state == started)
        #expect(decoded(context).haptics == nil)
    }

    /// The reason this type exists: a haptics change mid-walk must not erase
    /// the fact that a walk is running.
    @Test func aHapticsChangeDoesNotOverwriteTheSessionState() throws {
        let started = PhoneToWatchMessage.started(sessionID: sessionA, t0: Date(timeIntervalSince1970: 100.002))
        let context = try record([countdown, started, .hapticsChanged(enabled: false)])
        #expect(decoded(context).state == started)
        #expect(decoded(context).haptics == .hapticsChanged(enabled: false))
    }

    @Test func aNewCountdownClearsTheEarlierHapticsChange() throws {
        let context = try record([.hapticsChanged(enabled: false), .stopped(sessionID: sessionB), countdown])
        #expect(decoded(context).state == countdown)
        #expect(decoded(context).haptics == nil)
        #expect(context.dictionary[WatchSyncKeys.haptics] == nil)
    }

    @Test func stoppedAndCancelledReplaceTheState() throws {
        #expect(decoded(try record([countdown, .cancelled(sessionID: sessionA)])).state == .cancelled(sessionID: sessionA))
        #expect(decoded(try record([countdown, .stopped(sessionID: sessionA)])).state == .stopped(sessionID: sessionA))
    }
}

// MARK: - Composition root

@Suite struct WatchSessionWiringTests {
    @Test func bothProductionGraphsTalkToTheWatch() throws {
        let live = AppDependencies.live(container: try StoreContainer.make(inMemory: true))
        #expect(live.watchSession is WatchConnectivityService)

        // The store failing to open says nothing about the watch.
        #expect(AppDependencies.storeUnavailable().watchSession is WatchConnectivityService)
    }

    @Test func anOverrideReplacesTheWatchLink() throws {
        var overrides = LiveOverrides()
        overrides.watchSession = SilentWatchSessionService()
        let live = AppDependencies.live(container: try StoreContainer.make(inMemory: true), overrides: overrides)
        #expect(live.watchSession is SilentWatchSessionService)
    }
}
