import Foundation

/// The metronome's tempo for one session, and the structural proof that it came
/// from the right place (docs/10 §10.1, §10.3, Task 7.2.2).
///
/// The PRD gates the metronome twice: it is offered **only once that mode's
/// baseline exists** [PRD §5, §7], and the tempo is **that mode's**
/// `Baseline.cadenceBPM` [PRD §5]. Both gates are enforced by construction
/// rather than by a check at the call site — there is no initializer that takes
/// a bare BPM, so a session in its first five cannot select the metronome and a
/// Quick Test cannot borrow the Full Test's tempo.
///
/// It carries the mode it was built for so the mismatch is visible in the value
/// itself, not only in the code that built it.
struct MetronomeCue: Sendable, Equatable, Codable {
    let mode: TestMode
    let bpm: Double

    /// The tempo, from that mode's baseline, or nil when the metronome is not
    /// available for this session.
    ///
    /// Nil in exactly the cases the PRD forbids offering it: no baseline for
    /// this mode yet (sessions 1–5), or a baseline belonging to the other mode
    /// [PRD OQ-5 — a mode's results are only ever compared with its own].
    init?(baseline: Baseline?, mode: TestMode) {
        guard let baseline, baseline.mode == mode else { return nil }
        guard baseline.cadenceBPM.isFinite, baseline.cadenceBPM > 0 else { return nil }

        self.mode = mode
        self.bpm = baseline.cadenceBPM
    }

    /// Seconds between beats — `60 / bpm` (docs/10 §10.1).
    var interval: Duration { .seconds(60 / bpm) }

    /// What is persisted with the session, so a reader knows the walk was
    /// paced (docs/05 §5.1, docs/10 §10.4 — the PRD-sanctioned influence).
    var audioConfig: SessionAudioConfig { .metronome(cue: self) }

    // MARK: - Coding

    /// Decoding is a **read of history**, not a new opt-in.
    ///
    /// A persisted session records the tempo a past walk was actually paced at;
    /// the baseline that justified it may since have been replaced, and
    /// re-deriving it would rewrite the record. So decoding re-checks what is
    /// still checkable — a real, positive tempo — and refuses a row that could
    /// only come from corruption, rather than silently reconstructing one
    /// (the same reasoning as `Baseline`, reached the other way: `Baseline`
    /// declines `Codable` entirely because its invariant *can* be re-checked
    /// and synthesized decoding would skip it).
    private enum CodingKeys: String, CodingKey { case mode, bpm }

    enum DecodingError: Error, Equatable {
        case implausibleTempo(Double)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bpm = try container.decode(Double.self, forKey: .bpm)

        guard bpm.isFinite, bpm > 0 else {
            throw DecodingError.implausibleTempo(bpm)
        }

        self.mode = try container.decode(TestMode.self, forKey: .mode)
        self.bpm = bpm
    }
}
