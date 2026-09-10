#if DEBUG
import Foundation
import SwiftData

/// Erases everything the app has persisted, for testing first-launch flows
/// (docs/design/dev-notes.md).
///
/// **Debug builds only.** The whole file is inside `#if DEBUG`, so these symbols
/// do not exist in a release build and an accidental release call site fails to
/// compile rather than shipping a data-loss button. `DebugIsolationGuardTests`
/// holds that property.
///
/// It lives in `Persistence/` rather than beside the gesture in `Debug/` for the
/// ordinary reason: this is the layer allowed to import SwiftData (CLAUDE.md,
/// docs/03 rule 2). Only the gesture is debug-shaped UI; the erase itself is a
/// persistence operation and is written like one.
///
/// There is no confirmation and no recovery. Dev builds are throwaway state —
/// that is the point of the tool, and a reset that asks twice is one that gets
/// in the way twenty times a day.
enum DebugDataReset {

    /// The two artifacts that together answer "does a user exist?".
    ///
    /// `AppRouter.resolve()` derives its phase from stored state alone
    /// (docs/11 §11.1), so emptying both and re-resolving lands on Welcome with
    /// no relaunch. Clearing only the store would leave the draft behind and
    /// resume the wizard mid-flow instead of showing Welcome.
    static func eraseEverything(writer: StoreWriter) async {
        do {
            try await writer.eraseAllData()
        } catch {
            // A debug tool that cannot erase must say so, not leave a
            // half-cleared store looking like a clean one.
            assertionFailure("debug reset could not erase the store: \(error)")
        }
        eraseDefaults()
    }

    /// Removes the app's whole `UserDefaults` domain, not just the onboarding
    /// draft's key.
    ///
    /// The draft is the only key today, but Settings will add more, and a reset
    /// that clears one key by name quietly stops being a reset the moment it
    /// does. Dropping the domain stays correct without anyone remembering to
    /// update it.
    static func eraseDefaults() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }
}

extension StoreWriter {
    /// Deletes every row, through the store's single write path.
    ///
    /// **Not** `ModelContainer.deleteAllData()`. That call crashes the process
    /// against a container whose `@ModelActor`s already hold live contexts —
    /// which is every running app by the time anyone reaches for a reset, and
    /// was reproducible here the moment a profile had been fetched once. Going
    /// through the writer's own context deletes the way every other write in
    /// the app deletes, so `StoreReader` sees an empty store immediately and
    /// the router re-resolves to Welcome. `DebugResetTests` pins that.
    ///
    /// One transaction, like every other method here.
    func eraseAllData() throws {
        try modelContext.delete(model: UserProfileEntity.self)
        try modelContext.delete(model: GaitSessionEntity.self)
        try modelContext.delete(model: BaselineEntity.self)
        try modelContext.save()
    }
}
#endif
