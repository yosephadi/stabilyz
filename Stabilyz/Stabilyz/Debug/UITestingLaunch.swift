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
/// - an **in-memory store**, empty at every launch (or holding one onboarded
///   profile with `-ui-testing-onboarded`);
/// - **replayed sensors**: `FixtureSensorService` delivering a synthetic walk
///   long enough to clear the Quick Test minimum as soon as Go fires, so a
///   journey can tap Stop straight away and still reach a scoreable walk;
/// - silent audio, and in-memory stores for the onboarding draft and the
///   backup card, so nothing leaks between launches through `UserDefaults`;
/// - a restore file for Welcome, because the system document picker runs out
///   of process and cannot be scripted deterministically.
///
/// Scenario flags, each on top of `-ui-testing`:
///
/// - `-ui-testing-onboarded`: one profile past the disclaimer;
/// - `-ui-testing-motion-denied`: Motion & Fitness reports denied;
/// - `-ui-testing-unclear-walk`: a walk too short to measure;
/// - `-ui-testing-history`: an onboarded profile with walks in both modes, and
///   one invalid walk History must never list.
enum UITestingLaunch {
    static let flag = "-ui-testing"
    static let onboardedFlag = "-ui-testing-onboarded"
    static let motionDeniedFlag = "-ui-testing-motion-denied"
    static let unclearWalkFlag = "-ui-testing-unclear-walk"
    static let historyFlag = "-ui-testing-history"

    /// 110 seconds of walking. The countdown's first 5 seconds of samples are
    /// turned away at T-0, leaving 105 — past the Quick Test's 90-second floor
    /// and short of its 120-second clock, so the walk never ends on its own
    /// before the journey taps Stop.
    static let walkSeconds: Double = 110

    /// 30 seconds: 25 admitted after the countdown, far under the 90-second
    /// floor, so the walk is refused as insufficient walking — deterministically.
    static let unclearWalkSeconds: Double = 30

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

        var overrides = LiveOverrides()
        overrides.motionSensor = arguments.contains(motionDeniedFlag)
            ? DeniedMotionSensorService() as MotionSensorService
            : FixtureSensorService(fixture: fixture, clock: clock, pacing: .immediate)
        overrides.pedometer = FixturePedometerService(fixture: fixture, clock: clock)
        overrides.audioFeedback = SilentAudioFeedbackService()
        overrides.onboardingDrafts = EmptyOnboardingDraftStore()
        overrides.exportNudgeStore = InMemoryExportNudgeStore()
        let seedReader = StoreReader(modelContainer: container)
        let seedWriter = StoreWriter(modelContainer: container)
        overrides.restoreRecovery = UITestingStorePreparation(
            profiles: SwiftDataUserProfileRepository(reader: seedReader, writer: seedWriter),
            sessions: SwiftDataGaitSessionRepository(reader: seedReader, writer: seedWriter),
            seedsOnboardedProfile: arguments.contains(onboardedFlag) || arguments.contains(historyFlag),
            seedsHistory: arguments.contains(historyFlag)
        )

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "ui-testing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        var dependencies = AppDependencies.live(
            container: container,
            restoreStagingDirectory: scratch.appending(path: "RestoreStaging", directoryHint: .isDirectory),
            overrides: overrides
        )
        dependencies.uiTestingRestoreFile = try restoreFile(in: scratch)
        return dependencies
    }

    /// A file Restore can open. Not an export, so the journey also sees the
    /// preflight run and report it — deterministically, with no passphrase.
    private static func restoreFile(in directory: URL) throws -> URL {
        let url = directory.appending(path: "ui-test-backup.\(ArchiveFormat.fileExtension)")
        try Data("This is not a Stabilyz export.".utf8).write(to: url, options: .atomic)
        return url
    }
}

/// Seeds the UI-testing store before the router's first read.
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

    func recoverInterruptedRestore() async -> RestoreRecoveryOutcome {
        if seedsOnboardedProfile, (try? await profiles.fetchProfile()) == nil {
            await seedProfile()
        }
        if seedsHistory {
            await seedHistory()
        }
        return .nothingToRecover
    }

    private func seedProfile() async {
        let now = Date()
        if let profile = try? UserProfile(
            id: UUID(),
            amputationLevel: .transtibial,
            side: .left,
            timeSinceAmputationMonths: 24,
            disclaimerAcceptedAt: now,
            createdAt: now
        ) {
            try? await profiles.save(profile)
        }
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
