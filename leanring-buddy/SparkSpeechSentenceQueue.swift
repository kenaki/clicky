//
//  SparkSpeechSentenceQueue.swift
//  leanring-buddy
//
//  Speaks the sidecar's sentences with the voice server on Ken's DGX Spark
//  (spark-tts-server/, an OpenAI-compatible POST /v1/audio/speech, ADR 0004).
//  Same surface as SystemSpeechSentenceQueue so CompanionManager can use either.
//
//  Sentences are requested one at a time, in order: the server generates one
//  at a time anyway, and several concurrent requests reach its queue in
//  arbitrary order (seen 2026-09-28: sentence 4 generated before sentence 2,
//  so playback stalled). The next request goes out the moment the previous
//  audio arrives, so the server works on sentence two while sentence one
//  plays. Playback is one always-on AVAudioEngine player node, so sentences
//  play back to back and a stop drops everything queued at once.
//
//  Configuration: the server's base URL comes from the `SparkSpeechBaseURL`
//  user default (kept out of the repo because it names Ken's machine), e.g.
//    defaults write com.yourcompany.leanring-buddy SparkSpeechBaseURL http://<spark>.local:8880
//  `SparkSpeechModel` and `SparkSpeechVoice` pick what the server runs:
//  "miso-tts-8b" / "warm" (defaults) for spark-tts-server/, or "kokoro" /
//  e.g. "af_heart" for Kokoro-FastAPI. Both servers speak the same shape.
//

import AVFoundation
import Foundation

