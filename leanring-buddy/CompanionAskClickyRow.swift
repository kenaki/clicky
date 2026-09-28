//
//  CompanionAskClickyRow.swift
//  leanring-buddy
//
//  The menu bar panel's "Ask Clicky" field: type a question instead of
//  holding push-to-talk. Return sends it and closes the panel; the answer
//  streams into the transcript card like a voice turn (same screenshot and
//  pointing). The speaker button beside it is the global "speak answers"
//  switch, which applies to typed and spoken questions alike.
//
//  The field takes focus whenever the panel opens, so clicking the menu bar
//  icon and typing is enough. The panel is a KeyablePanel, which can become
//  key without activating the app.
//

import SwiftUI

struct CompanionAskClickyRow: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var tuningSettings: CompanionTuningSettings

    @State private var typedQuestionInput: String = ""
    @FocusState private var isTypedQuestionFieldFocused: Bool
    @State private var isSendButtonHovered = false
    @State private var isSpeakAnswersButtonHovered = false

    private var isTypedQuestionEmpty: Bool {
        typedQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            typedQuestionField
            speakAnswersToggleButton
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickyPanelDidShow)) { _ in
            // After the panel has become key, or the focus request is dropped.
            DispatchQueue.main.async {
                isTypedQuestionFieldFocused = true
            }
        }
    }

    private var typedQuestionField: some View {
        let fieldShape = RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
        return HStack(spacing: 6) {
            TextField("Ask Clicky…", text: $typedQuestionInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isTypedQuestionFieldFocused)
                .onSubmit(sendTypedQuestion)

            Button(action: sendTypedQuestion) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundColor(sendButtonColor)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(isTypedQuestionEmpty)
            .onHover { isHovering in isSendButtonHovered = isHovering }
            .help("Send (Return)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(fieldShape.fill(Color.white.opacity(0.08)))
        .overlay(
            fieldShape.stroke(
                isTypedQuestionFieldFocused ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle,
                lineWidth: isTypedQuestionFieldFocused ? 1 : 0.5
            )
        )
    }

    private var sendButtonColor: Color {
        if isTypedQuestionEmpty { return DS.Colors.textTertiary.opacity(0.6) }
        return isSendButtonHovered ? DS.Colors.accent.opacity(0.85) : DS.Colors.accent
    }

    /// Filled speaker when answers are spoken, slashed speaker when they only show.
    private var speakAnswersToggleButton: some View {
        let isSpeakingAnswersEnabled = tuningSettings.isSpeakingAnswersEnabled
        return Button(action: {
            tuningSettings.isSpeakingAnswersEnabled.toggle()
        }) {
            Image(systemName: isSpeakingAnswersEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSpeakingAnswersEnabled ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isSpeakAnswersButtonHovered ? 0.14 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in isSpeakAnswersButtonHovered = isHovering }
        .help(isSpeakingAnswersEnabled
              ? "Answers are spoken. Click to only show them."
              : "Answers only show in the transcript. Click to speak them too.")
    }

    private func sendTypedQuestion() {
        guard !isTypedQuestionEmpty else { return }
        companionManager.sendTypedQuestion(typedQuestionInput)
        typedQuestionInput = ""
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
    }
}
