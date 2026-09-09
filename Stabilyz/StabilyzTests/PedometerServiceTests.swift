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

@Test func pedometerReportsAvailabilityAndRefusesToStartWithout() async {
    // Availability is a device fact. On the simulator step counting is absent,
    // which is a legitimate outcome, not a failure — it is the path the
    // degraded Start button copy depends on (docs/07 §7.6, docs/19 §19.4).
    let service = CoreMotionPedometerService(logService: SilentPedometerLog())
    let available = await service.isAvailable

    if available {
        let stream = try? await service.start()
        #expect(stream != nil)
        await service.stop()
    } else {
        await #expect(throws: StabilyzError.sensor(.unavailable)) {
            _ = try await service.start()
        }
        await #expect(throws: StabilyzError.sensor(.unavailable)) {
            _ = try await service.events(from: Date(timeIntervalSinceNow: -60), to: Date())
        }
    }
}

@Test func pedometerStopIsSafeWhenNothingIsRunning() async {
    let service = CoreMotionPedometerService(logService: SilentPedometerLog())
    await service.stop()
    await service.stop()
}

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
