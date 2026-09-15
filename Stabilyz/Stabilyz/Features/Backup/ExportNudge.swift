import Foundation

/// What the backup prompt remembers (docs/21 #11, decisions.md entry 43).
///
/// Two facts about this device, not about the user's data: they live beside
/// the onboarding draft in `UserDefaults`, never in the store, and so are
/// neither exported nor replaced by a restore.
protocol ExportNudgeStore: Sendable {
    var isDismissed: Bool { get }
    var hasExported: Bool { get }
    func recordDismissal()
    /// A backup reached a share destination, from any entry point.
    func recordExport()
}

/// `UserDefaults`-backed, like `UserDefaultsOnboardingDraftStore`.
///
/// `@unchecked Sendable` for the same reason: `UserDefaults` is documented as
/// thread-safe but is not marked `Sendable`.
struct UserDefaultsExportNudgeStore: ExportNudgeStore, @unchecked Sendable {
    static let dismissedKey = "com.stabilyz.exportNudge.dismissed"
    static let exportedKey = "com.stabilyz.exportNudge.exported"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDismissed: Bool { defaults.bool(forKey: Self.dismissedKey) }
    var hasExported: Bool { defaults.bool(forKey: Self.exportedKey) }

    func recordDismissal() { defaults.set(true, forKey: Self.dismissedKey) }
    func recordExport() { defaults.set(true, forKey: Self.exportedKey) }
}

/// For graphs that must not read or write the device's defaults.
final class InMemoryExportNudgeStore: ExportNudgeStore, Sendable {
    private let state = Locked((dismissed: false, exported: false))

    init(isDismissed: Bool = false, hasExported: Bool = false) {
        state.withLock { $0 = (isDismissed, hasExported) }
    }

    var isDismissed: Bool { state.withLock { $0.dismissed } }
    var hasExported: Bool { state.withLock { $0.exported } }

    func recordDismissal() { state.withLock { $0.dismissed = true } }
    func recordExport() { state.withLock { $0.exported = true } }
}

/// The Walk tab's backup prompt (Task 10.2.3).
///
/// Whether it shows is `ExportNudgePolicy`'s, over the setup screen's own
/// baseline states, so the card and the screen's baseline card can never
/// disagree about whether a baseline exists.
@MainActor
@Observable
final class ExportNudgeViewModel {
    private(set) var isDismissed: Bool
    private(set) var hasExported: Bool

    /// "Back up now": the shell presents Export My Data.
    var onBackUp: @MainActor () -> Void

    private let store: ExportNudgeStore
    private let logService: LogService

    init(store: ExportNudgeStore, logService: LogService, onBackUp: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.logService = logService
        self.onBackUp = onBackUp
        isDismissed = store.isDismissed
        hasExported = store.hasExported
    }

    func isVisible(given baselineStates: [TestMode: BaselineState]) -> Bool {
        ExportNudgePolicy.shouldShow(baselineStates: baselineStates, isDismissed: isDismissed, hasExported: hasExported)
    }

    func backUpNow() {
        logService.log(.info, .backup, "export nudge: back up now")
        onBackUp()
    }

    /// For good: the prompt does not come back [docs/21 #11].
    func dismiss() {
        store.recordDismissal()
        isDismissed = true
        logService.log(.info, .backup, "export nudge dismissed")
    }

    /// Re-reads the store — after an export sheet closes, and when the tab
    /// appears, since an export from Settings also retires the prompt.
    func refresh() {
        isDismissed = store.isDismissed
        hasExported = store.hasExported
    }

    // MARK: - Copy

    static let title = "Protect your data"
    static let message = "Your baseline is set. Create an encrypted backup to make sure your progress is never lost."
    static let backUpLabel = "Back up now"
    static let dismissLabel = "Dismiss"
}
