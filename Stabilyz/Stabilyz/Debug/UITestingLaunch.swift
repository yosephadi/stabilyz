// UI-test launch configuration (Task 11.1.1, docs/19 §19.3).

#if DEBUG
import Foundation

/// What `-ui-testing` launches.
///
/// **Debug builds only**, like the reset gesture beside it: a release build
/// contains neither the flag nor the graph it selects, and
/// `DebugIsolationGuardTests` holds that nothing outside `#if DEBUG` names it.
///
/// A UI journey has to start from the same state every run and cannot depend
/// on hardware the simulator lacks, so this is the production graph with:
///
/// - an **in-memory store**, empty at every launch unless a scenario seeds it;
/// - **replayed sensors**: `FixtureSensorService` delivering a synthetic walk
///   long enough to clear the Quick Test minimum as soon as Go fires, so a
///   journey can tap Stop straight away and still reach a scoreable walk;
/// - silent audio, and in-memory stores for the onboarding draft and the
///   backup card, so nothing leaks between launches through `UserDefaults`;
/// - a restore file for Welcome and Settings, because the system document
///   picker runs out of process and cannot be scripted deterministically.
///
/// Scenario flags, each on top of `-ui-testing`:
///
/// - `-ui-testing-onboarded`: one profile past the disclaimer;
/// - `-ui-testing-onboarding-draft`: no profile, and a wizard left mid-way;
/// - `-ui-testing-motion-denied`: Motion & Fitness reports denied;
/// - `-ui-testing-unclear-walk`: a walk too short to measure;
/// - `-ui-testing-history`: an onboarded profile with walks in both modes, and
///   one invalid walk History must never list;
/// - `-ui-testing-real-backup`: the restore file is a real encrypted export,
///   opened by `realBackupPassphrase`, rather than a file that is not one.
enum UITestingLaunch {
    static let flag = "-ui-testing"
    static let onboardedFlag = "-ui-testing-onboarded"
    static let onboardingDraftFlag = "-ui-testing-onboarding-draft"
    static let motionDeniedFlag = "-ui-testing-motion-denied"
    static let unclearWalkFlag = "-ui-testing-unclear-walk"
    static let historyFlag = "-ui-testing-history"
    static let realBackupFlag = "-ui-testing-real-backup"

    /// The passphrase the real backup is sealed with. Known to the journey
    /// that restores it, and nowhere outside debug builds.
    static let realBackupPassphrase = "correct horse battery"

    /// 110 seconds of walking. The countdown's first 5 seconds of samples are
    /// turned away at T-0, leaving 105 — past the Quick Test's 90-second floor
    /// and short of its 120-second clock, so the walk never ends on its own
    /// before the journey taps Stop.
    static let walkSeconds: Double = 110

    /// 30 seconds: 25 admitted after the countdown, far under the 90-second
    /// floor, so the walk is refused as insufficient walking — deterministically.
    static let unclearWalkSeconds: Double = 30

    /// A wizard left on its third question, with the first two answered.
    static let resumableDraft = OnboardingDraft(
        step: .timeSinceAmputation,
        amputationLevel: .transfemoral,
        side: .right
    )

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static func dependencies(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> AppDependencies {
        let clock = SystemClock()
        let container = try StoreContainer.make(inMemory: true)
        let fixture = GaitFixture.makeWalk(
            name: "ui-testing-walk",
            cadenceBPM: 108,
            seconds: arguments.contains(unclearWalkFlag) ? unclearWalkSeconds : walkSeconds,
            noise: 0.01
        )

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "ui-testing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let restoreFile = scratch.appending(path: "ui-test-backup.\(ArchiveFormat.fileExtension)")
        // Not an export. Replaced with a real one before the first screen when
        // the scenario asks for it.
        try Data("This is not a Stabilyz export.".utf8).write(to: restoreFile, options: .atomic)

        var overrides = LiveOverrides()
        overrides.motionSensor = arguments.contains(motionDeniedFlag)
            ? DeniedMotionSensorService() as MotionSensorService
            : FixtureSensorService(fixture: fixture, clock: clock, pacing: .immediate)
        overrides.pedometer = FixturePedometerService(fixture: fixture, clock: clock)
        overrides.audioFeedback = SilentAudioFeedbackService()
        overrides.onboardingDrafts = UITestingDraftStore(
            draft: arguments.contains(onboardingDraftFlag) ? resumableDraft : nil
        )
        overrides.exportNudgeStore = InMemoryExportNudgeStore()
        let seedReader = StoreReader(modelContainer: container)
        let seedWriter = StoreWriter(modelContainer: container)
        overrides.restoreRecovery = UITestingStorePreparation(
            profiles: SwiftDataUserProfileRepository(reader: seedReader, writer: seedWriter),
            sessions: SwiftDataGaitSessionRepository(reader: seedReader, writer: seedWriter),
            seedsOnboardedProfile: arguments.contains(onboardedFlag) || arguments.contains(historyFlag),
            seedsHistory: arguments.contains(historyFlag),
            realBackupURL: arguments.contains(realBackupFlag) ? restoreFile : nil
        )

        var dependencies = AppDependencies.live(
            container: container,
            restoreStagingDirectory: scratch.appending(path: "RestoreStaging", directoryHint: .isDirectory),
            overrides: overrides
        )
        dependencies.uiTestingRestoreFile = restoreFile
        return dependencies
    }
}

/// Seeds the UI-testing store, and writes the real backup, before the router's
/// first read.
///
/// It rides the one launch hook that already runs before that read — the
/// interrupted-restore recovery slot — rather than adding a second path into
/// the router for tests alone. There is never a restore to recover in an
/// in-memory store, so the slot has nothing else to do.
struct UITestingStorePreparation: RestoreRecovering {
    let profiles: UserProfileRepository
    let sessions: GaitSessionRepository
    let seedsOnboardedProfile: Bool
    let seedsHistory: Bool
    let realBackupURL: URL?

