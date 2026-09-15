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
enum UITestingLaunch {
    static let flag = "-ui-testing"
    static let onboardedFlag = "-ui-testing-onboarded"

    /// 110 seconds of walking. The countdown's first 5 seconds of samples are
    /// turned away at T-0, leaving 105 — past the Quick Test's 90-second floor
    /// and short of its 120-second clock, so the walk never ends on its own
    /// before the journey taps Stop.
    static let walkSeconds: Double = 110

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static func dependencies(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> AppDependencies {
        let clock = SystemClock()
        let container = try StoreContainer.make(inMemory: true)
        let fixture = GaitFixture.makeWalk(
            name: "ui-testing-walk",
            cadenceBPM: 108,
            seconds: walkSeconds,
            noise: 0.01
        )

        var overrides = LiveOverrides()
        overrides.motionSensor = FixtureSensorService(fixture: fixture, clock: clock, pacing: .immediate)
        overrides.pedometer = FixturePedometerService(fixture: fixture, clock: clock)
        overrides.audioFeedback = SilentAudioFeedbackService()
        overrides.onboardingDrafts = EmptyOnboardingDraftStore()
        overrides.exportNudgeStore = InMemoryExportNudgeStore()
        overrides.restoreRecovery = UITestingStorePreparation(
            profiles: SwiftDataUserProfileRepository(
                reader: StoreReader(modelContainer: container),
                writer: StoreWriter(modelContainer: container)
            ),
            seedsOnboardedProfile: arguments.contains(onboardedFlag)
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
    let seedsOnboardedProfile: Bool

    func recoverInterruptedRestore() async -> RestoreRecoveryOutcome {
        guard seedsOnboardedProfile, (try? await profiles.fetchProfile()) == nil else {
            return .nothingToRecover
        }
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
        return .nothingToRecover
    }
}
#endif
