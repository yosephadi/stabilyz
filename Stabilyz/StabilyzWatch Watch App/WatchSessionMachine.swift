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
    /// How long Stop stays disabled after a tap with no answer from the phone.
    static let stopRetryInterval: TimeInterval = 3

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
            phase = .stopped(sessionID: id)
            stopRequestedAt = nil
            return session.playsHaptics ? [.playHaptic(.stop)] : []

        case .cancelled(let id):
            guard let session = phase.session, session.id == id else { return [] }
            phase = .waiting
            stopRequestedAt = nil
            return session.playsHaptics ? [.playHaptic(.stop)] : []

        case .hapticsChanged(let enabled):
            update { $0.hapticsEnabled = enabled }
            return []
        }
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
        if let requested = stopRequestedAt, now.timeIntervalSince(requested) >= Self.stopRetryInterval {
            stopRequestedAt = nil
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
