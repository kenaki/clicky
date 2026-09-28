//
//  AgentSidecarMessages.swift
//  leanring-buddy
//
//  Codable form of the app ↔ agent-sidecar wire protocol. The contract lives
//  in docs/ipc-protocol.md and agent-sidecar/src/protocol/messages.ts; change
//  all three in one commit. Optional fields are omitted when nil because the
//  sidecar's zod schemas reject `null` for optional keys.
//

import Foundation

enum AgentSidecarProtocol {
    static let protocolVersion = 1
    static let defaultPort = 47821
}

// MARK: - Shared shapes

/// One display's still frame, in the shape the sidecar expects.
/// Coordinates the sidecar sends back refer to this image's pixel space.
struct AgentSidecarScreenshot: Codable {
    let screenIndex: Int
    let label: String
    let isCursorScreen: Bool
    let widthPixels: Int
    let heightPixels: Int
    let jpegBase64: String
}

// MARK: - App → sidecar payloads

struct ClientHelloPayload: Encodable {
    let clientName: String
    let token: String?
}

struct SessionStartPayload: Encodable {
    /// Nil lets the sidecar use the directory it was started with
    /// (`--project` or `CLICKY_PROJECT_DIRECTORY` in agent-sidecar/.env).
    let projectDirectory: String?
    let resumeSessionId: String?
    /// `default`, `plan`, or `acceptEdits`.
    let permissionMode: String
}

struct UserUtterancePayload: Encodable {
    let utteranceId: String
    let transcript: String
    let screenshots: [AgentSidecarScreenshot]
}

struct UserInterruptPayload: Encodable {
    let utteranceId: String?
}

struct PermissionDecisionPayload: Encodable {
    let permissionRequestId: String
    /// `allow` or `deny`.
    let decision: String
    let denialReason: String?
}

struct ScreenshotCapturedPayload: Encodable {
    let screenshotRequestId: String
    let screenshots: [AgentSidecarScreenshot]
}

/// Asks for Clicky's saved conversations in a directory; allowed before `session.start`.
struct ConversationsListPayload: Encodable {
    let requestId: String
    /// Nil lists the sidecar's own directory, as for `session.start`.
    let projectDirectory: String?
}

/// Every outgoing message is wrapped in the versioned envelope.
struct OutgoingAgentSidecarEnvelope<Payload: Encodable>: Encodable {
    let protocolVersion: Int
    let type: String
    let messageId: String
    let sentAtMs: Int64
    let payload: Payload

    init(type: String, payload: Payload) {
        self.protocolVersion = AgentSidecarProtocol.protocolVersion
        self.type = type
        self.messageId = UUID().uuidString
        self.sentAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        self.payload = payload
    }
}

// MARK: - Sidecar → app payloads

struct SidecarHelloPayload: Decodable {
    let sidecarVersion: String
    let protocolVersion: Int
}

struct SessionReadyPayload: Decodable {
    let sessionId: String
    let projectDirectory: String
    let model: String?
}

/// A reopened session's recent question and answer pairs, oldest first.
struct SessionHistoryPayload: Decodable {
    struct Exchange: Decodable {
        let question: String
        let answer: String
    }

    let sessionId: String
    let exchanges: [Exchange]
}

/// Reply to `conversations.list`, newest first.
struct ConversationsListedPayload: Decodable {
    struct PastConversation: Decodable, Identifiable {
        let sessionId: String
        let title: String
        let lastModifiedMs: Double

        var id: String { sessionId }
        var lastModifiedDate: Date { Date(timeIntervalSince1970: lastModifiedMs / 1000) }
    }

    let requestId: String
    let projectDirectory: String
    let conversations: [PastConversation]
}

struct AgentStatusPayload: Decodable {
    let utteranceId: String
    /// `thinking`, `using_tool`, or `idle`.
    let phase: String
    let toolName: String?
}

struct AssistantSentencePayload: Decodable {
    let utteranceId: String
    let sentenceIndex: Int
    let text: String
}

