/**
 * Spike 0: the tracer bullet. No Swift, no WebSocket.
 *
 *   npm run spike:tracer-bullet -- --question "where is the search bar" --speak
 *   npm run spike:tracer-bullet -- --screenshot /path/to.jpg --once
 *
 * Captures the screen (or loads a JPEG), sends it with the question into a
 * real Agent SDK session, prints text as it streams, speaks each sentence the
 * moment it completes, prints every annotation tool call, answers screenshot
 * and permission requests from this terminal, and prints the session id so
 * you can `claude --resume` it.
 */
import { execFile } from "node:child_process";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";
import {
  AgentSession,
  type AgentSessionHost,
  type SessionReadyInfo,
  type TurnCompleteSummary,
  type TurnFailure
} from "../agent/agentSession.js";
import { isPointInsideBounds } from "../agent/tools/coordinateClamping.js";
import { loadSidecarConfig } from "../config/sidecarConfig.js";
import { createLogger, resolveLogLevelFromEnvironment } from "../logging/logger.js";
import type {
  AgentPhase,
  OverlayCommand,
  PermissionDecision,
  PermissionRequest,
  Screenshot,
  VoicePermissionMode
} from "../protocol/sharedShapes.js";
import { createDeferred, type Deferred } from "../util/deferred.js";
import { assertProjectDirectoryExists, loadDotEnvIfPresent, logCredentialSource } from "./environment.js";
import { captureMainDisplay, loadScreenshotFromFile } from "./macScreenCapture.js";

const execFileAsync = promisify(execFile);
const PERMISSION_ANSWER_TIMEOUT_MS = 30_000;

interface SpikeArguments {
  question: string;
  screenshotPath: string | null;
  shouldSpeak: boolean;
  runOnce: boolean;
  resumeSessionId: string | null;
  permissionMode: VoicePermissionMode;
}

function parseSpikeArguments(argv: string[]): SpikeArguments {
  const { values } = parseArgs({
    args: argv,
    options: {
      question: { type: "string", short: "q" },
      screenshot: { type: "string" },
      speak: { type: "boolean", default: false },
      once: { type: "boolean", default: false },
      resume: { type: "string" },
      "permission-mode": { type: "string" }
    },
    allowPositionals: true,
    strict: false
  });
  const permissionModeValue = (values["permission-mode"] as string | undefined) ?? "default";
  if (permissionModeValue !== "default" && permissionModeValue !== "plan" && permissionModeValue !== "acceptEdits") {
    throw new Error(`--permission-mode must be default, plan, or acceptEdits (got ${permissionModeValue})`);
  }
  return {
    question: (values.question as string | undefined) ?? "what am i looking at, and where is the most important button on this screen?",
    screenshotPath: (values.screenshot as string | undefined) ?? null,
    shouldSpeak: Boolean(values.speak),
    runOnce: Boolean(values.once),
    resumeSessionId: (values.resume as string | undefined) ?? null,
    permissionMode: permissionModeValue
  };
}

/** Speaks sentences one after another with macOS `say`, never overlapping. */
class SequentialSpeechQueue {
  private chain: Promise<void> = Promise.resolve();

  enqueue(text: string): void {
    this.chain = this.chain
      .then(() => execFileAsync("say", [text]))
      .then(() => undefined)
      .catch((error: unknown) => {
        process.stderr.write(`say failed: ${error instanceof Error ? error.message : String(error)}\n`);
      });
  }

  drain(): Promise<void> {
    return this.chain;
  }
}

/** Prints everything to the terminal and answers requests from stdin. */
class ConsoleSpikeHost implements AgentSessionHost {
  readonly annotationCommands: OverlayCommand[] = [];
  firstTextDeltaAtMs: number | null = null;
  firstSentenceAtMs: number | null = null;
  turnSentAtMs = 0;
  sessionReady: Deferred<SessionReadyInfo> = createDeferred();
  turnOutcome: Deferred<TurnCompleteSummary | TurnFailure> = createDeferred();

  constructor(
    private readonly latestScreenshot: Screenshot,
    private readonly readline: ReturnType<typeof createInterface>,
    private readonly speechQueue: SequentialSpeechQueue | null
  ) {}

  beginTurn(): void {
    this.turnOutcome = createDeferred();
    this.firstTextDeltaAtMs = null;
    this.firstSentenceAtMs = null;
    this.annotationCommands.length = 0;
    this.turnSentAtMs = Date.now();
  }

  handleSessionReady(info: SessionReadyInfo): void {
    process.stdout.write(`\n[session ready] id=${info.sessionId} model=${info.model}\n`);
    this.sessionReady.resolve(info);
  }

  handleStatus(status: { utteranceId: string; phase: AgentPhase; toolName?: string | undefined }): void {
    if (status.phase === "using_tool") {
      process.stdout.write(`\n[tool +${Date.now() - this.turnSentAtMs} ms] ${status.toolName ?? "?"}\n`);
    }
  }

  handleTextDelta(delta: { utteranceId: string; text: string }): void {
    if (this.firstTextDeltaAtMs === null) {
      this.firstTextDeltaAtMs = Date.now();
    }
    process.stdout.write(delta.text);
  }

  handleSentence(sentence: { utteranceId: string; sentenceIndex: number; text: string }): void {
    if (this.firstSentenceAtMs === null) {
      this.firstSentenceAtMs = Date.now();
    }
    process.stdout.write(`\n[sentence ${sentence.sentenceIndex} +${Date.now() - this.turnSentAtMs} ms] ${sentence.text}\n`);
    this.speechQueue?.enqueue(sentence.text);
  }

