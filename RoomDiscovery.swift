// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Bonjour advertisement and discovery of PlanetPort rooms on the local network. The Bonjour
// service only carries metadata (TXT: room, pw, game) and the room port; the room itself is
// Azahar's UDP/ENet server.

import Combine
import Darwin
import Foundation

@MainActor
final class RoomDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let serviceType = "_planetport._tcp."

    @Published private(set) var rooms: [DiscoveredRoom] = []
    @Published private(set) var isBrowsing = false

    private static let domain = "local."
    private static let resolveTimeout: TimeInterval = 5
    /// DNS-SD limits: service names to 63 bytes, each TXT key=value pair to 255 bytes.
    private static let maxServiceNameBytes = 63
    private static let maxTXTValueBytes = 200

    private var browser: NetServiceBrowser?
    private var publishedService: NetService?
    /// Final name of our own service (Bonjour may rename it on conflicts).
    private var publishedName: String?
    /// Services being resolved / kept alive, by service name.
    private var services: [String: NetService] = [:]
    private var resolvedRooms: [String: DiscoveredRoom] = [:]

    override init() {
        super.init()
    }

    // MARK: - Browsing

    func startBrowsing() {
        guard browser == nil else { return }
        let newBrowser = NetServiceBrowser()
        newBrowser.delegate = self
        newBrowser.includesPeerToPeer = false
        // Deliver callbacks on the main run loop in every common mode (also while scrolling).
        newBrowser.remove(from: .current, forMode: .default)
        newBrowser.schedule(in: .main, forMode: .common)
        browser = newBrowser
        isBrowsing = true
        newBrowser.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
    }

    func stopBrowsing() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in services.values {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        resolvedRooms.removeAll()
        rooms = []
        isBrowsing = false
    }

    // MARK: - Publishing

    func publish(roomName: String, port: UInt16, hasPassword: Bool, gameName: String) {
        unpublish()
        guard port > 0 else { return }

        let baseName = roomName.isEmpty ? "Stanza PlanetPort" : roomName
        let serviceName = Self.truncated(baseName, maxBytes: Self.maxServiceNameBytes)
        let service = NetService(domain: Self.domain, type: Self.serviceType, name: serviceName, port: Int32(port))
        service.delegate = self
        service.includesPeerToPeer = false

        let txt: [String: Data] = [
            "room": Data(Self.truncated(roomName, maxBytes: Self.maxTXTValueBytes).utf8),
            "pw": Data((hasPassword ? "1" : "0").utf8),
            "game": Data(Self.truncated(gameName, maxBytes: Self.maxTXTValueBytes).utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))

        service.remove(from: .current, forMode: .default)
        service.schedule(in: .main, forMode: .common)
        publishedService = service
        publishedName = serviceName
        // No .listenForConnections: the room has its own socket.
        service.publish()
        rebuildRooms()
    }

    func unpublish() {
        guard let service = publishedService else { return }
        service.stop()
        service.delegate = nil
        publishedService = nil
        publishedName = nil
        rebuildRooms()
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        isBrowsing = true
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        guard browser === self.browser else { return }
        self.browser = nil
        isBrowsing = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        // Typically the local network permission was denied; allow a later retry.
        browser.delegate = nil
        self.browser = nil
        isBrowsing = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let name = service.name
        if let existing = services[name], existing !== service {
            existing.stop()
            existing.delegate = nil
        }
        services[name] = service
        service.delegate = self
        service.remove(from: .current, forMode: .default)
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: Self.resolveTimeout)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        if let existing = services.removeValue(forKey: name) {
            existing.stop()
            existing.delegate = nil
        }
        resolvedRooms.removeValue(forKey: name)
        if !moreComing {
            rebuildRooms()
        }
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === publishedService else { return }
        publishedName = sender.name
        rebuildRooms()
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === publishedService else { return }
        // Advertising is best effort: friends can still join by IP address.
        sender.delegate = nil
        publishedService = nil
        publishedName = nil
        rebuildRooms()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender !== publishedService, services[sender.name] === sender else { return }
        guard sender.port > 0, sender.port <= Int(UInt16.max),
              let host = Self.preferredHost(from: sender.addresses ?? []) else { return }

        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let roomName = Self.string(txt["room"]).flatMap { $0.isEmpty ? nil : $0 } ?? sender.name
        let room = DiscoveredRoom(id: sender.name,
                                  name: roomName,
                                  host: host,
                                  port: UInt16(sender.port),
                                  hasPassword: Self.string(txt["pw"]) == "1",
                                  gameName: Self.string(txt["game"]) ?? "")
        resolvedRooms[sender.name] = room
        rebuildRooms()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard sender !== publishedService else { return }
        // Keep the service object: a later didFind/didRemove will refresh or drop it.
        sender.stop()
    }

    // MARK: - Private

    private func rebuildRooms() {
        let ownName = publishedName
        rooms = resolvedRooms.values
            .filter { $0.id != ownName }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order != .orderedSame ? order == .orderedAscending : lhs.id < rhs.id
            }
    }

    private static func string(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Truncates on character boundaries so the UTF-8 encoding fits in `maxBytes`.
    private static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Numeric host for the best resolved address: routable IPv4, then any IPv4, then routable
    /// IPv6, then link-local IPv6 (with scope id).
    private static func preferredHost(from addresses: [Data]) -> String? {
        var candidates: [(rank: Int, host: String)] = []
        for data in addresses {
            guard let resolved = numericHost(from: data) else { continue }
            let rank: Int
            if resolved.family == AF_INET {
                rank = resolved.host.hasPrefix("169.254.") ? 1 : 0
            } else {
                rank = resolved.host.lowercased().hasPrefix("fe80") ? 3 : 2
            }
            candidates.append((rank, resolved.host))
        }
        return candidates.min { $0.rank < $1.rank }?.host
    }

    /// Converts a sockaddr_in / sockaddr_in6 blob to its numeric host string.
    private static func numericHost(from data: Data) -> (family: Int32, host: String)? {
        var storage = sockaddr_storage()
        let length = min(data.count, MemoryLayout<sockaddr_storage>.size)
        guard length >= MemoryLayout<sockaddr_in>.size else { return nil }
        withUnsafeMutableBytes(of: &storage) { buffer in
            _ = data.copyBytes(to: buffer, count: length)
        }

        let family = Int32(storage.ss_family)
        let expectedLength: Int
        switch family {
        case AF_INET: expectedLength = MemoryLayout<sockaddr_in>.size
        case AF_INET6: expectedLength = MemoryLayout<sockaddr_in6>.size
        default: return nil
        }
        guard length >= expectedLength else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getnameinfo(address, socklen_t(expectedLength), &hostBuffer, socklen_t(NI_MAXHOST),
                            nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        let host = String(cString: hostBuffer)
        return host.isEmpty ? nil : (family, host)
    }
}
