#if DEBUG
import SwiftUI

/// A hidden five-tap gesture that erases the app's stored state, for testing
/// first-launch flows without leaving the simulator
/// (docs/design/dev-notes.md).
///
/// **Debug builds only.** The whole file is inside `#if DEBUG`: in a release
/// build the modifier does not exist, so an accidental call site fails to
/// compile rather than shipping a hidden data-loss gesture on Home.
/// `DebugIsolationGuardTests` holds that, and holds that nothing outside a
/// `#if DEBUG` block names it.
///
/// **Why this lives in `Debug/` rather than `Features/`.** `Features/` is
/// scanned by `DesignTokenGuardTests` for raw colours, font sizes and spacing,
/// and by `TerminologyGuardTests` for user-facing copy. Neither rule is meant
/// for a developer tool: this UI has no user, is never seen by one, and is not
/// part of the design system it would otherwise be held to. Putting it outside
/// those scans is the point — but it is a deliberate exemption, not an
/// accidental one, which is why it gets its own folder and this paragraph
/// rather than a quiet exception list inside the guards.
///
/// Five taps rather than a shake: this app reads the accelerometer, and a
/// shake-to-reset gesture living near session recording is asking for the one
/// bug report nobody can reproduce.
struct DebugResetGesture: ViewModifier {
    /// Taps needed to fire. High enough that nothing reaches it by accident,
    /// low enough to be quick when it is the twentieth reset of the day.
    static let tapCount = 5

    let perform: () async -> Void

    func body(content: Content) -> some View {
        content.onTapGesture(count: Self.tapCount) {
            Task { await perform() }
        }
    }
}

extension View {
    /// Erases the store and the app's `UserDefaults`, then re-resolves the
    /// router — one action, no confirmation, no recovery.
    ///
    /// The router is re-resolved rather than the phase being set directly:
    /// `AppRouter` derives its phase from stored state, so reading the emptied
    /// store is what proves the reset actually worked. Setting `.firstLaunch`
    /// by hand would show Welcome whether or not anything was deleted.
    func debugResetGesture(
        writer: StoreWriter?,
        router: AppRouter
    ) -> some View {
        modifier(DebugResetGesture {
            guard let writer else { return }
            await DebugDataReset.eraseEverything(writer: writer)
            await router.resolve()
        })
    }
}
#endif
