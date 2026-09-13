import Foundation

/// One recorded session (docs/05 §5.1).
///
/// Created in memory at recording start and committed to persistence only after
/// processing completes — valid or invalid. Invalid sessions are retained
/// locally for diagnostics and validity-counting transparency, but are excluded
/// from History, baseline counting, and export [REC + PRD].
///
/// **Invalid sessions are never scored** (CLAUDE.md hard rule). That is enforced
/// structurally: the memberwise initializer is private, and the only two ways to
/// build a session are `valid(...)`, which requires metrics, and `invalid(...)`,
/// which accepts neither metrics nor a score.
struct GaitSession: Sendable, Equatable, Identifiable {
    let id: UUID
    /// Stored with the session [PRD AC] and the key for every comparison [PRD OQ-5].
    let mode: TestMode
    let startedAt: Date
    let endedAt: Date
    /// What the clock ran, which is not what counted (docs/05 §5.1, [PRD OQ-3]).
    let advertisedClockElapsed: Duration
    /// Walking that actually counted, computed by the pipeline (docs/08 stage 4).
    let validWalkingDuration: Duration
    let outcome: SessionOutcome
    /// Valid sessions only [PRD §7].
    let metrics: GaitMetrics?
    /// Only when the mode's baseline existed at commit — from the 6th valid
    /// session onward [PRD §7].
    let score: SessionScore?
    /// The within-walk score, on its own 0-100 placeholder scale.
    ///
    /// Valid sessions only, and present from the **first** one — it needs no
    /// baseline. Kept beside `score` rather than merged into it because the two
    /// are different scales with different referents; see
    /// `ProvisionalStabilityScore` for why nothing that reads `relativeIndex`
    /// may ever read this. **[OPEN]** — the anchors behind it are a labelled
    /// placeholder pending Phase 12.
    let provisionalScore: ProvisionalStabilityScore?
    let audioConfig: SessionAudioConfig
    /// When the audio cue was silenced mid-walk, measured from T-0. Nil when it
    /// never was.
    ///
    /// The session keeps the config it *started* with, because that is what the
    /// user chose and what the first part of the walk actually had. This says
    /// the rest of it was silent. Only ever set by the user turning a cue off —
    /// there is no way to turn one on mid-walk, so a session is never part
    /// unpaced and part paced [PRD §5].
    let audioSilencedAt: Duration?
    let algorithmVersion: String
    let appVersion: String
    /// [REC] for future diagnostics.
    let deviceModel: String
    let interruptionCount: Int
    let gapInfo: SessionGapInfo
    /// False when the pedometer cross-check was unavailable while recording.
    /// Context metadata, kept alongside `gapInfo` to explain later analysis
    /// [REC — docs/05 §5.1].
    let pedometerAvailable: Bool

    private init(
        id: UUID,
        mode: TestMode,
        startedAt: Date,
        endedAt: Date,
        advertisedClockElapsed: Duration,
        validWalkingDuration: Duration,
        outcome: SessionOutcome,
        metrics: GaitMetrics?,
        score: SessionScore?,
        provisionalScore: ProvisionalStabilityScore?,
        audioConfig: SessionAudioConfig,
        audioSilencedAt: Duration? = nil,
        algorithmVersion: String,
        appVersion: String,
        deviceModel: String,
        interruptionCount: Int,
        gapInfo: SessionGapInfo,
        pedometerAvailable: Bool
    ) {
        self.id = id
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.advertisedClockElapsed = advertisedClockElapsed
        self.validWalkingDuration = validWalkingDuration
        self.outcome = outcome
        self.metrics = metrics
        self.score = score
        self.provisionalScore = provisionalScore
        self.audioConfig = audioConfig
        self.audioSilencedAt = audioSilencedAt
        self.algorithmVersion = algorithmVersion
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.interruptionCount = interruptionCount
        self.gapInfo = gapInfo
        self.pedometerAvailable = pedometerAvailable
    }

