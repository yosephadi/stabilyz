import Foundation

/// A session's result relative to the user's own baseline for that mode
/// (docs/05 §5.1).
///
/// Present only from the sixth valid session of a mode onward — there is
/// nothing to compare against before the baseline exists [PRD §7].
struct SessionScore: Sendable, Equatable, Codable {
    /// Baseline performance is 100 by construction; the PRD's worked example is
    /// 112 [PRD §7]. An **index**, not a percentage of anything.
    let relativeIndex: Int
    /// The weighted composite the index was mapped from. Kept so a breakdown can
    /// show how the index was reached rather than asserting it.
    let compositeZ: Double?
    /// The version the comparison was made under — the **baseline's**, since a
    /// score is only meaningful within one algorithm version (docs/09 §9.6).
    ///
    /// Optional so a row written before this field existed still decodes.
    let algorithmVersion: String?

    init(relativeIndex: Int, compositeZ: Double? = nil, algorithmVersion: String? = nil) {
        self.relativeIndex = relativeIndex
        self.compositeZ = compositeZ
        self.algorithmVersion = algorithmVersion
    }
}
