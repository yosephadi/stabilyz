import SwiftUI
import UniformTypeIdentifiers

/// First launch: the app's name, what it does, and the two ways in
/// [PRD §5] (Figma node 47:1275).
///
/// The wave mark, the title and the subtitle sit at the top; the illustration
/// runs full bleed beneath them, breaking the text margin entirely rather than
/// sharing it; the two capsules sit at the bottom on the same 70pt clearance the
/// wizard's primary uses, so the button does not move when the user taps through
/// to the first question.
///
/// The two `Spacer`s are what keep this working on a phone shorter than the
/// 874pt frame Figma draws: the header and the buttons hold their distance from
/// the two edges, and the illustration gives up the slack in between.
struct WelcomeView: View {
    /// "Get Started" — the only transition the router cannot derive from the
    /// store, so it is handed in rather than reached for (docs/12 §12.3).
    let beginOnboarding: () -> Void

    /// "Restore from Export": builds Restore your data around the file picked
    /// here, calling back when that screen is done with (Task 10.3.2).
    let makeRestore: @MainActor (_ onFinished: @escaping @MainActor () -> Void) -> RestoreDataViewModel

    @State private var isPickingFile = false
    @State private var restore: RestoreDataViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.screenMargin)

            Spacer(minLength: Space.x6)

            // Full bleed: the node draws this 402pt wide in a 402pt frame.
            Image("WelcomeIllustration")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                // Decorative. The title and subtitle already say everything it
                // says, so announcing it would only add a stop to navigate past.
                .accessibilityHidden(true)

            Spacer(minLength: Space.x6)

            actions
                .padding(.horizontal, Space.screenMargin)
        }
        .padding(.top, Space.x12)
        .padding(.bottom, Controls.footerBottomGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StabilyzColor.bgBase)
        // The picker opens over Welcome (Figma 64:4666); the passphrase screen
        // follows once there is a file to ask about. `.data` as well as the
        // export's type — see `RestoreDataView`.
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [ArchiveFormat.contentType, .data]
        ) { result in
            if case .failure(let error) = result, RestoreDataViewModel.isCancellation(error) { return }
            let model = makeRestore { restore = nil }
            restore = model
            Task { await model.fileImported(result) }
        }
        .fullScreenCover(item: $restore) { model in
            RestoreDataView(model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Space.x6) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(height: Controls.logoHeight)
                // The title directly beneath is the app's name in words.
                .accessibilityHidden(true)

            VStack(spacing: Space.x4) {
                Text("Stabilyz")
                    .font(StabilyzFont.heading)
                    .foregroundStyle(StabilyzColor.onboardingTitle)

                Text("Measure your walking stability over time, using your own baseline.")
                    .font(StabilyzFont.bodyRegular)
                    .foregroundStyle(StabilyzColor.onboardingTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Actions

    /// Both capsules are `CapsuleButtonStyle`, so the shape, the height and the
    /// edge-to-edge hit area are the same on each and neither view states them.
    private var actions: some View {
        VStack(spacing: Space.x4) {
            Button(action: beginOnboarding) {
                HStack(spacing: Space.x2) {
                    Text("Get Started")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.primaryCapsuleHero)

            // [PRD §5] puts restore here: a first launch that offered no route
            // back to an export would be the one screen where a returning user
            // is stuck.
            Button {
                isPickingFile = true
            } label: {
                HStack(spacing: Space.x2) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Restore from Export")
                }
            }
            .buttonStyle(.secondaryCapsuleHero)
        }
    }
}
