// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Multiplayer rooms (emulated local wireless relayed by Azahar's network library): hosting,
// joining, chat, moderation and console identity. Rooms hosted here are advertised on the local
// network through RoomDiscovery.

import Combine
import Darwin
import Foundation
import PlanetCore

@MainActor
final class MultiplayerController: NSObject, ObservableObject, PPMultiplayerDelegate {
    static let shared = MultiplayerController()

    @Published private(set) var isJoined = false
    @Published private(set) var isHosting = false
    @Published private(set) var isModerator = false
    @Published private(set) var roomName: String?
    @Published private(set) var members: [RoomMemberEntry] = []
    /// Includes system lines.
    @Published private(set) var chat: [ChatLine] = []
    @Published private(set) var unreadCount = 0
    @Published private(set) var isBusy = false
    /// Console user name (also the multiplayer nickname).
    @Published private(set) var nickname = ""
    @Published var alert: AppError?

    let discovery: RoomDiscovery

    private var isActivated = false
    private static let maxChatLines = 300

    private override init() {
        discovery = RoomDiscovery()
        super.init()
    }

    // MARK: - Setup

    /// Called once by EmulatorController.bootstrap(): sets the PPMultiplayer delegate, activate(),
    /// loads nickname.
    func activate() {
        let multiplayer = PPMultiplayer.shared
        multiplayer.delegate = self
        if !isActivated {
            isActivated = multiplayer.activate()
            if !isActivated {
                alert = AppError(title: "Multigiocatore non disponibile",
                                 message: "La rete dell'emulatore non è stata inizializzata. Riavvia l'app e riprova.")
            }
        }
        reloadNickname()
        syncRoomState()
    }

    /// Validates (PPMultiplayer.isValidNickname) and stores via PPEmulator.setConsoleUsername.
    /// Returns an Italian error message, or nil on success.
    func setNickname(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PPMultiplayer.isValidNickname(trimmed) else {
            return "Il nome deve avere da 4 a 10 caratteri: lettere senza accenti, numeri, spazi, punti, "
                + "trattini o trattini bassi."
        }
        guard !EmulatorController.shared.isActive else {
            return "Chiudi il gioco in corso prima di cambiare nome."
        }
        guard !isJoined else {
            return "Esci dalla stanza prima di cambiare nome."
        }
        do {
            try PPEmulator.shared.setConsoleUsername(trimmed)
        } catch {
            return Self.message(for: error)
        }
        reloadNickname()
        if nickname.isEmpty { nickname = trimmed }
        return nil
    }

    // MARK: - Rooms

    func host(name: String, port: UInt16, password: String, maxPlayers: Int) async -> Bool {
        guard !isBusy else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PPMultiplayer.isValidRoomName(trimmedName) else {
            alert = AppError(title: "Nome della stanza non valido",
                             message: "Il nome della stanza deve avere da 4 a 20 caratteri: lettere senza accenti, "
                                + "numeri, spazi, punti, trattini o trattini bassi.")
            return false
        }
        let checkedPort = Self.effectivePort(port)
        guard prepareIdentity() else { return false }
        guard !PPMultiplayer.shared.isJoined else {
            alert = AppError(title: "Sei già in una stanza",
                             message: "Esci dalla stanza attuale prima di crearne una nuova.")
            return false
        }

        isBusy = true
        defer { isBusy = false }

        let game = EmulatorController.shared.currentGame ?? GameLibrary.shared.featuredGame
        let gameName = game?.title ?? ""
        let gameID = game?.titleID ?? 0
        let roomPassword: String? = password.isEmpty ? nil : password
        let players = min(max(maxPlayers, 2), 16)

        let status: PPNetStatus = await withCheckedContinuation { continuation in
            PPMultiplayer.shared.hostRoomNamed(trimmedName,
                                               port: checkedPort,
                                               password: roomPassword,
                                               maxPlayers: players,
                                               preferredGameName: gameName,
                                               preferredGameID: gameID) { status in
                continuation.resume(returning: status)
            }
        }

        syncRoomState()
        guard status == .noError else {
            alert = AppError(title: "Impossibile creare la stanza", message: Self.explanation(for: status))
            return false
        }

        discovery.publish(roomName: trimmedName, port: checkedPort, hasPassword: roomPassword != nil, gameName: gameName)
        startNewConversation()
        appendSystem("Stanza «\(trimmedName)» creata sulla porta \(checkedPort).")
        return true
    }

