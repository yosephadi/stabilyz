import SwiftUI

/// The session cover: countdown, then the walk (Figma node 128:2591).
///
/// A full-screen cover with no navigation chrome — a deliberately modal,
/// interruption-free context (docs/11 §11.2). It opens at the countdown, which
/// is the first moment an interruption would cost the user something, and the
/// only ways out are Cancel before T-0 and Stop after it.
///
/// The countdown is an **overlay**, not a separate screen: the walk is drawn
/// underneath it from the start, so T-0 reveals what was already there rather
/// than pushing something new.
///
/// **The idle timer is not touched here.** `SessionRecorder` already holds it
/// down across the countdown *and* the session through `ScreenSleepController`
/// (docs/07 §7.7) — `prime()` disables it, `stop()` and `abort()` restore it. A
/// second writer on this screen would be two owners of one piece of system
/// state, with no ordering between them, which is the mistake docs/10 §10.2
/// calls out for the audio session.
struct SessionCoverView: View {
    let mode: TestMode
    let audioConfig: SessionAudioConfig
    let dependencies: AppDependencies
    /// Returns to the setup screen. Called on cancel, on failure, and after a
    /// walk is stopped.
    let dismiss: () -> Void

    @State private var coordinator: CountdownCoordinator
    @State private var session: ActiveSessionViewModel
    /// True for the moment after T-0, while "Go!" clears.
    @State private var isHoldingGo = false
    @State private var phase: SessionFlowPhase = .countdown
    @Environment(\.scenePhase) private var scenePhase

    init(
        mode: TestMode,
        audioConfig: SessionAudioConfig,
        dependencies: AppDependencies,
        dismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.audioConfig = audioConfig
        self.dependencies = dependencies
        self.dismiss = dismiss

        _coordinator = State(initialValue: CountdownCoordinator(
            recorder: dependencies.sessionRecorder,
            haptics: dependencies.hapticFeedback,
            audio: dependencies.audioFeedback,
            clock: dependencies.clock,
            logService: dependencies.logService
        ))
        let recorder = dependencies.sessionRecorder
        _session = State(initialValue: ActiveSessionViewModel(
            mode: mode,
            audioConfig: audioConfig,
            // Assigned below, once `self` exists — the closure has to reach the
            // view's state, which the initializer is still building.
            onStop: {},
            onSilenceAudioCue: {
                // Fire and forget, like every other audio request: the walk
                // must not wait on the engine going quiet (ledger 25).
                Task { await recorder.silenceAudioCues() }
            }
        ))
    }

    private var overlay: CountdownOverlayContent {
        .content(for: coordinator.state, isHoldingGo: isHoldingGo)
    }

    var body: some View {
        ZStack {
            switch phase {
            case .countdown, .recording:
                walk
            case .processing:
                ProcessingView(mode: mode)
                    .transition(.opacity)
            case .finished, .failed:
                // Task 8.2.5 puts the Score and Noisy screens here. Until then
                // the outcome is held on `phase` and the cover closes.
                ProcessingView(mode: mode)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Motion.countdownDismiss), value: phase)
        // No swipe-to-dismiss while the walk or its analysis is in flight
        // [PRD §5]: a recorded session the user can never see is worse than a
        // few seconds of waiting.
        .interactiveDismissDisabled(!phase.isDismissible)
        .task {
            session.onStop = endWalk
            coordinator.start(mode: mode, audioConfig: audioConfig)
        }
        .onChange(of: coordinator.state) { _, state in
            handle(state)
        }
        .onChange(of: overlay) { _, content in
            announce(content)
        }
        .onChange(of: scenePhase) { _, scene in
            if SessionBackgroundGuard.shouldCancelCountdown(
                scenePhase: scene,
                countdown: coordinator.state
            ) {
                cancelCountdown()
            }
        }
        .onChange(of: phase) { _, phase in
            if case .finished = phase { dismiss() }
            if case .failed = phase { dismiss() }
        }
    }

    /// The walk, with the countdown over it until T-0.
    private var walk: some View {
        ZStack {
            ActiveSessionView(model: session)
                // Nothing to read behind a countdown; VoiceOver should be on
                // the numerals until the walk actually starts.
                .accessibilityHidden(overlay.isVisible)

            if let text = overlay.text {
                CountdownOverlayView(
                    numeral: text,
                    isNumeral: overlay.isNumeral,
                    cancel: cancelCountdown
                )
                .transition(.opacity.combined(with: .scale(scale: 1.1)))
            }
        }
        .animation(.easeOut(duration: Motion.countdownDismiss), value: overlay)
    }

    // MARK: - Stop

    /// Stop, tapped or reached (docs/11 §11.3).
    ///
    /// Order matters: the pulse is requested first so the user feels the end at
    /// the moment it happens rather than after the screen has changed, then the
    /// recorder freezes the buffer and releases the sensors, and only then does
    /// the pipeline run. Like every other haptic it is requested, never awaited
    /// (ledger 25) — a wedged engine costs the walk its tap, never its data.
    private func endWalk() {
        guard phase.isRecording else { return }
        phase = .processing

        let recorder = dependencies.sessionRecorder
        let haptics = dependencies.hapticFeedback
        let log = dependencies.logService
        guard let outcomes = dependencies.sessionOutcomes else {
            // The store never opened, so this walk cannot be saved. Said
            // plainly rather than recorded into nothing (docs/15 §15.1).
            log.log(.error, .session, "session cannot be committed: no store")
            Task { _ = try? await dependencies.sessionRecorder.stop() }
            phase = .failed(.persistence(.saveFailed))
            return
        }

        if session.isHapticsOn {
            Task { await haptics.playSessionStop() }
        }

        Task {
            do {
                let buffer = try await recorder.stop()
                phase = .finished(try await outcomes.finish(buffer))
            } catch let error as StabilyzError {
                log.log(.error, .session, "session could not be completed")
                phase = .failed(error)
            } catch {
                log.log(.error, .session, "session could not be completed")
                phase = .failed(.processing(.cancelled))
            }
            await haptics.teardown()
        }
    }

    // MARK: - State

    private func handle(_ state: CountdownCoordinator.State) {
        switch state {
        case .running:
            phase = .recording
            reachedT0()
        case .cancelled:
            dismiss()
        case .failed:
            // The countdown already tore the recorder down; the setup screen
            // is where the error belongs, beside the Start button that will
            // try again [PRD §6].
            dismiss()
        case .idle, .priming, .counting:
            break
        }
    }

    /// T-0: hold "Go!", start draining the recorder's events, then clear.
    private func reachedT0() {
        guard let events = coordinator.recordingEvents else { return }

        isHoldingGo = true
        Task {
            // The walk is already recording; this only governs how long the
            // word stays up.
            try? await Task.sleep(for: .seconds(Motion.countdownGoHold))
            isHoldingGo = false
        }
        Task { await session.observe(events) }
    }

    private func cancelCountdown() {
        Task { await coordinator.cancel() }
    }

    /// One announcement per tick. Posted from the content rather than from the
    /// view's redraw, so a re-render cannot repeat a number.
    private func announce(_ content: CountdownOverlayContent) {
        guard let announcement = content.announcement else { return }
        AccessibilityNotification.Announcement(announcement).post()
    }
}
