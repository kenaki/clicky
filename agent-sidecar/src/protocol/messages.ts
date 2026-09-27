/**
 * The executable form of docs/ipc-protocol.md.
 *
 * Incoming (app → sidecar) messages are validated with zod before any other
 * code sees them. Outgoing (sidecar → app) messages are built through
 * `createOutgoingMessage` so every one carries the envelope.
 */
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { ProtocolError, type SidecarErrorCode } from "./errors.js";
import {
  PROTOCOL_VERSION,
  permissionModeSchema,
  screenshotSchema,
  type AgentPhase,
  type CircleRegionCommand,
  type PointAtCommand
} from "./sharedShapes.js";

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------

const envelopeFields = {
  protocolVersion: z.literal(PROTOCOL_VERSION),
  messageId: z.string().min(1),
  sentAtMs: z.number()
};

function incomingMessage<TypeName extends string, PayloadSchema extends z.ZodType>(
  typeName: TypeName,
  payloadSchema: PayloadSchema
) {
  return z.object({ ...envelopeFields, type: z.literal(typeName), payload: payloadSchema });
}

// ---------------------------------------------------------------------------
// App → sidecar
// ---------------------------------------------------------------------------

export const clientHelloPayloadSchema = z.object({
  clientName: z.string().min(1),
  token: z.string().optional()
});

export const sessionStartPayloadSchema = z.object({
  projectDirectory: z.string().min(1),
  resumeSessionId: z.string().min(1).optional(),
  permissionMode: permissionModeSchema.default("default")
});

export const userUtterancePayloadSchema = z.object({
  utteranceId: z.string().min(1),
  transcript: z.string().min(1),
  screenshots: z.array(screenshotSchema).default([])
});

export const userInterruptPayloadSchema = z.object({
  utteranceId: z.string().min(1).optional()
});

export const permissionDecisionPayloadSchema = z.object({
  permissionRequestId: z.string().min(1),
  decision: z.enum(["allow", "deny"]),
  denialReason: z.string().optional()
});

export const screenshotCapturedPayloadSchema = z.object({
  screenshotRequestId: z.string().min(1),
  screenshots: z.array(screenshotSchema)
});

export const incomingMessageSchema = z.discriminatedUnion("type", [
  incomingMessage("client.hello", clientHelloPayloadSchema),
  incomingMessage("session.start", sessionStartPayloadSchema),
  incomingMessage("user.utterance", userUtterancePayloadSchema),
  incomingMessage("user.interrupt", userInterruptPayloadSchema),
  incomingMessage("permission.decision", permissionDecisionPayloadSchema),
  incomingMessage("screenshot.captured", screenshotCapturedPayloadSchema)
]);

export type IncomingMessage = z.infer<typeof incomingMessageSchema>;
export type IncomingMessageOfType<TypeName extends IncomingMessage["type"]> = Extract<
  IncomingMessage,
  { type: TypeName }
>;

/**
 * Parses raw text off the socket. Throws ProtocolError("malformed_message")
 * with a readable issue path so the app can log what was wrong.
 */
export function parseIncomingMessage(rawText: string): IncomingMessage {
  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawText);
  } catch (error) {
    throw new ProtocolError("malformed_message", "Message is not valid JSON", { cause: error });
  }

  const validation = incomingMessageSchema.safeParse(parsedJson);
  if (!validation.success) {
    const issueSummary = validation.error.issues
      .map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("; ");
    throw new ProtocolError("malformed_message", `Message failed validation: ${issueSummary}`);
  }
  return validation.data;
}

// ---------------------------------------------------------------------------
// Sidecar → app
// ---------------------------------------------------------------------------

export interface OutgoingPayloads {
  "sidecar.hello": { sidecarVersion: string; protocolVersion: number };
  "session.ready": { sessionId: string; projectDirectory: string; model: string };
  "agent.status": { utteranceId: string; phase: AgentPhase; toolName?: string | undefined };
  "assistant.text_delta": { utteranceId: string; text: string };
  "assistant.turn_complete": {
    utteranceId: string;
    /** The final assistant text for the turn, what TTS should read. Not the concatenation of every delta. */
    spokenText: string;
    sessionId: string;
    durationMs: number;
    costUsd?: number | undefined;
  };
  "overlay.point_at": PointAtCommand;
  "overlay.circle_region": CircleRegionCommand;
  "overlay.clear": Record<string, never>;
  "screenshot.request": { screenshotRequestId: string };
  "permission.request": {
    permissionRequestId: string;
    toolName: string;
    input: Record<string, unknown>;
    spokenSummary: string;
  };
  error: { code: SidecarErrorCode; message: string; utteranceId?: string | undefined };
}

export type OutgoingMessageType = keyof OutgoingPayloads;

export type OutgoingMessage<TypeName extends OutgoingMessageType = OutgoingMessageType> =
  TypeName extends OutgoingMessageType
    ? {
        protocolVersion: typeof PROTOCOL_VERSION;
        type: TypeName;
        messageId: string;
        sentAtMs: number;
        payload: OutgoingPayloads[TypeName];
      }
    : never;

export function createOutgoingMessage<TypeName extends OutgoingMessageType>(
  type: TypeName,
  payload: OutgoingPayloads[TypeName],
  clock: () => number = Date.now
): OutgoingMessage<TypeName> {
  return {
    protocolVersion: PROTOCOL_VERSION,
    type,
    messageId: randomUUID(),
    sentAtMs: clock(),
    payload
  } as OutgoingMessage<TypeName>;
}

export function serializeOutgoingMessage(message: OutgoingMessage): string {
  return JSON.stringify(message);
}
