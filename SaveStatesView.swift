// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Save state slots of the running game (0 = quick slot, 1...10 = regular slots).

import SwiftUI
import PlanetCore

@MainActor
struct SaveStatesView: View {
    let game: GameEntry
    /// Called after a save/load choice, right before the sheet dismisses itself.
    var onFinish: (() -> Void)? = nil

    @EnvironmentObject private var emulator: EmulatorController
    @Environment(\.dismiss) private var dismiss

    @State private var states: [Int: PPSaveStateInfo] = [:]
    @State private var slotPendingOverwrite: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(0...10, id: \.self) { slot in
                        row(for: slot)
                    }
                } footer: {
                    Text("Gli stati salvano l'istante esatto della partita. Continua a usare anche i salvataggi del gioco: gli stati creati con un'altra versione dell'emulatore potrebbero non essere caricabili.")
                }
            }
            .navigationTitle("Stati di gioco")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sovrascrivere lo stato?",
                isPresented: Binding(
                    get: { slotPendingOverwrite != nil },
                    set: { if !$0 { slotPendingOverwrite = nil } }
                ),
                titleVisibility: .visible,
                presenting: slotPendingOverwrite
            ) { slot in
                Button("Sovrascrivi", role: .destructive) { save(to: slot) }
                Button("Annulla", role: .cancel) {}
            } message: { slot in
                Text("Lo stato salvato in «\(Self.slotTitle(slot))» verrà sostituito.")
            }
        }
        .onAppear { reload() }
    }

    private func row(for slot: Int) -> some View {
        let info = states[slot]
        let canLoad = canOperate && (info?.compatible ?? false)
        return HStack(spacing: 12) {
            Image(systemName: slot == 0 ? "bolt.circle.fill" : "\(slot).circle")
                .font(.title2)
                .foregroundStyle(PortTheme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.slotTitle(slot))
                    .font(.headline)
                if let info {
                    if let date = info.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    } else {
                        Text("Data sconosciuta")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    if !info.compatible {
                        Label("Creato con un'altra versione: non caricabile", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.orange)
                    }
                } else {
                    Text("Vuoto")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 8)

            Button("Salva") { requestSave(to: slot) }
                .buttonStyle(.bordered)
                .disabled(!canOperate)

            Button("Carica") { load(from: slot) }
                .buttonStyle(.borderedProminent)
                .disabled(!canLoad)
        }
        .padding(.vertical, 2)
    }

    private static func slotTitle(_ slot: Int) -> String {
        slot == 0 ? "Slot rapido" : "Slot \(slot)"
    }

    /// Requests are processed by the emulation thread while running (after resume when paused).
    private var canOperate: Bool {
        emulator.state == .running || emulator.state == .paused
    }

    private func reload() {
        let list = emulator.saveStates(for: game)
        states = Dictionary(list.map { (Int($0.slot), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func requestSave(to slot: Int) {
        if states[slot] != nil {
            slotPendingOverwrite = slot
        } else {
            save(to: slot)
        }
    }

    private func save(to slot: Int) {
        emulator.saveState(slot: slot)
        finish()
    }

    private func load(from slot: Int) {
        emulator.loadState(slot: slot)
        finish()
    }

    private func finish() {
        emulator.resume()
        onFinish?()
        dismiss()
    }
}
