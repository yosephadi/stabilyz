import Foundation
import Testing
@testable import Stabilyz

/// The Walk tab's backup prompt (Task 10.2.3, docs/21 #11, decisions.md entry
/// 43, [PRD §6]).

// MARK: - Doubles

private final class QuietLog: LogService, @unchecked Sendable {
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {}
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// A throwaway defaults suite, removed by the test.
private struct ScratchDefaults {
    let name = "com.stabilyz.tests.exportNudge.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func remove() { UserDefaults().removePersistentDomain(forName: name) }
}

private let established = BaselineState.established(.fixture(mode: .quickTest))

// MARK: - Policy

@Test(arguments: [
    BaselineState.notStarted,
    .building(validCount: 1),
    .building(validCount: 4),
    .baselineRefused(validCount: 5)
])
func noPromptBeforeABaselineExists(_ state: BaselineState) {
    #expect(ExportNudgePolicy.shouldShow(
        baselineStates: [.quickTest: state, .fullTest: state],
        isDismissed: false,
        hasExported: false
    ) == false)
}

@Test func thePromptAppearsOnceAnyModesBaselineIsEstablished() {
    #expect(ExportNudgePolicy.shouldShow(
        baselineStates: [.quickTest: established, .fullTest: .building(validCount: 2)],
        isDismissed: false,
        hasExported: false
    ))
    #expect(ExportNudgePolicy.shouldShow(
        baselineStates: [.quickTest: .notStarted, .fullTest: .established(.fixture(mode: .fullTest))],
        isDismissed: false,
        hasExported: false
    ))
}

@Test func aDismissedOrExportedPromptStaysGone() {
    let states: [TestMode: BaselineState] = [.quickTest: established]
    #expect(ExportNudgePolicy.shouldShow(baselineStates: states, isDismissed: true, hasExported: false) == false)
    #expect(ExportNudgePolicy.shouldShow(baselineStates: states, isDismissed: false, hasExported: true) == false)
}

@Test func unloadedBaselineStatesShowNothing() {
    #expect(ExportNudgePolicy.shouldShow(baselineStates: [:], isDismissed: false, hasExported: false) == false)
}

// MARK: - On the Walk tab

@MainActor
@Test func thePromptAppearsWhenTheSetupScreenLearnsTheBaselineWasJustEstablished() {
    let setup = SessionSetupViewModel(
        sessions: UnwiredGaitSessionRepository(),
        baselines: UnwiredBaselineRepository(),
        motionSensor: UnwiredMotionSensorService(),
        logService: QuietLog(),
        onStart: { _, _, _ in }
    )
    let nudge = ExportNudgeViewModel(store: InMemoryExportNudgeStore(), logService: QuietLog())

    setup.apply(.building(validCount: 4), for: .quickTest)
    #expect(nudge.isVisible(given: setup.baselineStates) == false)

    // The fifth valid walk committed and the screen refreshed.
    setup.apply(established, for: .quickTest)
    #expect(nudge.isVisible(given: setup.baselineStates))
}

@MainActor
@Test func dismissingHidesThePromptAndItStaysHiddenAfterRelaunch() {
    let scratch = ScratchDefaults()
    defer { scratch.remove() }
    let states: [TestMode: BaselineState] = [.quickTest: established]

    let nudge = ExportNudgeViewModel(store: UserDefaultsExportNudgeStore(defaults: scratch.defaults), logService: QuietLog())
    #expect(nudge.isVisible(given: states))

    nudge.dismiss()
    #expect(nudge.isVisible(given: states) == false)

    // A new launch reads the same defaults.
    let relaunched = ExportNudgeViewModel(store: UserDefaultsExportNudgeStore(defaults: scratch.defaults), logService: QuietLog())
    #expect(relaunched.isVisible(given: states) == false)
}

@MainActor
@Test func anExportFromAnywhereRetiresThePromptOnItsNextRefresh() {
    let store = InMemoryExportNudgeStore()
    let states: [TestMode: BaselineState] = [.quickTest: established]
    let nudge = ExportNudgeViewModel(store: store, logService: QuietLog())
    #expect(nudge.isVisible(given: states))

    // Export My Data completed from Settings.
    store.recordExport()
    nudge.refresh()

    #expect(nudge.isVisible(given: states) == false)
}

@MainActor
@Test func backUpNowAsksForTheExportFlowAndLeavesThePromptUntilAnExportCompletes() {
    var requests = 0
    let states: [TestMode: BaselineState] = [.quickTest: established]
    let nudge = ExportNudgeViewModel(store: InMemoryExportNudgeStore(), logService: QuietLog(), onBackUp: { requests += 1 })

    nudge.backUpNow()

    #expect(requests == 1)
    #expect(nudge.isVisible(given: states), "opening the flow is not the same as having a backup")
}

@MainActor
@Test func thePromptSaysWhatItWasAskedToSay() {
    #expect(ExportNudgeViewModel.title == "Protect your data")
    #expect(ExportNudgeViewModel.message == "Your baseline is set. Create an encrypted backup to make sure your progress is never lost.")
    #expect(ExportNudgeViewModel.backUpLabel == "Back up now")
}

// MARK: - Wiring

@Test func theStoresRememberTheirTwoFacts() {
    let scratch = ScratchDefaults()
    defer { scratch.remove() }
    let defaults = UserDefaultsExportNudgeStore(defaults: scratch.defaults)
    #expect(defaults.isDismissed == false && defaults.hasExported == false)
    defaults.recordDismissal()
    defaults.recordExport()
    #expect(defaults.isDismissed && defaults.hasExported)

    let memory = InMemoryExportNudgeStore()
    memory.recordExport()
    #expect(memory.hasExported && memory.isDismissed == false)
}

@MainActor
@Test func bothProductionGraphsRememberThePromptOnTheDevice() throws {
    let live = AppDependencies.live(container: try StoreContainer.make(inMemory: true))
    #expect(live.exportNudgeStore is UserDefaultsExportNudgeStore)
    #expect(AppDependencies.storeUnavailable().exportNudgeStore is UserDefaultsExportNudgeStore)
}
