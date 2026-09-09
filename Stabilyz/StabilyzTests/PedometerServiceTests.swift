import CoreMotion
import Foundation
import Testing
@testable import Stabilyz

private final class SilentPedometerLog: LogService {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

// NOTE: no test here touches CMPedometer. Any call into it — including
// `CMPedometer.isStepCountingAvailable()` — terminates the process with
// "attempted to access privacy-sensitive data without a usage description"
// until NSMotionUsageDescription is present in the app target's Info.plist.
// That is an .xcodeproj change (INFOPLIST_KEY_NSMotionUsageDescription), which
// CLAUDE.md reserves for the user. Availability, priming and streaming
// behaviour stay untested until then; docs/19 §19.4 already classes the
// pedometer as device-only validation.

@Test func pedometerEventsMapOntoTheSessionTimeline() {
    // docs/07 §7.2, §7.4: pedometer events sit on the same timeline as samples,
    // and every optional field stays optional rather than defaulting to zero.
    let timestamp = Date(timeIntervalSince1970: 1_700_000_120)
    let event = PedometerEvent(steps: 210, cadence: 1.75, pace: 0.8, distance: 180, timestamp: timestamp)

    #expect(event.steps == 210)
    #expect(event.cadence == 1.75)
    #expect(event.pace == 0.8)
    #expect(event.distance == 180)
    #expect(event.timestamp == timestamp)
}

@Test func missingPedometerFieldsStayNilRatherThanZero() {
    // A zero cadence would be a measurement; nil says the device did not report.
    let event = PedometerEvent(steps: 42, timestamp: Date(timeIntervalSince1970: 0))

    #expect(event.cadence == nil)
    #expect(event.pace == nil)
    #expect(event.distance == nil)
    #expect(event.steps == 42)
}