    func join(address: String, port: UInt16, password: String) async -> Bool {
        guard !isBusy else { return false }
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            alert = AppError(title: "Indirizzo mancante",
                             message: "Inserisci l'indirizzo IP del dispositivo che ospita la stanza.")
            return false
        }
        let checkedPort = Self.effectivePort(port)
        guard prepareIdentity() else { return false }
        guard !PPMultiplayer.shared.isJoined else {
            alert = AppError(title: "Sei già in una stanza",
                             message: "Esci dalla stanza attuale prima di entrare in un'altra.")
            return false
        }

        isBusy = true
        defer { isBusy = false }

        let roomPassword: String? = password.isEmpty ? nil : password
        let status: PPNetStatus = await withCheckedContinuation { continuation in
            PPMultiplayer.shared.joinRoom(atAddress: trimmedAddress,
                                          port: checkedPort,
                                          password: roomPassword) { status in
                continuation.resume(returning: status)
            }
        }

        syncRoomState()
        guard status == .noError else {
            alert = AppError(title: "Impossibile entrare nella stanza", message: Self.explanation(for: status))
            return false
        }

        startNewConversation()
        appendSystem("Sei entrato nella stanza «\(roomName ?? trimmedAddress)».")
        return true
    }

    func join(room: DiscoveredRoom, password: String) async -> Bool {
        await join(address: room.host, port: room.port, password: password)
    }

    /// Leaves the room (destroying it when hosting) and stops advertising it.
    func leave() async {
        discovery.unpublish()
        let multiplayer = PPMultiplayer.shared
        guard multiplayer.isJoined || multiplayer.isHosting || isJoined || isHosting else {
            syncRoomState()
            return
        }

        isBusy = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            multiplayer.leaveRoom {
                continuation.resume()
            }
        }
        isBusy = false

        syncRoomState()
        unreadCount = 0
        appendSystem("Hai lasciato la stanza.")
    }

    // MARK: - Chat and moderation

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isJoined else { return }
        // The bridge emits a local echo event, which adds the line to `chat`.
        PPMultiplayer.shared.sendChatMessage(trimmed)
    }

    func kick(_ nickname: String) {
        guard isModerator, nickname != self.nickname else { return }
        PPMultiplayer.shared.kickMember(nickname)
    }

    func ban(_ nickname: String) {
        guard isModerator, nickname != self.nickname else { return }
        PPMultiplayer.shared.banMember(nickname)
    }

    func markChatRead() {
        unreadCount = 0
    }

    // MARK: - Console identity

    /// Regenerate console identity (only when no game runs). Returns an Italian error or nil.
    func regenerateConsoleID() -> String? {
        guard !EmulatorController.shared.isActive else {
            return "Chiudi il gioco in corso prima di rigenerare l'ID della console."
        }
        do {
            try PPEmulator.shared.regenerateConsoleID()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    func regenerateMACAddress() -> String? {
        guard !EmulatorController.shared.isActive else {
            return "Chiudi il gioco in corso prima di rigenerare l'indirizzo MAC."
        }
        do {
            try PPEmulator.shared.regenerateMACAddress()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    // MARK: - Local addresses

    /// Non-loopback IPv4 addresses of this device (Wi-Fi first), for "tell your friends this IP".
    nonisolated static func localIPAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            let flags = Int32(truncatingIfNeeded: entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let text = String(cString: host)
            guard !text.isEmpty else { continue }
            found.append((String(cString: entry.ifa_name), text))
        }

        func rank(_ item: (interface: String, address: String)) -> Int {
            var value: Int
            if item.interface == "en0" {
                value = 0
            } else if item.interface.hasPrefix("en") {
                value = 1
            } else if item.interface.hasPrefix("bridge") {
                value = 2   // Personal Hotspot
            } else {
                value = 3   // cellular, VPN, ...
            }
            if item.address.hasPrefix("169.254.") { value += 10 } // link-local last
            return value
        }

        var seen = Set<String>()
        return found
            .enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (rank(lhs.element), rank(rhs.element))
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element.address }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - PPMultiplayerDelegate

    func multiplayer(_ multiplayer: PPMultiplayer, didReceive event: PPNetEvent) {
        switch event.status {
        case .chatMessage:
            guard let text = event.message, !text.isEmpty else { return }
            let author = event.nickname.flatMap { $0.isEmpty ? nil : $0 }
                ?? (event.isLocalEcho ? nickname : "?")
            append(ChatLine(nickname: author, text: text, isLocal: event.isLocalEcho))
            if !event.isLocalEcho {
                unreadCount += 1
            }

        case .memberJoin, .memberLeave, .memberKicked, .memberBanned:
            appendSystem(Self.systemText(for: event))
            syncRoomState()

        case .addressUnbanned:
            let description = PPMultiplayer.description(for: event.status)
            if let address = event.message, !address.isEmpty {
                appendSystem("\(description): \(address)")
            } else {
                appendSystem(description)
            }

        case .roomJoining, .roomJoined, .roomModerator, .noError:
            syncRoomState()

        case .roomIdle, .roomUninitialized:
            let wasJoined = isJoined
            syncRoomState()
            if wasJoined && !isJoined && !isBusy {
                appendSystem("Disconnesso dalla stanza.")
            }

        case .lostConnection, .hostKicked, .hostBanned:
            let description = PPMultiplayer.description(for: event.status)
            appendSystem(description)
            syncRoomState()
            if !isBusy {
                alert = AppError(title: "Multigiocatore", message: description)
            }

        default:
            // Errors of an ongoing host/join are reported by its completion; log the others.
            if !isBusy {
                appendSystem(Self.systemText(for: event))
            }
            syncRoomState()
        }
    }

    func multiplayerRoomDidChange(_ multiplayer: PPMultiplayer) {
        syncRoomState()
    }

    // MARK: - Private

    private func reloadNickname() {
        nickname = PPEmulator.shared.consoleUsername() ?? ""
    }

    /// Ensures the bridge is active and the console user name is a valid nickname.
    private func prepareIdentity() -> Bool {
        if !isActivated {
            activate()
        }
        guard isActivated else { return false }
        reloadNickname()
        guard PPMultiplayer.isValidNickname(nickname) else {
            alert = AppError(title: "Nome giocatore non valido",
                             message: "Imposta un nome giocatore da 4 a 10 caratteri (lettere senza accenti, numeri, "
                                + "spazi, punti o trattini) prima di giocare in multigiocatore.")
            return false
        }
        return true
    }

    /// Re-reads the room snapshot from the bridge.
    private func syncRoomState() {
        let multiplayer = PPMultiplayer.shared
        isJoined = multiplayer.isJoined
        isHosting = multiplayer.isHosting
        isModerator = multiplayer.isModerator
        if isJoined {
            let info = multiplayer.roomInfo
            roomName = info?.name
            members = multiplayer.members.map(RoomMemberEntry.init(member:))
        } else {
            roomName = nil
            members = []
        }
        if !isHosting {
            discovery.unpublish()
        }
    }

    private func startNewConversation() {
        chat.removeAll()
        unreadCount = 0
    }

    private func appendSystem(_ text: String) {
        append(ChatLine(nickname: nil, text: text, isLocal: false))
    }

    private func append(_ line: ChatLine) {
        chat.append(line)
        if chat.count > Self.maxChatLines {
            chat.removeFirst(chat.count - Self.maxChatLines)
        }
    }

    /// Port 0 is not usable: fall back to Azahar's default room port.
    private static func effectivePort(_ port: UInt16) -> UInt16 {
        port == 0 ? PPDefaultRoomPort : port
    }

    private static func systemText(for event: PPNetEvent) -> String {
        let description = PPMultiplayer.description(for: event.status)
        if let name = event.nickname, !name.isEmpty {
            return "\(description): \(name)"
        }
        return description
    }

    /// Status description plus a hint for the errors the user can fix from the app.
    private static func explanation(for status: PPNetStatus) -> String {
        let description = PPMultiplayer.description(for: status)
        switch status {
        case .consoleIdCollision:
            return description + "\n\nRigenera l'ID della console nelle impostazioni multigiocatore e riprova."
        case .macCollision:
            return description + "\n\nRigenera l'indirizzo MAC nelle impostazioni multigiocatore e riprova."
        case .nameCollision:
            return description + "\n\nCambia il tuo nome giocatore e riprova."
        case .couldNotConnect, .networkError:
            return description + "\n\nControlla che entrambi i dispositivi siano sulla stessa rete Wi-Fi, "
                + "che l'indirizzo e la porta siano corretti e che PlanetPort possa accedere alla rete locale "
                + "(Impostazioni > Privacy e sicurezza > Rete locale)."
        default:
            return description
        }
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        var text = nsError.localizedDescription
        if let details = nsError.userInfo[PPErrorCoreDetailsKey] as? String, !details.isEmpty {
            text += " (\(details))"
        }
        return text
    }
}
