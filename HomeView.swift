// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Library screen: featured game (or onboarding), other games, pending CIA installs, import.

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PlanetCore

@MainActor
struct HomeView: View {
    /// Called when the user starts a bootable game.
    var onPlay: (GameEntry) -> Void

    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var emulator: EmulatorController
    @EnvironmentObject private var multiplayer: MultiplayerController

    @State private var showImporter = false
    @State private var showMultiplayer = false
    @State private var showSettings = false
    @State private var jitAvailable = false
    @State private var gamePendingDeletion: GameEntry?
    @State private var ciaPendingInstall: URL?
    @State private var notice: AppError?

    var body: some View {
        ZStack {
            gameList
                .appErrorAlert($library.alert)
                .confirmationDialog(
                    "Eliminare il gioco?",
                    isPresented: Binding(
                        get: { gamePendingDeletion != nil },
                        set: { if !$0 { gamePendingDeletion = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: gamePendingDeletion
                ) { game in
                    Button("Elimina", role: .destructive) {
                        library.delete(game)
                    }
                    Button("Annulla", role: .cancel) {}
                } message: { game in
                    Text("«\(game.title)» verrà rimosso dalla libreria. I salvataggi restano nella memoria della console emulata.")
                }

            if library.isBusy {
                HomeBusyOverlay(message: library.busyMessage ?? "Attendere…", progress: library.progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: library.isBusy)
        .navigationTitle("PlanetPort")
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showMultiplayer) {
            MultiplayerView()
                .injectPlanetServices()
                .tint(PortTheme.accent)
        }
        .sheet(isPresented: $showSettings, onDismiss: { refreshJIT() }) {
            SettingsView()
                .injectPlanetServices()
                .tint(PortTheme.accent)
        }
        .confirmationDialog(
            "Installare il pacchetto CIA?",
            isPresented: Binding(
                get: { ciaPendingInstall != nil },
                set: { if !$0 { ciaPendingInstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: ciaPendingInstall
        ) { url in
            Button("Installa ed elimina il file .cia") {
                Task { await library.installPendingCIA(url, deleteAfterInstall: true) }
            }
            Button("Installa e conserva il file") {
                Task { await library.installPendingCIA(url, deleteAfterInstall: false) }
            }
            Button("Annulla", role: .cancel) {}
        } message: { url in
            Text("«\(url.lastPathComponent)» verrà installato nella memoria della console emulata.")
        }
        .appErrorAlert($notice)
        .onAppear { refreshJIT() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshJIT()
        }
    }

    // MARK: List

    private var gameList: some View {
        List {
            Section {
                if let featured = library.featuredGame {
                    HomeFeaturedCard(game: featured, isPlayDisabled: emulator.isActive) {
                        play(featured)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        deleteAction(for: featured)
                    }
                    .contextMenu {
                        deleteAction(for: featured)
                    }
                } else {
                    HomeOnboardingCard {
                        showImporter = true
                    }
                }
            } header: {
                HomeJITPill(isAvailable: jitAvailable)
                    .textCase(nil)
                    .padding(.bottom, 4)
            }

            if !otherGames.isEmpty {
                Section {
                    ForEach(otherGames) { game in
                        Button {
                            play(game)
                        } label: {
                            GameRowView(game: game)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteAction(for: game)
                        }
                    }
                } header: {
                    Text(library.featuredGame == nil ? "Giochi" : "Altri giochi")
                } footer: {
                    if otherGames.contains(where: { $0.isEncrypted }) {
                        Text("I giochi criptati non possono essere avviati: crea un dump decriptato della tua cartuccia o del titolo installato sulla tua console.")
                    }
                }
            }

            if !library.pendingCIAs.isEmpty {
                Section {
                    ForEach(library.pendingCIAs, id: \.self) { url in
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .font(.title2)
                                .foregroundStyle(PortTheme.accent)
                                .frame(width: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text("Pacchetto CIA da installare")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Installa") {
                                ciaPendingInstall = url
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(library.isBusy || emulator.isActive)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Da installare")
                } footer: {
                    Text("I file .cia vanno installati nella memoria della console emulata prima di poterli avviare. L'installazione è possibile solo quando nessun gioco è in esecuzione.")
                }
            }

            Section {
                Label {
                    Text("Puoi copiare i giochi con l'app File: Sul mio iPhone › PlanetPort › PlanetPort › games. Poi trascina la lista verso il basso per aggiornarla.")
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(PortTheme.accent)
                }
                Label {
                    Text("Servono dump decriptati (.3ds, .cci, .cxi, .cia) ottenuti dalle tue cartucce o dalla tua console.")
                } icon: {
                    Image(systemName: "lock.open")
                        .foregroundStyle(PortTheme.accent)
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Importa giochi", systemImage: "square.and.arrow.down")
                }
                .disabled(library.isBusy)
            } header: {
                Text("Aggiungere giochi")
            }
            .font(.subheadline)
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await refreshLibrary()
        }
    }

    private var otherGames: [GameEntry] {
        let featuredID = library.featuredGame?.id
        return library.games.filter { $0.id != featuredID }
    }

    private func deleteAction(for game: GameEntry) -> some View {
        Button {
            gamePendingDeletion = game
        } label: {
            Label("Elimina", systemImage: "trash")
        }
        .tint(Color.red)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            NavigationLink {
                AboutView()
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("Info")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                showImporter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Importa giochi")
            .disabled(library.isBusy)

            Button {
                showMultiplayer = true
            } label: {
                Image(systemName: multiplayer.isJoined ? "person.3.fill" : "person.3")
                    .overlay(alignment: .topTrailing) {
                        if multiplayer.unreadCount > 0 {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 9, height: 9)
                                .offset(x: 5, y: -3)
                        }
                    }
            }
            .accessibilityLabel("Multiplayer")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Impostazioni")
        }
    }

    // MARK: Actions

    private func refreshJIT() {
        jitAvailable = emulator.jitAvailable
    }

    private func refreshLibrary() async {
        await library.refresh()
        refreshJIT()
    }

    private func play(_ game: GameEntry) {
        guard !game.isEncrypted else {
            notice = AppError(
                title: "Gioco criptato",
                message: "Questo dump è criptato e non può essere avviato. Crea un dump decriptato del tuo gioco e importalo di nuovo."
            )
            return
        }
        guard !emulator.isActive else {
            notice = AppError(
                title: "Attendi un momento",
                message: "La sessione di gioco precedente si sta ancora chiudendo. Riprova tra qualche istante."
            )
            return
        }
        // Drop a stale message from an earlier session before the new one starts.
        emulator.alert = nil
        onPlay(game)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            notice = AppError(title: "Importazione non riuscita", error: error)
        case .success(let urls):
            let supported = urls.filter {
                GameLibrary.supportedExtensions.contains($0.pathExtension.lowercased())
            }
            let rejected = urls.filter {
                !GameLibrary.supportedExtensions.contains($0.pathExtension.lowercased())
            }
            if !rejected.isEmpty {
                let names = rejected.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
                let more = rejected.count > 3 ? " e altri \(rejected.count - 3)" : ""
                notice = AppError(
                    title: "File non supportati",
                    message: "Ignorati: \(names)\(more). Formati accettati: .3ds, .cci, .cxi, .cia, .app, .3dsx, .elf e le varianti compresse."
                )
            }
            guard !supported.isEmpty else { return }
            Task { await library.importFiles(supported) }
        }
    }
}

// MARK: - Components

/// Big card for the featured game (Kirby: Planet Robobot when present).
private struct HomeFeaturedCard: View {
    let game: GameEntry
    let isPlayDisabled: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                GameIconView(icon: game.icon, size: 80)
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("IL TUO GIOCO")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Color.white.opacity(0.8))
                    Text(game.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(3)
                    if !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            if game.isEncrypted {
                Label("Questo dump è criptato: crea un dump decriptato per poterci giocare.", systemImage: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Button(action: { onPlay() }) {
                    Label("Gioca", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(PortTheme.accentDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white)
                .controlSize(.large)
                .disabled(isPlayDisabled)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [PortTheme.accent, PortTheme.accentDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
    }

    private var details: String {
        var parts: [String] = []
        if !game.publisher.isEmpty { parts.append(game.publisher) }
        if !game.regions.isEmpty { parts.append(game.regions.joined(separator: ", ")) }
        if game.isInstalledTitle { parts.append("Installato") }
        return parts.joined(separator: " · ")
    }
}

/// Shown while the library has no featured game yet.
private struct HomeOnboardingCard: View {
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(PortTheme.accent)
            Text("Benvenuto in PlanetPort")
                .font(.title3.weight(.bold))
            Text("Importa il tuo dump decriptato di Kirby: Planet Robobot (.3ds/.cci/.cxi/.cia)")
                .font(.subheadline)
            Text("Funziona anche con gli altri giochi 3DS di cui possiedi una copia. Nessun gioco è incluso nell'app.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            Button(action: { onImport() }) {
                Label("Importa", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}

/// Green when the JIT can be used, orange when the interpreter fallback will be used.
private struct HomeJITPill: View {
    let isAvailable: Bool

    var body: some View {
        Label(
            isAvailable ? "JIT attivo" : "Interprete (JIT non disponibile)",
            systemImage: isAvailable ? "bolt.fill" : "tortoise.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isAvailable ? Color.green : Color.orange, in: Capsule())
        .accessibilityLabel(isAvailable ? "JIT attivo" : "JIT non disponibile, verrà usato l'interprete")
    }
}

/// Blocks the library while files are copied or installed.
private struct HomeBusyOverlay: View {
    let message: String
    let progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text(verbatim: "\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(40)
        }
    }
}