    /// A session that passed quality validation. Metrics are required; a score
    /// is present only when the mode's baseline already existed [PRD §7].
    static func valid(
        id: UUID,
        mode: TestMode,
        startedAt: Date,
        endedAt: Date,
        advertisedClockElapsed: Duration,
        validWalkingDuration: Duration,
        metrics: GaitMetrics,
        score: SessionScore? = nil,
        provisionalScore: ProvisionalStabilityScore? = nil,
        audioConfig: SessionAudioConfig,
        audioSilencedAt: Duration? = nil,
        algorithmVersion: String,
        appVersion: String,
        deviceModel: String,
        interruptionCount: Int = 0,
        gapInfo: SessionGapInfo = .none,
        pedometerAvailable: Bool = true
    ) -> GaitSession {
        GaitSession(
            id: id,
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            advertisedClockElapsed: advertisedClockElapsed,
            validWalkingDuration: validWalkingDuration,
            outcome: .valid,
            metrics: metrics,
            score: score,
            provisionalScore: provisionalScore,
            audioConfig: audioConfig,
            audioSilencedAt: audioSilencedAt,
            algorithmVersion: algorithmVersion,
            appVersion: appVersion,
            deviceModel: deviceModel,
            interruptionCount: interruptionCount,
            gapInfo: gapInfo,
            pedometerAvailable: pedometerAvailable
        )
    }

    /// A session that failed quality validation. It carries no metrics and no
    /// score, and never counts toward a baseline [PRD §5, §6, §7].
    static func invalid(
        id: UUID,
        mode: TestMode,
        reason: InvalidReason,
        startedAt: Date,
        endedAt: Date,
        advertisedClockElapsed: Duration,
        validWalkingDuration: Duration,
        audioConfig: SessionAudioConfig,
        audioSilencedAt: Duration? = nil,
        algorithmVersion: String,
        appVersion: String,
        deviceModel: String,
        interruptionCount: Int = 0,
        gapInfo: SessionGapInfo = .none,
        pedometerAvailable: Bool = true
    ) -> GaitSession {
        GaitSession(
            id: id,
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            advertisedClockElapsed: advertisedClockElapsed,
            validWalkingDuration: validWalkingDuration,
            outcome: .invalid(reason: reason),
            metrics: nil,
            score: nil,
            // An invalid session is never scored, on either scale [PRD §5, §7].
            provisionalScore: nil,
            audioConfig: audioConfig,
            audioSilencedAt: audioSilencedAt,
            algorithmVersion: algorithmVersion,
            appVersion: appVersion,
            deviceModel: deviceModel,
            interruptionCount: interruptionCount,
            gapInfo: gapInfo,
            pedometerAvailable: pedometerAvailable
        )
    }

    /// A copy of this session carrying `score`.
    ///
    /// The score is attached at commit rather than at construction, because the
    /// summary line needs history the pipeline does not have (entry 20).
    ///
    /// Returns nil for an invalid session. Invalid sessions are never scored
    /// [PRD AC], and this is the only path that could attach one after the fact,
    /// so the rule is enforced here rather than assumed.
    /// Every field is carried across explicitly. This rebuilds the session
    /// rather than mutating it, so anything left off here is silently lost at
    /// the moment a score is attached — which is what had been happening to
    /// `audioSilencedAt`, on exactly the sessions that get a score.
    func scored(_ score: SessionScore) -> GaitSession? {
        guard outcome.isValid, let metrics else { return nil }
        return GaitSession.valid(
            id: id, mode: mode, startedAt: startedAt, endedAt: endedAt,
            advertisedClockElapsed: advertisedClockElapsed,
            validWalkingDuration: validWalkingDuration,
            metrics: metrics, score: score, provisionalScore: provisionalScore,
            audioConfig: audioConfig, audioSilencedAt: audioSilencedAt,
            algorithmVersion: algorithmVersion, appVersion: appVersion,
            deviceModel: deviceModel, interruptionCount: interruptionCount,
            gapInfo: gapInfo, pedometerAvailable: pedometerAvailable
        )
    }

    var isValid: Bool { outcome.isValid }

    /// Whether this session counts toward its mode's five-session baseline
    /// requirement [PRD OQ-5].
    var countsTowardBaseline: Bool { outcome.isValid }

    /// Whether this session may appear in History and in an export archive
    /// [PRD §5, §6 — invalid sessions are excluded from both].
    var isUserVisible: Bool { outcome.isValid }
}
