import Foundation
import Testing
@testable import Stabilyz

/// Who plays the session haptics, and when the phone steps in (Task 12.3.1,
/// PRD §8 decision 3).
@Suite struct HapticOwnershipTests {
    @Test func onlyAReachableWatchOwnsTheHaptics() {
        #expect(HapticOwner(for: .reachable) == .watch)
        #expect(HapticOwner(for: .installedNotReachable) == .phone)
        #expect(HapticOwner(for: .unavailable) == .phone)
        #expect(HapticOwner.watch.wire == .watch)
        #expect(HapticOwner.phone.wire == .phone)
    }

    @Test func thePhonePlaysStopWhenItOwnsOrTheWatchIsGone() {
        typealias O = HapticOwnership
        #expect(O.phonePlaysStopPulse(owner: .phone, reachabilityAtStop: .reachable, hapticsOn: true))
        #expect(O.phonePlaysStopPulse(owner: .phone, reachabilityAtStop: .unavailable, hapticsOn: true))
        #expect(O.phonePlaysStopPulse(owner: .watch, reachabilityAtStop: .reachable, hapticsOn: true) == false)
        #expect(O.phonePlaysStopPulse(owner: .watch, reachabilityAtStop: .installedNotReachable, hapticsOn: true))
        #expect(O.phonePlaysStopPulse(owner: .watch, reachabilityAtStop: .unavailable, hapticsOn: true))
        for owner in [HapticOwner.phone, .watch] {
            for reachability in [WatchReachability.reachable, .installedNotReachable, .unavailable] {
                #expect(O.phonePlaysStopPulse(owner: owner, reachabilityAtStop: reachability, hapticsOn: false) == false)
            }
        }
    }

    @Test func thePhonePlaysGoOnlyWhenTheOwningWatchMissedIt() {
        typealias O = HapticOwnership
        #expect(O.phonePlaysGoFallback(owner: .watch, startedDelivery: .notDelivered, hapticsOn: true))
        #expect(O.phonePlaysGoFallback(owner: .watch, startedDelivery: .delivered, hapticsOn: true) == false)
        // When the phone owns, it already played Go itself.
        #expect(O.phonePlaysGoFallback(owner: .phone, startedDelivery: .notDelivered, hapticsOn: true) == false)
        #expect(O.phonePlaysGoFallback(owner: .watch, startedDelivery: .notDelivered, hapticsOn: false) == false)
    }

    @Test func theMockConfirmsDeliveryOnlyWhenReachable() async {
        let mock = MockWatchSessionService(reachability: .reachable)
        #expect(await mock.send(.hapticsChanged(enabled: true)) == .delivered)
        #expect(await mock.currentReachability() == .reachable)
        mock.setReachability(.installedNotReachable)
        #expect(await mock.send(.hapticsChanged(enabled: true)) == .notDelivered)
        #expect(await mock.currentReachability() == .installedNotReachable)
        #expect(await SilentWatchSessionService().send(.hapticsChanged(enabled: true)) == .notDelivered)
        #expect(await SilentWatchSessionService().currentReachability() == .unavailable)
    }
}
