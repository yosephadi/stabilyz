import Foundation
import UIKit

/// The app and device a session was recorded on (docs/05 §5.1).
///
/// Stored on every `GaitSession` because a metric is only interpretable
/// alongside the build that produced it — and the export carries it, so a
/// future version can tell whether an older row is safe to read [PRD §7].
///
/// Protocol-fronted for the same reason `Clock` is: a test asserting what was
/// persisted should not depend on which simulator it ran on.
protocol BuildInfoProviding: Sendable {
    var appVersion: String { get }
    var deviceModel: String { get }
}

/// Reads the real bundle and device.
struct SystemBuildInfo: BuildInfoProviding {
    init() {}

    /// `1.2 (34)` — the marketing version and the build, because a TestFlight
    /// tester reporting a problem has the second and not always the first.
    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// The hardware identifier — "iPhone16,1" rather than the marketing name.
    ///
    /// `UIDevice.model` returns "iPhone" for every iPhone ever made, which
    /// tells a later diagnosis nothing. The sysctl identifier distinguishes the
    /// sensor hardware the walk was actually measured on.
    var deviceModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return UIDevice.current.model }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}
