/**
 * Reports which credentials the Agent SDK will use, by making one tiny
 * request and reading the `apiKeySource` field from the session's init
 * message. No tools, one turn, nothing persisted.
 *
 *   npm run check-auth
 *
 * `apiKeySource: "none"` means the Claude Code login (claude.ai OAuth) is in
 * use; `"ANTHROPIC_API_KEY"` means the environment variable took precedence.
 */
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { loadDotEnvIfPresent } from "./environment.js";

async function main(): Promise<void> {
  const sidecarRootDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  loadDotEnvIfPresent(sidecarRootDirectory);

  const hasApiKey = Boolean(process.env.ANTHROPIC_API_KEY?.trim());
  process.stdout.write(`ANTHROPIC_API_KEY in environment: ${hasApiKey ? "set" : "not set"}\n`);
  process.stdout.write("sending one tiny request through the Agent SDK...\n");

  let apiKeySource: string | null = null;
  let model: string | null = null;
  let claudeCodeVersion: string | null = null;
  let resultText: string | null = null;
  let costUsd: number | null = null;
  const startedAtMs = Date.now();

  try {
    for await (const message of query({
      prompt: "Reply with exactly the word: ok",
      options: {
        cwd: tmpdir(),
        tools: [],
        maxTurns: 1,
        permissionMode: "dontAsk",
        persistSession: false,
        settingSources: []
      }
    })) {
      if (message.type === "system" && message.subtype === "init") {
        apiKeySource = message.apiKeySource;
        model = message.model;
        claudeCodeVersion = message.claude_code_version;
      }
      if (message.type === "result" && message.subtype === "success") {
        resultText = message.result;
        costUsd = message.total_cost_usd;
      }
    }
  } catch (error) {
    process.stdout.write(`request failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.stdout.write("if this mentions authentication, run `claude auth login` in a terminal, then retry.\n");
    process.exit(1);
  }

  process.stdout.write(`\ncredential source: ${apiKeySource ?? "unknown"}\n`);
  process.stdout.write(`model: ${model ?? "unknown"}  claude code: ${claudeCodeVersion ?? "unknown"}\n`);
  process.stdout.write(`reply: ${JSON.stringify(resultText)}  reported cost: $${costUsd ?? "?"}  took ${Date.now() - startedAtMs} ms\n`);

  if (apiKeySource === "none") {
    process.stdout.write("verdict: using your Claude Code login, no API key involved.\n");
  } else if (apiKeySource === "ANTHROPIC_API_KEY") {
    process.stdout.write("verdict: using ANTHROPIC_API_KEY. Unset it to use the Claude Code login instead.\n");
  } else {
    process.stdout.write(`verdict: credential source "${apiKeySource}".\n`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`check-auth failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
});
