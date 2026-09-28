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
//  `SparkSpeechVoice` picks the voice (default "warm").
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

    let voiceName: String
    /// Called with the sentence text when the server could not voice it, so the
    /// caller can fall back to the macOS voice rather than drop the words.
    var sentenceFailureHandler: ((String) -> Void)?

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
    private var sentenceTextsWaitingToBeRequested: [String] = []
    /// The one request in flight, if any.
    private var currentSpeechRequestTask: Task<Void, Never>?
    private var scheduledButUnplayedBufferCount = 0

    /// Nil when no voice server is configured; the caller then uses the macOS voice.
    static func makeIfConfigured() -> SparkSpeechSentenceQueue? {
        let configuredBaseURLString = UserDefaults.standard.string(forKey: "SparkSpeechBaseURL")
            ?? AppBundleConfiguration.stringValue(forKey: "SparkSpeechBaseURL")
        guard let configuredBaseURLString,
              let baseURL = URL(string: configuredBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              baseURL.scheme != nil else {
            return nil
        }
        let voiceName = UserDefaults.standard.string(forKey: "SparkSpeechVoice") ?? "warm"
        return SparkSpeechSentenceQueue(baseURL: baseURL, voiceName: voiceName)
    }

    private init(baseURL: URL, voiceName: String) {
        self.speechEndpointURL = baseURL.appendingPathComponent("v1/audio/speech")
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
            || !sentenceTextsWaitingToBeRequested.isEmpty
            || scheduledButUnplayedBufferCount > 0
    }

    func enqueueSentence(_ sentenceText: String) {
        let trimmedSentenceText = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentenceText.isEmpty else { return }
        sentenceTextsWaitingToBeRequested.append(trimmedSentenceText)
        requestNextSentenceIfIdle()
    }

    /// Stops playback, drops everything queued, and cancels the request in
    /// flight (the server stops generating when the connection goes away).
    func stopImmediately() {
        playbackGeneration += 1
        currentSpeechRequestTask?.cancel()
        currentSpeechRequestTask = nil
        sentenceTextsWaitingToBeRequested.removeAll()
        scheduledButUnplayedBufferCount = 0
        playerNode.stop()
    }

    // MARK: - Requests, one at a time

    private func requestNextSentenceIfIdle() {
        guard currentSpeechRequestTask == nil, !sentenceTextsWaitingToBeRequested.isEmpty else { return }
        let sentenceText = sentenceTextsWaitingToBeRequested.removeFirst()
        let playbackGenerationAtRequest = playbackGeneration

        currentSpeechRequestTask = Task {
            var sentenceBuffer: AVAudioPCMBuffer?
            do {
                sentenceBuffer = try await fetchSpeechBuffer(for: sentenceText)
            } catch {
                // A stop cancels this task; that is not a failure to report.
                guard !Task.isCancelled, playbackGeneration == playbackGenerationAtRequest else { return }
                print("⚠️ Spark voice failed: \(error.localizedDescription)")
                sentenceFailureHandler?(sentenceText)
            }

            guard playbackGeneration == playbackGenerationAtRequest else { return }
            currentSpeechRequestTask = nil
            if let sentenceBuffer {
                schedule(sentenceBuffer)
            }
            // Start the next sentence now, while this one plays.
            requestNextSentenceIfIdle()
        }
    }

    // MARK: - Playback

    private func schedule(_ sentenceBuffer: AVAudioPCMBuffer) {
        guard startAudioEngineIfNeeded() else { return }
        scheduledButUnplayedBufferCount += 1
        let playbackGenerationAtSchedule = playbackGeneration
        playerNode.scheduleBuffer(sentenceBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Called on an audio thread, and also for buffers dropped by stop().
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == playbackGenerationAtSchedule else { return }
                self.scheduledButUnplayedBufferCount = max(0, self.scheduledButUnplayedBufferCount - 1)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
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
            "model": "miso-tts-8b",
            "input": sentenceText,
            "voice": voiceName,
            "response_format": "pcm"
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
