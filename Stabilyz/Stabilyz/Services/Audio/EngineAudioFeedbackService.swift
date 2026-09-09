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
        guard isPrepared, !isSuspended, engine.isRunning,
              let player = players[tone], let buffer = buffers[tone]
        else { return }

        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
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
            // Staying suspended is the safe failure: silence, not a crash.
            logService.log(.warning, .audio, "audio could not resume; continuing silently")
            continuation.yield(.degraded)
        }
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
                continuation.yield(type == .began ? .interrupted : .interruptionEnded)
            }
        )

        observers.append(
            centre.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session, queue: nil
            ) { _ in
                continuation.yield(.routeChanged)
            }
        )
    }
}
