//
//  SystemSpeechSentenceQueue.swift
//  leanring-buddy
//
//  Speaks the sidecar's `assistant.sentence` messages in order with the
//  built-in macOS voice. A stand-in: upstream's ElevenLabs client needs a
//  Cloudflare Worker this fork never deploys, and the Spark voice replaces
//  this in chunk 7 of .claude/plans/active/agent-sidecar/plan.md.
//  AVSpeechSynthesizer queues utterances itself, so enqueueing each sentence
//  as it arrives plays them back to back with no gap handling here.
//

import AVFoundation

@MainActor
final class SystemSpeechSentenceQueue: NSObject, AVSpeechSynthesizerDelegate {
    private let speechSynthesizer = AVSpeechSynthesizer()
    /// Utterances handed to the synthesizer and not yet finished or cancelled.
    private var unfinishedUtteranceIdentifiers: Set<ObjectIdentifier> = []
    private var sentenceIndexByUtteranceIdentifier: [ObjectIdentifier: Int] = [:]

    /// Same contract as SparkSpeechSentenceQueue's: a sentence's index when it
    /// starts, nil when nothing is left to say.
    var sentencePlaybackChangeHandler: ((Int?) -> Void)?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    /// True while a sentence is playing or waiting in the queue.
    var isSpeaking: Bool {
        speechSynthesizer.isSpeaking
    }

    func enqueueSentence(_ sentenceText: String, sentenceIndex: Int? = nil) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmedSentenceText)
        let utteranceIdentifier = ObjectIdentifier(utterance)
        unfinishedUtteranceIdentifiers.insert(utteranceIdentifier)
        if let sentenceIndex {
            sentenceIndexByUtteranceIdentifier[utteranceIdentifier] = sentenceIndex
        }
        speechSynthesizer.speak(utterance)
    }

    /// Stops the current sentence and drops everything queued behind it.
    func stopImmediately() {
        unfinishedUtteranceIdentifiers.removeAll()
        sentenceIndexByUtteranceIdentifier.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate (called off the main thread)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let sentenceIndex = self.sentenceIndexByUtteranceIdentifier[utteranceIdentifier] else { return }
            self.sentencePlaybackChangeHandler?(sentenceIndex)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.forgetUtterance(withIdentifier: utteranceIdentifier)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.forgetUtterance(withIdentifier: utteranceIdentifier)
        }
    }

    private func forgetUtterance(withIdentifier utteranceIdentifier: ObjectIdentifier) {
        // Utterances dropped by stopImmediately() were already forgotten.
        guard unfinishedUtteranceIdentifiers.remove(utteranceIdentifier) != nil else { return }
        sentenceIndexByUtteranceIdentifier.removeValue(forKey: utteranceIdentifier)
        if unfinishedUtteranceIdentifiers.isEmpty {
            sentencePlaybackChangeHandler?(nil)
        }
    }
}
