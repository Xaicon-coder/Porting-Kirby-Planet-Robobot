// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Shared UI helpers: accent colours, service injection and the AppError alert modifier.

import SwiftUI
import UIKit

/// Colour palette of the app (soft pink accent, SF Symbols only, no third-party artwork).
enum PortTheme {
    static let accent = Color(red: 0.96, green: 0.40, blue: 0.64)
    static let accentDeep = Color(red: 0.82, green: 0.23, blue: 0.52)
    static let accentUIColor = UIColor(red: 0.96, green: 0.40, blue: 0.64, alpha: 1)
}

extension View {
    /// Injects every shared service as an environment object. Used at the root and again on every
    /// sheet / full screen cover so presented hierarchies never miss an object.
    @MainActor
    func injectPlanetServices() -> some View {
        environmentObject(EmulatorController.shared)
            .environmentObject(GameLibrary.shared)
            .environmentObject(SettingsStore.shared)
            .environmentObject(MultiplayerController.shared)
            .environmentObject(ControllerManager.shared)
    }

    /// Presents `error` in a standard alert with a single OK button. `onDismiss` runs when the user
    /// acknowledges it (before the binding is cleared).
    func appErrorAlert(_ error: Binding<AppError?>, onDismiss: ((AppError) -> Void)? = nil) -> some View {
        modifier(AppErrorAlertModifier(error: error, onDismiss: onDismiss))
    }
}

/// Backing modifier of `appErrorAlert(_:onDismiss:)`.
struct AppErrorAlertModifier: ViewModifier {
    @Binding var error: AppError?
    let onDismiss: ((AppError) -> Void)?

    func body(content: Content) -> some View {
        let isPresented = Binding<Bool>(
            get: { error != nil },
            set: { presented in
                if !presented { error = nil }
            }
        )
        return content.alert(error?.title ?? "", isPresented: isPresented, presenting: error) { current in
            Button("OK", role: .cancel) {
                onDismiss?(current)
            }
        } message: { current in
            Text(current.message)
        }
    }
}
