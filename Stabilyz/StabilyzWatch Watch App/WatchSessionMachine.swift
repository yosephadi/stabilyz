import Foundation

/// The mode and length the phone has selected, for Waiting [PRD §8].
nonisolated struct WatchSelection: Equatable, Sendable {
    let mode: WireTestMode
    let durationSeconds: Int
}

/// One session as the watch knows it, from `countdownStarted` on.
nonisolated struct WatchSession: Equatable, Sendable {
    let id: UUID
    let selection: WatchSelection
    /// When Go is planned. The numerals count down to this on the watch's own
    /// clock; it is a plan, not the anchor.
    let plannedGoAt: Date
    /// The session's time origin, from `started`. Nil until it arrives.
    var t0: Date?
    let hapticOwner: WireHapticOwner
    var hapticsEnabled: Bool
    /// Set when the watch moved to Running on its own because `started` was
    /// late (`missedStartedGrace`). `t0` is then the planned Go until the real
    /// one arrives.
    var t0IsEstimated = false

    /// Whether this watch plays the session haptics right now: it owns them
    /// and Start & Stop Haptics is on [PRD §8 decision 3].
    var playsHaptics: Bool { hapticOwner == .watch && hapticsEnabled }
}

/// Where the watch is [docs/04 §4.18]:
/// `waiting → countingDown → running ⇄ disconnected → stopped → waiting`,
/// and `countingDown → waiting` on cancel.
nonisolated enum WatchPhase: Equatable, Sendable {
    case waiting
    case countingDown(WatchSession)
    case running(WatchSession)
    /// Entered from `running` only. The local timer keeps going from T-0, and
    /// Stop is hidden.
    case disconnected(WatchSession)
    case stopped(sessionID: UUID)

    var session: WatchSession? {
        switch self {
        case .countingDown(let session), .running(let session), .disconnected(let session): session
        case .waiting, .stopped: nil
        }
    }
}

/// Something that happened to the watch.
nonisolated enum WatchEvent: Equatable, Sendable {
    case received(PhoneToWatchMessage, at: Date)
    /// What the phone stored while the watch was not listening.
    case catchUp(WatchCatchUp, at: Date)
    /// The phone's stored copy changed while the watch was listening. Applied
    /// only if no live message catches the watch up within `storedDriftGrace`.
    case storedUpdate(WatchCatchUp, at: Date)
    case reachability(Bool, at: Date)
    /// The clock moved. Drives the numerals and timeouts.
    case tick(Date)
    case stopTapped(at: Date)
    case doneTapped
}

/// The session haptics the watch plays when it owns them [PRD §8 Haptics].
/// Candidates, to be verified on a real watch (Task 12.6.1).
nonisolated enum WatchHaptic: Equatable, Sendable {
    /// Each countdown numeral.
    case click
    /// Go.
    case start
    /// Stop, and a cancelled countdown.
    case stop
}

/// Something the watch must do because of an event. The machine decides; the
/// model carries it out.
nonisolated enum WatchEffect: Equatable, Sendable {
    /// A VoiceOver announcement.
    case announce(String)
    /// Ask the phone to stop this session.
    case sendStopRequest(UUID)
    case playHaptic(WatchHaptic)
}

