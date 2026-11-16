/// The two selectable session modes, modeled on the 2MWT/6MWT clinical walk
/// tests [PRD §5, OQ-3].
///
/// This is the segregation key: Quick Test and Full Test never share a
/// baseline, a session count, or trend data [PRD OQ-5]. Every baseline query
/// and scoring call takes one of these explicitly, which makes cross-mode
/// mixing a compile-time impossibility rather than a convention (docs/09 §9.7).
///
/// The raw value is persisted on session and baseline rows (docs/05 §5.2), so
/// **these strings must not change**.
enum TestMode: String, Sendable, CaseIterable, Codable {
    case quickTest
    case fullTest

    /// The advertised test length shown to the user and run on the clock
    /// [PRD §5, OQ-3: Quick Test 90 s (1:30), Full Test 180 s (3:00)].
    ///
    /// **Provisional product lengths, not research-validated.** The 2MWT/6MWT
    /// clinical tests the modes are modelled on run 2 and 6 minutes; these
    /// shorter lengths were set by the product owner (2026-11-14) and are to be
    /// tuned against real-world session data.
    ///
    /// Deliberately **not** the same thing as the valid-walking requirement in
    /// `SessionPolicy`: a session can run the full advertised length and still
    /// fail to produce a score if too much of it was pauses, setup, or other
    /// non-walking motion [PRD OQ-3].
    var advertisedDuration: Duration {
        switch self {
        case .quickTest: .seconds(90)
        case .fullTest: .seconds(180)
        }
    }

    /// User-facing name [PRD §5].
    var displayName: String {
        switch self {
        case .quickTest: "Quick Test"
        case .fullTest: "Full Test"
        }
    }
}
