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
struct AppDependencies: Sendable {
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
    /// The countdown's haptic channel ([PRD OQ-6], Task 7.3.1). Separate from
    /// `audioFeedback` because it is: haptics never touch the audio session and
    /// never route through an audio device (docs/07 §7.1).
    let hapticFeedback: HapticFeedbackService
    let keyDerivation: KeyDerivation
    let secureArchive: SecureArchiveCoding

    /// Actor dependency: created once and shared, restarted per session via
    /// its lifecycle methods rather than recreated (docs/12 §12.3).
    let sessionRecorder: SessionRecorder

    /// Turns a frozen recording into a committed session (docs/08, docs/11 §11.3).
    ///
    /// **Nil when the store could not be opened.** Unlike the repositories,
    /// this cannot be stood up as a loudly-failing stand-in: it is built from
    /// concrete `StoreReader`/`StoreWriter`, which need a container there is
    /// none of. Nil is the honest answer — a session genuinely cannot be
    /// committed — and the session flow surfaces it as a persistence failure
    /// rather than recording a walk it can never save.
    let sessionOutcomes: SessionOutcomeService?

    /// Whether the onboarding wizard has something to resume (docs/04 §4.1).
    /// Task 8.1.2 replaces the empty store with the real UserDefaults-backed one.
    let onboardingDrafts: OnboardingDraftStore

    // Persistence
    let userProfileRepository: UserProfileRepository
    let gaitSessionRepository: GaitSessionRepository
    let baselineRepository: BaselineRepository

    /// Replaces the store from a staged export (Task 10.3.4).
    ///
    /// **Nil when the store could not be opened**, for the reason
    /// `sessionOutcomes` is: there is no container to replace into.
    let archiveRestorer: ArchiveRestoring?

    /// Whether the Walk tab's backup prompt was dismissed or an export
    /// completed (Task 10.2.3). Device state, not store data.
    let exportNudgeStore: ExportNudgeStore

    /// Published after a successful restore, so long-lived view models reload
    /// rather than show data that no longer exists (docs/11 §11.4–11.5).
    let storeEvents: StoreReplacementEvents

    /// Puts the store back if a restore was interrupted (Task 10.3.5). The
    /// router runs it before its first store read at launch.
    ///
    /// **Nil when the store could not be opened**: there is nothing to recover
    /// into, and the staging waits for a launch that has a store.
    let restoreRecovery: RestoreRecovering?

    #if DEBUG
    /// DEBUG-only handle for `DebugDataReset` (docs/design/dev-notes.md).
    ///
    /// Assigned after construction rather than through `init` on purpose: Swift
    /// does not allow `#if` inside a parameter list, and a debug-only parameter
    /// would otherwise have to exist in release signatures to keep call sites
    /// compiling. `nil` in the degraded graph, where there is no store to erase.
    var debugStoreWriter: StoreWriter?

    /// UI tests only: the file Welcome's Restore opens instead of presenting the
    /// system document picker, which runs out of process and cannot be driven
    /// deterministically (Task 11.1.1).
    var uiTestingRestoreFile: URL?
    #endif

    init(
        logService: LogService,
        clock: Clock,
        fileIO: FileIO,
        randomSource: RandomSource,
        motionSensor: MotionSensorService,
        pedometer: PedometerService,
        audioFeedback: AudioFeedbackService,
        hapticFeedback: HapticFeedbackService = SilentHapticFeedbackService(),
        keyDerivation: KeyDerivation,
        secureArchive: SecureArchiveCoding,
        sessionRecorder: SessionRecorder,
        sessionOutcomes: SessionOutcomeService? = nil,
        onboardingDrafts: OnboardingDraftStore = EmptyOnboardingDraftStore(),
        userProfileRepository: UserProfileRepository,
        gaitSessionRepository: GaitSessionRepository,
        baselineRepository: BaselineRepository,
        archiveRestorer: ArchiveRestoring? = nil,
        exportNudgeStore: ExportNudgeStore = InMemoryExportNudgeStore(),
        storeEvents: StoreReplacementEvents = StoreReplacementEvents(),
        restoreRecovery: RestoreRecovering? = nil
    ) {
        self.logService = logService
        self.clock = clock
        self.fileIO = fileIO
        self.randomSource = randomSource
        self.motionSensor = motionSensor
        self.pedometer = pedometer
        self.audioFeedback = audioFeedback
        self.hapticFeedback = hapticFeedback
        self.keyDerivation = keyDerivation
        self.secureArchive = secureArchive
        self.sessionRecorder = sessionRecorder
        self.sessionOutcomes = sessionOutcomes
        self.onboardingDrafts = onboardingDrafts
        self.userProfileRepository = userProfileRepository
        self.gaitSessionRepository = gaitSessionRepository
        self.baselineRepository = baselineRepository
        self.archiveRestorer = archiveRestorer
        self.exportNudgeStore = exportNudgeStore
        self.storeEvents = storeEvents
        self.restoreRecovery = restoreRecovery
    }
}

