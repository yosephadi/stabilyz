//
//  StabilyzApp.swift
//  Stabilyz
//
//  Created by Adi's Mac on 09/09/26.
//

import SwiftUI

@main
struct StabilyzApp: App {
    /// The composition root, built exactly once (docs/12 §12.1). Feature
    /// initializers receive what they need from here as they are built. The
    /// root is `AppRouter` (docs/11 §11.1); each phase's screen arrives with its
    /// own task.
    private let dependencies: AppDependencies

    init() {
        do {
            dependencies = try AppDependencies.live()
            dependencies.logService.log(.info, .app, "Stabilyz launched")
        } catch {
            // Never crash on a store that will not open; run degraded and say so.
            let degraded = AppDependencies.storeUnavailable()
            degraded.logService.log(.error, .persistence, "store unavailable at launch: \(error)")
            dependencies = degraded
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                router: AppRouter(
                    profiles: dependencies.userProfileRepository,
                    drafts: dependencies.onboardingDrafts,
                    logService: dependencies.logService,
                    recovery: dependencies.restoreRecovery
                ),
                dependencies: dependencies
            )
        }
    }
}
