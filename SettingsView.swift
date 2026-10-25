// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Settings sheet. Every change is persisted by SettingsStore and pushed to the core (debounced);
// boot-time-only values take effect at the next game start.

import SwiftUI
import Combine
import PlanetCore

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var emulator: EmulatorController
    @EnvironmentObject private var multiplayer: MultiplayerController
    @EnvironmentObject private var controllers: ControllerManager
    @Environment(\.dismiss) private var dismiss

    /// Pushes runtime settings to the core shortly after the user stops changing them.
    @StateObject private var applyScheduler = SettingsApplyScheduler()

    @State private var nicknameDraft = ""
    @State private var systemLanguage: PPSystemLanguage = .english
    @State private var pendingRegeneration: ConsoleRegeneration?
    @State private var confirmReset = false
    @State private var notice: AppError?

    private enum ConsoleRegeneration: String, Identifiable {
        case consoleID
        case macAddress
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                emulationSection
                graphicsSection
                audioSection
                controlsSection
                consoleSection
                resetSection
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .confirmationDialog(
                "Rigenerare l'identità della console?",
                isPresented: Binding(
                    get: { pendingRegeneration != nil },
                    set: { if !$0 { pendingRegeneration = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRegeneration
            ) { target in
                Button(target == .consoleID ? "Rigenera ID console" : "Rigenera indirizzo MAC", role: .destructive) {
                    regenerate(target)
                }
                Button("Annulla", role: .cancel) {}
            } message: { target in
                if target == .consoleID {
                    Text("Serve solo se il multiplayer segnala che un altro giocatore ha lo stesso ID console. Alcuni giochi potrebbero considerarla una console diversa.")
                } else {
                    Text("Serve solo se il multiplayer segnala che un altro giocatore ha lo stesso indirizzo MAC.")
                }
            }
            .confirmationDialog(
                "Ripristinare le impostazioni predefinite?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Ripristina", role: .destructive) {
                    settings.resetToDefaults()
                    emulator.applySettings()
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Nome giocatore, lingua e identità della console non vengono modificati.")
            }
        }
        .appErrorAlert($notice)
        .onAppear {
            nicknameDraft = multiplayer.nickname
            systemLanguage = PPEmulator.shared.systemLanguage()
        }
        .onDisappear {
            // Flush a change that may still be waiting in the debounce window.
            emulator.applySettings()
        }
    }

    // MARK: Emulation

    private var emulationSection: some View {
        Section {
            Picker("Motore CPU", selection: $settings.cpuBackend) {
                Text("Automatico").tag(PPCPUBackend.automatic)
                Text("JIT").tag(PPCPUBackend.jit)
                Text("Interprete").tag(PPCPUBackend.interpreter)
            }
            Label {
                Text(emulator.jitAvailable
                     ? "JIT attivo: il gioco girerà alla massima velocità possibile."
                     : "JIT non disponibile: verrà usato l'interprete, più lento. Avvia l'app con StikDebug o SideStore per attivarlo (vedi Info).")
            } icon: {
                Image(systemName: emulator.jitAvailable ? "bolt.fill" : "tortoise.fill")
                    .foregroundStyle(emulator.jitAvailable ? Color.green : Color.orange)
            }
            .font(.footnote)

            Toggle("Modalità New 3DS", isOn: $settings.isNew3DS)

            Picker("Regione", selection: $settings.region) {
                ForEach(Self.regionOptions) { option in
                    Text(option.title).tag(option.value)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Clock CPU")
                    Spacer()
                    Text(verbatim: "\(settings.cpuClockPercentage)%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: cpuClockBinding, in: 25...400, step: 25)
                if settings.cpuClockPercentage != 100 {
                    Label(
                        "Valori diversi da 100% possono causare blocchi o glitch. Aumentarlo può ridurre i rallentamenti ma consuma più batteria.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                }
            }

            Picker("Limite velocità", selection: $settings.frameLimitPercent) {
                ForEach(frameLimitOptions, id: \.self) { value in
                    Text(verbatim: value == 0 ? "Illimitato" : "\(value)%").tag(value)
                }
            }

            Picker("Velocità turbo", selection: $settings.turboSpeedPercent) {
                ForEach(turboOptions, id: \.self) { value in
                    Text(verbatim: "\(value)%").tag(value)
                }
            }
        } header: {
            Text("Emulazione")
        } footer: {
            Text("Motore CPU, modalità New 3DS e regione si applicano al prossimo avvio del gioco. La velocità turbo si usa con «Avanti veloce» nel menu di pausa.")
        }
    }

    // MARK: Graphics

    private var graphicsSection: some View {
        Section {
            Picker("Risoluzione interna", selection: $settings.resolutionFactor) {
                if settings.resolutionFactor == 0 {
                    Text("Automatica").tag(0)
                }
                ForEach(1...6, id: \.self) { factor in
                    Text(verbatim: "\(factor)x (\(400 * factor)×\(240 * factor))").tag(factor)
                }
            }
            Toggle("Compilazione shader asincrona", isOn: $settings.asyncShaderCompilation)
            Toggle("Cache shader su disco", isOn: $settings.useDiskShaderCache)
            Toggle("VSync", isOn: $settings.useVSync)
            Toggle("Filtro lineare", isOn: $settings.linearFiltering)

            Picker("Layout orizzontale", selection: $settings.landscapeLayout) {
                Text("Standard (impilati)").tag(PPScreenLayout.standard)
                Text("Schermo grande").tag(PPScreenLayout.largeScreen)
                Text("Affiancati").tag(PPScreenLayout.sideBySide)
                Text("Schermo singolo").tag(PPScreenLayout.singleScreen)
                Text("Ibrido").tag(PPScreenLayout.hybrid)
            }
            Picker("Layout verticale", selection: $settings.portraitLayout) {
                Text("Superiore a tutta larghezza").tag(PPPortraitLayout.topFullWidth)
                Text("Originale").tag(PPPortraitLayout.original)
            }
            Toggle("Scambia schermi", isOn: $settings.swapScreens)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Proporzione schermo grande")
                    Spacer()
                    Text(verbatim: String(format: "%.2f", settings.largeScreenProportion))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: $settings.largeScreenProportion, in: 1...4, step: 0.25)
            }

            Toggle("Mostra FPS e velocità", isOn: $settings.showPerformanceOverlay)
        } header: {
            Text("Grafica")
        } footer: {
            Text("Risoluzione e layout cambiano subito. Compilazione asincrona, cache su disco, VSync e filtro lineare si applicano al prossimo avvio. Risoluzioni alte richiedono un dispositivo potente.")
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text(verbatim: "\(Int((settings.volume * 100).rounded()))%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: $settings.volume, in: 0...1)
            }
            Toggle("Stretching audio (meno crepitii)", isOn: $settings.audioStretching)
            Toggle("Microfono", isOn: $settings.microphoneEnabled)
        } header: {
            Text("Audio")
        } footer: {
            Text("Il microfono si applica al prossimo avvio; al primo uso iOS chiederà il permesso.")
        }
    }

    // MARK: Controls

    private var controlsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Opacità comandi a schermo")
                    Spacer()
                    Text(verbatim: "\(Int((settings.controlsOpacity * 100).rounded()))%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                Slider(value: $settings.controlsOpacity, in: 0.15...1)
            }
            Picker("Comando sinistro", selection: $settings.leftControlStyle) {
                ForEach(LeftControlStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            Picker("Pulsanti del controller", selection: $settings.controllerFaceLayout) {
                ForEach(ControllerFaceLayout.allCases) { layout in
                    Text(layout.label).tag(layout)
                }
            }
            Toggle("Nascondi comandi con un controller", isOn: $settings.hideControlsWithGamepad)
            Toggle("Giroscopio e accelerometro", isOn: $settings.motionEnabled)
            Toggle("Vibrazione", isOn: $settings.hapticsEnabled)
            LabeledContent("Controller connesso", value: controllers.controllerName ?? "Nessuno")
        } header: {
            Text("Controlli")
        } footer: {
            Text("Sono supportati i controller MFi, Xbox, PlayStation e Switch Pro. Il giroscopio si attiva al prossimo avvio del gioco.")
        }
    }

    // MARK: Console

    private var consoleSection: some View {
        Section {
            HStack {
                TextField("Nome giocatore", text: $nicknameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveNickname() }
                Button("Salva") { saveNickname() }
                    .buttonStyle(.borderless)
                    .disabled(nicknameDraft == multiplayer.nickname)
            }
            Picker("Lingua di sistema", selection: languageBinding) {
                ForEach(Self.languageOptions) { option in
                    Text(option.title).tag(option.value)
                }
            }
            Button("Rigenera ID console") {
                pendingRegeneration = .consoleID
            }
            Button("Rigenera indirizzo MAC") {
                pendingRegeneration = .macAddress
            }
        } header: {
            Text("Console")
        } footer: {
            if emulator.isActive {
                Text("Chiudi il gioco in esecuzione per modificare queste impostazioni.")
            } else {
                Text("Il nome giocatore è anche il tuo nome nelle stanze multiplayer. Rigenera ID o MAC solo in caso di conflitto con un altro giocatore.")
            }
        }
        .disabled(emulator.isActive)
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button("Ripristina impostazioni predefinite", role: .destructive) {
                confirmReset = true
            }
        } footer: {
            Text("Le modifiche a risoluzione, layout, velocità e audio si applicano subito anche durante il gioco; le altre al prossimo avvio.")
        }
    }

    // MARK: Bindings and options

    private var cpuClockBinding: Binding<Double> {
        Binding(
            get: { Double(settings.cpuClockPercentage) },
            set: { settings.cpuClockPercentage = Int($0.rounded()) }
        )
    }

    private var languageBinding: Binding<PPSystemLanguage> {
        Binding(
            get: { systemLanguage },
            set: { newValue in
                do {
                    try PPEmulator.shared.setSystemLanguage(newValue)
                    systemLanguage = newValue
                } catch {
                    notice = AppError(title: "Impossibile cambiare la lingua", error: error)
                }
            }
        )
    }

    /// Unlimited (0) is listed last; the current value is always present.
    private var frameLimitOptions: [Int] {
        let values = Set([50, 75, 100, 125, 150, 200, 300, 0, settings.frameLimitPercent])
        return values.sorted { lhs, rhs in
            if lhs == 0 { return false }
            if rhs == 0 { return true }
            return lhs < rhs
        }
    }

    private var turboOptions: [Int] {
        Set([150, 200, 250, 300, 400, 500, settings.turboSpeedPercent]).sorted()
    }

    private static let regionOptions: [SettingsOption<PPRegion>] = [
        SettingsOption(value: .automatic, title: "Automatica"),
        SettingsOption(value: .japan, title: "Giappone"),
        SettingsOption(value: .usa, title: "Nord America"),
        SettingsOption(value: .europe, title: "Europa"),
        SettingsOption(value: .australia, title: "Australia"),
        SettingsOption(value: .china, title: "Cina"),
        SettingsOption(value: .korea, title: "Corea"),
        SettingsOption(value: .taiwan, title: "Taiwan"),
    ]

    private static let languageOptions: [SettingsOption<PPSystemLanguage>] = [
        SettingsOption(value: .japanese, title: "Giapponese"),
        SettingsOption(value: .english, title: "Inglese"),
        SettingsOption(value: .french, title: "Francese"),
        SettingsOption(value: .german, title: "Tedesco"),
        SettingsOption(value: .italian, title: "Italiano"),
        SettingsOption(value: .spanish, title: "Spagnolo"),
        SettingsOption(value: .simplifiedChinese, title: "Cinese semplificato"),
        SettingsOption(value: .korean, title: "Coreano"),
        SettingsOption(value: .dutch, title: "Olandese"),
        SettingsOption(value: .portuguese, title: "Portoghese"),
        SettingsOption(value: .russian, title: "Russo"),
        SettingsOption(value: .traditionalChinese, title: "Cinese tradizionale"),
    ]

    // MARK: Actions

    private func saveNickname() {
        let name = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = multiplayer.setNickname(name) {
            notice = AppError(title: "Nome non valido", message: error)
        } else {
            nicknameDraft = multiplayer.nickname
        }
    }

    private func regenerate(_ target: ConsoleRegeneration) {
        let error: String?
        switch target {
        case .consoleID:
            error = multiplayer.regenerateConsoleID()
        case .macAddress:
            error = multiplayer.regenerateMACAddress()
        }
        if let error {
            notice = AppError(title: "Operazione non riuscita", message: error)
        } else {
            notice = AppError(
                title: "Fatto",
                message: target == .consoleID ? "È stato generato un nuovo ID console." : "È stato generato un nuovo indirizzo MAC."
            )
        }
    }
}

/// A picker entry for an imported Objective-C enum.
private struct SettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// Debounces SettingsStore changes and forwards them to the running core.
@MainActor
final class SettingsApplyScheduler: ObservableObject {
    private var cancellable: AnyCancellable?

    init() {
        cancellable = SettingsStore.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in
                    EmulatorController.shared.applySettings()
                }
            }
    }
}
