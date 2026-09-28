/**
 * One long-lived Agent SDK session in streaming-input mode.
 *
 * The session owns the SDK query, the queue of user messages feeding it, and
 * the bookkeeping that attributes SDK messages to the utterance in flight.
 * Everything the outside world needs to know arrives through the
 * `AgentSessionHost` interface, so the same session runs under the WebSocket
 * server and under the console spike.
 */
import { query, type EffortLevel, type Query, type SDKMessage, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { describeUnknownError, SessionError } from "../protocol/errors.js";
import type {
  AgentPhase,
  OverlayCommand,
  PermissionDecision,
  PermissionRequest,
  Screenshot,
  ScreenshotBounds,
  VoicePermissionMode
} from "../protocol/sharedShapes.js";
import type { Logger } from "../logging/logger.js";
import { AsyncPushQueue } from "../util/asyncPushQueue.js";
import { createDeferred, type Deferred } from "../util/deferred.js";
import { createPermissionRelay } from "./permissionRelay.js";
import { SentenceStreamSplitter } from "./sentenceStreamSplitter.js";
import {
  createScreenAnnotationToolServer,
  SCREEN_ANNOTATION_ALLOWED_TOOLS,
  SCREEN_ANNOTATION_SERVER_NAME
} from "./tools/screenAnnotationTools.js";
import { VOICE_PERSONA_PROMPT } from "./voicePersonaPrompt.js";

/** Shorter sentences ("sure.") are joined to the next one before being spoken; see SentenceStreamSplitter. */
const MINIMUM_WORDS_PER_SPOKEN_SENTENCE = 4;

export interface SessionReadyInfo {
  sessionId: string;
  projectDirectory: string;
  model: string;
}

export interface TurnCompleteSummary {
  utteranceId: string;
  spokenText: string;
  sessionId: string;
  durationMs: number;
  costUsd: number | undefined;
}

export interface TurnFailure {
  utteranceId: string | null;
  code: "session_failed" | "turn_interrupted";
  message: string;
}

export interface AgentSessionHost {
  handleSessionReady(info: SessionReadyInfo): void;
  handleStatus(status: { utteranceId: string; phase: AgentPhase; toolName?: string | undefined }): void;
  handleTextDelta(delta: { utteranceId: string; text: string }): void;
  /** Fired as soon as a full sentence has streamed, including narration before and between tool calls. */
  handleSentence(sentence: { utteranceId: string; sentenceIndex: number; text: string }): void;
  handleOverlayCommand(command: OverlayCommand): void;
  requestScreenshots(): Promise<Screenshot[]>;
  requestPermission(request: PermissionRequest): Promise<PermissionDecision>;
  handleTurnComplete(summary: TurnCompleteSummary): void;
  handleTurnFailed(failure: TurnFailure): void;
}

export interface AgentSessionOptions {
  projectDirectory: string;
  permissionMode: VoicePermissionMode;
  resumeSessionId?: string | undefined;
  model: string;
  effort: EffortLevel;
  /** False keeps the transcript, and therefore every screenshot, off disk; see docs/privacy.md. */
  persistSessions: boolean;
  host: AgentSessionHost;
  logger: Logger;
}

export interface UtteranceInput {
  utteranceId: string;
  transcript: string;
  screenshots: Screenshot[];
}

type UserContentBlock = Exclude<SDKUserMessage["message"]["content"], string>[number];

interface TurnInFlight {
  utteranceId: string;
  startedAtMs: number;
  finished: Deferred<void>;
  interruptRequested: boolean;
  sentenceSplitter: SentenceStreamSplitter;
  sentenceCount: number;
}

export class AgentSession {
  private readonly options: AgentSessionOptions;
  private readonly logger: Logger;
  private readonly inputQueue = new AsyncPushQueue<SDKUserMessage>();
  private readonly abortController = new AbortController();
  private readonly latestScreenshotBoundsByScreenIndex = new Map<number, ScreenshotBounds>();

  private sdkQuery: Query | null = null;
  private consumeLoop: Promise<void> | null = null;
  private sessionId: string | null = null;
  private turnInFlight: TurnInFlight | null = null;
  private terminalFailureMessage: string | null = null;

  constructor(options: AgentSessionOptions) {
    this.options = options;
    this.logger = options.logger;
  }

  get currentSessionId(): string | null {
    return this.sessionId;
  }

  get isTurnInProgress(): boolean {
    return this.turnInFlight !== null;
  }

  /** Builds the SDK query and starts consuming its messages. Call once. */
  start(): void {
    if (this.sdkQuery) {
      throw new SessionError("session_already_started", "AgentSession.start() was called twice");
    }

    const annotationServer = createScreenAnnotationToolServer(
      {
        resolveScreenshotBounds: (screenIndex) => this.latestScreenshotBoundsByScreenIndex.get(screenIndex) ?? null,
        handleOverlayCommand: (command) => this.options.host.handleOverlayCommand(command),
        requestScreenshots: async () => {
          const screenshots = await this.options.host.requestScreenshots();
          this.rememberScreenshotBounds(screenshots);
          return screenshots;
        }
      },
      this.logger.child("tools")
    );

    const { resumeSessionId } = this.options;

    this.sdkQuery = query({
      prompt: this.inputQueue,
      options: {
        cwd: this.options.projectDirectory,
        systemPrompt: { type: "preset", preset: "claude_code", append: VOICE_PERSONA_PROMPT },
        settingSources: ["user", "project"],
        mcpServers: { [SCREEN_ANNOTATION_SERVER_NAME]: annotationServer },
        allowedTools: [...SCREEN_ANNOTATION_ALLOWED_TOOLS],
        permissionMode: this.options.permissionMode,
        canUseTool: createPermissionRelay(this.options.host, this.logger.child("permissions")),
        includePartialMessages: true,
        model: this.options.model,
        effort: this.options.effort,
        persistSession: this.options.persistSessions,
        abortController: this.abortController,
        stderr: (line) => this.logger.debug("claude stderr", { line: line.trimEnd() }),
        ...(resumeSessionId !== undefined ? { resume: resumeSessionId } : {})
      }
    });

    this.consumeLoop = this.consumeSdkMessages(this.sdkQuery);
    this.logger.info("session starting", {
      projectDirectory: this.options.projectDirectory,
      permissionMode: this.options.permissionMode,
      model: this.options.model,
      effort: this.options.effort,
      persistSessions: this.options.persistSessions,
      resumeSessionId: resumeSessionId ?? null
    });
  }

  /**
   * Sends one voice turn. If a turn is already in progress it is interrupted
   * first, matching upstream Clicky's "new key press cancels the old answer".
   */
  async sendUtterance(input: UtteranceInput): Promise<void> {
    this.assertUsable();
    if (this.turnInFlight) {
      this.logger.info("interrupting previous turn before new utterance", { previousUtteranceId: this.turnInFlight.utteranceId });
      await this.interrupt();
    }

    this.rememberScreenshotBounds(input.screenshots);
    this.turnInFlight = {
      utteranceId: input.utteranceId,
      startedAtMs: Date.now(),
      finished: createDeferred<void>(),
      interruptRequested: false,
      sentenceSplitter: new SentenceStreamSplitter(MINIMUM_WORDS_PER_SPOKEN_SENTENCE),
      sentenceCount: 0
    };

    this.inputQueue.push({
      type: "user",
      message: { role: "user", content: this.buildUserContent(input) },
      parent_tool_use_id: null
    });
    this.options.host.handleStatus({ utteranceId: input.utteranceId, phase: "thinking" });
    this.logger.info("utterance sent", {
      utteranceId: input.utteranceId,
      transcriptLength: input.transcript.length,
      screenshotCount: input.screenshots.length,
      screenshotBytes: input.screenshots.reduce((total, screenshot) => total + screenshot.jpegBase64.length, 0)
    });
  }

  /** Resolves once the interrupted turn has produced its result message. */
  async interrupt(): Promise<void> {
    const turn = this.turnInFlight;
    if (!turn || !this.sdkQuery) {
      return;
    }
    turn.interruptRequested = true;
    try {
      await this.sdkQuery.interrupt();
    } catch (error) {
      this.logger.warn("interrupt call failed", { error: describeUnknownError(error) });
    }
    await turn.finished.promise;
  }

  /** Waits for the current turn, if any, to finish. Used by the spike. */
  async waitForCurrentTurn(): Promise<void> {
    await this.turnInFlight?.finished.promise;
  }

  async close(): Promise<void> {
    this.logger.info("session closing");
    this.inputQueue.close();
    this.abortController.abort();
    this.finishTurn({ kind: "failed", code: "turn_interrupted", message: "session closed" });
    try {
      await this.consumeLoop;
    } catch {
      // Errors were already reported through the host.
    }
  }

  // ---------------------------------------------------------------------------

  private assertUsable(): void {
    if (!this.sdkQuery) {
      throw new SessionError("session_not_started", "AgentSession.start() has not been called");
    }
    if (this.terminalFailureMessage !== null) {
      throw new SessionError("session_failed", `the agent session has ended: ${this.terminalFailureMessage}`);
    }
  }

  private emitSentence(turn: TurnInFlight, text: string): void {
    const sentenceIndex = turn.sentenceCount;
    turn.sentenceCount += 1;
    this.options.host.handleSentence({ utteranceId: turn.utteranceId, sentenceIndex, text });
  }

  private rememberScreenshotBounds(screenshots: Screenshot[]): void {
    for (const screenshot of screenshots) {
      this.latestScreenshotBoundsByScreenIndex.set(screenshot.screenIndex, {
        widthPixels: screenshot.widthPixels,
        heightPixels: screenshot.heightPixels
      });
    }
  }

  private buildUserContent(input: UtteranceInput): UserContentBlock[] {
    const contentBlocks: UserContentBlock[] = [];
    for (const screenshot of input.screenshots) {
      contentBlocks.push({
        type: "image",
        source: { type: "base64", media_type: "image/jpeg", data: screenshot.jpegBase64 }
      });
      contentBlocks.push({
        type: "text",
        text: `${screenshot.label} (image dimensions: ${screenshot.widthPixels}x${screenshot.heightPixels} pixels, screen index ${screenshot.screenIndex})`
      });
    }
    contentBlocks.push({ type: "text", text: input.transcript });
    return contentBlocks;
  }

  private async consumeSdkMessages(sdkQuery: Query): Promise<void> {
    try {
      for await (const message of sdkQuery) {
        this.handleSdkMessage(message);
      }
      this.logger.info("sdk message stream ended");
    } catch (error) {
      if (this.abortController.signal.aborted) {
        return;
      }
      const message = describeUnknownError(error);
      this.logger.error("sdk query failed", { error: message });
      this.terminalFailureMessage = message;
      this.finishTurn({ kind: "failed", code: "session_failed", message });
      if (!this.turnInFlight) {
        this.options.host.handleTurnFailed({ utteranceId: null, code: "session_failed", message });
      }
    }
  }

  private handleSdkMessage(message: SDKMessage): void {
    switch (message.type) {
      case "system":
        if (message.subtype === "init") {
          this.sessionId = message.session_id;
          this.logger.info("session ready", {
            sessionId: message.session_id,
            model: message.model,
            apiKeySource: message.apiKeySource,
            mcpServers: message.mcp_servers.map((server) => `${server.name}:${server.status}`)
          });
          this.options.host.handleSessionReady({
            sessionId: message.session_id,
            projectDirectory: this.options.projectDirectory,
            model: message.model
          });
        }
        return;

      case "stream_event": {
        const turn = this.turnInFlight;
        if (!turn || message.parent_tool_use_id !== null) return;
        const { event } = message;
        if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
          this.options.host.handleTextDelta({ utteranceId: turn.utteranceId, text: event.delta.text });
          for (const sentence of turn.sentenceSplitter.feed(event.delta.text)) {
            this.emitSentence(turn, sentence);
          }
        } else if (event.type === "content_block_stop") {
          // A text block ending (usually because a tool call follows) is a sentence
          // boundary even without trailing punctuation or whitespace.
          const trailingSentence = turn.sentenceSplitter.flushAtPause();
          if (trailingSentence !== null) {
            this.emitSentence(turn, trailingSentence);
          }
        }
        return;
      }

      case "assistant": {
        const turn = this.turnInFlight;
        if (!turn || message.parent_tool_use_id !== null) return;
        for (const block of message.message.content) {
          if (block.type === "tool_use") {
            this.options.host.handleStatus({ utteranceId: turn.utteranceId, phase: "using_tool", toolName: block.name });
          }
        }
        return;
      }

      case "result": {
        if (message.subtype === "success") {
          this.finishTurn({
            kind: "completed",
            spokenText: message.result,
            costUsd: message.total_cost_usd,
            sessionId: message.session_id
          });
        } else {
          this.finishTurn({
            kind: "failed",
            code: "session_failed",
            message: `${message.subtype}: ${message.errors.join("; ") || "no details"}`
          });
        }
        return;
      }

      default:
        return;
    }
  }

  private finishTurn(
    outcome:
      | { kind: "completed"; spokenText: string; costUsd: number | undefined; sessionId: string }
      | { kind: "failed"; code: "session_failed" | "turn_interrupted"; message: string }
  ): void {
    const turn = this.turnInFlight;
    if (!turn) return;
    this.turnInFlight = null;

    const durationMs = Date.now() - turn.startedAtMs;
    if (outcome.kind === "completed" && !turn.interruptRequested) {
      const trailingSentence = turn.sentenceSplitter.flush();
      if (trailingSentence !== null) {
        this.emitSentence(turn, trailingSentence);
      }
      this.logger.info("turn complete", { utteranceId: turn.utteranceId, durationMs, costUsd: outcome.costUsd });
      this.options.host.handleTurnComplete({
        utteranceId: turn.utteranceId,
        spokenText: outcome.spokenText,
        sessionId: outcome.sessionId,
        durationMs,
        costUsd: outcome.costUsd
      });
    } else {
      const code = turn.interruptRequested ? "turn_interrupted" : outcome.kind === "failed" ? outcome.code : "turn_interrupted";
      const failureMessage = turn.interruptRequested ? "interrupted by a new utterance" : outcome.kind === "failed" ? outcome.message : "";
      this.logger.info("turn ended without completion", { utteranceId: turn.utteranceId, code, durationMs });
      this.options.host.handleTurnFailed({ utteranceId: turn.utteranceId, code, message: failureMessage });
    }
    this.options.host.handleStatus({ utteranceId: turn.utteranceId, phase: "idle" });
    turn.finished.resolve();
  }
}
