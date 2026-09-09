import AVFoundation
import Foundation

/// Production `AudioFeedbackService` over AVAudioEngine (docs/10 §10.2).
///
/// **This component solely owns `AVAudioSession`.** Nothing else in the app
/// configures, activates or observes it — the interruption observer from
/// Task 4.2.3 receives route and interruption events through this service's
/// `events` stream instead. One owner means the session's category and active
/// state have a single writer, and there is no ordering question between two
/// components both trying to manage it.
///
/// Buffers are synthesised and attached once at start-up, so a tick is a
/// `scheduleBuffer` on an already-running engine: no allocation, no file I/O and
/// no main-thread hop on the play path [PRD §7 — the sound must feel connected
/// to the step].
///
/// Every method is non-throwing. Audio failure is surfaced as silent degradation
/// and can never fail a session (docs/10 §10.4) — a walk is still measured
/// perfectly well in silence.
actor EngineAudioFeedbackService: AudioFeedbackService {
    private let engine: AVAudioEngine
    private let session: AVAudioSession
    private let logService: LogService

    /// One player node per tone, so a step tick never waits behind a stop tone.
    private var players: [Tone: AVAudioPlayerNode] = [:]
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]

    private var isPrepared = false
    private var isSuspended = false
    /// Tones actually handed to the engine.
    ///
    /// Exists so "dropped, not queued" is observable: a tick requested while
    /// suspended must never appear here, and must not appear later either.
    private(set) var scheduledToneCount = 0
    /// Whether audio has degraded to silence for the rest of the session.
    private(set) var isDegraded = false

    private nonisolated let continuation: AsyncStream<AudioFeedbackEvent>.Continuation
    nonisolated let events: AsyncStream<AudioFeedbackEvent>

    private var observers: [NSObjectProtocol] = []

    enum Tone: Hashable, CaseIterable {
        case start, stop, stepTick, metronome

        var spec: ToneSpec {
            switch self {
            case .start: .start
            case .stop: .stop
            case .stepTick: .stepTick
            case .metronome: .metronome
            }
        }
    }

    init(
        logService: LogService,
        engine: AVAudioEngine = AVAudioEngine(),
        session: AVAudioSession = .sharedInstance()
    ) {
        self.logService = logService
        self.engine = engine
        self.session = session

        let (stream, continuation) = AsyncStream<AudioFeedbackEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle

    /// Configures the session, attaches the nodes and preloads every buffer.
    ///
    /// Safe to call repeatedly. A failure here degrades to silence rather than
    /// propagating: the session still records.
    func prepare() async {
        guard !isPrepared else { return }

        do {
            // Playback, ducking off (docs/10 §10.2): the tones are the point,
            // not a layer over other audio, and ducking someone's music to play
            // a step tick would be its own annoyance.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            logService.log(.warning, .audio, "audio session unavailable; continuing silently")
            continuation.yield(.degraded)
            return
        }

        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            logService.log(.warning, .audio, "no output format; continuing silently")
            continuation.yield(.degraded)
            return
        }

        for tone in Tone.allCases {
            guard let buffer = ToneSynthesis.buffer(for: tone.spec, format: format) else { continue }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players[tone] = player
            buffers[tone] = buffer
        }

        observeSessionEvents()

        do {
            engine.prepare()
            try engine.start()
            for player in players.values { player.play() }
            isPrepared = true
            logService.log(.info, .audio, "audio engine started")
        } catch {
            logService.log(.warning, .audio, "audio engine failed to start; continuing silently")
            continuation.yield(.degraded)
        }
    }

    /// Stops the engine and releases the session.
    func teardown() async {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()

        if engine.isRunning { engine.stop() }
        players.removeAll()
        buffers.removeAll()
        isPrepared = false

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Whether the engine is running and able to play.
    var isRunning: Bool { isPrepared && engine.isRunning && !isSuspended }

    // MARK: - Tones

    func playStartTone() async { play(.start) }
    func playStopTone() async { play(.stop) }
    func playStepTick() async { play(.stepTick) }

    /// Task 7.2.2 supplies the scheduled metronome. A single click is available
    /// now so the engine's node is exercised rather than dormant.
    func startMetronome(bpm: Double) async {
        logService.log(.info, .audio, "metronome requested at \(Int(bpm)) bpm")
        play(.metronome)
    }

    func stopMetronome() async {
        players[.metronome]?.stop()
        players[.metronome]?.play()
    }

    /// Schedules a preloaded buffer on an already-running node.
    ///
    /// Nothing here allocates, reads a file or touches the main actor. A tone
    /// requested while suspended or degraded is silently dropped — [PRD §6]
    /// requires audio never to crash or freeze the session, and a queued tick
    /// arriving after an interruption would be worse than no tick.
    private func play(_ tone: Tone) {
        guard isPrepared, !isSuspended, !isDegraded, engine.isRunning,
              let player = players[tone], let buffer = buffers[tone]
        else { return }

        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        scheduledToneCount += 1
    }

    // MARK: - Suspend / resume (hooks for Task 7.1.2)

    /// Stops playback without tearing the engine down.
    ///
    /// Task 7.1.2 drives these from interruption and route-change events; they
    /// are separate from `teardown` because an interruption is temporary and
    /// rebuilding the engine for one would cost the latency the preload bought.
    func suspend() async {
        guard isPrepared, !isSuspended else { return }
        isSuspended = true
        for player in players.values { player.stop() }
        if engine.isRunning { engine.pause() }
        logService.log(.info, .audio, "audio suspended")
    }

    func resume() async {
        guard isPrepared, isSuspended else { return }
        do {
            try session.setActive(true)
            try engine.start()
            for player in players.values { player.play() }
            isSuspended = false
            logService.log(.info, .audio, "audio resumed")
        } catch {
            // Silence, not a crash. The session carries on regardless.
            degrade("could not resume after interruption")
        }
    }

    // MARK: - Degradation (Task 7.1.2)

    /// Applies an audio-session event to the engine (docs/10 §10.3).
    ///
    /// Separated from the notification observer so the state machine is
    /// testable without real hardware: a route change on a simulator cannot be
    /// provoked, but the response to one can be driven directly.
    ///
    /// **Nothing here touches the recorder.** Audio state is independent of the
    /// sample path, the gap machinery and the session's own event stream; the
    /// recorder learns of audio trouble only through the feedback signals it
    /// already carries, and those never count as recording interruptions
    /// (Task 4.2.3).
    func handle(_ event: AudioFeedbackEvent) async {
        switch event {
        case .interrupted:
            // A call or alarm took the session. Stop cleanly rather than
            // fighting for it [PRD §6].
            logService.log(.warning, .audio, "audio interrupted")
            await suspend()

        case .interruptionEnded:
            logService.log(.info, .audio, "audio interruption ended")
            await resume()

        case .routeChanged:
            // Headphones unplugged, AirPods gone flat, a switch to the car.
            // iOS reroutes playback itself; the engine may still need rebuilding
            // because the new route can have a different output format.
            logService.log(.info, .audio, "audio route changed")
            await reconfigureForRouteChange()

        case .degraded:
            // Already reported by whoever raised it.
            break
        }
    }

    /// Rebuilds the engine against the current route.
    ///
    /// A route change can change the output sample rate, which invalidates the
    /// existing connections and buffers. Rebuilding is cheap and happens between
    /// tones; failing to rebuild degrades to silence rather than leaving nodes
    /// connected to a format that no longer exists.
    private func reconfigureForRouteChange() async {
        guard isPrepared, !isDegraded else { return }

        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            degrade("no output format after route change")
            return
        }

        if engine.isRunning { engine.stop() }

        for (tone, player) in players {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            buffers[tone] = ToneSynthesis.buffer(for: tone.spec, format: format)
        }

        do {
            try engine.start()
            if !isSuspended {
                for player in players.values { player.play() }
            }
            logService.log(.info, .audio, "audio engine rebuilt for new route")
        } catch {
            degrade("engine would not restart after route change")
        }
    }

    /// Falls silent for the rest of the session.
    ///
    /// Silent to the user and logged for diagnostics [PRD §6]: there is no
    /// alert, no error screen and no interruption to the walk. The recording
    /// continues untouched.
    private func degrade(_ reason: String) {
        guard !isDegraded else { return }
        isDegraded = true
        for player in players.values { player.stop() }
        if engine.isRunning { engine.stop() }
        logService.log(.warning, .audio, "audio degraded: \(reason)")
        continuation.yield(.degraded)
    }

    // MARK: - Session events

    /// Publishes route and interruption events for the rest of the app.
    ///
    /// The interruption observer (Task 4.2.3) consumes these rather than
    /// observing `AVAudioSession` itself, so ownership stays here.
    private func observeSessionEvents() {
        let centre = NotificationCenter.default
        let continuation = self.continuation

        observers.append(
            centre.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session, queue: nil
            ) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let event: AudioFeedbackEvent = type == .began ? .interrupted : .interruptionEnded
                continuation.yield(event)
                Task { await self.handle(event) }
            }
        )

        observers.append(
            centre.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session, queue: nil
            ) { _ in
                continuation.yield(.routeChanged)
                Task { await self.handle(.routeChanged) }
            }
        )
    }
}
