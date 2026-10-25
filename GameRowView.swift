// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// One game in the library list, plus the reusable game icon view.

import SwiftUI
import UIKit
import PlanetCore

/// A row of the library list.
struct GameRowView: View {
    let game: GameEntry

    var body: some View {
        HStack(spacing: 12) {
            GameIconView(icon: game.icon, size: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                if game.isEncrypted {
                    Label("Criptato: non avviabile", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: game.isEncrypted ? "lock.circle" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(game.isEncrypted ? Color.secondary : PortTheme.accent)
        }
        .padding(.vertical, 4)
        .opacity(game.isEncrypted ? 0.65 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isEncrypted ? "Questo dump è criptato e non può essere avviato" : "Tocca per giocare")
    }

    private var subtitle: String {
        var parts: [String] = []
        if !game.publisher.isEmpty { parts.append(game.publisher) }
        if !game.fileType.isEmpty { parts.append(game.fileType) }
        if game.isInstalledTitle { parts.append("Installato") }
        if !game.regions.isEmpty { parts.append(game.regions.joined(separator: ", ")) }
        return parts.isEmpty ? game.url.lastPathComponent : parts.joined(separator: " · ")
    }
}

/// The SMDH icon of a game, or a neutral placeholder when the file has none.
struct GameIconView: View {
    let icon: UIImage?
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [PortTheme.accent, PortTheme.accentDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}