    func recoverInterruptedRestore() async -> RestoreRecoveryOutcome {
        if seedsOnboardedProfile, (try? await profiles.fetchProfile()) == nil,
           let profile = Self.profile(level: .transtibial, side: .left) {
            try? await profiles.save(profile)
        }
        if seedsHistory {
            await seedHistory()
        }
        if let realBackupURL {
            await writeRealBackup(to: realBackupURL)
        }
        return .nothingToRecover
    }

    private static func profile(level: AmputationLevel, side: AmputationSide) -> UserProfile? {
        let now = Date()
        return try? UserProfile(
            id: UUID(),
            amputationLevel: level,
            side: side,
            timeSinceAmputationMonths: 24,
            disclaimerAcceptedAt: now,
            createdAt: now
        )
    }

    /// Three valid Quick Tests (the newest walk overall, so History opens on
    /// Quick Test), one valid Full Test, and one invalid Quick Test that no
    /// History segment may ever list [PRD §5, §7].
    private func seedHistory() async {
        let walks = [
            Self.walk(.quickTest, daysAgo: 1, valid: true),
            Self.walk(.quickTest, daysAgo: 2, valid: true),
            Self.walk(.quickTest, daysAgo: 3, valid: true),
            Self.walk(.fullTest, daysAgo: 4, valid: true),
            Self.walk(.quickTest, daysAgo: 1.5, valid: false)
        ]
        for walk in walks {
            try? await sessions.save(walk)
        }
    }

    /// A real export — a different profile and no walks — sealed with
    /// `UITestingLaunch.realBackupPassphrase` at the minimum iteration count,
    /// through the same coder an export uses.
    private func writeRealBackup(to url: URL) async {
        guard let profile = Self.profile(level: .transfemoral, side: .right) else { return }
        let payload = ArchivePayload(
            profile: profile,
            baselines: [],
            sessions: [],
            appVersion: "UI testing",
            algorithmVersion: AlgorithmConfiguration.v1.version,
            exportedAt: Date()
        )
        let data = try? await SecureArchiveCoder().encode(
            payload,
            passphrase: PassphraseEncoding.bytes(from: UITestingLaunch.realBackupPassphrase),
            iterations: KeyDerivationPolicy.minimumIterations
        )
        if let data {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func walk(_ mode: TestMode, daysAgo: Double, valid: Bool) -> GaitSession {
        let startedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        let endedAt = startedAt.addingTimeInterval(120)
        let version = AlgorithmConfiguration.v1.version
        guard valid else {
            return .invalid(
                id: UUID(), mode: mode, reason: .excessiveNoise,
                startedAt: startedAt, endedAt: endedAt,
                advertisedClockElapsed: mode.advertisedDuration, validWalkingDuration: .seconds(20),
                audioConfig: .none, algorithmVersion: version, appVersion: "UI testing", deviceModel: "Simulator"
            )
        }
        return .valid(
            id: UUID(), mode: mode,
            startedAt: startedAt, endedAt: endedAt,
            advertisedClockElapsed: mode.advertisedDuration, validWalkingDuration: .seconds(100),
            metrics: GaitMetrics(
                stepRegularity: 0.82, strideRegularity: 0.78, cadenceMean: 104, stepTimeCV: 0.041,
                trunkMotionML: 1.12, trunkMotionVT: 2.3, validStrideCount: 90, windowCount: 10
            ),
            audioConfig: .none, algorithmVersion: version, appVersion: "UI testing", deviceModel: "Simulator"
        )
    }
}

/// The onboarding draft, in memory: seeded for the resume journey, otherwise
/// empty, and never written to `UserDefaults`.
final class UITestingDraftStore: OnboardingDraftStore, Sendable {
    private let draft: Locked<OnboardingDraft?>

    init(draft: OnboardingDraft?) {
        self.draft = Locked(draft)
    }

    func load() async -> OnboardingDraft? { draft.withLock { $0 } }
    func save(_ draft: OnboardingDraft) async { self.draft.withLock { $0 = draft } }
    func clear() async { draft.withLock { $0 = nil } }
}

/// Motion & Fitness, denied: what Session Setup must explain rather than let
/// Start fail silently [PRD §6].
struct DeniedMotionSensorService: MotionSensorService {
    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { .denied } }

    func requestAuthorization() async -> MotionAuthorizationStatus { .denied }

    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        throw StabilyzError.permission(.motionDenied)
    }

    func stop() async {}
}
#endif
