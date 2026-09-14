import SwiftUI

/// The app's three persistent surfaces (Figma node 123:914, docs/11 §11.1).
///
/// Walk / Result / You, named as the node names them. The tab bar is the
/// router chrome the setup screen sits inside — it belongs here rather than in
/// `SessionSetupView`, which draws only its own content.
///
/// Result carries the session list and trend (Tasks 9.1.1, 9.1.2), with the
/// Clinician Summary behind its stethoscope (Task 9.2.1). You is a placeholder
/// until its task lands, named rather than empty so the shell is visible in the
/// running app, the same way `ContentView` names its unbuilt phases.
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
        /// Start & Stop Haptics, as the user left it on the setup screen.
        let hapticsEnabled: Bool

        /// The mode is enough: only one session can be pending at a time, and
        /// re-presenting the same mode is the same sheet.
        var id: TestMode { mode }
    }

    /// Named so it does not shadow SwiftUI's own `Tab`.
    enum ShellTab: Hashable {
        case walk
        case result
        case you
    }

    /// Selected so History's empty state can hand the user to the Walk tab.
    @State private var selectedTab: ShellTab = .walk
    @State private var pendingSession: PendingSession?
    /// Held rather than rebuilt per body pass.
    ///
    /// It has to survive the cover: dismissing one re-runs this body, and a
    /// model constructed here each time would throw away the baseline states
    /// the just-committed session changed and start again from nothing —
    /// which is exactly what the screen must show after a commit [PRD §5].
    @State private var setupModel: SessionSetupViewModel
    /// Held for the same reason: the filter the user chose should survive the
    /// cover, and the list is refreshed rather than rebuilt when it closes.
    @State private var historyModel: SessionListViewModel
    /// The Result tab's stethoscope: the Clinician Summary (Task 9.2.1). Each
    /// presentation builds a fresh model, so it always reads the store as it is.
    @State private var showsClinicianSummary = false

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
            onStart: { _, _, _ in }
        ))
        _historyModel = State(initialValue: SessionListViewModel(
            sessions: dependencies.gaitSessionRepository,
            logService: dependencies.logService,
            // What a baseline scores by construction, from the configuration
            // the pipeline used — the same source the Score screen reads.
            baselineIndex: Int(AlgorithmConfiguration.v1.composite.indexCenter)
        ))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            walkTab
                .tabItem { Label("Walk", systemImage: "figure.walk") }
                .tag(ShellTab.walk)

            NavigationStack {
                SessionListView(model: historyModel)
                    .navigationTitle("Result")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showsClinicianSummary = true
                            } label: {
                                Image(systemName: "stethoscope")
                            }
                            .accessibilityLabel(ClinicianSummaryViewModel.title)
                        }
                    }
            }
            .sheet(isPresented: $showsClinicianSummary) {
                ClinicianSummaryView(model: ClinicianSummaryViewModel(
                    sessions: dependencies.gaitSessionRepository,
                    baselines: dependencies.baselineRepository,
                    logService: dependencies.logService,
                    baselineIndex: Int(AlgorithmConfiguration.v1.composite.indexCenter),
                    // Opens on the mode the user was looking at.
                    mode: historyModel.mode
                ))
            }
            .tabItem { Label("Result", systemImage: "text.document.fill") }
            .tag(ShellTab.result)
            .task { historyModel.onSetUp = setUpFromHistory }

            NavigationStack {
                TabPlaceholder(name: "You", task: "Task 8.3.1")
                    .navigationTitle("You")
            }
            .tabItem { Label("You", systemImage: "person.fill") }
            .tag(ShellTab.you)
        }
        .tint(StabilyzColor.primary600)
    }

    /// An empty History mode's "Set Up" action: the Walk tab, with that mode
    /// chosen. Nothing starts — Start is still the user's to tap.
    private func setUpFromHistory(_ mode: TestMode) {
        setupModel.select(mode)
        selectedTab = .walk
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
                hapticsEnabled: session.hapticsEnabled,
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
            // The walk just committed belongs at the top of Result
            // (docs/11 §11.2: History refresh reflects the committed session).
            Task { await historyModel.load() }
        }
    }

    /// Start, tapped: the chosen session is what the cover is presented with.
    private func handOff(mode: TestMode, audioConfig: SessionAudioConfig, hapticsEnabled: Bool) {
        pendingSession = PendingSession(
            mode: mode,
            audioConfig: audioConfig,
            hapticsEnabled: hapticsEnabled
        )
        dependencies.logService.log(
            .info, .session,
            "session setup handed off: mode=\(mode.rawValue) audio=\(audioConfig) haptics=\(hapticsEnabled)"
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
