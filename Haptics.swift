// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Haptic feedback for the on-screen controls.

import UIKit

@MainActor
enum Haptics {
    private static var impactGenerator: UIImpactFeedbackGenerator?

    /// Light impact, only if SettingsStore.shared.hapticsEnabled.
    static func buttonDown() {
        guard SettingsStore.shared.hapticsEnabled else { return }
        let generator: UIImpactFeedbackGenerator
        if let existing = impactGenerator {
            generator = existing
        } else {
            generator = UIImpactFeedbackGenerator(style: .light)
            impactGenerator = generator
        }
        generator.impactOccurred()
        // Keep the Taptic Engine warm for the next press.
        generator.prepare()
    }
}
