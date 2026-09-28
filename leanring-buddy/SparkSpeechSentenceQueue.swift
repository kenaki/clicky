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
//  `SparkSpeechModel` picks what the server runs: "miso-tts-8b" (default) for
//  spark-tts-server/, or "kokoro" for Kokoro-FastAPI. Both speak the same shape.
//  Voice and speed come from CompanionTuningSettings at every request, so a
//  change in the menu bar panel applies from the next sentence.
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
    /// Kokoro answers in well under a second, so anything past 20 s means the
    /// Spark is gone and the macOS voice should take over.
    private static let misoRequestTimeoutSeconds: TimeInterval = 240
    private static let kokoroRequestTimeoutSeconds: TimeInterval = 20
    /// After a failure, every sentence goes straight to the macOS voice for this
    /// long instead of each one waiting out its own timeout (seen 2026-09-28:
    /// the Spark dropped off the network and the panel sat on "getting the voice ready").
    private static let fallbackAfterFailureSeconds: TimeInterval = 60

    let modelName: String
    private let tuningSettings: CompanionTuningSettings
    private let requestTimeoutSeconds: TimeInterval
    /// Set by a failed request; until then, sentences skip the Spark.
    private var skipSparkUntil: Date?
    /// Called with the sentence text (and its index, if any) when the server could
    /// not voice it, so the caller can fall back to the macOS voice rather than drop the words.
    var sentenceFailureHandler: ((String, Int?) -> Void)?
    /// Called with a sentence's index when its audio starts playing, and with nil
    /// when playback runs out of audio (the voice is behind), for the transcript panel.
    var sentencePlaybackChangeHandler: ((Int?) -> Void)?

    private let speechEndpointURL: URL
    private let voicesEndpointURL: URL
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
    static func makeIfConfigured(tuningSettings: CompanionTuningSettings) -> SparkSpeechSentenceQueue? {
        let configuredBaseURLString = UserDefaults.standard.string(forKey: "SparkSpeechBaseURL")
            ?? AppBundleConfiguration.stringValue(forKey: "SparkSpeechBaseURL")
        guard let configuredBaseURLString,
              let baseURL = URL(string: configuredBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              baseURL.scheme != nil else {
            return nil
        }
        let modelName = UserDefaults.standard.string(forKey: "SparkSpeechModel") ?? "miso-tts-8b"
        return SparkSpeechSentenceQueue(baseURL: baseURL, modelName: modelName, tuningSettings: tuningSettings)
    }

    private init(baseURL: URL, modelName: String, tuningSettings: CompanionTuningSettings) {
        self.speechEndpointURL = baseURL.appendingPathComponent("v1/audio/speech")
        self.voicesEndpointURL = baseURL.appendingPathComponent("v1/audio/voices")
        self.modelName = modelName
        self.tuningSettings = tuningSettings
        self.requestTimeoutSeconds = modelName == "kokoro" ? Self.kokoroRequestTimeoutSeconds : Self.misoRequestTimeoutSeconds

        let sessionConfiguration = URLSessionConfiguration.default
        // The server sends nothing until the whole sentence is generated, so
        // the idle timeout has to cover the full generation time too.
        sessionConfiguration.timeoutIntervalForRequest = requestTimeoutSeconds
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
        if let skipSparkUntil, Date() < skipSparkUntil {
            sentenceFailureHandler?(trimmedSentenceText, sentenceIndex)
            return
        }
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
                print("⚠️ Spark voice failed, using the macOS voice for \(Int(Self.fallbackAfterFailureSeconds)) s: \(error.localizedDescription)")
                skipSparkUntil = Date().addingTimeInterval(Self.fallbackAfterFailureSeconds)
                // This sentence and everything behind it, in order, rather than
                // each one waiting out the same failure.
                sentenceFailureHandler?(sentenceText, sentenceIndex)
                let sentencesBehindIt = sentencesWaitingToBeRequested
                sentencesWaitingToBeRequested.removeAll()
                for waitingSentence in sentencesBehindIt {
                    sentenceFailureHandler?(waitingSentence.text, waitingSentence.sentenceIndex)
                }
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
        var speechRequest = URLRequest(url: speechEndpointURL, timeoutInterval: requestTimeoutSeconds)
        speechRequest.httpMethod = "POST"
        speechRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        speechRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "input": sentenceText,
            "voice": tuningSettings.speechVoiceRequestValue,
            "speed": tuningSettings.speechSpeed,
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

    /// English voice ids the server offers (Kokoro's `GET /v1/audio/voices`,
    /// entries shaped `{ id, name, … }`), sorted, without the older "v0" set.
    /// Empty when the server has no voice list, as the Miso server does not.
    func fetchAvailableEnglishVoiceNames() async -> [String] {
        struct VoiceListResponse: Decodable {
            struct VoiceEntry: Decodable { let id: String }
            let voices: [VoiceEntry]
        }
        do {
            let (responseData, response) = try await urlSession.data(from: voicesEndpointURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let voiceIds = try JSONDecoder().decode(VoiceListResponse.self, from: responseData).voices.map(\.id)
            // Kokoro ids start with a language letter then gender: "af_", "bm_", …
            // "a" is American English, "b" British English.
            return voiceIds
                .filter { voiceId in
                    let prefix = voiceId.prefix(3)
                    return ["af_", "am_", "bf_", "bm_"].contains(String(prefix)) && !voiceId.contains("_v0")
                }
                .sorted()
        } catch {
            print("⚠️ Spark voice: could not list voices: \(error.localizedDescription)")
            return []
        }
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
