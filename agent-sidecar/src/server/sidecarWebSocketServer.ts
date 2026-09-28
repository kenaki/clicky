/**
 * The localhost WebSocket transport. One client at a time. Every inbound
 * frame is validated, then routed to the agent session; every session event
 * goes back out through ConnectionSessionHost.
 */
import type { EffortLevel } from "@anthropic-ai/claude-agent-sdk";
import { WebSocketServer, WebSocket, type RawData } from "ws";
import { AgentSession } from "../agent/agentSession.js";
import { listPastConversations, loadConversationExchanges } from "../agent/pastConversations.js";
import { describeUnknownError, ProtocolError, SessionError, SidecarError } from "../protocol/errors.js";
import {
  createOutgoingMessage,
  parseIncomingMessage,
  serializeOutgoingMessage,
  type IncomingMessage,
  type OutgoingMessageType,
  type OutgoingPayloads
} from "../protocol/messages.js";
import { PROTOCOL_VERSION } from "../protocol/sharedShapes.js";
import type { Logger } from "../logging/logger.js";
import { ConnectionSessionHost } from "./connectionSessionHost.js";

export interface SidecarWebSocketServerOptions {
  port: number;
  sharedToken: string | null;
  sidecarVersion: string;
  /** Used when `session.start` omits `projectDirectory`. */
  defaultProjectDirectory: string;
  model: string;
  effort: EffortLevel;
  persistSessions: boolean;
  sandboxCommands: boolean;
  logger: Logger;
  screenshotTimeoutMs?: number;
  permissionTimeoutMs?: number;
  /** Called when the only client disconnects, so the CLI can decide to exit. */
  onClientDisconnected?: () => void;
}

const DEFAULT_SCREENSHOT_TIMEOUT_MS = 5_000;
const DEFAULT_PERMISSION_TIMEOUT_MS = 30_000;
/** How many conversations the menu bar's "Past" menu offers. */
const MAXIMUM_LISTED_CONVERSATION_COUNT = 20;
/** The transcript card keeps this many earlier exchanges (CompanionTranscriptPanel.swift). */
const MAXIMUM_RESUMED_EXCHANGE_COUNT = 12;

class ClientConnection {
  private hasSaidHello = false;
  private session: AgentSession | null = null;
  private sessionHost: ConnectionSessionHost | null = null;
  private readonly logger: Logger;

  constructor(
    private readonly socket: WebSocket,
    private readonly serverOptions: SidecarWebSocketServerOptions,
    logger: Logger
  ) {
    this.logger = logger;
  }

  readonly send = <TypeName extends OutgoingMessageType>(type: TypeName, payload: OutgoingPayloads[TypeName]) => {
    const message = createOutgoingMessage(type, payload);
    if (this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(serializeOutgoingMessage(message));
    }
    return message;
  };

  async handleRawFrame(rawData: RawData): Promise<void> {
    let message: IncomingMessage;
    try {
      message = parseIncomingMessage(rawData.toString());
    } catch (error) {
      this.reportError(error);
      return;
    }

    if (!this.hasSaidHello && message.type !== "client.hello") {
      this.send("error", { code: "hello_required", message: "first message must be client.hello" });
      this.socket.close(4000, "hello required");
      return;
    }

    try {
      await this.routeMessage(message);
    } catch (error) {
      this.reportError(error);
    }
  }

  async dispose(reason: string): Promise<void> {
    this.sessionHost?.abandonPendingReplies(new SessionError("session_failed", reason));
    if (this.session) {
      await this.session.close();
      this.session = null;
    }
  }

  private async routeMessage(message: IncomingMessage): Promise<void> {
    switch (message.type) {
      case "client.hello": {
        const expectedToken = this.serverOptions.sharedToken;
        if (expectedToken !== null && message.payload.token !== expectedToken) {
          this.send("error", { code: "unauthorized", message: "token mismatch" });
          this.socket.close(4001, "unauthorized");
          return;
        }
        this.hasSaidHello = true;
        this.logger.info("client said hello", { clientName: message.payload.clientName });
        this.send("sidecar.hello", { sidecarVersion: this.serverOptions.sidecarVersion, protocolVersion: PROTOCOL_VERSION });
        return;
      }

      case "session.start": {
        if (this.session) {
          throw new SessionError("session_already_started", "a session is already running on this connection");
        }
        this.sessionHost = new ConnectionSessionHost({
          send: this.send,
          logger: this.logger.child("host"),
          screenshotTimeoutMs: this.serverOptions.screenshotTimeoutMs ?? DEFAULT_SCREENSHOT_TIMEOUT_MS,
          permissionTimeoutMs: this.serverOptions.permissionTimeoutMs ?? DEFAULT_PERMISSION_TIMEOUT_MS
        });
        const projectDirectory = message.payload.projectDirectory ?? this.serverOptions.defaultProjectDirectory;
        this.session = new AgentSession({
          projectDirectory,
          permissionMode: message.payload.permissionMode,
          resumeSessionId: message.payload.resumeSessionId,
          model: this.serverOptions.model,
          effort: this.serverOptions.effort,
          persistSessions: this.serverOptions.persistSessions,
          sandboxCommands: this.serverOptions.sandboxCommands,
          host: this.sessionHost,
          logger: this.logger.child("session")
        });
        this.session.start();
        if (message.payload.resumeSessionId !== undefined) {
          void this.sendResumedSessionHistory(message.payload.resumeSessionId, projectDirectory);
        }
        return;
      }

      case "conversations.list": {
        const projectDirectory = message.payload.projectDirectory ?? this.serverOptions.defaultProjectDirectory;
        const conversations = await listPastConversations(projectDirectory, MAXIMUM_LISTED_CONVERSATION_COUNT);
        this.send("conversations.listed", { requestId: message.payload.requestId, projectDirectory, conversations });
        return;
      }

      case "user.utterance": {
        const session = this.requireSession();
        await session.sendUtterance(message.payload);
        return;
      }

      case "user.interrupt": {
        const session = this.requireSession();
        await session.interrupt();
        return;
      }

      case "permission.decision": {
        const host = this.requireSessionHost();
        const { permissionRequestId, decision, denialReason } = message.payload;
        host.deliverPermissionDecision(
          permissionRequestId,
          decision === "allow" ? { decision: "allow" } : { decision: "deny", denialReason }
        );
        return;
      }

      case "screenshot.captured": {
        const host = this.requireSessionHost();
        host.deliverScreenshots(message.payload.screenshotRequestId, message.payload.screenshots);
        return;
      }
    }
  }

