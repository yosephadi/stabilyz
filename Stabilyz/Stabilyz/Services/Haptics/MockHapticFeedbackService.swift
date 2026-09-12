import Foundation

/// One recorded call on a `HapticFeedbackService`.
///
/// Exists so a test can assert the *sequence*, not just the count. The
/// countdown's whole contract is ordering — five ticks, then a distinct Go —
/// and a mock that only counted taps would pass on a recorder that played them
/// in any order, or played Go five times.
enum HapticCall: Sendable, Equatable {
    case prepare
    case cadenceTick
    case sessionStart
    case sessionStop
    case teardown
}

/// Records what it was asked to play, and plays nothing (docs/12 §12.2).
///
/// The counterpart to `SilentAudioFeedbackService`, with one difference: this
/// one remembers. Haptics have no observable output — no route, no events, no
/// audible result — so a test's only way to hold the countdown to [PRD OQ-6]
/// is to ask the double what it was told to do.
///
/// An actor rather than a locked class: calls arrive from whatever context the
/// caller is on, and the recorded order is the thing under test, so it has to
/// be serialised rather than merely safe.
actor MockHapticFeedbackService: HapticFeedbackService {
    private(set) var calls: [HapticCall] = []

    init() {}

    /// Every call in order, including `prepare` and `teardown`.
    var recordedCalls: [HapticCall] { calls }

    /// Just the taps, for assertions about the countdown's shape that do not
    /// care where the lifecycle calls fell.
    var taps: [HapticCall] {
        calls.filter { $0 != .prepare && $0 != .teardown }
    }

    func count(of call: HapticCall) -> Int {
        calls.filter { $0 == call }.count
    }

    func reset() {
        calls.removeAll()
    }

    func prepare() async { calls.append(.prepare) }
    func playCadenceTick() async { calls.append(.cadenceTick) }
    func playSessionStart() async { calls.append(.sessionStart) }
    func playSessionStop() async { calls.append(.sessionStop) }
    func teardown() async { calls.append(.teardown) }
}

/// Does nothing and remembers nothing — the preview and placeholder double
/// (docs/12 §12.2).
///
/// Distinct from `MockHapticFeedbackService` on purpose: a preview has no
/// assertions to make, and using a recording double where nothing reads the
/// recording would only invite someone to start reading it.
struct SilentHapticFeedbackService: HapticFeedbackService {
    init() {}

    func playCadenceTick() async {}
    func playSessionStart() async {}
    func playSessionStop() async {}
}
