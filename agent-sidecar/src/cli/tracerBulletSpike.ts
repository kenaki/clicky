/**
 * Spike 0: the tracer bullet. No Swift, no WebSocket.
 *
 *   npm run spike:tracer-bullet -- --question "where is the search bar" --speak
 *
 * Captures the screen, sends it with the question into a real Agent SDK
 * session, prints every text delta and every annotation tool call as it
 * happens, answers screenshot and permission requests from this terminal,
 * then prints the session id so you can `claude --resume` it.
 */
import { execFile } from "node:child_process";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { parseArgs, promisify } from "node:util";
import { AgentSession, type AgentSessionHost, type SessionReadyInfo, type TurnCompleteSummary, type TurnFailure } from "../agent/agentSession.js";
import { isPointInsideBounds } from "../agent/tools/coordinateClamping.js";
import { loadSidecarConfig } from "../config/sidecarConfig.js";
import { createLogger, resolveLogLevelFromEnvironment } from "../logging/logger.js";
import type { AgentPhase, OverlayCommand, PermissionDecision, PermissionRequest, Screenshot, VoicePermissionMode } from "../protocol/sharedShapes.js";
import { createDeferred, type Deferred } from "../util/deferred.js";
import { assertProjectDirectoryExists, loadDotEnvIfPresent, logCredentialSource } from "./environment.js";
import { captureMainDisplay, loadScreenshotFromFile } from "./macScreenCapture.js";

const execFileAsync = promisify(execFile);
const PERMISSION_ANSWER_TIMEOUT_MS = 30_000;

interface SpikeArguments {
  question: string;
  screenshotPath: string | null;
  shouldSpeak: boolean;
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
      resume: { type: "string" },
      "permission-mode": { type: "string" }
    },
    allowPositionals: true,
    strict: false
  });
  const permissionModeValue = (values["permission-mode"] as string | undefined) ?? "plan";
  if (permissionModeValue !== "default" && permissionModeValue !== "plan" && permissionModeValue !== "acceptEdits") {
    throw new Error(`--permission-mode must be default, plan, or acceptEdits (got ${permissionModeValue})`);
  }
  return {
    question: (values.question as string | undefined) ?? "what am i looking at, and where is the most important button on this screen?",
    screenshotPath: (values.screenshot as string | undefined) ?? null,
    shouldSpeak: Boolean(values.speak),
    resumeSessionId: (values.resume as string | undefined) ?? null,
    permissionMode: permissionModeValue
  };
}

/** Prints everything to the terminal and answers requests from stdin. */
class ConsoleSpikeHost implements AgentSessionHost {
  readonly annotationCommands: OverlayCommand[] = [];
  firstTextDeltaAtMs: number | null = null;
  sessionReady: Deferred<SessionReadyInfo> = createDeferred();
  turnOutcome: Deferred<TurnCompleteSummary | TurnFailure> = createDeferred();

  constructor(
    private readonly latestScreenshot: Screenshot,
    private readonly readline: ReturnType<typeof createInterface>
  ) {}

  resetForNextTurn(): void {
    this.turnOutcome = createDeferred();
    this.firstTextDeltaAtMs = null;
    this.annotationCommands.length = 0;
  }

  handleSessionReady(info: SessionReadyInfo): void {
    process.stdout.write(`\n[session ready] id=${info.sessionId} model=${info.model}\n`);
    this.sessionReady.resolve(info);
  }

  handleStatus(status: { utteranceId: string; phase: AgentPhase; toolName?: string | undefined }): void {
    if (status.phase === "using_tool") {
      process.stdout.write(`\n[tool] ${status.toolName ?? "?"}\n`);
    }
  }

  handleTextDelta(delta: { utteranceId: string; text: string }): void {
    if (this.firstTextDeltaAtMs === null) {
      this.firstTextDeltaAtMs = Date.now();
    }
    process.stdout.write(delta.text);
  }

