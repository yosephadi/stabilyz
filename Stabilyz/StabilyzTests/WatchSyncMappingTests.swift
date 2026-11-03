import Foundation
import Testing
@testable import Stabilyz

/// `TestMode` ↔ wire mapping (Task 12.1.2). The only place the domain mode
/// meets the watch contract.
@Suite struct WatchSyncMappingTests {
    @Test(arguments: TestMode.allCases)
    func everyModeRoundTripsThroughTheWire(_ mode: TestMode) {
        #expect(WireTestMode(mode).testMode == mode)
    }

    @Test func theMappingIsOneToOne() {
        let wire = TestMode.allCases.map(WireTestMode.init)
        #expect(Set(wire) == Set(WireTestMode.allCases))
        #expect(wire.count == WireTestMode.allCases.count)
    }

    @Test func durationsMatchTheAdvertisedLengths() {
        #expect(WatchSyncMapping.durationSeconds(for: .quickTest) == 120)
        #expect(WatchSyncMapping.durationSeconds(for: .fullTest) == 360)
        for mode in TestMode.allCases {
            #expect(.seconds(WatchSyncMapping.durationSeconds(for: mode)) == mode.advertisedDuration)
        }
    }
}
