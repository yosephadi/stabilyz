import Foundation

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
    /// The production graph.
    ///
    /// Slots whose concrete implementation has not been built yet are filled
    /// with the conformances in `UnwiredDependencies.swift`, each naming the
    /// task that replaces it. As those tasks land, swap the value here — no
    /// call site changes.
    static func live() -> AppDependencies {
        AppDependencies(
            logService: OSLogService(),
            clock: SystemClock(),
            fileIO: FileManagerFileIO(),
            randomSource: UnwiredRandomSource(),               // Task 10.1.1
            motionSensor: UnwiredMotionSensorService(),        // Task 4.1.1
            pedometer: UnwiredPedometerService(),              // Task 4.1.2
            audioFeedback: SilentAudioFeedbackService(),       // Task 7.1.1
            keyDerivation: UnwiredKeyDerivation(),             // Task 10.1.1
            secureArchive: UnwiredSecureArchiveCoding(),       // Task 10.1.2
            userProfileRepository: UnwiredUserProfileRepository(),  // Task 3.2.3
            gaitSessionRepository: UnwiredGaitSessionRepository(),  // Task 3.2.1
            baselineRepository: UnwiredBaselineRepository()         // Task 3.2.2
        )
    }
}
