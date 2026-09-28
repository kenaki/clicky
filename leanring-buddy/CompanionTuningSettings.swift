//
//  CompanionTuningSettings.swift
//  leanring-buddy
//
//  Voice and motion settings changed live from the menu bar panel. Each is a
//  user default, so it survives relaunches and can also be set from a
//  terminal (`defaults write com.yourcompany.leanring-buddy <key> <value>`).
//  Readers pick up a change at their next use: the voice at the next
//  sentence, the cursor at its next flight, the transcript panel at its next
//  animation. Nothing needs a relaunch.
//

import Combine
import Foundation

@MainActor
final class CompanionTuningSettings: ObservableObject {
    enum DefaultsKey {
        static let isSpeakingAnswersEnabled = "SpeakAnswersAloud"
        static let speechVoiceName = "SparkSpeechVoice"
        static let speechBlendVoiceName = "SparkSpeechBlendVoice"
        static let speechBlendShare = "SparkSpeechBlendShare"
        static let speechSpeed = "SparkSpeechSpeed"
        static let cursorFlightSpeed = "CursorFlightSpeed"
        static let pointingHoldSeconds = "PointingHoldSeconds"
        static let transcriptPanelAnimationSpeed = "TranscriptPanelAnimationSpeed"
    }

    static let speechSpeedRange: ClosedRange<Double> = 0.5...2.0
    static let cursorFlightSpeedRange: ClosedRange<Double> = 0.4...2.5
    static let pointingHoldSecondsRange: ClosedRange<Double> = 1...10
    static let transcriptPanelAnimationSpeedRange: ClosedRange<Double> = 0.4...2.5

    private let userDefaults = UserDefaults.standard

    // MARK: - Voice

    /// Off: answers (typed or spoken questions) only stream into the
    /// transcript card, and permission questions show there without being
    /// said. The voice preview still plays, since asking for it is explicit.
    @Published var isSpeakingAnswersEnabled: Bool {
        didSet { userDefaults.set(isSpeakingAnswersEnabled, forKey: DefaultsKey.isSpeakingAnswersEnabled) }
    }
    /// Kokoro voice id (e.g. "af_heart"), or "warm" for the Miso server.
    @Published var speechVoiceName: String {
        didSet { userDefaults.set(speechVoiceName, forKey: DefaultsKey.speechVoiceName) }
    }
    /// A second Kokoro voice mixed into the first; empty for none.
    @Published var speechBlendVoiceName: String {
        didSet { userDefaults.set(speechBlendVoiceName, forKey: DefaultsKey.speechBlendVoiceName) }
    }
    /// How much of the blend voice is in the mix, 0 to 1.
    @Published var speechBlendShare: Double {
        didSet { userDefaults.set(speechBlendShare, forKey: DefaultsKey.speechBlendShare) }
    }
    /// Kokoro's own speaking rate, 1 is normal. Miso ignores it.
    @Published var speechSpeed: Double {
        didSet { userDefaults.set(speechSpeed, forKey: DefaultsKey.speechSpeed) }
    }

    // MARK: - Motion

    /// Multiplies the cursor's flight speed; 2 flies there in half the time.
    @Published var cursorFlightSpeed: Double {
        didSet { userDefaults.set(cursorFlightSpeed, forKey: DefaultsKey.cursorFlightSpeed) }
    }
    /// How long the cursor stays on its target before flying back.
    @Published var pointingHoldSeconds: Double {
        didSet { userDefaults.set(pointingHoldSeconds, forKey: DefaultsKey.pointingHoldSeconds) }
    }
    /// Multiplies the transcript panel's fades, scrolling, and highlight.
    @Published var transcriptPanelAnimationSpeed: Double {
        didSet { userDefaults.set(transcriptPanelAnimationSpeed, forKey: DefaultsKey.transcriptPanelAnimationSpeed) }
    }

    init() {
        isSpeakingAnswersEnabled = userDefaults.object(forKey: DefaultsKey.isSpeakingAnswersEnabled) as? Bool ?? true
        let speechModelName = userDefaults.string(forKey: "SparkSpeechModel") ?? "miso-tts-8b"
        speechVoiceName = userDefaults.string(forKey: DefaultsKey.speechVoiceName)
            ?? (speechModelName == "kokoro" ? "af_heart" : "warm")
        speechBlendVoiceName = userDefaults.string(forKey: DefaultsKey.speechBlendVoiceName) ?? ""
        speechBlendShare = Self.storedDouble(DefaultsKey.speechBlendShare, fallback: 0.3, in: 0...1)
        speechSpeed = Self.storedDouble(DefaultsKey.speechSpeed, fallback: 1, in: Self.speechSpeedRange)
        cursorFlightSpeed = Self.storedDouble(DefaultsKey.cursorFlightSpeed, fallback: 1, in: Self.cursorFlightSpeedRange)
        pointingHoldSeconds = Self.storedDouble(DefaultsKey.pointingHoldSeconds, fallback: 3, in: Self.pointingHoldSecondsRange)
        transcriptPanelAnimationSpeed = Self.storedDouble(DefaultsKey.transcriptPanelAnimationSpeed, fallback: 1, in: Self.transcriptPanelAnimationSpeedRange)
    }

    /// The `voice` field for the speech request. A blend uses Kokoro's
    /// weighted form, e.g. "af_heart(70)+bf_emma(30)" (Kokoro-FastAPI v0.9.0
    /// `tts_service.py` parses weights in parentheses and normalizes them).
    var speechVoiceRequestValue: String {
        let blendPercent = Int((speechBlendShare * 100).rounded())
        guard !speechBlendVoiceName.isEmpty,
              speechBlendVoiceName != speechVoiceName,
              blendPercent > 0 else {
            return speechVoiceName
        }
        guard blendPercent < 100 else { return speechBlendVoiceName }
        return "\(speechVoiceName)(\(100 - blendPercent))+\(speechBlendVoiceName)(\(blendPercent))"
    }

    func resetMotionToDefaults() {
        cursorFlightSpeed = 1
        pointingHoldSeconds = 3
        transcriptPanelAnimationSpeed = 1
    }

    private static func storedDouble(_ key: String, fallback: Double, in allowedRange: ClosedRange<Double>) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return min(max(UserDefaults.standard.double(forKey: key), allowedRange.lowerBound), allowedRange.upperBound)
    }
}
