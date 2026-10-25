// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Root of the window: the library in a navigation stack, gameplay as a full screen cover.

import SwiftUI
import PlanetCore

@MainActor
struct RootView: View {
    /// The game being played; non-nil while the emulation cover is presented.
    @State private var selectedGame: GameEntry?

    var body: some View {
        NavigationStack {
            HomeView(onPlay: { game in
                selectedGame = game
            })
        }
        .fullScreenCover(item: $selectedGame) { game in
            EmulationView(game: game)
                .injectPlanetServices()
                .tint(PortTheme.accent)
        }
    }
}
