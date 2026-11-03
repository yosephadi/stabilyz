import Foundation

/// The one place `TestMode` meets the watch contract's wire types
/// (docs/04 §4.18).
///
/// Kept on the phone side on purpose: the shared contract cannot see `Domain/`,
/// and `Domain/` must not know the watch exists.
extension WireTestMode {
    init(_ mode: TestMode) {
        switch mode {
        case .quickTest: self = .quick
        case .fullTest: self = .full
        }
    }

    var testMode: TestMode {
        switch self {
        case .quick: .quickTest
        case .full: .fullTest
        }
    }
}

enum WatchSyncMapping {
    /// The advertised length on the wire, in whole seconds. Advertised lengths
    /// are whole minutes [PRD §5], so nothing is lost.
    static func durationSeconds(for mode: TestMode) -> Int {
        Int(mode.advertisedDuration.components.seconds)
    }
}
