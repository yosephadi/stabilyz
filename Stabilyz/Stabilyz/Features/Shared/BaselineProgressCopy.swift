import Foundation

/// The one wording for baseline progress, used by Walk setup, the Score screen,
/// the Result tab's trend card and its rows.
///
/// "Walk N of 5 toward your baseline" for how far along, "N more walks to go"
/// for what is left, numerals throughout. The 5 is always
/// `Baseline.requiredValidSessionCount`; nothing else spells the count.
enum BaselineProgressCopy {
    /// "Walk 2 of 5 toward your baseline". `walk` is clamped to the range.
    static func progress(
        walk: Int,
        required: Int = Baseline.requiredValidSessionCount
    ) -> String {
        "Walk \(max(0, min(walk, required))) of \(required) toward your baseline"
    }

    /// Under a bare "N of 5" on the no-score ring, completing the phrase.
    static let ringCaption = "walks toward your baseline"

    /// "4 more walks to go", "1 more walk to go".
    static func remaining(_ count: Int) -> String {
        "\(count) more \(count == 1 ? "walk" : "walks") to go"
    }

    /// `remaining` read as a sentence about the payoff.
    static func remainingSentence(_ count: Int) -> String {
        "\(remaining(count)) before your personal baseline is set."
    }
}
