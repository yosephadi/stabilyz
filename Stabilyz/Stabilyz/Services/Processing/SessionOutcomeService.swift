import Foundation

/// Turns a frozen recording into a committed session (docs/08, docs/11 §11.3).
///
/// The seam between Stop and the Score screen, and the one place the three
/// halves meet: the pipeline decides *what the walk was*, `GaitSession` is the
/// record of it, and `SessionCommitService` decides what it does to the
/// baseline. Each of those already exists and is tested on its own; this
/// orchestrates and adds no rules of its own.
///
/// **Nothing is written until the pipeline has finished.** A run that throws —
/// or is cancelled — leaves the store exactly as it was, so a failed analysis
/// costs the user their walk but never their history (docs/14 §14.3).
struct SessionOutcomeService: Sendable {
    private let processor: SessionProcessor
    private let commits: SessionCommitService
    private let baselines: BaselineRepository
    private let profiles: UserProfileRepository
    private let buildInfo: BuildInfoProviding
    private let logService: LogService

    init(
        processor: SessionProcessor,
        commits: SessionCommitService,
        baselines: BaselineRepository,
        profiles: UserProfileRepository,
        buildInfo: BuildInfoProviding,
        logService: LogService
    ) {
        self.processor = processor
        self.commits = commits
        self.baselines = baselines
        self.profiles = profiles
        self.buildInfo = buildInfo
        self.logService = logService
    }

    /// Analyses the buffer and commits whatever it concluded.
    ///
    /// Both outcomes are committed. An invalid session is still the user's
    /// walk: it is persisted for diagnostics, shown the plain-language noisy
    /// screen, and never scored, never counted toward a baseline, never listed
    /// in History [PRD §5, §6, §7] — all of which `SessionCommitService`
    /// already enforces.
    /// - Parameter id: the identity the stored row takes. Passed in rather
    ///   than minted here so a test can assert on a known session, and so a
    ///   retry of the same walk could reuse it rather than duplicating history.
    func finish(
        _ buffer: RawSessionBuffer,
        id: UUID = UUID()
    ) async throws -> SessionCommitResult {
        // The mode's own baseline, and only its own [PRD OQ-5]. The processor
        // refuses a mismatch, but asking for the right one is this layer's job.
        let baseline = try await baselines.baseline(mode: buffer.mode)
        // Context for the algorithm — an absent profile is not a failure, it
        // only means the unilateral asymmetry feature has no side to work from.
        let profile = try? await profiles.fetchProfile()

        let analysis = try await processor.process(
            buffer: buffer,
            baseline: baseline,
            profile: profile
        )

        let result = try await commits.commit(
            session(from: buffer, analysis: analysis, id: id),
            partialScore: partialScore(from: analysis)
        )

        logService.log(
            .info,
            .session,
            "session committed: mode=\(buffer.mode.rawValue) valid=\(result.session.isValid) count=\(result.validSessionCount)"
        )
        return result
    }

    // MARK: - Building the record

    private func session(
        from buffer: RawSessionBuffer,
        analysis: SessionAnalysisResult,
        id: UUID
    ) -> GaitSession {
        switch analysis.outcome {
        case .valid(let metrics, let validWalkingDuration, _):
            // The score is deliberately not attached here: only the commit
            // knows whether this mode's baseline existed *before* this session,
            // which is what decides whether a score may exist at all
            // [PRD §7, docs/09 §9.5].
            return .valid(
                id: id,
                mode: buffer.mode,
                startedAt: buffer.startedAt,
                endedAt: buffer.endedAt,
                advertisedClockElapsed: buffer.advertisedClockElapsed,
                validWalkingDuration: validWalkingDuration,
                metrics: metrics,
                audioConfig: buffer.audioConfig,
                audioSilencedAt: buffer.audioSilencedAt,
                algorithmVersion: analysis.algorithmVersion,
                appVersion: buildInfo.appVersion,
                deviceModel: buildInfo.deviceModel,
                interruptionCount: buffer.interruptionCount,
                gapInfo: buffer.gapInfo,
                pedometerAvailable: buffer.pedometerAvailable
            )

        case .invalid(let reason, let validWalkingDuration):
            return .invalid(
                id: id,
                mode: buffer.mode,
                reason: reason,
                startedAt: buffer.startedAt,
                endedAt: buffer.endedAt,
                advertisedClockElapsed: buffer.advertisedClockElapsed,
                validWalkingDuration: validWalkingDuration,
                audioConfig: buffer.audioConfig,
                audioSilencedAt: buffer.audioSilencedAt,
                algorithmVersion: analysis.algorithmVersion,
                appVersion: buildInfo.appVersion,
                deviceModel: buildInfo.deviceModel,
                interruptionCount: buffer.interruptionCount,
                gapInfo: buffer.gapInfo,
                pedometerAvailable: buffer.pedometerAvailable
            )
        }
    }

    private func partialScore(from analysis: SessionAnalysisResult) -> PartialSessionScore? {
        guard case .valid(_, _, let score) = analysis.outcome else { return nil }
        return score
    }
}
