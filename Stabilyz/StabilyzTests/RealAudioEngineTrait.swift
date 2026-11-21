import Foundation
import Testing

/// Marks a test that builds a real `EngineAudioFeedbackService`, and so a real
/// `AVAudioEngine`, instead of a spy.
///
/// **Why these are skipped on CI and nowhere else.** GitHub's hosted macOS
/// runners have no usable audio route. On them the simulator's audio server
/// answers the engine's remote calls late or not at all, and two things follow:
///
/// 1. Releasing the engine can abort the whole test process. The crash report
///    from run 43616249895 shows `AURemoteIO::~AURemoteIO` →
///    `_ReportRPCTimeout` → `abort`, reached from a test's `deinit` of the
///    service. Every test still queued in that process is then reported failed.
/// 2. While those calls wait, they hold threads of the cooperative pool the
///    whole suite runs on, so unrelated tests take minutes of wall time and
///    wall-clock assertions elsewhere fail.
///
/// Neither is a defect in the app or in these tests: on a Mac with audio
/// hardware (every local run) they pass. So they stay enabled by default and
/// are switched off only when the environment asks for it by name.
///
/// **How CI asks.** `.github/workflows/ci.yml` sets
/// `TEST_RUNNER_STABILYZ_SKIP_REAL_AUDIO_ENGINE_TESTS=1` on the `xcodebuild`
/// step; `xcodebuild` strips the `TEST_RUNNER_` prefix and hands the rest to the
/// test process (the same route `STABILYZ_REGENERATE_GOLDENS` uses). The
/// variable is specific to this purpose — not `CI` — so nothing else can switch
/// these tests off by accident, and it switches off nothing but them.
///
/// `RealAudioEngineGuardTests` keeps the marking honest in both directions:
/// every test that builds the real service carries the trait, and no test
/// carries it without building one.
enum RealAudioEngine {
    static let skipVariable = "STABILYZ_SKIP_REAL_AUDIO_ENGINE_TESTS"

    /// True only when the environment sets the skip variable to exactly "1".
    static func isSkipped(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[skipVariable] == "1"
    }
}

extension Trait where Self == ConditionTrait {
    /// The test builds a real audio engine; skipped where the environment
    /// declares there is no audio route for one (hosted CI). See `RealAudioEngine`.
    static var requiresRealAudioEngine: Self {
        .disabled(
            if: RealAudioEngine.isSkipped(),
            "Builds a real AVAudioEngine; skipped because STABILYZ_SKIP_REAL_AUDIO_ENGINE_TESTS=1 (no audio route on hosted CI)."
        )
    }
}
