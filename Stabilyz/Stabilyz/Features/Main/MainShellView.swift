import SwiftUI

/// The app's three persistent surfaces (Figma node 123:914, docs/11 §11.1).
///
/// Walk / Result / You, named as the node names them. The tab bar is the
/// router chrome the setup screen sits inside — it belongs here rather than in
/// `SessionSetupView`, which draws only its own content.
///
/// Result and You are placeholders until their tasks land (9.1.1 History,
/// 9.2.1 Clinician Summary, Settings). They are named rather than empty so the
/// shell is visible in the running app, the same way `ContentView` names its
/// unbuilt phases.
struct MainShellView: View {
    let dependencies: AppDependencies
    /// Passed through so the DEBUG reset gesture can re-resolve the root.
    let router: AppRouter

    /// What Start hands over, and what the cover is presented with.
    ///
    /// A value rather than a `Bool`: the cover needs the mode and the audio
    /// config, and keeping them together means the hand-off is not
    /// reconstructed from the setup screen's state at the moment it is
    /// covered. Nil dismisses the cover.
    struct PendingSession: Equatable, Identifiable {
        let mode: TestMode
        let audioConfig: SessionAudioConfig

        /// The mode is enough: only one session can be pending at a time, and
        /// re-presenting the same mode is the same sheet.
        var id: TestMode { mode }
    }

    @State private var pendingSession: PendingSession?
    /// Held rather than rebuilt per body pass.
    ///
    /// It has to survive the cover: dismissing one re-runs this body, and a
    /// model constructed here each time would throw away the baseline states
    /// the just-committed session changed and start again from nothing —
    /// which is exactly what the screen must show after a commit [PRD §5].
    @State private var setupModel: SessionSetupViewModel

    init(dependencies: AppDependencies, router: AppRouter) {
        self.dependencies = dependencies
        self.router = router
        // `onStart` is assigned in `walkTab`'s task, once `self` exists: the
        // closure has to reach `pendingSession`, which this is still building.
        _setupModel = State(initialValue: SessionSetupViewModel(
            sessions: dependencies.gaitSessionRepository,
            baselines: dependencies.baselineRepository,
            motionSensor: dependencies.motionSensor,
            logService: dependencies.logService,
            openSettings: SystemSettingsLink.open,
            onStart: { _, _ in }
        ))
    }

    var body: some View {
        TabView {
            walkTab
                .tabItem { Label("Walk", systemImage: "figure.walk") }

            NavigationStack {
                TabPlaceholder(name: "Result", task: "Task 9.1.1")
                    .navigationTitle("Result")
            }
            .tabItem { Label("Result", systemImage: "text.document.fill") }

            NavigationStack {
                TabPlaceholder(name: "You", task: "Task 8.3.1")
                    .navigationTitle("You")
            }
            .tabItem { Label("You", systemImage: "person.fill") }
        }
        .tint(StabilyzColor.primary600)
    }

    /// The Walk tab: session setup, under the node's large "Walk" title, with
    /// the session cover over it once Start is tapped (docs/11 §11.2).
    private var walkTab: some View {
        NavigationStack {
            SessionSetupView(model: setupModel)
                .navigationTitle("Walk")
        }
        .fullScreenCover(item: $pendingSession) { session in
            SessionCoverView(
                mode: session.mode,
                audioConfig: session.audioConfig,
                dependencies: dependencies,
                dismiss: { pendingSession = nil }
            )
        }
        .task { setupModel.onStart = handOff }
        .onChange(of: pendingSession) { previous, current in
            // A committed session moves the mode's valid count and may have
            // established its baseline, both of which the setup screen's cards
            // and cue rules read [PRD §5]. Refreshed on the way out of the
            // cover rather than on a broadcast, because this is the only place
            // a session can commit from.
            guard previous != nil, current == nil else { return }
            Task { await setupModel.refreshBaselineStates() }
        }
    }

    /// Start, tapped: the chosen session is what the cover is presented with.
    private func handOff(mode: TestMode, audioConfig: SessionAudioConfig) {
        pendingSession = PendingSession(mode: mode, audioConfig: audioConfig)
        dependencies.logService.log(
            .info, .session,
            "session setup handed off: mode=\(mode.rawValue) audio=\(audioConfig)"
        )
    }
}

/// A named, unbuilt surface. Mirrors `ContentView`'s treatment of phases whose
/// screens have not arrived yet.
private struct TabPlaceholder: View {
    let name: String
    let task: String

    var body: some View {
        VStack(spacing: Space.x4) {
            Text(name)
                .font(StabilyzFont.heading)
                .foregroundStyle(StabilyzColor.ink900)
            Text("Arrives with \(task).")
                .font(StabilyzFont.smallRegular)
                .foregroundStyle(StabilyzColor.ink600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StabilyzColor.bgBase)
    }
}
