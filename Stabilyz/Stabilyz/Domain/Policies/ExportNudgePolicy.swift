import Foundation

/// When the Walk tab offers a backup (docs/21 #11, decisions.md entry 43,
/// Task 10.2.3).
///
/// [PRD §6]: the app should nudge toward Export My Data "e.g. after baseline is
/// first established", because a lost phone with no export is unrecoverable.
/// Settled as **one** prompt, not a schedule:
///
/// - it appears once **any** mode's baseline is established — the first point
///   at which there is something that took real effort to rebuild;
/// - it goes for good when the person dismisses it, or when any export
///   completes, from whichever screen.
enum ExportNudgePolicy {
    static func shouldShow(
        baselineStates: [TestMode: BaselineState],
        isDismissed: Bool,
        hasExported: Bool
    ) -> Bool {
        guard !isDismissed, !hasExported else { return false }
        return TestMode.allCases.contains { baselineStates[$0]?.isEstablished == true }
    }
}
