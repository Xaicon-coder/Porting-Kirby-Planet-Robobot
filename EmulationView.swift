// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Full-screen gameplay: render surface, touch controls, pause menu and status overlays.

import SwiftUI
import UIKit
import PlanetCore

@MainActor
struct EmulationView: View {
    let game: GameEntry

    @EnvironmentObject private var emulator: EmulatorController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controllers: ControllerManager
    @EnvironmentObject private var multiplayer: MultiplayerController
    @Environment(\.dismiss) private var dismiss

    @State private var isMenuVisible = false
    @State private var activeSheet: EmulationSheet?
    @State private var isExiting = false
    @State private var sessionBegan = false
    @State private var didClose = false
    @State private var confirmRestart = false
    @State private var confirmExit = false

    private enum EmulationSheet: String, Identifiable {
        case saveStates
        case multiplayer
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let frames = EmulationLayout(size: proxy.size)
            ZStack(alignment: .topLeading) {
                // Always the first child so the CAMetalLayer keeps its identity across rotations.
                MetalScreenView { layer, drawableSize, portrait in
                    EmulatorController.shared.start(
                        game: game,
                        layer: layer,
                        drawableSize: drawableSize,
                        portrait: portrait
                    )
                }
                .frame(width: frames.screen.width, height: frames.screen.height)
                .position(x: frames.screen.midX, y: frames.screen.midY)

                if showsTouchControls {
                    GamepadOverlay(
                        isPortrait: frames.isPortrait,
                        opacity: settings.controlsOpacity,
                        leftStyle: settings.leftControlStyle
                    )
                    .frame(width: frames.pad.width, height: frames.pad.height)
                    .position(x: frames.pad.midX, y: frames.pad.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { refreshMotionOrientation() }
            .onChange(of: proxy.size) { _ in
                refreshMotionOrientation()
                // The scene orientation can settle slightly after the new size during rotation.
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    refreshMotionOrientation()
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $emulator.keyboardPrompt) { prompt in
            KeyboardPromptView(prompt: prompt)
                .injectPlanetServices()
                .tint(PortTheme.accent)
        }
        .overlay(alignment: .topLeading) { infoOverlay }
        .overlay(alignment: .top) { toastOverlay }
        .overlay { statusOverlay }
        .overlay(alignment: .topTrailing) { menuButton }
        .overlay {
            if isMenuVisible {
                pauseMenu
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isMenuVisible)
        .animation(.easeInOut(duration: 0.25), value: emulator.toast)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .saveStates:
                SaveStatesView(game: game, onFinish: { isMenuVisible = false })
                    .injectPlanetServices()
                    .tint(PortTheme.accent)
            case .multiplayer:
                MultiplayerView()
                    .injectPlanetServices()
                    .tint(PortTheme.accent)
            }
        }
        .appErrorAlert($emulator.alert) { error in
            alertAcknowledged(error)
        }
        .onChange(of: emulator.state) { _ in evaluateSession() }
        .onChange(of: emulator.currentGame) { _ in evaluateSession() }
        .onDisappear {
            emulator.releaseAllInputs()
        }
    }

    // MARK: Overlays

    private var showsTouchControls: Bool {
        !(controllers.isControllerConnected && settings.hideControlsWithGamepad)
    }

    private var menuButton: some View {
        Group {
            if !isMenuVisible && !isExiting {
                Button {
                    openMenu()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.35), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                }
                .opacity(0.75)
                .padding(.top, 8)
                .padding(.trailing, 10)
                .accessibilityLabel("Menu di pausa")
            }
        }
    }

