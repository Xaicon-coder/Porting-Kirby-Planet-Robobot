// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Application entry point.

import SwiftUI
import PlanetCore

@main
struct PlanetPortApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .injectPlanetServices()
                .tint(PortTheme.accent)
                .onAppear {
                    // bootstrap() is idempotent: it prepares the core, the audio session,
                    // multiplayer and game controller support.
                    EmulatorController.shared.bootstrap()
                    Task { await GameLibrary.shared.refresh() }
                }
        }
        .onChange(of: scenePhase) { phase in
            EmulatorController.shared.handleScenePhase(phase)
        }
    }
}
