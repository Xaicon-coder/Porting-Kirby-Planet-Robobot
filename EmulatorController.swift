// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Owns the emulation session: one-time bridge preparation, boot/stop, pause handling for scene
// phase and audio interruptions, save states, performance polling and the delegate callbacks of
// PPEmulator (all delivered on the main queue).

import AVFoundation
import Combine
import Foundation
import os
import PlanetCore
import QuartzCore
import SwiftUI
import UIKit

private let emulatorControllerLog = Logger(subsystem: "org.planetport.app", category: "Emulator")

@MainActor
final class EmulatorController: NSObject, ObservableObject, PPEmulatorDelegate {
    static let shared = EmulatorController()

    @Published private(set) var state: PPEmulationState = .idle
    @Published private(set) var currentGame: GameEntry?
    /// Non-nil only while `.loadingShaders`.
    @Published private(set) var shaderProgress: ShaderProgress?
    /// Refreshed every second while running.
    @Published private(set) var stats: PerformanceSnapshot = .zero
    @Published private(set) var isFastForward = false
    /// Set by the delegate; the view clears it after finishing the request.
    @Published var keyboardPrompt: KeyboardPrompt?
    /// Last SoftwareKeyboard::ShowError text.
    @Published var keyboardError: String?
    /// Fatal stop errors and warnings.
    @Published var alert: AppError?
    /// Short transient message (auto-clears after 2.5 s).
    @Published private(set) var toast: String?
    @Published private(set) var isPrepared = false

    /// Documents/PlanetPort/ (created by bootstrap()).
    let userDirectory: URL

    var jitAvailable: Bool { PPEmulator.isJITAvailable }
    var isActive: Bool { state != .idle }

    private var didInstallObservers = false
    /// YES when the game was paused by the app (scene phase / audio interruption), not by the user.
    private var autoPaused = false
    private var statsTimer: AnyCancellable?
    private var toastTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    private static let toastDuration: UInt64 = 2_500_000_000

