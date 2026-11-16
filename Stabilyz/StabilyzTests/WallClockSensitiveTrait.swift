import Foundation
import Testing

/// Marks a test whose assertion is a wall-clock limit — "this finished within
/// N real seconds" — rather than a count, a state or a monotonic test clock.
///
/// **Why these are skipped on CI and nowhere else.** The suite's ~1,500 Swift
/// Testing tests run concurrently in one process. On a GitHub-hosted macOS
/// runner they share three cores, and the median test there takes over a minute
/// of wall time from start to finish simply waiting its turn (measured on runs
/// 43623148247 and 43675172004, with and without the audio tests). A real-time
/// limit of a few seconds cannot hold under that, whatever the code under test
/// does: `aStalledAudioConsumerNeverDelaysRecording` asserts 20 s and recorded
/// 77.6 s on CI, and it has failed the same way on `main`.
///
/// The assertion itself is right and stays as written. On a developer's Mac the
/// test passes in well under its limit, so it remains enabled by default and is
/// switched off only when the environment asks for it by name.
///
/// **How CI asks.** `.github/workflows/ci.yml` sets
/// `TEST_RUNNER_STABILYZ_SKIP_WALL_CLOCK_TESTS=1` on the phone job's
/// `xcodebuild` step; `xcodebuild` strips `TEST_RUNNER_` and passes the rest to
/// the test process. The variable is specific to this purpose — not `CI` — and
/// separate from the audio-engine one, so each switches off only its own tests.
///
/// Use this sparingly. A test that can assert on a count, a state or an injected
/// clock should do that instead and needs no trait.
enum WallClockSensitive {
    static let skipVariable = "STABILYZ_SKIP_WALL_CLOCK_TESTS"

    /// True only when the environment sets the skip variable to exactly "1".
    static func isSkipped(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[skipVariable] == "1"
    }
}

extension Trait where Self == ConditionTrait {
    /// The test asserts a real-time limit; skipped where the environment
    /// declares wall-clock limits cannot hold (hosted CI). See `WallClockSensitive`.
    static var wallClockSensitive: Self {
        .disabled(
            if: WallClockSensitive.isSkipped(),
            "Asserts a wall-clock limit; skipped because STABILYZ_SKIP_WALL_CLOCK_TESTS=1 (hosted CI runs the suite on three shared cores)."
        )
    }
}
