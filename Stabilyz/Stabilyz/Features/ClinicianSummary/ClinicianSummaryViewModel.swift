import Foundation

/// Drives the Clinician Summary (docs/04 §4.14, [PRD §5, §7], Task 9.2.1).
///
/// Reads both modes on every load — each through its own mode-named queries
/// [PRD OQ-5] — and derives each mode's state through the shared
/// `BaselineStateMachine`, so this screen cannot disagree with Walk or Result
/// about how far calibration has got (docs/09 §9.4). The segment then only
/// chooses which mode's section to show.
@MainActor
@Observable
final class ClinicianSummaryViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The last read failed. Summaries from an earlier read are kept.
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var mode: TestMode
    private(set) var summaries: [TestMode: ClinicianModeSummary] = [:]

    /// The selected mode's section, and only that mode's.
    var selected: ClinicianModeSummary? { summaries[mode] }

    /// A failed refresh over a section still on screen.
    var showsFailureBanner: Bool { phase == .failed && selected != nil }

    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository
    private let logService: LogService
    private let baselineIndex: Int
    private let recentCount: Int
    private var generation = 0

    init(
        sessions: GaitSessionRepository,
        baselines: BaselineRepository,
        logService: LogService,
        baselineIndex: Int,
        mode: TestMode = .quickTest,
        recentCount: Int = ClinicianSummaryPolicy.recentScoredSessionCount
    ) {
        self.sessions = sessions
        self.baselines = baselines
        self.logService = logService
        self.baselineIndex = baselineIndex
        self.mode = mode
        self.recentCount = recentCount
    }

    func select(_ mode: TestMode) {
        self.mode = mode
    }

    func load() async {
        generation += 1
        let current = generation
        phase = .loading

        do {
            var loaded: [TestMode: ClinicianModeSummary] = [:]
            for mode in TestMode.allCases {
                let count = try await sessions.validSessionCount(mode: mode)
                let baseline = try await baselines.baseline(mode: mode)
                // Valid only [PRD §5, §6]; the summary filters again.
                let stored = try await sessions.sessions(mode: mode, includeInvalid: false, limit: nil)
                // Throws on a baseline from the other mode rather than
                // tolerating it — the one blend [PRD OQ-5] forbids outright.
                let state = try BaselineStateMachine.state(
                    for: mode,
                    validSessionCount: count,
                    baseline: baseline
                )
                loaded[mode] = ClinicianModeSummary(
                    mode: mode,
                    state: state,
                    sessions: stored,
                    baselineIndex: baselineIndex,
                    recentCount: recentCount
                )
            }
            guard current == generation else { return }
            summaries = loaded
            phase = .loaded
        } catch {
            guard current == generation else { return }
            logService.log(.error, .persistence, "clinician summary load failed: \(LogRedaction.describe(error))")
            phase = .failed
        }
    }

    // MARK: - Copy

    static let title = "Clinician Summary"
    static let closeLabel = "Close"
    static let modePickerLabel = "Test"
    static let failedMessage = "The summary couldn't be loaded. Nothing has been changed."
    static let retryLabel = "Try Again"
}
