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
        .task { coordinator.start(mode: mode, audioConfig: audioConfig) }
        .onChange(of: coordinator.state) { _, state in
            handle(state)
        }
        .onChange(of: overlay) { _, content in
            announce(content)
        }
    }

    // MARK: - State

    private func handle(_ state: CountdownCoordinator.State) {
        switch state {
        case .running:
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
