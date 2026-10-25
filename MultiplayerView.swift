// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Multiplayer rooms: nickname, Wi-Fi room discovery, hosting, joining by address, current room.

import SwiftUI
import PlanetCore

@MainActor
struct MultiplayerView: View {
    @EnvironmentObject private var multiplayer: MultiplayerController
    @EnvironmentObject private var emulator: EmulatorController
    @Environment(\.dismiss) private var dismiss

    @State private var nicknameDraft = ""
    @State private var nicknameFeedback: String?
    @State private var nicknameFeedbackIsError = false

    @State private var roomName = ""
    @State private var hostPort = String(PPDefaultRoomPort)
    @State private var hostPassword = ""
    @State private var maxPlayers = 4

    @State private var joinAddress = ""
    @State private var joinPort = String(PPDefaultRoomPort)
    @State private var joinPassword = ""

    @State private var roomAwaitingPassword: DiscoveredRoom?
    @State private var discoveredRoomPassword = ""
    @State private var memberPendingBan: String?
    @State private var didLoadDrafts = false

    var body: some View {
        NavigationStack {
            Form {
                nicknameSection
                if multiplayer.isJoined {
                    currentRoomSection
                } else {
                    DiscoveredRoomsSection(
                        discovery: multiplayer.discovery,
                        isDisabled: multiplayer.isBusy,
                        onSelect: { room in select(room) }
                    )
                    hostSection
                    joinSection
                }
                helpSection
            }
            .navigationTitle("Multiplayer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .overlay {
                if multiplayer.isBusy {
                    ProgressView("Attendere…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert(
                "Password della stanza",
                isPresented: Binding(
                    get: { roomAwaitingPassword != nil },
                    set: { if !$0 { roomAwaitingPassword = nil } }
                ),
                presenting: roomAwaitingPassword
            ) { room in
                SecureField("Password", text: $discoveredRoomPassword)
                Button("Entra") { join(room, password: discoveredRoomPassword) }
                Button("Annulla", role: .cancel) {}
            } message: { room in
                Text("La stanza «\(room.name)» è protetta da password.")
            }
            .confirmationDialog(
                "Bannare il giocatore?",
                isPresented: Binding(
                    get: { memberPendingBan != nil },
                    set: { if !$0 { memberPendingBan = nil } }
                ),
                titleVisibility: .visible,
                presenting: memberPendingBan
            ) { nickname in
                Button("Banna \(nickname)", role: .destructive) { multiplayer.ban(nickname) }
                Button("Annulla", role: .cancel) {}
            } message: { _ in
                Text("Il giocatore verrà espulso e non potrà più rientrare in questa stanza.")
            }
        }
        .appErrorAlert($multiplayer.alert)
        .onAppear {
            loadDrafts()
            multiplayer.discovery.startBrowsing()
        }
        .onDisappear {
            multiplayer.discovery.stopBrowsing()
        }
    }

    // MARK: Sections

    private var nicknameSection: some View {
        Section {
            HStack {
                TextField("Nome giocatore", text: $nicknameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveNickname() }
                Button("Salva") { saveNickname() }
                    .buttonStyle(.borderless)
                    .disabled(nicknameDraft == multiplayer.nickname || emulator.isActive)
            }
            .disabled(emulator.isActive)
            if let feedback = nicknameFeedback {
                Text(feedback)
                    .font(.footnote)
                    .foregroundStyle(nicknameFeedbackIsError ? Color.red : Color.green)
            }
        } header: {
            Text("Il tuo nome")
        } footer: {
            if emulator.isActive {
                Text("Chiudi il gioco per cambiare nome: è il nome utente della console emulata.")
            } else {
                Text("Da 4 a 10 caratteri: lettere, numeri, spazi, punto, trattino o trattino basso. È anche il nome utente della console emulata.")
            }
        }
    }

    private var currentRoomSection: some View {
        Section {
            LabeledContent("Stanza", value: multiplayer.roomName ?? "—")
            LabeledContent("Il tuo ruolo", value: roleDescription)
            if multiplayer.isHosting {
                LabeledContent("Indirizzi IP", value: localAddressesText)
            }
            ForEach(multiplayer.members) { member in
                memberRow(member)
            }
            NavigationLink {
                ChatView()
            } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .badge(multiplayer.unreadCount)
            Button(role: .destructive) {
                Task { await multiplayer.leave() }
            } label: {
                Label("Esci dalla stanza", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(multiplayer.isBusy)
        } header: {
            Text("Stanza attuale")
        } footer: {
            if multiplayer.isModerator {
                Text("Tieni premuto su un giocatore per espellerlo o bannarlo.")
            }
        }
    }

    private func memberRow(_ member: RoomMemberEntry) -> some View {
        let isSelf = member.nickname == multiplayer.nickname
        return HStack(spacing: 12) {
            Image(systemName: isSelf ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(PortTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelf ? "\(member.nickname) (tu)" : member.nickname)
                    .font(.body.weight(.semibold))
                Text(member.gameName.isEmpty ? "Nessun gioco avviato" : member.gameName)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .contextMenu {
            if multiplayer.isModerator && !isSelf {
                Button {
                    multiplayer.kick(member.nickname)
                } label: {
                    Label("Espelli", systemImage: "person.badge.minus")
                }
                Button(role: .destructive) {
                    memberPendingBan = member.nickname
                } label: {
                    Label("Banna", systemImage: "nosign")
                }
            }
        }
    }

    private var hostSection: some View {
        Section {
            TextField("Nome della stanza", text: $roomName)
                .autocorrectionDisabled()
            HStack {
                Text("Porta")
                Spacer()
                TextField(String(PPDefaultRoomPort), text: $hostPort)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
            }
            SecureField("Password (facoltativa)", text: $hostPassword)
            Stepper(value: $maxPlayers, in: 2...8) {
                Text("Giocatori massimi: \(maxPlayers)")
            }
            Button {
                hostRoom()
            } label: {
                Label("Crea stanza", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(multiplayer.isBusy)
        } header: {
            Text("Ospita una stanza")
        } footer: {
            Text(hostFooter)
        }
    }

    private var joinSection: some View {
        Section {
            TextField("Indirizzo IP o nome host", text: $joinAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text("Porta")
                Spacer()
                TextField(String(PPDefaultRoomPort), text: $joinPort)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
            }
            SecureField("Password (se richiesta)", text: $joinPassword)
            Button {
                joinByAddress()
            } label: {
                Label("Connetti", systemImage: "network")
            }
            .disabled(multiplayer.isBusy || joinAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Connettiti a un indirizzo")
        } footer: {
            Text("Usa l'indirizzo comunicato da chi ospita (anche nel formato indirizzo:porta).")
        }
    }

    private var helpSection: some View {
        Section {
            helpRow("person.2.fill", "Ogni giocatore deve avere la propria copia del gioco e il proprio dispositivo con PlanetPort.")
            helpRow("gamecontroller.fill", "Entrate tutti nella stessa stanza prima di avviare il gioco, poi scegliete il gioco in locale (per esempio Team Kirby Clash): la stanza simula la connessione wireless tra console.")
            helpRow("wifi", "Nella stessa rete Wi-Fi le stanze compaiono automaticamente qui sopra.")
            helpRow("globe", "Via Internet: chi ospita deve aprire la porta UDP 24872 sul proprio router (port forwarding), oppure usate tutti una VPN come Tailscale o ZeroTier e connettetevi all'indirizzo VPN di chi ospita.")
        } header: {
            Text("Come giocare online")
        }
    }

    private func helpRow(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(PortTheme.accent)
        }
    }

    // MARK: Derived text

    private var roleDescription: String {
        if multiplayer.isHosting { return "Host" }
        if multiplayer.isModerator { return "Moderatore" }
        return "Giocatore"
    }

    private var localAddressesText: String {
        let addresses = MultiplayerController.localIPAddresses()
        return addresses.isEmpty ? "Nessuna rete" : addresses.joined(separator: ", ")
    }

    private var hostFooter: String {
        let addresses = MultiplayerController.localIPAddresses()
        if addresses.isEmpty {
            return "Nessun indirizzo di rete locale trovato: collegati a una rete Wi-Fi."
        }
        return "I tuoi indirizzi: \(addresses.joined(separator: ", ")). Nella stessa rete gli amici trovano la stanza automaticamente; da 2 a 8 giocatori."
    }

    // MARK: Actions

    private func loadDrafts() {
        guard !didLoadDrafts else { return }
        didLoadDrafts = true
        nicknameDraft = multiplayer.nickname
        if roomName.isEmpty {
            roomName = Self.defaultRoomName(for: multiplayer.nickname)
        }
    }

    private static func defaultRoomName(for nickname: String) -> String {
        let candidate = "Stanza di \(nickname)"
        return PPMultiplayer.isValidRoomName(candidate) ? candidate : "Stanza PlanetPort"
    }

    private func saveNickname() {
        let name = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = multiplayer.setNickname(name) {
            nicknameFeedback = error
            nicknameFeedbackIsError = true
        } else {
            nicknameDraft = multiplayer.nickname
            nicknameFeedback = "Nome salvato."
            nicknameFeedbackIsError = false
        }
    }

    private static func parsePort(_ text: String) -> UInt16? {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    private func hostRoom() {
        guard PPMultiplayer.isValidNickname(multiplayer.nickname) else {
            multiplayer.alert = AppError(
                title: "Nome non valido",
                message: "Imposta prima un nome giocatore valido (da 4 a 10 caratteri: lettere, numeri, spazi, punto, trattino o trattino basso)."
            )
            return
        }
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PPMultiplayer.isValidRoomName(name) else {
            multiplayer.alert = AppError(
                title: "Nome della stanza non valido",
                message: "Usa da 4 a 20 caratteri: lettere, numeri, spazi, punto, trattino o trattino basso."
            )
            return
        }
        guard let port = Self.parsePort(hostPort) else {
            multiplayer.alert = AppError(
                title: "Porta non valida",
                message: "Inserisci un numero tra 1 e 65535 (predefinita \(PPDefaultRoomPort))."
            )
            return
        }
        let password = hostPassword
        let players = maxPlayers
        Task {
            _ = await multiplayer.host(name: name, port: port, password: password, maxPlayers: players)
        }
    }

    private func joinByAddress() {
        var address = joinAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        var portText = joinPort
        // Accept "host:port" (IPv4 or host name; IPv6 addresses contain more than one colon).
        let parts = address.split(separator: ":")
        if parts.count == 2, UInt16(parts[1]) != nil {
            address = String(parts[0])
            portText = String(parts[1])
        }
        guard !address.isEmpty else {
            multiplayer.alert = AppError(title: "Indirizzo mancante", message: "Inserisci l'indirizzo IP o il nome host della stanza.")
            return
        }
        guard let port = Self.parsePort(portText) else {
            multiplayer.alert = AppError(
                title: "Porta non valida",
                message: "Inserisci un numero tra 1 e 65535 (predefinita \(PPDefaultRoomPort))."
            )
            return
        }
        let password = joinPassword
        let host = address
        Task {
            _ = await multiplayer.join(address: host, port: port, password: password)
        }
    }

    private func select(_ room: DiscoveredRoom) {
        if room.hasPassword {
            discoveredRoomPassword = ""
            roomAwaitingPassword = room
        } else {
            join(room, password: "")
        }
    }

    private func join(_ room: DiscoveredRoom, password: String) {
        Task {
            _ = await multiplayer.join(room: room, password: password)
        }
    }
}

/// Rooms advertised over Bonjour by other PlanetPort devices on the same network.
@MainActor
private struct DiscoveredRoomsSection: View {
    @ObservedObject var discovery: RoomDiscovery
    let isDisabled: Bool
    let onSelect: (DiscoveredRoom) -> Void

    var body: some View {
        Section {
            if discovery.rooms.isEmpty {
                HStack(spacing: 10) {
                    if discovery.isBrowsing {
                        ProgressView()
                    }
                    Text(discovery.isBrowsing ? "Ricerca di stanze in corso…" : "Nessuna stanza trovata")
                        .foregroundStyle(Color.secondary)
                }
            } else {
                ForEach(discovery.rooms) { room in
                    Button {
                        onSelect(room)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: room.hasPassword ? "lock.fill" : "wifi")
                                .foregroundStyle(PortTheme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(detail(for: room))
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                }
            }
        } header: {
            Text("Stanze nella tua rete Wi-Fi")
        } footer: {
            Text("Le stanze create con PlanetPort su altri dispositivi della stessa rete compaiono qui automaticamente. Tocca una stanza per entrare.")
        }
    }

    private func detail(for room: DiscoveredRoom) -> String {
        let address = "\(room.host):\(room.port)"
        return room.gameName.isEmpty ? address : "\(room.gameName) · \(address)"
    }
}
