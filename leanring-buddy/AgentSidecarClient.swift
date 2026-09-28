//
//  AgentSidecarClient.swift
//  leanring-buddy
//
//  WebSocket client for the agent sidecar (agent-sidecar/, a Node process
//  hosting the Claude Agent SDK). Sends `client.hello`, waits for
//  `sidecar.hello`, then delivers every decoded message to
//  `incomingMessageHandler` on the main actor. The contract is
//  docs/ipc-protocol.md.
//

import Foundation

@MainActor
final class AgentSidecarClient {
    enum ConnectionError: LocalizedError {
        case helloTimedOut
        case helloRejected(reason: String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .helloTimedOut:
                return "The sidecar did not answer client.hello in time."
            case .helloRejected(let reason):
                return "The sidecar refused the connection: \(reason)"
            case .notConnected:
                return "Not connected to the agent sidecar."
            }
        }
    }

    /// Called on the main actor for every message after the handshake.
    var incomingMessageHandler: ((IncomingAgentSidecarMessage) -> Void)?
    /// Called on the main actor when an established connection drops.
    var disconnectHandler: ((String) -> Void)?

    private(set) var isConnected = false

    /// One long-lived session, for the same reason AssemblyAI shares one:
    /// recreating sessions per connection churns the OS connection pool.
    private let urlSession = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    /// Set by the handshake deadline so a cancelled receive reads as a timeout.
    private var didHelloTimeOut = false

    /// Opens the socket and completes the hello handshake. Fails fast when
    /// nothing is listening on the port, which is how attach mode probes for
    /// a sidecar you started yourself with `npm run serve`.
    func connect(port: Int, sharedToken: String?, helloTimeoutSeconds: Double) async throws -> SidecarHelloPayload {
        disconnect()

        let webSocketURL = URL(string: "ws://127.0.0.1:\(port)")!
        let newWebSocketTask = urlSession.webSocketTask(with: webSocketURL)
        // Incoming messages are small; this only guards against a runaway frame.
        newWebSocketTask.maximumMessageSize = 16 * 1024 * 1024
        webSocketTask = newWebSocketTask
        newWebSocketTask.resume()

        // Cancelling the socket makes the pending receive() throw, which is
        // the simplest way to put a deadline on the handshake.
        didHelloTimeOut = false
        let helloTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(helloTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.didHelloTimeOut = true
            newWebSocketTask.cancel(with: .goingAway, reason: nil)
        }
        defer { helloTimeoutTask.cancel() }

        do {
            try await send(type: "client.hello", payload: ClientHelloPayload(clientName: "clicky-mac-app", token: sharedToken))
            let firstFrame = try await newWebSocketTask.receive()
            let (firstMessage, _) = try IncomingAgentSidecarMessage.decode(fromJSONData: Self.data(from: firstFrame))

            switch firstMessage {
            case .sidecarHello(let sidecarHelloPayload):
                isConnected = true
                startReceiveLoop(for: newWebSocketTask)
                return sidecarHelloPayload
            case .error(let sidecarErrorPayload):
                throw ConnectionError.helloRejected(reason: "\(sidecarErrorPayload.code): \(sidecarErrorPayload.message)")
            default:
                throw ConnectionError.helloRejected(reason: "unexpected first message")
            }
        } catch {
            newWebSocketTask.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            if didHelloTimeOut { throw ConnectionError.helloTimedOut }
            throw error
        }
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    // MARK: - Sending

    func startSession(permissionMode: String) async throws {
        try await send(type: "session.start", payload: SessionStartPayload(projectDirectory: nil, resumeSessionId: nil, permissionMode: permissionMode))
    }

    func sendUtterance(utteranceId: String, transcript: String, screenshots: [AgentSidecarScreenshot]) async throws {
        try await send(type: "user.utterance", payload: UserUtterancePayload(utteranceId: utteranceId, transcript: transcript, screenshots: screenshots))
    }

    func sendInterrupt(utteranceId: String?) async throws {
        try await send(type: "user.interrupt", payload: UserInterruptPayload(utteranceId: utteranceId))
    }

    func sendScreenshotCaptured(screenshotRequestId: String, screenshots: [AgentSidecarScreenshot]) async throws {
        try await send(type: "screenshot.captured", payload: ScreenshotCapturedPayload(screenshotRequestId: screenshotRequestId, screenshots: screenshots))
    }

    func sendPermissionDecision(permissionRequestId: String, decision: String, denialReason: String?) async throws {
        try await send(type: "permission.decision", payload: PermissionDecisionPayload(permissionRequestId: permissionRequestId, decision: decision, denialReason: denialReason))
    }

    private func send<Payload: Encodable>(type: String, payload: Payload) async throws {
        guard let webSocketTask else { throw ConnectionError.notConnected }
        let envelope = OutgoingAgentSidecarEnvelope(type: type, payload: payload)
        let jsonData = try JSONEncoder().encode(envelope)
        // The sidecar parses text frames; a binary frame would fail JSON.parse on its side.
        try await webSocketTask.send(.string(String(decoding: jsonData, as: UTF8.self)))
    }

    // MARK: - Receiving

    private func startReceiveLoop(for connectedWebSocketTask: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                let frame: URLSessionWebSocketTask.Message
                do {
                    frame = try await connectedWebSocketTask.receive()
                } catch {
                    self?.handleConnectionDropped(for: connectedWebSocketTask, reason: error.localizedDescription)
                    return
                }

                do {
                    let (message, sentAtMs) = try IncomingAgentSidecarMessage.decode(fromJSONData: Self.data(from: frame))
                    let hopMilliseconds = Int(Date().timeIntervalSince1970 * 1000 - sentAtMs)
                    if case .ignored = message {
                        // text deltas and unknown types: nothing to do
                    } else {
                        print("🧩 Sidecar → \(Self.describe(message)) (\(hopMilliseconds) ms hop)")
                    }
                    self?.incomingMessageHandler?(message)
                } catch {
                    print("⚠️ Sidecar: could not decode a message: \(error)")
                }
            }
        }
    }

    private func handleConnectionDropped(for droppedWebSocketTask: URLSessionWebSocketTask, reason: String) {
        // A reconnect may already have replaced the task; only report the current one.
        guard droppedWebSocketTask === webSocketTask else { return }
        webSocketTask = nil
        isConnected = false
        print("⚠️ Sidecar connection dropped: \(reason)")
        disconnectHandler?(reason)
    }

    private static func data(from frame: URLSessionWebSocketTask.Message) -> Data {
        switch frame {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    /// Short log label; screenshot payloads never reach the log.
    private static func describe(_ message: IncomingAgentSidecarMessage) -> String {
        switch message {
        case .sidecarHello: return "sidecar.hello"
        case .sessionReady(let payload): return "session.ready \(payload.sessionId) in \(payload.projectDirectory)"
        case .agentStatus(let payload): return "agent.status \(payload.phase) \(payload.toolName ?? "")"
        case .assistantSentence(let payload): return "assistant.sentence #\(payload.sentenceIndex)"
        case .assistantTurnComplete(let payload): return "assistant.turn_complete \(Int(payload.durationMs)) ms"
        case .overlayPointAt(let payload): return "overlay.point_at (\(Int(payload.x)), \(Int(payload.y))) screen \(payload.screenIndex) \"\(payload.label)\""
        case .overlayCircleRegion(let payload): return "overlay.circle_region \"\(payload.label)\""
        case .overlayClear: return "overlay.clear"
        case .screenshotRequest: return "screenshot.request"
        case .permissionRequest(let payload): return "permission.request \(payload.toolName)"
        case .error(let payload): return "error \(payload.code): \(payload.message)"
        case .ignored(let type): return type
        }
    }
}
