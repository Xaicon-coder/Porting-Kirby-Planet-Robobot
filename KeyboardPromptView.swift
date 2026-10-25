// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// The 3DS software keyboard applet. The emulation thread waits until the request is finished,
// so the sheet cannot be swiped away: the user must pick one of the game's buttons.

import SwiftUI
import PlanetCore

@MainActor
struct KeyboardPromptView: View {
    let prompt: KeyboardPrompt

    @EnvironmentObject private var emulator: EmulatorController

    @State private var text = ""
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    private var request: PPKeyboardRequest { prompt.request }
    private var maxLength: Int { Int(request.maxLength) }
    /// Italian error from the game's own validation rules, nil when the text is acceptable.
    private var validationMessage: String? { request.validateText(text) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if request.hintText.isEmpty {
                        Text("Il gioco chiede di inserire del testo.")
                            .font(.headline)
                    } else {
                        Text(request.hintText)
                            .font(.headline)
                    }

                    inputField

                    HStack(alignment: .firstTextBaseline) {
                        if let message = validationMessage {
                            Label(message, systemImage: "exclamationmark.circle")
                                .foregroundStyle(Color.orange)
                        }
                        Spacer(minLength: 8)
                        if maxLength > 0 {
                            Text(verbatim: "\(text.count)/\(maxLength)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .font(.footnote)

                    if let error = emulator.keyboardError, !error.isEmpty {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }

                    buttons
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Inserisci testo")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
        .presentationDetents(request.multiline ? [.large] : [.medium, .large])
        .onAppear { isFocused = true }
        .onChange(of: text) { newValue in
            if maxLength > 0, newValue.count > maxLength {
                text = String(newValue.prefix(maxLength))
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if request.multiline {
            TextEditor(text: $text)
                .focused($isFocused)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        } else {
            TextField("Testo", text: $text)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit {
                    if validationMessage == nil {
                        finish(buttonIndex: request.confirmButtonIndex)
                    }
                }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            ForEach(Array(request.buttonTitles.enumerated()), id: \.offset) { index, title in
                if index == request.confirmButtonIndex {
                    Button {
                        finish(buttonIndex: index)
                    } label: {
                        Text(title)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFinished || validationMessage != nil)
                } else {
                    Button {
                        finish(buttonIndex: index)
                    } label: {
                        Text(title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isFinished)
                }
            }
        }
        .controlSize(.large)
    }

    private func finish(buttonIndex: Int) {
        guard !isFinished else { return }
        isFinished = true
        emulator.keyboardError = nil
        request.finish(withText: text, buttonIndex: buttonIndex)
        // If the game rejects the text, the bridge sends a new request (and an error message).
        if emulator.keyboardPrompt?.id == prompt.id {
            emulator.keyboardPrompt = nil
        }
    }
}
