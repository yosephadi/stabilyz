import Foundation
import SwiftData
import Testing
@testable import Stabilyz

/// The DEBUG-only reset behind the Home-screen gesture
/// (docs/design/dev-notes.md, `Debug/DebugResetGesture.swift`).
///
/// The property that matters is not "the rows are gone" in the abstract — it is
/// that the **live** `StoreReader` the app has already been reading through
/// reports the store as empty afterwards. A reset that clears the file but
/// leaves that actor answering from a warm context would strand the app on Home
/// holding a profile it had just deleted, which is precisely the bug a dev tool
/// must not have.
///
/// This is also the by-hand check that chose the implementation.
/// `ModelContainer.deleteAllData()` is the obvious one-liner and does not work
/// here: against a container whose `@ModelActor`s already hold live contexts it
/// crashes the process outright. That is not written as a test, because a test
/// that crashes takes the suite with it — it is why `StoreWriter.eraseAllData()`
/// exists instead.
@Suite struct DebugResetTests {

    /// A store with a profile already fetched through the reader, so the actor's
    /// context is warm — the state a running app is always in.
    private func makeWarmStore() async throws -> InMemoryStore {
        let store = try InMemoryStore()
        try await store.profiles.save(.fixture(level: .transtibial, side: .left))
        #expect(try await store.profiles.fetchProfile() != nil, "setup did not store a profile")
        return store
    }

    @Test func theResetEmptiesTheStoreThroughTheLiveReader() async throws {
        let store = try await makeWarmStore()

        try await store.writer.eraseAllData()

        // The same repository instances the app would still be holding.
        #expect(try await store.profiles.fetchProfile() == nil, "the profile survived the reset")
        #expect(try await store.sessions.validSessionCount(mode: .quickTest) == 0)
        #expect(try await store.baselines.allBaselines().isEmpty)
    }

    @Test func theResetIsWhatSendsTheRouterBackToWelcome() async throws {
        // The end-to-end reason the tool exists: the phase is a total function
        // of stored state (docs/11 §11.1), so erasing and re-resolving has to
        // land on Welcome without a relaunch.
        let store = try await makeWarmStore()
        let router = await AppRouter(
            profiles: store.profiles,
            drafts: EmptyOnboardingDraftStore(),
            logService: SilentStoreLog()
        )

        await router.resolve()
        #expect(await router.phase == .main, "setup did not reach Home")

        try await store.writer.eraseAllData()
        await router.resolve()

        #expect(await router.phase == .firstLaunch)
    }

    @Test func erasingAnAlreadyEmptyStoreIsHarmless() async throws {
        // The gesture is one tap and dev builds get tapped twice.
        let store = try InMemoryStore()

        try await store.writer.eraseAllData()
        try await store.writer.eraseAllData()

        #expect(try await store.profiles.fetchProfile() == nil)
    }
}
