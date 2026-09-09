import CoreMotion
import Foundation
import Testing
@testable import Stabilyz

private struct FixedClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let uptime: TimeInterval = 1_000
}

private final class SilentLog: LogService {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private func makeService() -> CoreMotionSensorService {
    CoreMotionSensorService(clock: FixedClock(), logService: SilentLog(), primingBudget: .milliseconds(200))
}

// MARK: - Authorization mapping (pure, testable without hardware)

@Test func authorizationStatusMapsEveryCoreMotionCase() {
    #expect(CoreMotionSensorService.mapAuthorization(.notDetermined) == .notDetermined)
    #expect(CoreMotionSensorService.mapAuthorization(.authorized) == .authorized)
    #expect(CoreMotionSensorService.mapAuthorization(.denied) == .denied)
    #expect(CoreMotionSensorService.mapAuthorization(.restricted) == .restricted)
}

// MARK: - Availability

@Test func serviceReportsAvailabilityFromTheHardware() async {
    // docs/19 §19.4: the simulator has no accelerometer, so this is the
    // "sensor absent" path — the one the degraded Start button copy relies on.
    let service = makeService()
    let available = await service.isAvailable

    if !available {
        await #expect(throws: StabilyzError.sensor(.unavailable)) {
            _ = try await service.start(policy: AlgorithmConfiguration.v1.motionAcquisition)
        }
    }
}

@Test func startFailsFastRatherThanRecordingNothing() async {
    // docs/07 §7.3: priming failure is a plain-language error, never silence.
    let service = makeService()

    do {
        _ = try await service.start(policy: AlgorithmConfiguration.v1.motionAcquisition)
        // Hardware present: stop cleanly so the test leaves nothing running.
        await service.stop()
    } catch let error as StabilyzError {
        #expect(error == .sensor(.unavailable) || error == .sensor(.primingTimeout))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func stopIsSafeWhenNothingIsRunning() async {
    let service = makeService()
    await service.stop()
    await service.stop()
}

// MARK: - Sample conversion

@Test func samplesCarryTheStartAnchorAndDeviceTimebase() {
    // docs/07 §7.4: deviceTimestamp is device uptime, the monotonic clock all
    // durations come from; the anchor pair is captured once at start.
    let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_200)
    let sample = SensorSample(
        deviceTimestamp: 1_234.5,
        anchor: anchor,
        acceleration: Vector3(x: 0.1, y: -0.2, z: 0.98),
        gravity: Vector3(x: 0, y: 0, z: -1)
    )

    #expect(sample.anchor == anchor)
    #expect(sample.deviceTimestamp == 1_234.5)
    #expect(sample.gravity != nil)
}

@Test func accelerometerOnlySamplesCarryNoGravity() {
    // Gravity is only available with device-motion updates enabled.
    let sample = SensorSample(
        deviceTimestamp: 1,
        anchor: TimeAnchor(wallClock: Date(timeIntervalSince1970: 0), uptime: 0),
        acceleration: Vector3(x: 0, y: 0, z: 0)
    )
    #expect(sample.gravity == nil)
}
