import Foundation
import SwiftData
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
            logService: OSLogService(subsystem: "com.stabilyz.tests"),
            clock: clock,
            fileIO: FileManagerFileIO(),
            randomSource: StubRandomSource(),
            motionSensor: UnwiredMotionSensorService(),
            pedometer: UnwiredPedometerService(),
            audioFeedback: SilentAudioFeedbackService(),
            keyDerivation: UnwiredKeyDerivation(),
            secureArchive: UnwiredSecureArchiveCoding(),
            sessionRecorder: SessionRecorder(
                motionSensor: UnwiredMotionSensorService(),
                pedometer: UnwiredPedometerService(),
                audioFeedback: SilentAudioFeedbackService(),
                interruptionObserver: SystemSessionInterruptionObserver(audioFeedback: SilentAudioFeedbackService()),
                screenSleep: SystemScreenSleepController(),
                clock: clock,
                logService: OSLogService(subsystem: "com.stabilyz.tests"),
                fileIO: FileManagerFileIO()
            ),
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

@Test func liveGraphSuppliesRealClockAndFileIO() throws {
    let dependencies = AppDependencies.live(container: try StoreContainer.make(inMemory: true))

    #expect(dependencies.clock.uptime > 0)
    // Wall clock and uptime are independent timebases (docs/07 §7.4).
    #expect(dependencies.clock.now.timeIntervalSince1970 > 1_600_000_000)
    #expect(dependencies.fileIO.temporaryDirectory().isFileURL)
    // EPIC 3 landed: the live graph now uses the SwiftData repositories.
    #expect(dependencies.gaitSessionRepository is SwiftDataGaitSessionRepository)
    #expect(dependencies.baselineRepository is SwiftDataBaselineRepository)
    #expect(dependencies.userProfileRepository is SwiftDataUserProfileRepository)
}

@Test func bothLiveGraphsPlayRealAudio() throws {
    // The EPIC 7 audit finding this pins: the whole audio epic was built,
    // tested and unreachable, because `live()` still held the silent double and
    // every audio test constructed the engine directly. A green suite said
    // nothing about whether the shipped app made a sound.
    let live = AppDependencies.live(container: try StoreContainer.make(inMemory: true))
    #expect(live.audioFeedback is EngineAudioFeedbackService)

    // The degraded graph too. A store that will not open says nothing about the
    // audio route, and this is the graph a user is most likely to be looking at
    // when they need the rest of the app to behave normally.
    let degraded = AppDependencies.storeUnavailable()
    #expect(degraded.audioFeedback is EngineAudioFeedbackService)

    // Not asserted here, but the reason `live()` binds the service to a `let`
    // and hands that one value to both the recorder and the interruption
    // observer: this type solely owns the `AVAudioSession` (docs/10 §10.2), so
    // a second instance would be a second writer to one piece of system state.
}

// MARK: - Unwired slots fail loudly

@Test func unwiredMotionServiceReportsUnavailableAndRefusesToStart() async throws {
    let service = UnwiredMotionSensorService()

    #expect(await service.isAvailable == false)
    #expect(await service.authorizationStatus == .notDetermined)

    await #expect(throws: DependencyNotWired.self) {
        _ = try await service.start(policy: AlgorithmConfiguration.v1.motionAcquisition)
    }
}

@Test func storeUnavailableRepositoriesThrowRatherThanReportingEmptyData() async throws {
    // When the store cannot be opened the app runs degraded, but a repository
    // read must fail loudly rather than look like "no sessions yet".
    let dependencies = AppDependencies.storeUnavailable()

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
    let dependencies = AppDependencies.storeUnavailable()

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