@MainActor
final class SparkSpeechSentenceQueue {
    enum SpeechRequestError: LocalizedError {
        case unexpectedStatus(code: Int, body: String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let code, let body):
                return "The voice server answered \(code): \(body)"
            case .emptyAudio:
                return "The voice server returned no audio."
            }
        }
    }

    /// OpenAI's "pcm" format: raw 24 kHz mono 16-bit little-endian samples.
    private static let serverSampleRate: Double = 24_000
    /// Miso generates slower than real time and one sentence at a time, so a
    /// later sentence can wait behind earlier ones for well over a minute.
    private static let requestTimeoutSeconds: TimeInterval = 240

    let modelName: String
    let voiceName: String
    /// Called with the sentence text (and its index, if any) when the server could
    /// not voice it, so the caller can fall back to the macOS voice rather than drop the words.
    var sentenceFailureHandler: ((String, Int?) -> Void)?
    /// Called with a sentence's index when its audio starts playing, and with nil
    /// when playback runs out of audio (the voice is behind), for the transcript panel.
    var sentencePlaybackChangeHandler: ((Int?) -> Void)?

    private let speechEndpointURL: URL
    private let urlSession: URLSession
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SparkSpeechSentenceQueue.serverSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Bumped by every stop; responses and completions from an older value are stale and dropped.
    private var playbackGeneration = 0
    /// Sentences waiting for their turn at the server, oldest first.
    private var sentencesWaitingToBeRequested: [(text: String, sentenceIndex: Int?)] = []
    /// The one request in flight, if any.
    private var currentSpeechRequestTask: Task<Void, Never>?
    /// One entry per buffer handed to the player node and not yet played; the
    /// first is the one playing now.
    private var sentenceIndexesScheduledForPlayback: [Int?] = []

    /// Nil when no voice server is configured; the caller then uses the macOS voice.
    static func makeIfConfigured() -> SparkSpeechSentenceQueue? {
        let configuredBaseURLString = UserDefaults.standard.string(forKey: "SparkSpeechBaseURL")
            ?? AppBundleConfiguration.stringValue(forKey: "SparkSpeechBaseURL")
        guard let configuredBaseURLString,
              let baseURL = URL(string: configuredBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              baseURL.scheme != nil else {
            return nil
        }
        let modelName = UserDefaults.standard.string(forKey: "SparkSpeechModel") ?? "miso-tts-8b"
        let voiceName = UserDefaults.standard.string(forKey: "SparkSpeechVoice") ?? "warm"
        return SparkSpeechSentenceQueue(baseURL: baseURL, modelName: modelName, voiceName: voiceName)
    }

    private init(baseURL: URL, modelName: String, voiceName: String) {
        self.speechEndpointURL = baseURL.appendingPathComponent("v1/audio/speech")
        self.modelName = modelName
        self.voiceName = voiceName

        let sessionConfiguration = URLSessionConfiguration.default
        // The server sends nothing until the whole sentence is generated, so
        // the idle timeout has to cover the full generation time too.
        sessionConfiguration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
        self.urlSession = URLSession(configuration: sessionConfiguration)

        audioEngine.attach(playerNode)
        // The mixer resamples 24 kHz to whatever the output device runs at.
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
    }

    /// True while any sentence is being generated, waiting its turn, or playing.
    var isSpeaking: Bool {
        currentSpeechRequestTask != nil
            || !sentencesWaitingToBeRequested.isEmpty
            || !sentenceIndexesScheduledForPlayback.isEmpty
    }

    func enqueueSentence(_ sentenceText: String, sentenceIndex: Int? = nil) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty else { return }
        sentencesWaitingToBeRequested.append((text: trimmedSentenceText, sentenceIndex: sentenceIndex))
        requestNextSentenceIfIdle()
    }

    /// Stops playback, drops everything queued, and cancels the request in
    /// flight (the server stops generating when the connection goes away).
    func stopImmediately() {
        playbackGeneration += 1
        currentSpeechRequestTask?.cancel()
        currentSpeechRequestTask = nil
        sentencesWaitingToBeRequested.removeAll()
        sentenceIndexesScheduledForPlayback.removeAll()
        playerNode.stop()
    }

    // MARK: - Requests, one at a time

    private func requestNextSentenceIfIdle() {
        guard currentSpeechRequestTask == nil, !sentencesWaitingToBeRequested.isEmpty else { return }
        let (sentenceText, sentenceIndex) = sentencesWaitingToBeRequested.removeFirst()
        let playbackGenerationAtRequest = playbackGeneration

        currentSpeechRequestTask = Task {
            var sentenceBuffer: AVAudioPCMBuffer?
            do {
                sentenceBuffer = try await fetchSpeechBuffer(for: sentenceText)
            } catch {
                // A stop cancels this task; that is not a failure to report.
                guard !Task.isCancelled, playbackGeneration == playbackGenerationAtRequest else { return }
                print("⚠️ Spark voice failed: \(error.localizedDescription)")
                sentenceFailureHandler?(sentenceText, sentenceIndex)
            }

            guard playbackGeneration == playbackGenerationAtRequest else { return }
            currentSpeechRequestTask = nil
            if let sentenceBuffer {
                schedule(sentenceBuffer, sentenceIndex: sentenceIndex)
            }
            // Start the next sentence now, while this one plays.
            requestNextSentenceIfIdle()
        }
    }

    // MARK: - Playback

    private func schedule(_ sentenceBuffer: AVAudioPCMBuffer, sentenceIndex: Int?) {
        guard startAudioEngineIfNeeded() else { return }
        let startsPlayingNow = sentenceIndexesScheduledForPlayback.isEmpty
        sentenceIndexesScheduledForPlayback.append(sentenceIndex)
        let playbackGenerationAtSchedule = playbackGeneration
        playerNode.scheduleBuffer(sentenceBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Called on an audio thread, and also for buffers dropped by stop().
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == playbackGenerationAtSchedule else { return }
                if !self.sentenceIndexesScheduledForPlayback.isEmpty {
                    self.sentenceIndexesScheduledForPlayback.removeFirst()
                }
                // Buffers play back to back, so the next one is already playing.
                if self.sentenceIndexesScheduledForPlayback.isEmpty {
                    self.sentencePlaybackChangeHandler?(nil)
                } else if let nextSentenceIndex = self.sentenceIndexesScheduledForPlayback.first ?? nil {
                    self.sentencePlaybackChangeHandler?(nextSentenceIndex)
                }
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        if startsPlayingNow, let sentenceIndex {
            sentencePlaybackChangeHandler?(sentenceIndex)
        }
    }

    /// The engine stops itself when the output device changes (for example
    /// AirPods connecting), so check before every schedule rather than once.
    private func startAudioEngineIfNeeded() -> Bool {
        guard !audioEngine.isRunning else { return true }
        do {
            try audioEngine.start()
            return true
        } catch {
            print("⚠️ Spark voice: could not start the audio engine: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Network

    private func fetchSpeechBuffer(for sentenceText: String) async throws -> AVAudioPCMBuffer {
        var speechRequest = URLRequest(url: speechEndpointURL, timeoutInterval: Self.requestTimeoutSeconds)
        speechRequest.httpMethod = "POST"
        speechRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        speechRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "input": sentenceText,
            "voice": voiceName,
            "response_format": "pcm",
            // Kokoro-FastAPI streams by default; one whole body per sentence keeps
            // this the same as Miso. Kokoro is fast enough that it costs little.
            "stream": false
        ])

        let requestStartedAt = Date()
        let (responseData, response) = try await urlSession.data(for: speechRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            throw SpeechRequestError.unexpectedStatus(code: statusCode, body: String(decoding: responseData.prefix(200), as: UTF8.self))
        }

        let sentenceBuffer = try makeFloatBuffer(fromLittleEndianInt16PCM: responseData)
        print("🔊 Spark voice: \(String(format: "%.1f", Double(sentenceBuffer.frameLength) / Self.serverSampleRate)) s of audio after \(String(format: "%.1f", Date().timeIntervalSince(requestStartedAt))) s")
        return sentenceBuffer
    }

    /// Converts raw 16-bit samples to the Float32 buffer the player node plays.
    private func makeFloatBuffer(fromLittleEndianInt16PCM pcmData: Data) throws -> AVAudioPCMBuffer {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let sentenceBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatSamples = sentenceBuffer.floatChannelData?[0] else {
            throw SpeechRequestError.emptyAudio
        }
        pcmData.withUnsafeBytes { rawBytes in
            for sampleIndex in 0..<sampleCount {
                // loadUnaligned: Data gives no alignment guarantee for Int16 reads.
                let littleEndianSample = rawBytes.loadUnaligned(fromByteOffset: sampleIndex * 2, as: Int16.self)
                floatSamples[sampleIndex] = Float(Int16(littleEndian: littleEndianSample)) / 32768
            }
        }
        sentenceBuffer.frameLength = AVAudioFrameCount(sampleCount)
        return sentenceBuffer
    }
}