    private override init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
        userDirectory = documents.appendingPathComponent("PlanetPort", isDirectory: true)
        super.init()
    }

    // MARK: - Bootstrap

    /// Idempotent. Creates the user folder, prepares the bridge, sets the delegate, configures the
    /// audio session, activates multiplayer and starts game controller support.
    func bootstrap() {
        if !didInstallObservers {
            didInstallObservers = true
            configureAudioSession(recording: false)
            installAudioObservers()
            ControllerManager.shared.start()
        }
        guard !isPrepared else { return }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: userDirectory.appendingPathComponent("games", isDirectory: true),
                                            withIntermediateDirectories: true)
            try PPEmulator.shared.prepare(withUserDirectory: userDirectory.path)
        } catch {
            emulatorControllerLog.error("Bridge preparation failed: \(error.localizedDescription, privacy: .public)")
            alert = AppError(title: "Avvio dell'emulatore non riuscito", error: error)
            return
        }

        PPEmulator.shared.delegate = self
        isPrepared = true
        MultiplayerController.shared.activate()
    }

    // MARK: - Lifecycle

    /// Starts `game` on `layer`. Sets currentGame. On immediate failure sets `alert`.
    func start(game: GameEntry, layer: CAMetalLayer, drawableSize: CGSize, portrait: Bool) {
        if isActive {
            // EmulationView may call this more than once while the layer settles.
            if currentGame == game { return }
            alert = AppError(title: "Gioco già in esecuzione",
                             message: "Chiudi il gioco in corso prima di avviarne un altro.",
                             isFatal: true)
            return
        }
        if !isPrepared { bootstrap() }
        guard isPrepared else {
            alert = AppError(title: "Emulatore non pronto",
                             message: "L'emulatore non è stato inizializzato correttamente. Riavvia l'app e riprova.",
                             isFatal: true)
            return
        }
        guard !game.isEncrypted else {
            alert = AppError(title: "Gioco criptato",
                             message: "Questo file è criptato e non può essere avviato. Usa una copia decriptata "
                                + "ottenuta dalla tua console, poi importala di nuovo.",
                             isFatal: true)
            return
        }
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            alert = AppError(title: "Impossibile avviare il gioco",
                             message: "La superficie di disegno non è ancora pronta. Riprova.",
                             isFatal: true)
            return
        }

        let settings = SettingsStore.shared
        configureAudioSession(recording: settings.microphoneEnabled)

        do {
            try PPEmulator.shared.startGame(atPath: game.id,
                                            layer: layer,
                                            drawableSize: drawableSize,
                                            portrait: portrait,
                                            settings: settings.makePPSettings())
        } catch {
            emulatorControllerLog.error("startGame failed: \(error.localizedDescription, privacy: .public)")
            alert = AppError(title: Self.title(forStopError: error), error: error, isFatal: true)
            return
        }

        currentGame = game
        stats = .zero
        shaderProgress = nil
        isFastForward = false
        keyboardPrompt = nil
        keyboardError = nil
        autoPaused = false
        state = PPEmulator.shared.state
        updateSessionEffects()
    }

    func stop() {
        autoPaused = false
        PPEmulator.shared.releaseAllInputs()
        if PPEmulator.shared.state == .idle && state == .idle {
            // Nothing is running: no didStopWithError will follow, clean up locally.
            finishSession()
            return
        }
        PPEmulator.shared.stop()
    }

    func pause() {
        autoPaused = false
        guard PPEmulator.shared.state == .running else { return }
        PPEmulator.shared.releaseAllInputs()
        PPEmulator.shared.pause()
    }

    func resume() {
        autoPaused = false
        guard PPEmulator.shared.state == .paused else { return }
        PPEmulator.shared.resume()
    }

    func togglePause() {
        switch PPEmulator.shared.state {
        case .running: pause()
        case .paused: resume()
        default: break
        }
    }

    func reset() {
        guard isActive else { return }
        PPEmulator.shared.releaseAllInputs()
        PPEmulator.shared.reset()
        showToast("Gioco riavviato")
    }

    func setFastForward(_ enabled: Bool) {
        guard isActive else {
            isFastForward = false
            return
        }
        PPEmulator.shared.setFastForwardEnabled(enabled)
        isFastForward = enabled
    }

    func updateDrawable(size: CGSize, portrait: Bool) {
        guard isActive, size.width > 0, size.height > 0 else { return }
        PPEmulator.shared.updateDrawableSize(size, portrait: portrait)
    }

    /// Pushes SettingsStore.shared.makePPSettings() to PPEmulator.applyRuntimeSettings.
    func applySettings() {
        PPEmulator.shared.applyRuntimeSettings(SettingsStore.shared.makePPSettings())
        updateSessionEffects()
    }

    // MARK: - Save states

    func saveState(slot: Int) {
        guard isActive, (0...10).contains(slot) else { return }
        PPEmulator.shared.saveState(toSlot: slot)
        if PPEmulator.shared.state == .paused {
            showToast("Lo stato verrà salvato alla ripresa del gioco")
        }
    }

    func loadState(slot: Int) {
        guard isActive, (0...10).contains(slot) else { return }
        PPEmulator.shared.releaseAllInputs()
        PPEmulator.shared.loadState(fromSlot: slot)
        if PPEmulator.shared.state == .paused {
            showToast("Lo stato verrà caricato alla ripresa del gioco")
        }
    }

    func saveStates(for game: GameEntry) -> [PPSaveStateInfo] {
        guard isPrepared else { return [] }
        return PPEmulator.shared.saveStates(forTitleID: game.titleID)
    }

    // MARK: - Input passthrough

    func setButton(_ button: PPButton, pressed: Bool) {
        PPEmulator.shared.setButton(button, pressed: pressed)
    }

    func setStick(_ stick: PPAnalogStick, x: Float, y: Float) {
        PPEmulator.shared.setAnalogStick(stick, x: x, y: y)
    }

    func releaseAllInputs() {
        PPEmulator.shared.releaseAllInputs()
    }

    @discardableResult
    func touchBegan(at pixel: CGPoint) -> Bool {
        PPEmulator.shared.touchBegan(at: pixel)
    }

    func touchMoved(to pixel: CGPoint) {
        PPEmulator.shared.touchMoved(to: pixel)
    }

    func touchEnded() {
        PPEmulator.shared.touchEnded()
    }

    // MARK: - Scene phase

    /// .background/.inactive: pause if running (remember auto-pause). .active: resume if auto-paused.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            try? AVAudioSession.sharedInstance().setActive(true)
            if autoPaused {
                autoPaused = false
                if PPEmulator.shared.state == .paused {
                    PPEmulator.shared.resume()
                }
            }
        case .inactive, .background:
            if PPEmulator.shared.state == .running {
                PPEmulator.shared.releaseAllInputs()
                PPEmulator.shared.pause()
                autoPaused = true
            }
        @unknown default:
            break
        }
    }

    // MARK: - PPEmulatorDelegate

    /// ObjC selector emulator:didChangeState:. Swift prunes the trailing "State" (it repeats the
    /// PPEmulationState type name after the verb "Change"), like MCSessionDelegate's
    /// session:peer:didChangeState: -> session(_:peer:didChange:).
    func emulator(_ emulator: PPEmulator, didChange state: PPEmulationState) {
        self.state = state
        if state == .loadingShaders {
            if shaderProgress == nil {
                shaderProgress = ShaderProgress(stage: .prepare, progress: 0, total: 0)
            }
        } else {
            shaderProgress = nil
        }
        if state == .running, UIApplication.shared.applicationState != .active {
            // Boot finished while the app is not in the foreground: never render in background.
            emulator.pause()
            autoPaused = true
        }
        updateSessionEffects()
    }

    func emulator(_ emulator: PPEmulator, didStopWithError error: Error?) {
        finishSession()
        if let error {
            emulatorControllerLog.error("Emulation stopped with error: \(error.localizedDescription, privacy: .public)")
            alert = AppError(title: Self.title(forStopError: error), error: error, isFatal: true)
        }
    }

    func emulator(_ emulator: PPEmulator, didReportWarning warning: Error) {
        emulatorControllerLog.notice("Warning: \(warning.localizedDescription, privacy: .public)")
        alert = AppError(title: Self.title(forWarning: warning), error: warning, isFatal: false)
    }

    func emulator(_ emulator: PPEmulator, shaderLoadStage stage: PPShaderLoadStage, progress: Int, total: Int) {
        guard self.state == .loadingShaders else { return }
        if stage == .complete {
            shaderProgress = nil
        } else {
            shaderProgress = ShaderProgress(stage: stage, progress: progress, total: total)
        }
    }

    func emulator(_ emulator: PPEmulator, requestsKeyboard request: PPKeyboardRequest) {
        // Buttons held when the applet opened would otherwise stay pressed.
        emulator.releaseAllInputs()
        keyboardPrompt = KeyboardPrompt(request: request)
    }

    func emulator(_ emulator: PPEmulator, keyboardError message: String) {
        keyboardError = message
    }

    func emulator(_ emulator: PPEmulator, didFinishSaveStateOperation isLoad: Bool, slot: Int, success: Bool) {
        // Failures are also reported (with details) through didReportWarning.
        guard success else { return }
        let slotName = slot == 0 ? "rapido" : "\(slot)"
        showToast(isLoad ? "Stato caricato (slot \(slotName))" : "Stato salvato (slot \(slotName))")
    }

    // MARK: - Private

    /// Resets every session related value after the emulation thread has shut down.
    private func finishSession() {
        state = .idle
        currentGame = nil
        shaderProgress = nil
        stats = .zero
        isFastForward = false
        autoPaused = false
        keyboardPrompt = nil
        keyboardError = nil
        stopStatsTimer()
        MotionProvider.shared.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if SettingsStore.shared.microphoneEnabled {
            // Leave record mode so other apps' audio routing is not affected while idle.
            configureAudioSession(recording: false)
        }
    }

    /// Keeps the idle timer, stats polling and motion input in sync with the current state.
    private func updateSessionEffects() {
        let current = state
        let keepAwake = current == .booting || current == .loadingShaders || current == .running
        UIApplication.shared.isIdleTimerDisabled = keepAwake

        if current == .running {
            startStatsTimer()
            if SettingsStore.shared.motionEnabled {
                MotionProvider.shared.start()
            } else {
                MotionProvider.shared.stop()
            }
        } else {
            stopStatsTimer()
            MotionProvider.shared.stop()
        }
    }

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStats()
            }
    }

    private func stopStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    private func refreshStats() {
        guard state == .running else { return }
        let snapshot = PPEmulator.shared.performanceStats()
        stats = PerformanceSnapshot(fps: snapshot.gameFPS,
                                    speedPercent: snapshot.speedPercent,
                                    frameTimeMs: snapshot.frameTimeMs)
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Audio

    private func configureAudioSession(recording: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if recording {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            // Audio is not essential for emulation: log and continue.
            emulatorControllerLog.error("AVAudioSession configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installAudioObservers() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioInterruption(notification)
            }
            .store(in: &observers)

        center.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.configureAudioSession(recording: self.isActive && SettingsStore.shared.microphoneEnabled)
            }
            .store(in: &observers)
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            if PPEmulator.shared.state == .running {
                PPEmulator.shared.releaseAllInputs()
                PPEmulator.shared.pause()
                autoPaused = true
            }
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            if autoPaused,
               PPEmulator.shared.state == .paused,
               UIApplication.shared.applicationState == .active {
                autoPaused = false
                PPEmulator.shared.resume()
            }
        @unknown default:
            break
        }
    }

    // MARK: Error titles

    private static func errorCode(of error: Error) -> PPError.Code? {
        let nsError = error as NSError
        guard nsError.domain == PPErrorDomain else { return nil }
        return PPError.Code(rawValue: nsError.code)
    }

    private static func title(forStopError error: Error) -> String {
        guard let code = errorCode(of: error) else { return "Emulazione interrotta" }
        switch code {
        case .notPrepared: return "Emulatore non pronto"
        case .alreadyRunning: return "Gioco già in esecuzione"
        case .fileNotFound: return "File non trovato"
        case .unsupportedFormat: return "Formato non supportato"
        case .encryptedROM: return "Gioco criptato"
        case .ciaNeedsInstall: return "CIA da installare"
        case .new3DSRequired: return "Richiede un New 3DS"
        case .gbaVirtualConsole: return "Titolo GBA non supportato"
        case .systemMode: return "Modalità di sistema non supportata"
        case .loaderFailed: return "Caricamento del gioco non riuscito"
        case .coreException: return "Errore interno dell'emulatore"
        case .shaderCacheCrash: return "Cache degli shader danneggiata"
        case .graphicsInitFailed: return "Errore della grafica"
        default: return "Emulazione interrotta"
        }
    }

    private static func title(forWarning warning: Error) -> String {
        guard let code = errorCode(of: warning) else { return "Avviso" }
        switch code {
        case .systemFilesMissing: return "File di sistema mancanti"
        case .saveStateFailed: return "Stato di salvataggio non riuscito"
        default: return "Avviso"
        }
    }
}
