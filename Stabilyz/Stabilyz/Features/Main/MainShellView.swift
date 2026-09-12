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
    }

    /// Built per appearance rather than held, because the model reads the store
    /// on appear and the tab is the only thing that owns it.
    private var setupModel: SessionSetupViewModel {
        SessionSetupViewModel(
            sessions: dependencies.gaitSessionRepository,
            baselines: dependencies.baselineRepository,
            motionSensor: dependencies.motionSensor,
            logService: dependencies.logService,
            openSettings: SystemSettingsLink.open,
            onStart: { mode, audioConfig in
                pendingSession = PendingSession(mode: mode, audioConfig: audioConfig)
                dependencies.logService.log(
                    .info, .session,
                    "session setup handed off: mode=\(mode.rawValue) audio=\(audioConfig)"
                )
            }
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