/// The watch companion's state machine (Task 12.2.1, docs/04 §4.18).
///
/// Pure: no SwiftUI, no WatchKit, no clock of its own. Every input is a
/// `WatchEvent` and every output is a new phase plus `WatchEffect`s, so the
/// whole of the watch's behaviour is testable without a watch.
///
/// **The phone is authoritative** [PRD §8 decision 2]. A message about another
/// session is ignored, except `countdownStarted`, which always starts the new
/// one. The watch never ends a session on its own: Stop is a request, and the
/// watch moves to Stopped only when the phone says so.
nonisolated struct WatchSessionMachine: Equatable, Sendable {
    static let countdownStart = 5
    /// How long after the planned Go the watch waits for `started` before
    /// moving to Running on its own, from the planned Go and with no Go haptic.
    static let missedStartedGrace: TimeInterval = 2
    /// How long after its planned end a stored session still counts as
    /// current. Older than this, catch-up leaves the watch on Waiting.
    static let catchUpWindow: TimeInterval = 5 * 60
    /// How long Stop stays disabled after a tap with no answer from the phone.
    static let stopRetryInterval: TimeInterval = 3
    /// How long the phone's stored copy may stay ahead of the watch while
    /// connected before the watch catches up on it. A live message landing
    /// within this wins; past it, the live one was lost.
    static let storedDriftGrace: TimeInterval = 2

    private(set) var phase: WatchPhase = .waiting
    private(set) var selection: WatchSelection?
    private(set) var isPhoneReachable = false
    /// When Stop was tapped, while the request is unanswered. Stop is disabled
    /// until the phone answers, `stopRetryInterval` passes, or the phone
    /// becomes reachable again.
    private(set) var stopRequestedAt: Date?
    /// The numeral last announced, so each is announced once however often the
    /// clock ticks.
    private var announcedNumeral: Int?
    /// Sessions this watch has seen end — stopped, cancelled, or run out
    /// locally — so catch-up never brings one back.
    private var endedSessions: Set<UUID> = []
    /// A stored copy that is ahead of the watch, and since when it has been.
    private var storedAhead: StoredAhead?

    private struct StoredAhead: Equatable, Sendable {
        var stored: WatchCatchUp
        let since: Date
    }

    init() {}

    var isStopPending: Bool { stopRequestedAt != nil }

    /// The numeral showing at `now`: 5…1, counting down to `plannedGoAt`. Holds
    /// at 1 until `started` arrives.
    static func numeral(plannedGoAt: Date, at now: Date) -> Int {
        let remaining = plannedGoAt.timeIntervalSince(now)
        return min(max(Int(remaining.rounded(.up)), 1), countdownStart)
    }

    mutating func handle(_ event: WatchEvent) -> [WatchEffect] {
        switch event {
        case .received(let message, let now):
            return receive(message, at: now)
        case .catchUp(let stored, let now):
            return catchUp(stored, at: now)
        case .storedUpdate(let stored, let now):
            return storedUpdate(stored, at: now)
        case .reachability(let reachable, _):
            return reachabilityChanged(reachable)
        case .tick(let now):
            return tick(now)
        case .stopTapped(let now):
            return stopTapped(at: now)
        case .doneTapped:
            if case .stopped = phase { phase = .waiting }
            return []
        }
    }

    // MARK: - Messages

    private mutating func receive(_ message: PhoneToWatchMessage, at now: Date) -> [WatchEffect] {
        switch message {
        case .setupSelection(let mode, let seconds):
            selection = WatchSelection(mode: mode, durationSeconds: seconds)
            return []

        case .countdownStarted(let id, let mode, let seconds, let plannedGoAt, let owner, let enabled):
            let selection = WatchSelection(mode: mode, durationSeconds: seconds)
            self.selection = selection
            phase = .countingDown(WatchSession(
                id: id,
                selection: selection,
                plannedGoAt: plannedGoAt,
                t0: nil,
                hapticOwner: owner,
                hapticsEnabled: enabled
            ))
            stopRequestedAt = nil
            announcedNumeral = nil
            return tick(now)

        case .started(let id, let t0):
            guard var session = phase.session, session.id == id else { return [] }
            let wasCounting = if case .countingDown = phase { true } else { false }
            session.t0 = t0
            session.t0IsEstimated = false
            // A message just arrived, so the phone is reachable.
            isPhoneReachable = true
            phase = .running(session)
            // Go is felt and announced only on time. After the fallback has
            // moved on, a late `started` only re-syncs the clock.
            guard wasCounting else { return [] }
            return [.announce(WatchCopy.go)] + (session.playsHaptics ? [.playHaptic(.start)] : [])

        case .stopped(let id):
            guard let session = phase.session, session.id == id else { return [] }
            end(session.id, in: .stopped(sessionID: id))
            return session.playsHaptics ? [.playHaptic(.stop)] : []

        case .cancelled(let id):
            guard let session = phase.session, session.id == id else { return [] }
            end(session.id, in: .waiting)
            return session.playsHaptics ? [.playHaptic(.stop)] : []

        case .hapticsChanged(let enabled):
            update { $0.hapticsEnabled = enabled }
            return []
        }
    }

    // MARK: - Catch-up (Task 12.3.3)

    /// Rebuilds the screen from what the phone stored.
    ///
    /// **No cue for anything that already happened**: no replayed numeral, no
    /// late Go, no Stop buzz for a walk that ended while the watch was away.
    /// What happens *after* catching up plays as usual — a countdown joined at
    /// "2" still clicks 2 and 1 and plays Go.
    ///
    /// It never moves a session backwards, never revives one this watch saw
    /// end, and ignores a session more than `catchUpWindow` past its planned
    /// end.
    private mutating func catchUp(_ stored: WatchCatchUp, at now: Date) -> [WatchEffect] {
        storedAhead = nil
        if case .setupSelection(let mode, let seconds)? = stored.setup {
            selection = WatchSelection(mode: mode, durationSeconds: seconds)
        }

        guard case .countdownStarted(let id, let mode, let seconds, let plannedGoAt, let owner, let enabled)? = stored.countdown,
              isCurrent(stored, at: now) else { return [] }

        let known = phase.session?.id == id ? phase.session : nil
        var session = known ?? WatchSession(
            id: id,
            selection: WatchSelection(mode: mode, durationSeconds: seconds),
            plannedGoAt: plannedGoAt,
            t0: nil,
            hapticOwner: owner,
            hapticsEnabled: enabled
        )
        if case .hapticsChanged(let enabled)? = stored.haptics { session.hapticsEnabled = enabled }

        let state = stored.sessionState?.sessionID == id ? stored.sessionState : stored.countdown
        switch state {
        case .countdownStarted?:
            guard known == nil else {
                update { $0.hapticsEnabled = session.hapticsEnabled }
                return []
            }
            selection = session.selection
            phase = .countingDown(session)
            stopRequestedAt = nil
            // Only the numeral showing now is announced and felt; the ones the
            // watch missed are not replayed.
            announcedNumeral = nil
            return tick(now)

        case .started(_, let t0)?:
            let wasCounting = if case .countingDown = phase { true } else { false }
            session.t0 = t0
            session.t0IsEstimated = false
            let elapsed = now.timeIntervalSince(t0)
            // The walk already ran out while the watch was away, and the phone
            // is not there to say so: show it ended, without a buzz.
            if elapsed >= Double(seconds), !isPhoneReachable {
                end(id, in: .stopped(sessionID: id))
                return []
            }
            if case .disconnected = phase, known != nil {
                phase = .disconnected(session)
            } else {
                phase = isPhoneReachable || known == nil ? .running(session) : .disconnected(session)
            }
            // Go is still now if T-0 was under a moment ago: the stored copy
            // simply beat the live one here.
            guard wasCounting, known != nil, elapsed < WatchScreen.goHold else { return [] }
            return [.announce(WatchCopy.go)] + (session.playsHaptics ? [.playHaptic(.start)] : [])

        case .stopped?:
            end(id, in: .stopped(sessionID: id))
            return []

        case .cancelled?:
            if known != nil { phase = .waiting }
            endedSessions.insert(id)
            stopRequestedAt = nil
            return []

        default:
            return []
        }
    }

    /// Whether `stored` holds a session this watch has not seen end and that
    /// is within `catchUpWindow` of its planned end.
    private func isCurrent(_ stored: WatchCatchUp, at now: Date) -> Bool {
        guard case .countdownStarted(let id, _, let seconds, let plannedGoAt, _, _)? = stored.countdown else { return false }
        return !endedSessions.contains(id)
            && now.timeIntervalSince(plannedGoAt) <= Double(seconds) + Self.catchUpWindow
    }

    // MARK: - Stored updates while listening

    /// The phone's stored copy changed while the watch was listening.
    ///
    /// Normally the live message carries the same news, and may land just
    /// after the stored copy — so catching up at once would treat a live Go
    /// as one already past. Instead the watch notes that the stored copy is
    /// ahead, and catches up on it only if it is still ahead after
    /// `storedDriftGrace`: the live message was lost.
    private mutating func storedUpdate(_ stored: WatchCatchUp, at now: Date) -> [WatchEffect] {
        if case .setupSelection(let mode, let seconds)? = stored.setup {
            selection = WatchSelection(mode: mode, durationSeconds: seconds)
        }
        guard isAhead(stored, at: now) else {
            storedAhead = nil
            return []
        }
        storedAhead = StoredAhead(stored: stored, since: storedAhead?.since ?? now)
        return []
    }

    /// Whether `stored` is further along than the watch: a session it has not
    /// joined, or a later step of the one it shows. Running from an estimated
    /// T-0 counts as behind a stored `started`, so the clock re-syncs.
    private func isAhead(_ stored: WatchCatchUp, at now: Date) -> Bool {
        guard isCurrent(stored, at: now),
              case .countdownStarted(let id, _, _, _, _, _)? = stored.countdown else { return false }
        let state = stored.sessionState?.sessionID == id ? stored.sessionState : stored.countdown
        let storedStep = switch state {
        case .countdownStarted?: 1
        case .started?: 2
        case .stopped?, .cancelled?: 3
        default: 0
        }
        let watchStep: Int
        switch phase {
        case .waiting, .stopped:
            watchStep = 0
        case .countingDown(let session):
            guard session.id == id else { return false }
            watchStep = 1
        case .running(let session), .disconnected(let session):
            guard session.id == id else { return false }
            watchStep = session.t0IsEstimated ? 1 : 2
        }
        return storedStep > watchStep
    }

    private mutating func end(_ id: UUID, in phase: WatchPhase) {
        self.phase = phase
        endedSessions.insert(id)
        stopRequestedAt = nil
    }

    // MARK: - Reachability

    private mutating func reachabilityChanged(_ reachable: Bool) -> [WatchEffect] {
        let cameBack = reachable && !isPhoneReachable
        isPhoneReachable = reachable
        switch phase {
        case .running(let session) where !reachable:
            phase = .disconnected(session)
        case .disconnected(let session) where reachable:
            phase = .running(session)
        default:
            break
        }
        // A request sent into a dropped link may never have arrived. Let the
        // user try again once the phone is back.
        if cameBack { stopRequestedAt = nil }
        return []
    }

    // MARK: - Time

    private mutating func tick(_ now: Date) -> [WatchEffect] {
        if let pending = storedAhead {
            if !isAhead(pending.stored, at: now) {
                storedAhead = nil
            } else if now.timeIntervalSince(pending.since) >= Self.storedDriftGrace {
                // The live message was lost. Catch up — with no cue for what
                // is already past, as on launch.
                return catchUp(pending.stored, at: now)
            }
        }

        if let requested = stopRequestedAt, now.timeIntervalSince(requested) >= Self.stopRetryInterval {
            stopRequestedAt = nil
        }

        // 00:00 with the phone out of reach: the phone stops the walk on its
        // own clock, but cannot say so. Show it ended, and feel it if this
        // watch owns the haptics — the phone plays its fallback pulse too,
        // and the double buzz is accepted [PRD §8 decision 3].
        if case .disconnected(let session) = phase, let t0 = session.t0,
           now.timeIntervalSince(t0) >= Double(session.selection.durationSeconds) {
            end(session.id, in: .stopped(sessionID: session.id))
            return session.playsHaptics ? [.playHaptic(.stop)] : []
        }

        guard case .countingDown(var session) = phase else { return [] }

        // `started` never came: the phone may have missed sending it, or the
        // link dropped during the countdown. The walk is almost certainly
        // recording, so show it from the planned Go — without a Go haptic,
        // which would be late and might be wrong — and re-sync if it arrives.
        if now.timeIntervalSince(session.plannedGoAt) >= Self.missedStartedGrace {
            session.t0 = session.plannedGoAt
            session.t0IsEstimated = true
            phase = isPhoneReachable ? .running(session) : .disconnected(session)
            return []
        }

        let numeral = Self.numeral(plannedGoAt: session.plannedGoAt, at: now)
        guard numeral != announcedNumeral else { return [] }
        announcedNumeral = numeral
        return [.announce("\(numeral)")] + (session.playsHaptics ? [.playHaptic(.click)] : [])
    }

    // MARK: - Stop

    private mutating func stopTapped(at now: Date) -> [WatchEffect] {
        guard case .running(let session) = phase, stopRequestedAt == nil else { return [] }
        stopRequestedAt = now
        return [.sendStopRequest(session.id)]
    }

    // MARK: - Helpers

    private mutating func update(_ change: (inout WatchSession) -> Void) {
        switch phase {
        case .countingDown(var session):
            change(&session); phase = .countingDown(session)
        case .running(var session):
            change(&session); phase = .running(session)
        case .disconnected(var session):
            change(&session); phase = .disconnected(session)
        case .waiting, .stopped:
            break
        }
    }
}
