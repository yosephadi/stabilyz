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
    /// initializers receive what they need from here as they are built; the app
    /// currently launches to a placeholder screen (docs/22 Phase 1 DoD).
    private let dependencies = AppDependencies.live()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
