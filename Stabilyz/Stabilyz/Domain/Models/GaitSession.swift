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
    let audioConfig: SessionAudioConfig
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
        audioConfig: SessionAudioConfig,
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
        self.audioConfig = audioConfig
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
        audioConfig: SessionAudioConfig,
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
            audioConfig: audioConfig,
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
            audioConfig: audioConfig,
            algorithmVersion: algorithmVersion,
            appVersion: appVersion,
            deviceModel: deviceModel,
            interruptionCount: interruptionCount,
            gapInfo: gapInfo,
            pedometerAvailable: pedometerAvailable
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
