// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// About screen: what the app is, legal note, credits, JIT how-to and file locations.

import SwiftUI
import PlanetCore

@MainActor
struct AboutView: View {
    @EnvironmentObject private var emulator: EmulatorController

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 84, height: 84)
                        .background(
                            LinearGradient(
                                colors: [PortTheme.accent, PortTheme.accentDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                        )
                    Text("PlanetPort")
                        .font(.title2.weight(.bold))
                    Text(verbatim: versionText)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("PlanetPort è un frontend nativo per iOS basato sul core open source dell'emulatore Azahar (derivato da Citra). Ti permette di giocare alla tua copia di Kirby: Planet Robobot, o di qualsiasi altro gioco 3DS che possiedi, con comandi touch, controller, giroscopio e multiplayer tramite stanze online o in rete locale.")
            } header: {
                Text("Che cos'è")
            }

            Section {
                Text("Kirby e Nintendo 3DS sono marchi di Nintendo. PlanetPort è un progetto indipendente, non affiliato né approvato da Nintendo.")
                Text("L'app non contiene codice, chiavi, firmware, giochi o risorse grafiche di Nintendo. Devi usare un dump decriptato del tuo gioco, ottenuto legalmente dalla tua cartuccia o dalla tua console.")
                Text("PlanetPort è software libero distribuito secondo la GNU General Public License versione 2 (o successiva).")
            } header: {
                Text("Nota legale")
            }

            Section {
                creditRow("Azahar e Citra", "Core di emulazione 3DS (GPLv2+)")
                creditRow("MoltenVK", "Vulkan su Metal")
                creditRow("Dynarmic", "Ricompilatore dinamico ARM (JIT)")
                creditRow("OpenAL Soft", "Uscita audio e microfono")
            } header: {
                Text("Crediti")
            }

            Section {
                LabeledContent("Stato attuale", value: emulator.jitAvailable ? "JIT attivo" : "Interprete")
                Text("Senza JIT il gioco usa l'interprete: funziona sempre, ma è molto più lento e spesso non raggiunge la piena velocità.")
                numberedStep(1, "Installa PlanetPort con SideStore (o AltStore, o da Xcode).")
                numberedStep(2, "Avvia l'app tramite StikDebug oppure con la funzione «Enable JIT» di SideStore: il JIT resta attivo finché l'app non viene chiusa.")
                numberedStep(3, "Nella schermata principale compare l'etichetta verde «JIT attivo».")
                Label {
                    Text("Su iOS 26, nei dispositivi con TXM (Trusted Execution Monitor, i chip più recenti), il JIT tradizionale potrebbe non funzionare o richiedere versioni aggiornate di StikDebug. In quel caso PlanetPort usa automaticamente l'interprete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                }
                .font(.footnote)
            } header: {
                Text("Attivare il JIT")
            }

            Section {
                Label {
                    Text("App File › Sul mio iPhone (o iPad) › PlanetPort › PlanetPort › games: copia qui i tuoi giochi (.3ds, .cci, .cxi, .cia).")
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(PortTheme.accent)
                }
                Label {
                    Text("Nella stessa cartella PlanetPort si trovano anche i salvataggi (sdmc, nand), gli stati di gioco (states) e la cache degli shader (shaders).")
                } icon: {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(PortTheme.accent)
                }
            } header: {
                Text("Dove sono i file")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Versione \(version) (\(build))"
    }

    private func creditRow(_ name: String, _ role: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.body.weight(.semibold))
            Text(role)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
    }

    private func numberedStep(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(PortTheme.accent)
        }
    }
}
