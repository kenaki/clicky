/**
 * Spike 3 client: a throwaway WebSocket client that drives the sidecar the
 * way the Swift app will, and prints every event it gets back.
 *
 *   npm run serve -- --project /path/to/project        (terminal 1)
 *   npm run spike:ipc-client -- --question "where is the search bar"   (terminal 2)
 *   npm run spike:ipc-client -- --hello-only           (transport smoke test, no API call)
 *
 * Screenshot requests are answered by capturing the display; permission
 * requests are answered from this terminal.
 */
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline/promises";
import { parseArgs } from "node:util";
import { WebSocket } from "ws";
import { DEFAULT_SIDECAR_PORT } from "../config/sidecarConfig.js";
import { PROTOCOL_VERSION, type Screenshot, type VoicePermissionMode } from "../protocol/sharedShapes.js";
import { captureMainDisplay } from "./macScreenCapture.js";

interface ClientSpikeArguments {
  port: number;
  /** Null lets the sidecar use the directory it was started with. */
  projectDirectory: string | null;
  question: string;
  helloOnly: boolean;
  token: string | null;
  permissionMode: VoicePermissionMode;
}

function parseClientSpikeArguments(argv: string[]): ClientSpikeArguments {
  const { values } = parseArgs({
    args: argv,
    options: {
      port: { type: "string" },
      project: { type: "string" },
      question: { type: "string", short: "q" },
      "hello-only": { type: "boolean", default: false },
      token: { type: "string" },
      "permission-mode": { type: "string" }
    },
    allowPositionals: true,
    strict: false
  });
  const permissionMode = ((values["permission-mode"] as string | undefined) ?? "default") as VoicePermissionMode;
  return {
    port: values.port ? Number.parseInt(values.port as string, 10) : Number.parseInt(process.env.CLICKY_SIDECAR_PORT ?? String(DEFAULT_SIDECAR_PORT), 10),
    projectDirectory: (values.project as string | undefined) ?? null,
    question: (values.question as string | undefined) ?? "what am i looking at, and where is the most important button on this screen?",
    helloOnly: Boolean(values["hello-only"]),
    token: (values.token as string | undefined) ?? process.env.CLICKY_SIDECAR_TOKEN ?? null,
    permissionMode
  };
}

interface SidecarEvent {
  type: string;
  payload: Record<string, unknown>;
  sentAtMs: number;
}

function isSidecarEvent(value: unknown): value is SidecarEvent {
  return typeof value === "object" && value !== null && typeof (value as { type?: unknown }).type === "string" && typeof (value as { payload?: unknown }).payload === "object";
}

async function main(): Promise<void> {
  const spikeArguments = parseClientSpikeArguments(process.argv.slice(2));
  const socket = new WebSocket(`ws://127.0.0.1:${spikeArguments.port}`);
  const readline = createInterface({ input: process.stdin, output: process.stdout });

  const sendToSidecar = (type: string, payload: Record<string, unknown>): void => {
    socket.send(JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type, messageId: randomUUID(), sentAtMs: Date.now(), payload }));
  };

  const finish = (exitCode: number): void => {
    readline.close();
    socket.close();
    process.exit(exitCode);
  };

  let firstTextDeltaAtMs: number | null = null;
  let utteranceSentAtMs = 0;

  socket.on("open", () => {
    process.stdout.write(`connected to ws://127.0.0.1:${spikeArguments.port}\n`);
    sendToSidecar("client.hello", { clientName: "ipc-client-spike", ...(spikeArguments.token ? { token: spikeArguments.token } : {}) });
  });

  socket.on("message", (rawData) => {
    void (async () => {
      const parsed: unknown = JSON.parse(rawData.toString());
      if (!isSidecarEvent(parsed)) {
        process.stdout.write(`?? unrecognised frame: ${rawData.toString().slice(0, 200)}\n`);
        return;
      }
      const hopLatencyMs = Date.now() - parsed.sentAtMs;

      switch (parsed.type) {
        case "sidecar.hello":
          process.stdout.write(`<- sidecar.hello ${JSON.stringify(parsed.payload)} (${hopLatencyMs} ms hop)\n`);
          if (spikeArguments.helloOnly) {
            process.stdout.write("hello-only: handshake ok\n");
            finish(0);
            return;
          }
          sendToSidecar("session.start", {
            ...(spikeArguments.projectDirectory !== null ? { projectDirectory: spikeArguments.projectDirectory } : {}),
            permissionMode: spikeArguments.permissionMode
          });
          process.stdout.write("capturing screenshot...\n");
          const screenshot: Screenshot = await captureMainDisplay();
          utteranceSentAtMs = Date.now();
          sendToSidecar("user.utterance", { utteranceId: randomUUID(), transcript: spikeArguments.question, screenshots: [screenshot] });
          process.stdout.write(`-> user.utterance "${spikeArguments.question}" with ${screenshot.widthPixels}x${screenshot.heightPixels} screenshot\n`);
          return;

        case "assistant.text_delta":
          if (firstTextDeltaAtMs === null) {
            firstTextDeltaAtMs = Date.now();
            process.stdout.write(`\n[first text after ${firstTextDeltaAtMs - utteranceSentAtMs} ms]\n`);
          }
          process.stdout.write(String(parsed.payload.text ?? ""));
          return;

        case "assistant.sentence":
          process.stdout.write(`\n[sentence ${String(parsed.payload.sentenceIndex)} +${Date.now() - utteranceSentAtMs} ms] ${String(parsed.payload.text)}\n`);
          return;

        case "screenshot.request": {
          process.stdout.write("\n<- screenshot.request, capturing...\n");
          const freshScreenshot = await captureMainDisplay();
          sendToSidecar("screenshot.captured", { screenshotRequestId: parsed.payload.screenshotRequestId, screenshots: [freshScreenshot] });
          return;
        }

        case "permission.request": {
          process.stdout.write(`\n<- permission.request: ${String(parsed.payload.spokenSummary)}\n`);
          const answer = await readline.question("allow? [y/N] ");
          sendToSidecar("permission.decision", {
            permissionRequestId: parsed.payload.permissionRequestId,
            decision: answer.trim().toLowerCase().startsWith("y") ? "allow" : "deny",
            denialReason: "the user said no in the terminal"
          });
          return;
        }

        case "assistant.turn_complete":
          process.stdout.write(`\n\n<- assistant.turn_complete ${JSON.stringify({ ...parsed.payload, spokenText: undefined })}\n`);
          process.stdout.write(`spoken text: ${String(parsed.payload.spokenText)}\n`);
          process.stdout.write(`resume in a terminal: claude --resume ${String(parsed.payload.sessionId)}\n`);
          finish(0);
          return;

        case "error":
          process.stdout.write(`\n<- error ${JSON.stringify(parsed.payload)}\n`);
          if (String(parsed.payload.code).startsWith("session_") || parsed.payload.code === "unauthorized" || parsed.payload.code === "hello_required") {
            finish(1);
          }
          return;

        default:
          process.stdout.write(`\n<- ${parsed.type} ${JSON.stringify(parsed.payload)} (${hopLatencyMs} ms hop)\n`);
      }
    })().catch((error: unknown) => {
      process.stderr.write(`client error: ${error instanceof Error ? error.message : String(error)}\n`);
      finish(1);
    });
  });

  socket.on("close", (code, reason) => {
    process.stdout.write(`socket closed (${code} ${reason.toString()})\n`);
    finish(0);
  });

  socket.on("error", (error) => {
    process.stderr.write(`socket error: ${error.message}\n`);
    finish(1);
  });
}

main().catch((error: unknown) => {
  process.stderr.write(`ipc client spike failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
});
