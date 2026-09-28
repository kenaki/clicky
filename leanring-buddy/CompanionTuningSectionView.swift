//
//  CompanionTuningSectionView.swift
//  leanring-buddy
//
//  The "Voice & motion" section of the menu bar panel: Kokoro voice, blend
//  and speed with a preview, then cursor flight speed, pointing hold time and
//  transcript panel animation speed. Every control writes straight to
//  CompanionTuningSettings, which takes effect at the next use.
//

import SwiftUI

struct CompanionTuningSectionView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var tuningSettings: CompanionTuningSettings
    @AppStorage("isVoiceAndMotionSectionExpanded") private var isExpanded = true

    private static let rowLabelWidth: CGFloat = 92
    private static let valueLabelWidth: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader

            if isExpanded {
                if companionManager.availableSpeechVoiceNames.isEmpty {
                    Text(companionManager.isSparkVoiceConfigured
                         ? "this voice server has no voices to pick from."
                         : "voice settings need the Spark voice server.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.vertical, 2)
                } else {
                    voiceRows
                }

                motionRows
                    .padding(.top, 6)
            }
        }
        .onAppear {
            companionManager.refreshAvailableSpeechVoices()
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: DS.Animation.fast)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text("Voice & motion")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Voice

    private var voiceRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            tuningRow(label: "Voice") {
                voiceMenu(
                    selectedVoiceName: tuningSettings.speechVoiceName,
                    includesNoneOption: false
                ) { chosenVoiceName in
                    tuningSettings.speechVoiceName = chosenVoiceName
                }
                Spacer(minLength: 0)
            }

            tuningRow(label: "Blend with") {
                voiceMenu(
                    selectedVoiceName: tuningSettings.speechBlendVoiceName,
                    includesNoneOption: true
                ) { chosenVoiceName in
                    tuningSettings.speechBlendVoiceName = chosenVoiceName
                }
                Spacer(minLength: 0)
            }

            if !tuningSettings.speechBlendVoiceName.isEmpty {
                tuningSliderRow(
                    label: "Mix",
                    value: $tuningSettings.speechBlendShare,
                    range: 0...1,
                    step: 0.05,
                    valueText: "\(Int((tuningSettings.speechBlendShare * 100).rounded()))%"
                )
            }

            tuningSliderRow(
                label: "Speed",
                value: $tuningSettings.speechSpeed,
                range: CompanionTuningSettings.speechSpeedRange,
                step: 0.05,
                valueText: String(format: "%.2f×", tuningSettings.speechSpeed)
            )

            HStack {
                Spacer()
                smallPillButton(title: "Preview voice", systemImageName: "play.fill") {
                    companionManager.previewSpeechVoice()
                }
            }
        }
    }

    private func voiceMenu(
        selectedVoiceName: String,
        includesNoneOption: Bool,
        onChoose: @escaping (String) -> Void
    ) -> some View {
        let voiceNames = companionManager.availableSpeechVoiceNames
        let voiceGroups: [(title: String, prefix: String)] = [
            ("US female", "af_"), ("US male", "am_"), ("UK female", "bf_"), ("UK male", "bm_")
        ]
        return Menu {
            if includesNoneOption {
                Button("None") { onChoose("") }
                Divider()
            }
            ForEach(voiceGroups, id: \.prefix) { voiceGroup in
                let groupVoiceNames = voiceNames.filter { $0.hasPrefix(voiceGroup.prefix) }
                if !groupVoiceNames.isEmpty {
                    Section(voiceGroup.title) {
                        ForEach(groupVoiceNames, id: \.self) { voiceName in
                            Button(Self.displayName(forVoiceName: voiceName)) { onChoose(voiceName) }
                        }
                    }
                }
            }
            // Anything the grouping missed (a custom voice), so it stays choosable.
            let ungroupedVoiceNames = voiceNames.filter { voiceName in
                !voiceGroups.contains { voiceName.hasPrefix($0.prefix) }
            }
            ForEach(ungroupedVoiceNames, id: \.self) { voiceName in
                Button(voiceName) { onChoose(voiceName) }
            }
        } label: {
            Text(selectedVoiceName.isEmpty ? "None" : Self.displayName(forVoiceName: selectedVoiceName))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .pointerCursor()
    }

    /// "af_heart" → "Heart · US female". Other names are shown as they are.
    static func displayName(forVoiceName voiceName: String) -> String {
        let nameParts = voiceName.split(separator: "_", maxSplits: 1)
        guard nameParts.count == 2, nameParts[0].count == 2 else { return voiceName }
        let languageAndGender = nameParts[0]
        let accent: String
        switch languageAndGender.first {
        case "a": accent = "US"
        case "b": accent = "UK"
        default: return voiceName
        }
        let gender = languageAndGender.last == "f" ? "female" : "male"
        let readableName = nameParts[1].replacingOccurrences(of: "_", with: " ").capitalized
        return "\(readableName) · \(accent) \(gender)"
    }

    // MARK: - Motion

    private var motionRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            tuningSliderRow(
                label: "Cursor flight",
                value: $tuningSettings.cursorFlightSpeed,
                range: CompanionTuningSettings.cursorFlightSpeedRange,
                step: 0.1,
                valueText: String(format: "%.1f×", tuningSettings.cursorFlightSpeed)
            )
            tuningSliderRow(
                label: "Pointing hold",
                value: $tuningSettings.pointingHoldSeconds,
                range: CompanionTuningSettings.pointingHoldSecondsRange,
                step: 0.5,
                valueText: String(format: "%.1f s", tuningSettings.pointingHoldSeconds)
            )
            tuningSliderRow(
                label: "Panel motion",
                value: $tuningSettings.transcriptPanelAnimationSpeed,
                range: CompanionTuningSettings.transcriptPanelAnimationSpeedRange,
                step: 0.1,
                valueText: String(format: "%.1f×", tuningSettings.transcriptPanelAnimationSpeed)
            )
            HStack {
                Spacer()
                smallPillButton(title: "Reset motion", systemImageName: "arrow.counterclockwise") {
                    tuningSettings.resetMotionToDefaults()
                }
            }
        }
    }

    // MARK: - Building Blocks

    private func tuningRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: Self.rowLabelWidth, alignment: .leading)
            content()
        }
    }

    private func tuningSliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        tuningRow(label: label) {
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .tint(DS.Colors.accent)
            Text(valueText)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: Self.valueLabelWidth, alignment: .trailing)
        }
    }

    private func smallPillButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImageName)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
