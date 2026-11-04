import Foundation

/// What the phone link reports.
nonisolated enum WatchLinkEvent: Equatable, Sendable {
    case message(PhoneToWatchMessage)
    case reachability(Bool)
    /// What the phone stored, on launch or when the phone comes back.
    case catchUp(WatchCatchUp)
    /// The phone's stored copy changed while the watch was listening.
    case storedUpdate(WatchCatchUp)
}

/// The watch's side of WatchConnectivity, behind a protocol so the model can be
/// tested with a fake. The live one is `WatchPhoneLink`.
nonisolated protocol WatchPhoneLinking: Sendable {
    /// Starts the link. Events arrive on the main actor.
    func activate(onEvent: @escaping @MainActor @Sendable (WatchLinkEvent) -> Void)
    func send(_ message: WatchToPhoneMessage)
}

/// Runs the state machine for the screens (Task 12.2.1).
///
/// Holds no rules of its own: it feeds the machine events — link messages,
/// reachability, taps, and a clock tick — and carries out the effects the
/// machine returns. Everything worth testing is in `WatchSessionMachine` and
/// `WatchScreen`.
@MainActor
@Observable
final class WatchSessionModel {
    private(set) var machine = WatchSessionMachine()
    private(set) var now: Date

    /// How often the clock ticks. Fast enough that a numeral changes within a
    /// tenth of a second of its moment.
    static let tickInterval: Duration = .milliseconds(100)

    private let link: WatchPhoneLinking
    private let haptics: WatchHapticPlaying
    /// Keeps the app running through wrist-down (Task 12.4.1). When, is
    /// `keepAlivePolicy`'s call.
    private let keepAlive: WatchKeepAliveControlling
    private(set) var keepAlivePolicy = WatchKeepAlivePolicy()
    /// Whether the app is active (frontmost, wrist raised). The keep-alive
    /// can start only then.
    private var isActive = false
    private let clock: @MainActor () -> Date
    private let announce: @MainActor (String) -> Void
    private var tickTask: Task<Void, Never>?

    init(
        link: WatchPhoneLinking,
        haptics: WatchHapticPlaying,
        keepAlive: WatchKeepAliveControlling = NoKeepAlive(),
        clock: @escaping @MainActor () -> Date = { Date() },
        announce: @escaping @MainActor (String) -> Void
    ) {
        self.link = link
        self.haptics = haptics
        self.keepAlive = keepAlive
        self.clock = clock
        self.announce = announce
        self.now = clock()
    }

    var screen: WatchScreen { WatchScreen(machine, at: now) }

    /// Activates the link and starts the clock. Call once.
    func start() {
        link.activate { [weak self] event in self?.receive(event) }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func receive(_ event: WatchLinkEvent) {
        let now = clock()
        switch event {
        case .message(let message): apply(.received(message, at: now))
        case .reachability(let reachable): apply(.reachability(reachable, at: now))
        case .catchUp(let stored): apply(.catchUp(stored, at: now))
        case .storedUpdate(let stored): apply(.storedUpdate(stored, at: now))
        }
    }

    /// The app became active or stopped being active (scene phase).
    func setActive(_ active: Bool) {
        isActive = active
        updateKeepAlive()
    }

    func tick() { apply(.tick(clock())) }
    func tapStop() { apply(.stopTapped(at: clock())) }
    func tapDone() { apply(.doneTapped) }

    private func apply(_ event: WatchEvent) {
        let effects = machine.handle(event)
        now = clock()
        for effect in effects {
            perform(effect)
        }
        updateKeepAlive()
    }

    private func updateKeepAlive() {
        switch keepAlivePolicy.update(phase: machine.phase, isActive: isActive, now: clock()) {
        case .start?:
            // The system ending it never touches the walk; it only lets the
            // policy start a new one at the next chance.
            keepAlive.start { [weak self] in self?.keepAlivePolicy.keepAliveEnded() }
        case .end?:
            keepAlive.end()
        case nil:
            break
        }
    }

    private func perform(_ effect: WatchEffect) {
        switch effect {
        case .announce(let text):
            announce(text)
        case .sendStopRequest(let id):
            link.send(.stopRequest(sessionID: id))
        case .playHaptic(let haptic):
            haptics.play(haptic)
        }
    }
}