  /**
   * Lets the app refill its transcript card with a reopened conversation. The
   * card is only a convenience, so a session file that cannot be read is
   * logged and skipped; the resume itself carries on either way.
   */
  private async sendResumedSessionHistory(sessionId: string, projectDirectory: string): Promise<void> {
    try {
      const exchanges = await loadConversationExchanges(sessionId, projectDirectory, MAXIMUM_RESUMED_EXCHANGE_COUNT);
      this.send("session.history", { sessionId, exchanges });
    } catch (error) {
      this.logger.warn("could not read the resumed session's history", { sessionId, error: describeUnknownError(error) });
    }
  }

  private requireSession(): AgentSession {
    if (!this.session) {
      throw new SessionError("session_not_started", "send session.start before this message");
    }
    return this.session;
  }

  private requireSessionHost(): ConnectionSessionHost {
    if (!this.sessionHost) {
      throw new SessionError("session_not_started", "send session.start before this message");
    }
    return this.sessionHost;
  }

  private reportError(error: unknown): void {
    if (error instanceof SidecarError) {
      this.logger.warn("request failed", { code: error.code, message: error.message });
      this.send("error", {
        code: error.code,
        message: error.message,
        ...(error.utteranceId !== undefined ? { utteranceId: error.utteranceId } : {})
      });
      return;
    }
    const message = describeUnknownError(error);
    this.logger.error("unexpected error handling message", { error: message });
    this.send("error", { code: "internal_error", message });
  }
}

export class SidecarWebSocketServer {
  private webSocketServer: WebSocketServer | null = null;
  private activeConnection: ClientConnection | null = null;
  private readonly logger: Logger;

  constructor(private readonly options: SidecarWebSocketServerOptions) {
    this.logger = options.logger;
  }

  start(): Promise<{ port: number }> {
    return new Promise((resolve, reject) => {
      const webSocketServer = new WebSocketServer({ host: "127.0.0.1", port: this.options.port });
      this.webSocketServer = webSocketServer;

      webSocketServer.once("error", reject);
      webSocketServer.once("listening", () => {
        webSocketServer.off("error", reject);
        webSocketServer.on("error", (error) => this.logger.error("websocket server error", { error: error.message }));
        resolve({ port: this.options.port });
      });

      webSocketServer.on("connection", (socket) => this.acceptConnection(socket));
    });
  }

  async stop(): Promise<void> {
    await this.activeConnection?.dispose("server stopping");
    this.activeConnection = null;
    await new Promise<void>((resolve) => {
      if (!this.webSocketServer) return resolve();
      this.webSocketServer.close(() => resolve());
      for (const client of this.webSocketServer.clients) {
        client.terminate();
      }
    });
    this.webSocketServer = null;
  }

  private acceptConnection(socket: WebSocket): void {
    if (this.activeConnection) {
      this.logger.warn("refusing second client");
      const refusal = createOutgoingMessage("error", { code: "client_already_connected", message: "another client is connected" });
      socket.send(serializeOutgoingMessage(refusal));
      socket.close(4002, "client already connected");
      return;
    }

    const connectionLogger = this.logger.child("connection");
    const connection = new ClientConnection(socket, this.options, connectionLogger);
    this.activeConnection = connection;
    connectionLogger.info("client connected");

    // Frames are handled one at a time so a slow utterance cannot race a permission reply.
    let frameChain: Promise<void> = Promise.resolve();
    socket.on("message", (rawData) => {
      frameChain = frameChain.then(() => connection.handleRawFrame(rawData));
    });

    socket.on("close", (code, reason) => {
      connectionLogger.info("client disconnected", { code, reason: reason.toString() });
      void connection.dispose("client disconnected").finally(() => {
        if (this.activeConnection === connection) {
          this.activeConnection = null;
        }
        this.options.onClientDisconnected?.();
      });
    });

    socket.on("error", (error) => connectionLogger.warn("socket error", { error: error.message }));
  }
}
