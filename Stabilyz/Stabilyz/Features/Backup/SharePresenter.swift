import SwiftUI
import UIKit

/// Presents the system share sheet for an export file, and reports how it
/// ended (docs/13 §13.2 step 5, Task 10.2.2).
///
/// `UIActivityViewController` rather than `ShareLink`: `ShareLink` gives no
/// signal when the sheet closes, and the temporary file has to be deleted at
/// exactly that moment. The activity controller's completion handler fires
/// for every ending — an activity completed, the sheet cancelled, an activity
/// failed.
///
/// Presented from an invisible host controller placed behind the flow, so
/// UIKit presents it properly over the export sheet instead of nesting it in a
/// SwiftUI sheet that could be swiped away without the handler ever firing.
///
/// The destination is the person's choice, never the app's [PRD §5].
struct SharePresenter: UIViewControllerRepresentable {
    let export: PreparedExport
    /// Changes when the flow asks for the sheet again.
    let attempt: Int
    /// `failed` is whether the sheet reported an error; the error itself is
    /// not passed on, since nothing about it changes what the person is told.
    let onFinish: @MainActor (_ completed: Bool, _ failed: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let request = Coordinator.Request(exportID: export.id, attempt: attempt)
        guard context.coordinator.lastRequest != request else { return }
        context.coordinator.lastRequest = request

        let fileURL = export.fileURL
        let onFinish = self.onFinish
        // The next main-actor turn, so the host is in the window hierarchy
        // before it presents anything.
        Task { @MainActor in
            guard host.view.window != nil, host.presentedViewController == nil else { return }

            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = host.view
            activity.completionWithItemsHandler = { _, completed, _, error in
                let failed = error != nil
                // UIKit calls this on the main thread.
                MainActor.assumeIsolated {
                    onFinish(completed, failed)
                }
            }
            host.present(activity, animated: true)
        }
    }

    final class Coordinator {
        struct Request: Equatable {
            let exportID: UUID
            let attempt: Int
        }

        var lastRequest: Request?
    }
}