/// Stand-ins for parts of the production graph, for a UI-testing launch
/// (Task 11.1.1, docs/19 §19.3). Everything left nil is the production value;
/// nothing outside a `#if DEBUG` launch path sets one.
struct LiveOverrides {
    var motionSensor: MotionSensorService?
    var pedometer: PedometerService?
    var audioFeedback: AudioFeedbackService?
    var onboardingDrafts: OnboardingDraftStore?
    var exportNudgeStore: ExportNudgeStore?
    /// Runs before the router's first store read, in place of launch recovery.
    var restoreRecovery: RestoreRecovering?

    init() {}
}

extension AppDependencies {
    /// The production graph, backed by the SwiftData store.
    ///
    /// Slots whose concrete implementation has not been built yet are filled
    /// with the conformances in `UnwiredDependencies.swift`, each naming the
    /// task that replaces it. As those tasks land, swap the value here — no
    /// call site changes.
    /// - Parameter restoreStagingDirectory: where a restore keeps its on-disk
    ///   safety net; tests point it at a scratch directory.
    static func live(
        container: ModelContainer,
        restoreStagingDirectory: URL = RestoreStagingArea.defaultDirectory,
        overrides: LiveOverrides = LiveOverrides()
    ) -> AppDependencies {
        let reader = StoreReader(modelContainer: container)
        let writer = StoreWriter(modelContainer: container)

        let logService = OSLogService()
        let clock = SystemClock()
        let fileIO = FileManagerFileIO()
        let motionSensor: MotionSensorService = overrides.motionSensor
            ?? CoreMotionSensorService(clock: clock, logService: logService)
        let pedometer: PedometerService = overrides.pedometer
            ?? CoreMotionPedometerService(logService: logService)
        // One instance, shared by the recorder and the interruption observer:
        // this type solely owns the `AVAudioSession` (docs/10 §10.2), so two of
        // them would be two writers to one piece of system state. It activates
        // nothing until `SessionRecorder` calls `prepare()` at the start of a
        // session, so constructing it here costs the launch nothing and the app
        // holds no audio route while the user is not walking.
        let audioFeedback: AudioFeedbackService = overrides.audioFeedback
            ?? EngineAudioFeedbackService(logService: logService)
        // Holds no hardware until `prepare()`, so constructing it at launch
        // costs nothing and nothing is reserved while the user is not walking.
        let hapticFeedback = LiveHapticFeedbackService(logService: logService)

        let sessions = SwiftDataGaitSessionRepository(reader: reader, writer: writer)
        let baselines = SwiftDataBaselineRepository(reader: reader, writer: writer)
        let profiles = SwiftDataUserProfileRepository(reader: reader, writer: writer)
        // One cache and one broadcaster, shared by the commit path and the
        // restore path: a restore that rebuilt a different cache would leave
        // the commit path reading stale baseline states.
        let stateStore = BaselineStateStore(sessions: sessions, baselines: baselines)
        let storeEvents = StoreReplacementEvents()
        // The restore and launch recovery share one replacer and one staging
        // directory: recovery reads exactly what the restore wrote.
        let replacer = SwiftDataStoreReplacer(reader: reader, writer: writer)
        let restoreStaging = RestoreStagingArea(directory: restoreStagingDirectory, fileIO: fileIO, clock: clock)
        let outcomes = SessionOutcomeService(
            processor: SessionProcessor(algorithm: GaitAnalysisPipeline(), logService: logService),
            commits: SessionCommitService(
                sessions: sessions,
                baselines: baselines,
                writer: writer,
                reader: reader,
                stateStore: stateStore,
                logService: logService,
                clock: clock
            ),
            baselines: baselines,
            profiles: profiles,
            buildInfo: SystemBuildInfo(),
            logService: logService
        )

        var dependencies = AppDependencies(
            logService: logService,
            clock: clock,
            fileIO: fileIO,
            randomSource: SystemRandomSource(),
            motionSensor: motionSensor,
            pedometer: pedometer,
            audioFeedback: audioFeedback,
            hapticFeedback: hapticFeedback,
            keyDerivation: CommonCryptoKeyDerivation(),
            secureArchive: SecureArchiveCoder(),
            sessionRecorder: SessionRecorder(
                motionSensor: motionSensor,
                pedometer: pedometer,
                audioFeedback: audioFeedback,
                interruptionObserver: SystemSessionInterruptionObserver(audioFeedback: audioFeedback),
                screenSleep: SystemScreenSleepController(),
                clock: clock,
                logService: logService,
                fileIO: fileIO
            ),
            sessionOutcomes: outcomes,
            onboardingDrafts: overrides.onboardingDrafts ?? UserDefaultsOnboardingDraftStore(),
            userProfileRepository: profiles,
            gaitSessionRepository: sessions,
            baselineRepository: baselines,
            archiveRestorer: ArchiveRestoreService(
                replacer: replacer,
                events: storeEvents,
                logService: logService,
                staging: restoreStaging,
                rebuildBaselineStates: { try await stateStore.rebuild() }
            ),
            exportNudgeStore: overrides.exportNudgeStore ?? UserDefaultsExportNudgeStore(),
            storeEvents: storeEvents,
            restoreRecovery: overrides.restoreRecovery ?? RestoreRecoveryService(
                staging: restoreStaging,
                replacer: replacer,
                logService: logService,
                rebuildBaselineStates: { try await stateStore.rebuild() }
            )
        )

        #if DEBUG
        dependencies.debugStoreWriter = writer
        #endif
        return dependencies
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
        let logService = OSLogService()
        let clock = SystemClock()
        let fileIO = FileManagerFileIO()
        let motionSensor = UnwiredMotionSensorService()
        let pedometer = UnwiredPedometerService()
        // Real audio even here. The store failing to open says nothing about
        // the audio route, and the degraded graph is the one a user is most
        // likely to be looking at when they need the app to behave normally.
        let audioFeedback = EngineAudioFeedbackService(logService: logService)
        // Real haptics here too: the store failing to open says nothing about
        // the Taptic Engine.
        let hapticFeedback = LiveHapticFeedbackService(logService: logService)

        return AppDependencies(
            logService: logService,
            clock: clock,
            fileIO: fileIO,
            // Real crypto even here: the store failing to open says nothing
            // about the system RNG or CommonCrypto, and restoring an export
            // is a way back from a store that will not open.
            randomSource: SystemRandomSource(),
            motionSensor: motionSensor,
            pedometer: pedometer,
            audioFeedback: audioFeedback,
            hapticFeedback: hapticFeedback,
            keyDerivation: CommonCryptoKeyDerivation(),
            secureArchive: SecureArchiveCoder(),
            sessionRecorder: SessionRecorder(
                motionSensor: motionSensor,
                pedometer: pedometer,
                audioFeedback: audioFeedback,
                interruptionObserver: SystemSessionInterruptionObserver(audioFeedback: audioFeedback),
                screenSleep: SystemScreenSleepController(),
                clock: clock,
                logService: logService,
                fileIO: fileIO
            ),
            // No store, so nothing can be committed. See the slot's note.
            sessionOutcomes: nil,
            // UserDefaults is unaffected by the store failing to open, so a
            // half-finished wizard still survives the degraded launch.
            onboardingDrafts: UserDefaultsOnboardingDraftStore(),
            userProfileRepository: UnwiredUserProfileRepository(),
            gaitSessionRepository: UnwiredGaitSessionRepository(),
            baselineRepository: UnwiredBaselineRepository(),
            // UserDefaults is unaffected by the store failing to open.
            exportNudgeStore: UserDefaultsExportNudgeStore()
        )
    }
}