  handleOverlayCommand(command: OverlayCommand): void {
    this.annotationCommands.push(command);
    const bounds = { widthPixels: this.latestScreenshot.widthPixels, heightPixels: this.latestScreenshot.heightPixels };
    const insideBounds = isPointInsideBounds({ x: command.x, y: command.y }, bounds);
    process.stdout.write(`\n[overlay] ${command.kind} ${JSON.stringify(command)} inBounds=${insideBounds}\n`);
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
    return answer.trim().toLowerCase().startsWith("y") ? { decision: "allow" } : { decision: "deny", denialReason: "the user said no in the terminal" };
  }

  handleTurnComplete(summary: TurnCompleteSummary): void {
    this.turnOutcome.resolve(summary);
  }

  handleTurnFailed(failure: TurnFailure): void {
    this.turnOutcome.resolve(failure);
  }
}

async function speakWithMacOS(text: string): Promise<void> {
  if (text.trim() === "") return;
  await execFileAsync("say", [text]);
}

async function main(): Promise<void> {
  const sidecarRootDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  loadDotEnvIfPresent(sidecarRootDirectory);
  const spikeArguments = parseSpikeArguments(process.argv.slice(2));
  const config = loadSidecarConfig({ argv: process.argv.slice(2), env: process.env, defaultProjectDirectory: process.cwd() });
  const logger = createLogger("spike", { minimumLevel: resolveLogLevelFromEnvironment(config.logLevel) });

  assertProjectDirectoryExists(config.projectDirectory);
  logCredentialSource(config.hasAnthropicApiKey, logger);

  process.stdout.write(`project: ${config.projectDirectory}\npermission mode: ${spikeArguments.permissionMode}\n`);
  process.stdout.write(spikeArguments.screenshotPath ? `screenshot: ${spikeArguments.screenshotPath}\n` : "capturing main display...\n");
  const screenshot = spikeArguments.screenshotPath
    ? await loadScreenshotFromFile(spikeArguments.screenshotPath)
    : await captureMainDisplay();
  process.stdout.write(`screenshot: ${screenshot.widthPixels}x${screenshot.heightPixels} px, ${Math.round(screenshot.jpegBase64.length / 1024)} KB base64\n`);

  const readline = createInterface({ input: process.stdin, output: process.stdout });
  const host = new ConsoleSpikeHost(screenshot, readline);
  const session = new AgentSession({
    projectDirectory: config.projectDirectory,
    permissionMode: spikeArguments.permissionMode,
    resumeSessionId: spikeArguments.resumeSessionId ?? undefined,
    model: config.model ?? undefined,
    host,
    logger: logger.child("session")
  });

  session.start();

  let question = spikeArguments.question;
  let turnNumber = 0;
  while (question.trim() !== "") {
    turnNumber += 1;
    host.resetForNextTurn();
    const sentAtMs = Date.now();
    process.stdout.write(`\n=== turn ${turnNumber}: "${question}" ===\n`);
    await session.sendUtterance({
      utteranceId: `spike-turn-${turnNumber}`,
      transcript: question,
      screenshots: turnNumber === 1 ? [screenshot] : []
    });

    const outcome = await host.turnOutcome.promise;
    const timeToFirstTextMs = host.firstTextDeltaAtMs === null ? null : host.firstTextDeltaAtMs - sentAtMs;
    process.stdout.write("\n\n--- turn summary ---\n");
    if ("spokenText" in outcome) {
      process.stdout.write(`time to first text: ${timeToFirstTextMs ?? "n/a"} ms\n`);
      process.stdout.write(`total: ${outcome.durationMs} ms, cost: $${outcome.costUsd?.toFixed(4) ?? "?"}\n`);
      process.stdout.write(`annotations: ${host.annotationCommands.length} (${host.annotationCommands.map((command) => command.kind).join(", ") || "none"})\n`);
      process.stdout.write(`spoken text: ${outcome.spokenText}\n`);
      if (spikeArguments.shouldSpeak) {
        await speakWithMacOS(outcome.spokenText);
      }
    } else {
      process.stdout.write(`turn failed: ${outcome.code}: ${outcome.message}\n`);
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
