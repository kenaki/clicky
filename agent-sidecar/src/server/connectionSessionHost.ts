/**
 * Implements the agent session's host interface on top of one WebSocket
 * client: session events become outgoing messages, and requests that need a
 * reply (screenshots, permissions) are parked in registries until the app
 * answers or the timeout fires.
 */
import { randomUUID } from "node:crypto";
import type { AgentSessionHost, SessionReadyInfo, TurnCompleteSummary, TurnFailure } from "../agent/agentSession.js";
import { HostReplyTimeoutError } from "../protocol/errors.js";
import type { OutgoingMessage, OutgoingMessageType, OutgoingPayloads } from "../protocol/messages.js";
import type { AgentPhase, OverlayCommand, PermissionDecision, PermissionRequest, Screenshot } from "../protocol/sharedShapes.js";
import type { Logger } from "../logging/logger.js";
import { PendingReplyRegistry } from "./pendingReplies.js";

export type SendOutgoing = <TypeName extends OutgoingMessageType>(type: TypeName, payload: OutgoingPayloads[TypeName]) => OutgoingMessage<TypeName>;

export interface ConnectionSessionHostOptions {
  send: SendOutgoing;
  logger: Logger;
  screenshotTimeoutMs: number;
  permissionTimeoutMs: number;
}

export class ConnectionSessionHost implements AgentSessionHost {
  private readonly send: SendOutgoing;
  private readonly logger: Logger;
  private readonly screenshotReplies: PendingReplyRegistry<Screenshot[]>;
  private readonly permissionReplies: PendingReplyRegistry<PermissionDecision>;

  constructor(options: ConnectionSessionHostOptions) {
    this.send = options.send;
    this.logger = options.logger;
    this.screenshotReplies = new PendingReplyRegistry<Screenshot[]>({
      timeoutMs: options.screenshotTimeoutMs,
      createTimeoutError: (requestId) => new HostReplyTimeoutError("screenshot_timeout", `no screenshot for request ${requestId} within ${options.screenshotTimeoutMs} ms`)
    });
    this.permissionReplies = new PendingReplyRegistry<PermissionDecision>({
      timeoutMs: options.permissionTimeoutMs,
      createTimeoutError: (requestId) => new HostReplyTimeoutError("permission_timeout", `no permission decision for request ${requestId} within ${options.permissionTimeoutMs} ms`)
    });
  }

  // --- replies coming back from the app -------------------------------------

  deliverScreenshots(screenshotRequestId: string, screenshots: Screenshot[]): void {
    if (!this.screenshotReplies.resolve(screenshotRequestId, screenshots)) {
      this.logger.warn("screenshot reply for unknown or expired request", { screenshotRequestId });
    }
  }

  deliverPermissionDecision(permissionRequestId: string, decision: PermissionDecision): void {
    if (!this.permissionReplies.resolve(permissionRequestId, decision)) {
      this.logger.warn("permission decision for unknown or expired request", { permissionRequestId });
    }
  }

  /** Called when the socket closes so no tool handler waits forever. */
  abandonPendingReplies(reason: Error): void {
    this.screenshotReplies.rejectAll(reason);
    this.permissionReplies.rejectAll(reason);
  }

  // --- AgentSessionHost --------------------------------------------------------

  handleSessionReady(info: SessionReadyInfo): void {
    this.send("session.ready", info);
  }

  handleStatus(status: { utteranceId: string; phase: AgentPhase; toolName?: string | undefined }): void {
    this.send("agent.status", status);
  }

  handleTextDelta(delta: { utteranceId: string; text: string }): void {
    this.send("assistant.text_delta", delta);
  }

  handleSentence(sentence: { utteranceId: string; sentenceIndex: number; text: string }): void {
    this.send("assistant.sentence", sentence);
  }

  handleOverlayCommand(command: OverlayCommand): void {
    if (command.kind === "point_at") {
      const { kind: _kind, ...payload } = command;
      this.send("overlay.point_at", payload);
    } else {
      const { kind: _kind, ...payload } = command;
      this.send("overlay.circle_region", payload);
    }
  }

  requestScreenshots(): Promise<Screenshot[]> {
    const screenshotRequestId = randomUUID();
    const reply = this.screenshotReplies.register(screenshotRequestId);
    this.send("screenshot.request", { screenshotRequestId });
    return reply;
  }

  requestPermission(request: PermissionRequest): Promise<PermissionDecision> {
    const reply = this.permissionReplies.register(request.permissionRequestId);
    this.send("permission.request", request);
    return reply;
  }

  handleTurnComplete(summary: TurnCompleteSummary): void {
    this.send("assistant.turn_complete", summary);
  }

  handleTurnFailed(failure: TurnFailure): void {
    this.send("error", {
      code: failure.code,
      message: failure.message,
      ...(failure.utteranceId !== null ? { utteranceId: failure.utteranceId } : {})
    });
  }
}
