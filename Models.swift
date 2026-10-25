// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Value types shared by the services (Core/) and the views (UI/).

import Foundation
import PlanetCore
import UIKit

/// A bootable game known to the app (a ROM file in the games folder or an installed title).
struct GameEntry: Identifiable, Hashable {
    /// Absolute path of the bootable file (unique).
    let id: String
    let url: URL
    let title: String
    let publisher: String
    let titleID: UInt64
    let titleIDString: String
    let fileType: String
    let isInstalledTitle: Bool
    let isEncrypted: Bool
    let isPlanetRobobot: Bool
    let regions: [String]
    /// Not part of equality/hash.
    let icon: UIImage?

    init(info: PPGameInfo) {
        id = info.path
        url = URL(fileURLWithPath: info.path)
        title = info.title
        publisher = info.publisher
        titleID = info.titleID
        titleIDString = info.titleIDString
        fileType = info.fileTypeDescription
        isInstalledTitle = info.isInstalledTitle
        isEncrypted = info.isEncrypted
        isPlanetRobobot = info.looksLikePlanetRobobot
        regions = info.regions
        icon = info.icon
    }

    static func == (lhs: GameEntry, rhs: GameEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// An error shown to the user in an alert.
struct AppError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    /// Fatal errors end the emulation session; non-fatal ones are informational.
    let isFatal: Bool

    init(title: String, message: String, isFatal: Bool = false) {
        self.title = title
        self.message = message
        self.isFatal = isFatal
    }

    init(title: String, error: Error, isFatal: Bool = false) {
        self.title = title
        let nsError = error as NSError
        var text = nsError.localizedDescription
        if let details = nsError.userInfo[PPErrorCoreDetailsKey] as? String, !details.isEmpty {
            text += "\n\n(\(details))"
        }
        self.message = text
        self.isFatal = isFatal
    }

    static func == (lhs: AppError, rhs: AppError) -> Bool { lhs.id == rhs.id }
}

/// Disk shader cache loading progress.
struct ShaderProgress: Equatable {
    let stage: PPShaderLoadStage
    let progress: Int
    let total: Int

    var fraction: Double { total > 0 ? Double(progress) / Double(total) : 0 }
}

/// Snapshot of PPPerformanceStats.
struct PerformanceSnapshot: Equatable {
    var fps: Double
    var speedPercent: Double
    var frameTimeMs: Double

    static let zero = PerformanceSnapshot(fps: 0, speedPercent: 0, frameTimeMs: 0)
}

/// Wraps a PPKeyboardRequest so SwiftUI can present it with `.sheet(item:)`.
struct KeyboardPrompt: Identifiable {
    let id = UUID()
    let request: PPKeyboardRequest
}

/// One line of the multiplayer chat / event log.
struct ChatLine: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    /// nil for system lines (joins, leaves, errors).
    let nickname: String?
    let text: String
    let isLocal: Bool

    var isSystem: Bool { nickname == nil }
}

/// A member of the current room.
struct RoomMemberEntry: Identifiable, Equatable {
    var id: String { nickname }
    let nickname: String
    let gameName: String
    let gameID: UInt64
    let macAddress: String

    init(member: PPRoomMember) {
        nickname = member.nickname
        gameName = member.gameName
        gameID = member.gameID
        macAddress = member.macAddress
    }
}

/// A room advertised on the local network via Bonjour by another PlanetPort device.
struct DiscoveredRoom: Identifiable, Equatable {
    /// Bonjour service name (unique on the network).
    let id: String
    let name: String
    /// Resolved IPv4 (preferred) or IPv6 address.
    let host: String
    let port: UInt16
    let hasPassword: Bool
    let gameName: String
}
