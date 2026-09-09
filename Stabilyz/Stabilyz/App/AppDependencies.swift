import Foundation
import SwiftData

/// The single composition root (docs/12-dependency-injection.md §12.1, §12.3).
///
/// A plain struct of protocol-typed slots, built once in `StabilyzApp` and
/// passed to feature initializers. Manual constructor injection: the dependency
/// graph is small and fully static, so no DI framework is used [PRD posture:
/// minimal dependencies].
///
/// Wiring rules (docs/12 §12.3):
/// - **Only this type knows concrete implementations.** Everything else takes
///   protocols and value types.
/// - View models never reach global state; they receive what they need.
/// - Actor dependencies (`SessionRecorder`, `SessionProcessor`) are created once
///   and shared, then restarted per session via lifecycle methods. They join
///   this struct in Tasks 4.2.2 and 5.1.1.
///
/// Tests build one of these from doubles; there is no singleton and no
/// environment-wide service lookup.
nonisolated struct AppDependencies: Sendable {
    // Observability
    let logService: LogService

    // Utilities
    let clock: Clock
    let fileIO: FileIO
    let randomSource: RandomSource

    // Services
    let motionSensor: MotionSensorService
    let pedometer: PedometerService
    let audioFeedback: AudioFeedbackService
    let keyDerivation: KeyDerivation
    let secureArchive: SecureArchiveCoding

    // Persistence
    let userProfileRepository: UserProfileRepository
    let gaitSessionRepository: GaitSessionRepository
    let baselineRepository: BaselineRepository

    init(
        logService: LogService,
        clock: Clock,
        fileIO: FileIO,
        randomSource: RandomSource,
        motionSensor: MotionSensorService,
        pedometer: PedometerService,
        audioFeedback: AudioFeedbackService,
        keyDerivation: KeyDerivation,
        secureArchive: SecureArchiveCoding,
        userProfileRepository: UserProfileRepository,
        gaitSessionRepository: GaitSessionRepository,
        baselineRepository: BaselineRepository
    ) {
        self.logService = logService
        self.clock = clock
        self.fileIO = fileIO
        self.randomSource = randomSource
        self.motionSensor = motionSensor
        self.pedometer = pedometer
        self.audioFeedback = audioFeedback
        self.keyDerivation = keyDerivation
        self.secureArchive = secureArchive
        self.userProfileRepository = userProfileRepository
        self.gaitSessionRepository = gaitSessionRepository
        self.baselineRepository = baselineRepository
    }
}

extension AppDependencies {
    /// The production graph, backed by the SwiftData store.
    ///
    /// Slots whose concrete implementation has not been built yet are filled
    /// with the conformances in `UnwiredDependencies.swift`, each naming the
    /// task that replaces it. As those tasks land, swap the value here — no
    /// call site changes.
    static func live(container: ModelContainer) -> AppDependencies {
        let reader = StoreReader(modelContainer: container)
        let writer = StoreWriter(modelContainer: container)

        return AppDependencies(
            logService: OSLogService(),
            clock: SystemClock(),
            fileIO: FileManagerFileIO(),
            randomSource: UnwiredRandomSource(),               // Task 10.1.1
            motionSensor: UnwiredMotionSensorService(),        // Task 4.1.1
            pedometer: UnwiredPedometerService(),              // Task 4.1.2
            audioFeedback: SilentAudioFeedbackService(),       // Task 7.1.1
            keyDerivation: UnwiredKeyDerivation(),             // Task 10.1.1
            secureArchive: UnwiredSecureArchiveCoding(),       // Task 10.1.2
            userProfileRepository: SwiftDataUserProfileRepository(reader: reader, writer: writer),
            gaitSessionRepository: SwiftDataGaitSessionRepository(reader: reader, writer: writer),
            baselineRepository: SwiftDataBaselineRepository(reader: reader, writer: writer)
        )
    }

    /// Builds the store and the production graph.
    static func live() throws -> AppDependencies {
        live(container: try StoreContainer.make())
    }

    /// The graph used when the store cannot be opened at launch.
    ///
    /// The app still runs; every repository call fails loudly rather than
    /// reporting empty data, which would read as "no sessions yet" and could
    /// misreport baseline progress. Surfacing this as a user-facing recovery
    /// path belongs to app-level persistence error handling (docs/15 §15.1).
    static func storeUnavailable() -> AppDependencies {
        AppDependencies(
            logService: OSLogService(),
            clock: SystemClock(),
            fileIO: FileManagerFileIO(),
            randomSource: UnwiredRandomSource(),
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
