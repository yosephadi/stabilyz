import Foundation

/// What the countdown overlay is showing, derived from the coordinator's state.
///
/// A pure mapping in its own type so the overlay's rules — when it appears,
/// what it says, when it clears — can be asserted without rendering anything
/// (docs/11 §11.5). The one thing it cannot derive is "Go!", which is a moment
/// rather than a state: the coordinator is already `.running` by then, and the
/// walk is recording underneath.
enum CountdownOverlayContent: Equatable {
    /// No overlay — the walk is visible on its own.
    case hidden
    /// Sensors are coming up. Deliberately not a numeral: priming can take a
    /// moment, and counting down through it would mean the countdown lied
    /// about how long it was ([PRD OQ-6] — the five seconds are the user's, to
    /// get situated).
    case preparing
    /// A numeral: "5" … "1".
    case counting(String)
    /// T-0. Held briefly while the overlay clears.
    case go

    static let preparingText = "Getting ready…"

    /// The string the overlay draws, or nil when there is nothing to draw.
    var text: String? {
        switch self {
        case .hidden: nil
        case .preparing: Self.preparingText
        case .counting(let numeral): numeral
        case .go: CountdownOverlayView.goText
        }
    }

    var isVisible: Bool { self != .hidden }

    /// Whether the text is the big numeral or the smaller preparing line.
    var isNumeral: Bool {
        switch self {
        case .counting, .go: true
        case .hidden, .preparing: false
        }
    }

    /// What VoiceOver says when this content appears.
    ///
    /// Every tick, because a user who has pocketed the phone can neither see
    /// the numerals nor necessarily feel the taps, and would otherwise have
    /// nothing until the tone at Go [PRD OQ-6]. `preparing` is silent: it is
    /// not a tick, and announcing it would put a sentence in front of the
    /// count.
    var announcement: String? {
        switch self {
        case .counting(let numeral): numeral
        case .go: CountdownOverlayView.goText
        case .hidden, .preparing: nil
        }
    }

    /// The overlay's content for a coordinator state.
    ///
    /// - Parameter isHoldingGo: set by the cover for the moment after T-0, and
    ///   the only reason this is not a function of the state alone.
    static func content(
        for state: CountdownCoordinator.State,
        isHoldingGo: Bool = false
    ) -> CountdownOverlayContent {
        switch state {
        case .priming:
            return .preparing
        case .counting(let remaining):
            return .counting("\(remaining)")
        case .running:
            // The walk is recording. The overlay is on borrowed time.
            return isHoldingGo ? .go : .hidden
        case .idle, .cancelled, .failed:
            // Cancelled and failed both land back on the setup screen, so the
            // overlay has nothing to say about either.
            return .hidden
        }
    }
}
