import Foundation
import Testing
@testable import Stabilyz

// MARK: - Doubles

private struct FixedClock: Clock {
    let now: Date
    let uptime: TimeInterval
}

private struct StubRandomSource: RandomSource {
    func bytes(count: Int) throws -> [UInt8] { Array(repeating: 0xAB, count: count) }
}

private extension AppDependencies {
    /// A graph built entirely from doubles, proving the composition root is
    /// constructible without any Apple framework backing (docs/19 §19.4).
    static func testDouble(clock: Clock = FixedClock(now: Date(timeIntervalSince1970: 0), uptime: 0)) -> AppDependencies {
        AppDependencies(
            clock: clock,
            fileIO: FileManagerFileIO(),
            randomSource: StubRandomSource(),
            motionSensor: UnwiredMotionSensorService(),
            pedometer: UnwiredPedometerService(),
            audioFeedback: SilentAudioFeedbackService(),
            keyDerivation: UnwiredKeyDerivation(),
            secureArchive: UnwiredSecureArchiveCoding(),
            userProfileRepository: UnwiredUserProfileRepository(),
            gaitSessionRepository: UnwiredGaitSessionRepository(),
            baselineRepository: UnwiredBaselineRepository()
        )
    }
}

// MARK: - Composition root

@Test func dependenciesComposeFromDoubles() throws {
    let dependencies = AppDependencies.testDouble(
        clock: FixedClock(now: Date(timeIntervalSince1970: 1_000), uptime: 42)
    )

    #expect(dependencies.clock.now == Date(timeIntervalSince1970: 1_000))
    #expect(dependencies.clock.uptime == 42)
    #expect(try dependencies.randomSource.bytes(count: 4) == [0xAB, 0xAB, 0xAB, 0xAB])
}

@Test func liveGraphSuppliesRealClockAndFileIO() {
    let dependencies = AppDependencies.live()

    #expect(dependencies.clock.uptime > 0)
    // Wall clock and uptime are independent timebases (docs/07 §7.4).
    #expect(dependencies.clock.now.timeIntervalSince1970 > 1_600_000_000)
    #expect(dependencies.fileIO.temporaryDirectory().isFileURL)
}

// MARK: - Unwired slots fail loudly

@Test func unwiredMotionServiceReportsUnavailableAndRefusesToStart() async throws {
    let service = UnwiredMotionSensorService()

    #expect(service.isAvailable == false)
    #expect(await service.authorizationStatus == .notDetermined)

    await #expect(throws: DependencyNotWired.self) {
        _ = try await service.start(policy: .recommendedDefault)
    }
}

@Test func unwiredRepositoriesThrowRatherThanReportingEmptyData() async throws {
    let dependencies = AppDependencies.live()

    // An empty read would be indistinguishable from "no sessions yet", which
    // would silently misreport baseline progress.
    await #expect(throws: DependencyNotWired.self) {
        _ = try await dependencies.gaitSessionRepository.validSessionCount(mode: .quickTest)
    }
    await #expect(throws: DependencyNotWired.self) {
        _ = try await dependencies.baselineRepository.baseline(mode: .fullTest)
    }
    await #expect(throws: DependencyNotWired.self) {
        _ = try await dependencies.userProfileRepository.fetchProfile()
    }
}

@Test func unwiredCryptoNeverSubstitutesAStandInPrimitive() async throws {
    let dependencies = AppDependencies.live()

    #expect(throws: DependencyNotWired.self) {
        _ = try dependencies.randomSource.bytes(count: 16)
    }
    await #expect(throws: DependencyNotWired.self) {
        _ = try await dependencies.secureArchive.seal(payload: Data(), passphrase: [])
    }
}

@Test func silentAudioServiceIsAnAcceptedDegradedState() async {
    // Audio failure must never fail a session (docs/10 §10.4), so every call is
    // a no-op and the event stream simply completes.
    let service = SilentAudioFeedbackService()
    await service.playStartTone()
    await service.startMetronome(bpm: 108)
    await service.playStopTone()

    var events: [AudioFeedbackEvent] = []
    for await event in service.events { events.append(event) }
    #expect(events.isEmpty)
}

@Test func dependencyNotWiredNamesTheOwningTask() {
    let error = DependencyNotWired(dependency: "BaselineRepository", owningTask: "3.2.2")
    #expect(error.description == "BaselineRepository is not wired yet — supplied by Task 3.2.2.")
}

// MARK: - Live FileIO

@Test func fileIORoundTripsThroughTheTemporaryDirectory() throws {
    let fileIO = FileManagerFileIO()
    let url = fileIO.temporaryDirectory().appendingPathComponent("\(UUID().uuidString).stabilyz")
    let copy = fileIO.temporaryDirectory().appendingPathComponent("\(UUID().uuidString).stabilyz")
    defer {
        try? fileIO.remove(at: url)
        try? fileIO.remove(at: copy)
    }

    #expect(fileIO.fileExists(at: url) == false)

    let payload = Data("STBLYZ".utf8)
    try fileIO.write(payload, to: url)
    #expect(fileIO.fileExists(at: url))
    #expect(try fileIO.read(from: url) == payload)

    // Snapshot copy, as the restore path needs (docs/13 §13.5).
    try fileIO.copyItem(at: url, to: copy)
    #expect(try fileIO.read(from: copy) == payload)

    try fileIO.remove(at: url)
    #expect(fileIO.fileExists(at: url) == false)
}
