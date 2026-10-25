// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Room chat with system lines (joins, leaves, errors) styled apart from messages.

import SwiftUI
import PlanetCore

@MainActor
struct ChatView: View {
    @EnvironmentObject private var multiplayer: MultiplayerController

    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if multiplayer.chat.isEmpty {
                            Text("Nessun messaggio. Saluta gli altri giocatori!")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(multiplayer.chat) { line in
                            ChatLineRow(line: line)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToBottom(proxy, animated: false) }
                // Keyed on the last line's id, not the count: the chat is capped at maxChatLines,
                // so once full the count stops changing while new lines keep arriving.
                .onChange(of: multiplayer.chat.last?.id) { _ in
                    scrollToBottom(proxy, animated: true)
                    multiplayer.markChatRead()
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    multiplayer.isJoined ? "Messaggio" : "Non sei in una stanza",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit { send() }
                .disabled(!multiplayer.isJoined)

                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 38, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .accessibilityLabel("Invia")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(multiplayer.roomName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { multiplayer.markChatRead() }
        .onDisappear { multiplayer.markChatRead() }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        multiplayer.isJoined && !trimmedDraft.isEmpty
    }

    private func send() {
        guard canSend else { return }
        multiplayer.send(trimmedDraft)
        draft = ""
        isInputFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = multiplayer.chat.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

/// One chat entry: centred capsule for system lines, bubbles for messages.
private struct ChatLineRow: View {
    let line: ChatLine

    var body: some View {
        if line.isSystem {
            HStack {
                Spacer(minLength: 0)
                Text(line.text)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .bottom) {
                if line.isLocal { Spacer(minLength: 48) }
                VStack(alignment: line.isLocal ? .trailing : .leading, spacing: 3) {
                    if !line.isLocal, let nickname = line.nickname {
                        Text(nickname)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PortTheme.accent)
                    }
                    Text(line.text)
                        .foregroundStyle(line.isLocal ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            line.isLocal ? PortTheme.accent : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .textSelection(.enabled)
                    Text(line.date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
                if !line.isLocal { Spacer(minLength: 48) }
            }
        }
    }
}
