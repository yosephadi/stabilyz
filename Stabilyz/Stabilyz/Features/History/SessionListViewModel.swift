import Foundation

/// Drives the Result tab's session list (docs/04 §4.13, Figma node 64:7837).
///
/// Reads both modes once per load, each through its own mode-named query
/// [PRD OQ-5], and filters in memory. Switching the segment is then instant and
/// cannot race a read, and calibration walks can be numbered — which needs
/// every valid session of the mode.
///
/// Every string the list shows is decided here or in `SessionHistoryRow`, so
/// the rules are testable without rendering (docs/11 §11.5).
@MainActor
@Observable
final class SessionListViewModel {
    enum Phase: Equatable {
        /// Nothing asked yet.
        case idle
        case loading
        case loaded
        /// The last read failed. Rows from an earlier read are kept: a store
        /// that could not be read this time says nothing about what it held
        /// last time, and blanking the list would read as "no sessions".
        case failed
    }

    /// What the area under the segment shows.
    enum Content: Equatable {
        /// Before the first answer. Blank rather than an empty state, which
        /// would flash "no sessions" at someone who has twenty.
        case waiting
        case sessions
        case empty
        /// Nothing to show because nothing could be read.
        case failed
    }

    /// The empty state for the selected mode.
    struct EmptyState: Equatable {
        let title: String
        let message: String
        let actionTitle: String
    }

    private(set) var phase: Phase = .idle

    /// The segment: Quick Test or Full Test, never both.
    ///
    /// docs/04 §4.13 lists an `all` filter; Figma node 64:7837 draws two
    /// segments, and the node is the design authority (docs/11 §11.1). Two is
    /// also the only honest shape for this screen: the baseline card and trend
    /// that join the list under this control (Task 9.1.2) are per-mode by
    /// nature, and an "All" view would put two baselines under one heading
    /// [PRD OQ-5].
    private(set) var mode: TestMode = .quickTest

    /// Every valid session of both modes, newest first.
    private(set) var allRows: [SessionHistoryRow] = []

    /// What the list draws.
    var rows: [SessionHistoryRow] {
        allRows.filter { $0.mode == mode }
    }

    var content: Content {
        if rows.isEmpty == false { return .sessions }
        switch phase {
        case .failed: return .failed
        case .loaded: return .empty
        case .idle, .loading: return hasLoaded ? .empty : .waiting
        }
    }

    /// A failed refresh over rows that are still on screen.
    var showsFailureBanner: Bool { phase == .failed && rows.isEmpty == false }

    /// Hands the empty state's action outward: the shell owns the tabs and the
    /// setup screen. A `var` for the reason `SessionSetupViewModel.onStart` is
    /// one — the shell builds this in its initializer, before the state the
    /// closure reaches exists.
    var onSetUp: @MainActor (TestMode) -> Void

    private let sessions: GaitSessionRepository
    private let logService: LogService
    private let baselineIndex: Int
    /// Bumped per load, so a slow read that finishes after a newer one cannot
    /// overwrite it with an older answer.
    private var generation = 0
    private var hasLoaded = false
    /// Until the user picks a segment, the list opens on the mode they walked
    /// most recently — a user who only runs Full Tests should not land on an
    /// empty Quick Test list every time.
    private var hasChosenMode = false

    init(
        sessions: GaitSessionRepository,
        logService: LogService,
        baselineIndex: Int,
        onSetUp: @escaping @MainActor (TestMode) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.logService = logService
        self.baselineIndex = baselineIndex
        self.onSetUp = onSetUp
    }

    func select(_ mode: TestMode) {
        self.mode = mode
        hasChosenMode = true
    }

    func load() async {
        generation += 1
        let current = generation
        phase = .loading

        do {
            var loaded: [GaitSession] = []
            for mode in TestMode.allCases {
                // Valid only: invalid sessions never appear in History
                // [PRD §5, §6]. `SessionHistoryRow.rows` checks again.
                loaded += try await sessions.sessions(mode: mode, includeInvalid: false, limit: nil)
            }
            guard current == generation else { return }
            allRows = SessionHistoryRow.rows(from: loaded, baselineIndex: baselineIndex)
            if hasChosenMode == false, let newest = allRows.first {
                mode = newest.mode
            }
            hasLoaded = true
            phase = .loaded
        } catch {
            guard current == generation else { return }
            logService.log(.error, .persistence, "history load failed: \(error)")
            phase = .failed
        }
    }

    /// The empty state's action: to the Walk tab, with this mode chosen. It
    /// does not start anything — setup is still the user's to confirm.
    func setUp() {
        onSetUp(mode)
    }

    // MARK: - Copy

    static let modePickerLabel = "Test"
    /// The node's group title.
    static let sectionTitle = "Recent Sessions"
    static let rowHint = "Opens this walk's full result."

    /// Two variants, because an empty mode means two different things.
    ///
    /// With nothing in either mode it is the start of the app, and the copy says
    /// what the list is for. With walks in the *other* mode it is the moment
    /// [PRD §6] names — a user with a Quick Test history opening Full Test for
    /// the first time — where an empty list can read as data lost, so the copy
    /// says the modes are kept apart on purpose.
    var emptyState: EmptyState {
        let tests = "\(mode.displayName)s"
        let others = TestMode.allCases.filter { $0 != mode }
        let otherHasSessions = allRows.contains { $0.mode != mode }
        let required = SessionScorePresentation.spelledOut(Baseline.requiredValidSessionCount)

        let message: String
        if otherHasSessions, let other = others.first {
            message = """
                \(tests) keep their own baseline, separate from your \
                \(other.displayName)s. Your first \(required) valid \(tests) set it.
                """
        } else {
            message = """
                Each \(mode.displayName) you finish shows up here. Your first \
                \(required) valid \(tests) set your personal baseline, so later \
                walks have something to be compared with.
                """
        }

        return EmptyState(
            title: "No \(tests) Yet",
            message: message,
            actionTitle: "Set Up a \(mode.displayName)"
        )
    }

    static let failedTitle = "Sessions Couldn't Load"
    static let failedMessage = "Nothing has been changed. Try again in a moment."
    static let bannerMessage = "Your latest sessions couldn't be loaded. Nothing has been changed."
    static let retryLabel = "Try Again"
}
