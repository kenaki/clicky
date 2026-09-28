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
final class SystemSpeechSentenceQueue {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True while a sentence is playing or waiting in the queue.
    var isSpeaking: Bool {
        speechSynthesizer.isSpeaking
    }

    func enqueueSentence(_ sentenceText: String) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty else { return }
        speechSynthesizer.speak(AVSpeechUtterance(string: trimmedSentenceText))
    }

    /// Stops the current sentence and drops everything queued behind it.
    func stopImmediately() {
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
}