    private var infoOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            if settings.showPerformanceOverlay && (emulator.state == .running || emulator.state == .paused) {
                Text(verbatim: String(
                    format: "%.0f FPS · %.0f%% · %.1f ms",
                    emulator.stats.fps,
                    emulator.stats.speedPercent,
                    emulator.stats.frameTimeMs
                ))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if emulator.isFastForward {
                Label("Avanti veloce", systemImage: "forward.fill")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(PortTheme.accent.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(Color.white)
        .padding(.top, 8)
        .padding(.leading, 10)
        .allowsHitTesting(false)
    }

    private var toastOverlay: some View {
        Group {
            if let toast = emulator.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if isExiting {
            statusCard {
                ProgressView()
                    .tint(Color.white)
                Text("Chiusura…")
                    .font(.headline)
            }
        } else if emulator.state == .loadingShaders {
            statusCard {
                if let progress = emulator.shaderProgress {
                    Text(Self.stageName(progress.stage))
                        .font(.headline)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(PortTheme.accent)
                        .frame(width: 220)
                    if progress.total > 0 {
                        Text(verbatim: "\(progress.progress) / \(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                } else {
                    ProgressView()
                        .tint(Color.white)
                    Text("Caricamento degli shader…")
                        .font(.headline)
                }
            }
        } else if emulator.state == .booting || (!sessionBegan && emulator.state == .idle && emulator.alert == nil) {
            statusCard {
                ProgressView()
                    .tint(Color.white)
                Text("Avvio di \(game.title)…")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .foregroundStyle(Color.white)
        .padding(22)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
        .allowsHitTesting(false)
    }

    // MARK: Pause menu

    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { closeMenu(resume: true) }

            VStack(spacing: 0) {
                ViewThatFits(in: .vertical) {
                    pauseMenuContent
                    ScrollView {
                        pauseMenuContent
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 380)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(16)
        }
        .alert("Riavviare il gioco?", isPresented: $confirmRestart) {
            Button("Riavvia", role: .destructive) { restartGame() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("I progressi non salvati andranno persi.")
        }
        .alert("Uscire dal gioco?", isPresented: $confirmExit) {
            Button("Esci", role: .destructive) { exitGame() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("I progressi non salvati andranno persi. Ricordati di salvare nel gioco o in uno stato.")
        }
    }

    private var pauseMenuContent: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(stateDescription)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.bottom, 6)

            menuRow("Riprendi", systemImage: "play.fill") {
                closeMenu(resume: true)
            }
            menuRow("Salva / Carica stato", systemImage: "square.and.arrow.down.on.square") {
                activeSheet = .saveStates
            }
            .disabled(!canUseSaveStates)
            .opacity(canUseSaveStates ? 1 : 0.45)

            Toggle(isOn: fastForwardBinding) {
                Label("Avanti veloce", systemImage: "forward.fill")
                    .font(.body.weight(.semibold))
            }
            .tint(PortTheme.accent)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            menuRow(multiplayerTitle, systemImage: multiplayer.isJoined ? "person.3.fill" : "person.3") {
                activeSheet = .multiplayer
            }
            menuRow("Scambia schermi", systemImage: "arrow.up.arrow.down") {
                settings.swapScreens.toggle()
                emulator.applySettings()
            }
            menuRow("Riavvia", systemImage: "arrow.counterclockwise") {
                confirmRestart = true
            }
            menuRow("Esci", systemImage: "xmark.circle", isDestructive: true) {
                confirmExit = true
            }
        }
    }

    private func menuRow(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(PauseMenuButtonStyle(isDestructive: isDestructive))
    }

    private var multiplayerTitle: String {
        if multiplayer.isJoined, let name = multiplayer.roomName {
            return "Multiplayer · \(name)"
        }
        return "Multiplayer"
    }

    private var stateDescription: String {
        switch emulator.state {
        case .idle: return "Non in esecuzione"
        case .booting: return "Avvio in corso"
        case .loadingShaders: return "Caricamento shader"
        case .running: return "In esecuzione"
        case .paused: return "In pausa"
        case .stopping: return "Chiusura in corso"
        @unknown default: return ""
        }
    }

    private var canUseSaveStates: Bool {
        emulator.state == .running || emulator.state == .paused
    }

    private var fastForwardBinding: Binding<Bool> {
        Binding(
            get: { emulator.isFastForward },
            set: { emulator.setFastForward($0) }
        )
    }

    // MARK: Actions

    private func openMenu() {
        if emulator.state == .running {
            emulator.pause()
        }
        emulator.releaseAllInputs()
        isMenuVisible = true
    }

    private func closeMenu(resume: Bool) {
        isMenuVisible = false
        if resume && emulator.state == .paused {
            emulator.resume()
        }
    }

    private func restartGame() {
        isMenuVisible = false
        if emulator.state == .paused {
            emulator.resume()
        }
        emulator.reset()
    }

    private func exitGame() {
        isMenuVisible = false
        activeSheet = nil
        isExiting = true
        emulator.releaseAllInputs()
        if emulator.state == .idle {
            closeView()
        } else {
            emulator.stop()
        }
    }

    /// Decides whether the session is over and the cover can go away. The view stays until the
    /// controller reports `.idle` (and, normally, `currentGame == nil`, set when the core has
    /// fully shut down and released the layer).
    private func evaluateSession() {
        if emulator.state != .idle || emulator.currentGame != nil {
            sessionBegan = true
        }
        guard emulator.state == .idle else { return }

        if isExiting {
            if emulator.currentGame == nil {
                closeView()
            } else {
                // Safety net in case the stop notification is late.
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if isExiting && emulator.state == .idle {
                        closeView()
                    }
                }
            }
            return
        }

        // The game ended by itself (shutdown requested by the game, or a fatal error).
        guard sessionBegan, emulator.currentGame == nil else { return }
        if emulator.alert == nil {
            closeView()
        }
        // Otherwise the alert is shown first; alertAcknowledged(_:) closes the view.
    }

    private func alertAcknowledged(_ error: AppError) {
        if emulator.isActive {
            if error.isFatal {
                exitGame()
            }
        } else {
            closeView()
        }
    }

    private func closeView() {
        guard !didClose else { return }
        didClose = true
        isMenuVisible = false
        emulator.releaseAllInputs()
        dismiss()
    }

    // MARK: Motion orientation

    private func refreshMotionOrientation() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let orientation = scene?.interfaceOrientation else { return }
        MotionProvider.shared.orientation = Self.motionOrientation(for: orientation)
    }

    private static func motionOrientation(for orientation: UIInterfaceOrientation) -> PPInterfaceOrientation {
        switch orientation {
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private static func stageName(_ stage: PPShaderLoadStage) -> String {
        switch stage {
        case .prepare: return "Preparazione della cache degli shader"
        case .preload: return "Lettura della cache degli shader"
        case .decompile: return "Decompilazione degli shader"
        case .build: return "Compilazione degli shader"
        case .complete: return "Shader pronti"
        @unknown default: return "Caricamento degli shader"
        }
    }
}

// MARK: - Layout

/// Frames of the render view and of the touch controls for a given container size.
private struct EmulationLayout {
    let isPortrait: Bool
    let screen: CGRect
    let pad: CGRect

    init(size: CGSize) {
        let portrait = size.height > size.width
        isPortrait = portrait
        if portrait {
            // Both 3DS screens stacked: 400 x 480 points of content.
            var height = size.width * 480 / 400
            var width = size.width
            let maxHeight = size.height * 0.62
            if height > maxHeight {
                height = maxHeight
                width = height * 400 / 480
            }
            let screenRect = CGRect(
                x: ((size.width - width) / 2).rounded(),
                y: 0,
                width: width.rounded(),
                height: height.rounded()
            )
            screen = screenRect
            pad = CGRect(
                x: 0,
                y: screenRect.maxY,
                width: size.width,
                height: max(size.height - screenRect.maxY, 0)
            )
        } else {
            let full = CGRect(origin: .zero, size: size)
            screen = full
            pad = full
        }
    }
}

/// Large translucent rows used by the pause menu.
private struct PauseMenuButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.18 : 0.07),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}