  handleOverlayCommand(command: OverlayCommand): void {
    this.annotationCommands.push(command);
    const bounds = { widthPixels: this.latestScreenshot.widthPixels, heightPixels: this.latestScreenshot.heightPixels };
    const insideBounds = isPointInsideBounds({ x: command.x, y: command.y }, bounds);
    process.stdout.write(`\n[overlay +${Date.now() - this.turnSentAtMs} ms] ${command.kind} ${JSON.stringify(command)} inBounds=${insideBounds}\n`);
  }

  async requestScreenshots(): Promise<Screenshot[]> {
    process.stdout.write("\n[screenshot requested by agent] capturing...\n");
    return [await captureMainDisplay()];
  }

  async requestPermission(request: PermissionRequest): Promise<PermissionDecision> {
    process.stdout.write(`\n[permission] ${request.spokenSummary}  (${request.toolName})\n`);
    const answer = await Promise.race([
      this.readline.question("allow? [y/N] "),
      new Promise<string>((resolveTimeout) => setTimeout(() => resolveTimeout(""), PERMISSION_ANSWER_TIMEOUT_MS).unref())
    ]);
    return answer.trim().toLowerCase().startsWith("y")
      ? { decision: "allow" }
      : { decision: "deny", denialReason: "the user said no in the terminal" };
  }

  handleTurnComplete(summary: TurnCompleteSummary): void {
    this.turnOutcome.resolve(summary);
  }

  handleTurnFailed(failure: TurnFailure): void {
    this.turnOutcome.resolve(failure);
  }
}

async function main(): Promise<void> {
  const sidecarRootDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  loadDotEnvIfPresent(sidecarRootDirectory);
  const spikeArguments = parseSpikeArguments(process.argv.slice(2));
  const config = loadSidecarConfig({ argv: process.argv.slice(2), env: process.env, defaultProjectDirectory: process.cwd() });
  const logger = createLogger("spike", { minimumLevel: resolveLogLevelFromEnvironment(config.logLevel) });

  assertProjectDirectoryExists(config.projectDirectory);
  logCredentialSource(config.hasAnthropicApiKey, logger);

  process.stdout.write(`project: ${config.projectDirectory}\nmodel: ${config.model}  effort: ${config.effort}  permission mode: ${spikeArguments.permissionMode}\n`);
  process.stdout.write(spikeArguments.screenshotPath ? `screenshot: ${spikeArguments.screenshotPath}\n` : "capturing main display...\n");
  const screenshot = spikeArguments.screenshotPath
    ? await loadScreenshotFromFile(spikeArguments.screenshotPath)
    : await captureMainDisplay();
  process.stdout.write(`screenshot: ${screenshot.widthPixels}x${screenshot.heightPixels} px, ${Math.round(screenshot.jpegBase64.length / 1024)} KB base64\n`);

  const readline = createInterface({ input: process.stdin, output: process.stdout });
  const speechQueue = spikeArguments.shouldSpeak ? new SequentialSpeechQueue() : null;
  const host = new ConsoleSpikeHost(screenshot, readline, speechQueue);
  const session = new AgentSession({
    projectDirectory: config.projectDirectory,
    permissionMode: spikeArguments.permissionMode,
    resumeSessionId: spikeArguments.resumeSessionId ?? undefined,
    model: config.model,
    effort: config.effort,
    host,
    logger: logger.child("session")
  });

  session.start();

  let question = spikeArguments.question;
  let turnNumber = 0;
  while (question.trim() !== "") {
    turnNumber += 1;
    host.beginTurn();
    process.stdout.write(`\n=== turn ${turnNumber}: "${question}" ===\n`);
    await session.sendUtterance({
      utteranceId: `spike-turn-${turnNumber}`,
      transcript: question,
      screenshots: turnNumber === 1 ? [screenshot] : []
    });

    const outcome = await host.turnOutcome.promise;
    const elapsed = (atMs: number | null) => (atMs === null ? "n/a" : `${atMs - host.turnSentAtMs} ms`);
    process.stdout.write("\n\n--- turn summary ---\n");
    if ("spokenText" in outcome) {
      process.stdout.write(`time to first text: ${elapsed(host.firstTextDeltaAtMs)}\n`);
      process.stdout.write(`time to first sentence (speech could start): ${elapsed(host.firstSentenceAtMs)}\n`);
      process.stdout.write(`total: ${outcome.durationMs} ms, sdk cost estimate: $${outcome.costUsd?.toFixed(4) ?? "?"}\n`);
      process.stdout.write(`annotations: ${host.annotationCommands.length} (${host.annotationCommands.map((command) => command.kind).join(", ") || "none"})\n`);
      process.stdout.write(`final text: ${outcome.spokenText}\n`);
    } else {
      process.stdout.write(`turn failed: ${outcome.code}: ${outcome.message}\n`);
    }

    if (speechQueue) {
      await speechQueue.drain();
    }
    if (spikeArguments.runOnce) {
      break;
    }
    question = await readline.question("\nfollow-up question (enter to quit): ");
  }

  const sessionId = session.currentSessionId;
  await session.close();
  readline.close();
  process.stdout.write(`\nsession id: ${sessionId ?? "unknown"}\n`);
  if (sessionId) {
    process.stdout.write(`continue it in a terminal with:\n  cd ${config.projectDirectory} && claude --resume ${sessionId}\n`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`spike failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
});