struct AssistantTurnCompletePayload: Decodable {
    let utteranceId: String
    let spokenText: String
    let sessionId: String
    let durationMs: Double
    let costUsd: Double?
}

struct OverlayPointAtPayload: Decodable {
    let x: Double
    let y: Double
    let label: String
    let screenIndex: Int
}

struct OverlayCircleRegionPayload: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let label: String
    let screenIndex: Int
}

struct ScreenshotRequestPayload: Decodable {
    let screenshotRequestId: String
}

/// `input` (the raw tool arguments) is on the wire too but the app only
/// needs the spoken summary, so it is not decoded.
struct PermissionRequestPayload: Decodable {
    let permissionRequestId: String
    let toolName: String
    let spokenSummary: String
}

struct SidecarErrorPayload: Decodable {
    let code: String
    let message: String
    let utteranceId: String?
}

/// A decoded sidecar → app message. Types the app does not act on
/// (`assistant.text_delta`) and unknown future types land in `.ignored`.
enum IncomingAgentSidecarMessage {
    case sidecarHello(SidecarHelloPayload)
    case sessionReady(SessionReadyPayload)
    case sessionHistory(SessionHistoryPayload)
    case conversationsListed(ConversationsListedPayload)
    case agentStatus(AgentStatusPayload)
    case assistantSentence(AssistantSentencePayload)
    case assistantTurnComplete(AssistantTurnCompletePayload)
    case overlayPointAt(OverlayPointAtPayload)
    case overlayCircleRegion(OverlayCircleRegionPayload)
    case overlayClear
    case screenshotRequest(ScreenshotRequestPayload)
    case permissionRequest(PermissionRequestPayload)
    case error(SidecarErrorPayload)
    case ignored(type: String)

    /// Only the header fields, decoded first so the payload can be decoded by type.
    private struct EnvelopeHeader: Decodable {
        let type: String
        let sentAtMs: Double
    }

    private struct EnvelopeWithPayload<Payload: Decodable>: Decodable {
        let payload: Payload
    }

    static func decode(fromJSONData jsonData: Data) throws -> (message: IncomingAgentSidecarMessage, sentAtMs: Double) {
        let jsonDecoder = JSONDecoder()
        let envelopeHeader = try jsonDecoder.decode(EnvelopeHeader.self, from: jsonData)

        func decodePayload<Payload: Decodable>(_ payloadType: Payload.Type) throws -> Payload {
            try jsonDecoder.decode(EnvelopeWithPayload<Payload>.self, from: jsonData).payload
        }

        let message: IncomingAgentSidecarMessage
        switch envelopeHeader.type {
        case "sidecar.hello": message = .sidecarHello(try decodePayload(SidecarHelloPayload.self))
        case "session.ready": message = .sessionReady(try decodePayload(SessionReadyPayload.self))
        case "session.history": message = .sessionHistory(try decodePayload(SessionHistoryPayload.self))
        case "conversations.listed": message = .conversationsListed(try decodePayload(ConversationsListedPayload.self))
        case "agent.status": message = .agentStatus(try decodePayload(AgentStatusPayload.self))
        case "assistant.sentence": message = .assistantSentence(try decodePayload(AssistantSentencePayload.self))
        case "assistant.turn_complete": message = .assistantTurnComplete(try decodePayload(AssistantTurnCompletePayload.self))
        case "overlay.point_at": message = .overlayPointAt(try decodePayload(OverlayPointAtPayload.self))
        case "overlay.circle_region": message = .overlayCircleRegion(try decodePayload(OverlayCircleRegionPayload.self))
        case "overlay.clear": message = .overlayClear
        case "screenshot.request": message = .screenshotRequest(try decodePayload(ScreenshotRequestPayload.self))
        case "permission.request": message = .permissionRequest(try decodePayload(PermissionRequestPayload.self))
        case "error": message = .error(try decodePayload(SidecarErrorPayload.self))
        default: message = .ignored(type: envelopeHeader.type)
        }
        return (message, envelopeHeader.sentAtMs)
    }
}
