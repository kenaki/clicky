/**
 * Loads sidecar configuration from command-line arguments and environment
 * variables, in that precedence order, and validates it. This is the only
 * module that reads `process.env`-shaped input. It does no filesystem I/O;
 * the CLI checks that the project directory exists.
 */
import { isAbsolute } from "node:path";
import { parseArgs } from "node:util";
import { z } from "zod";

export interface SidecarConfig {
  /** Localhost port the WebSocket server listens on. */
  port: number;
  /** Absolute path of the project the agent works in. */
  projectDirectory: string;
  /** Optional shared secret the client must present in `client.hello`. */
  sharedToken: string | null;
  /** Model passed to the Agent SDK. */
  model: string;
  /** Thinking effort passed to the Agent SDK. Low is fastest, which voice wants. */
  effort: AgentEffortLevel;
  /** Parent process id to watch; the sidecar exits when it disappears. */
  parentProcessId: number | null;
  /** True if an Anthropic API key is present in the environment. */
  hasAnthropicApiKey: boolean;
  logLevel: "debug" | "info" | "warn" | "error";
}

export const DEFAULT_SIDECAR_PORT = 47821;
export const DEFAULT_AGENT_MODEL = "claude-opus-5-5";
export const DEFAULT_AGENT_EFFORT: AgentEffortLevel = "low";

/** Mirrors the SDK's EffortLevel so the config layer does not import the SDK. */
export type AgentEffortLevel = "low" | "medium" | "high" | "xhigh" | "max";

const sidecarConfigSchema = z.object({
  port: z.number().int().min(1024).max(65535),
  projectDirectory: z
    .string()
    .min(1)
    .refine((value) => isAbsolute(value), { message: "projectDirectory must be an absolute path" }),
  sharedToken: z.string().min(1).nullable(),
  model: z.string().min(1),
  effort: z.enum(["low", "medium", "high", "xhigh", "max"]),
  parentProcessId: z.number().int().positive().nullable(),
  hasAnthropicApiKey: z.boolean(),
  logLevel: z.enum(["debug", "info", "warn", "error"])
});

export interface LoadSidecarConfigInput {
  argv: string[];
  env: Record<string, string | undefined>;
  /** Used when neither --project nor CLICKY_PROJECT_DIRECTORY is given. */
  defaultProjectDirectory: string;
}

export class SidecarConfigError extends Error {}

function parseOptionalInteger(rawValue: string | undefined, fieldName: string): number | null {
  if (rawValue === undefined || rawValue === "") {
    return null;
  }
  const parsedValue = Number.parseInt(rawValue, 10);
  if (Number.isNaN(parsedValue)) {
    throw new SidecarConfigError(`${fieldName} must be an integer, got "${rawValue}"`);
  }
  return parsedValue;
}

function emptyToNull(rawValue: string | undefined): string | null {
  if (rawValue === undefined) return null;
  const trimmedValue = rawValue.trim();
  return trimmedValue === "" ? null : trimmedValue;
}

export function loadSidecarConfig(input: LoadSidecarConfigInput): SidecarConfig {
  const { values } = parseArgs({
    args: input.argv,
    options: {
      port: { type: "string" },
      project: { type: "string" },
      model: { type: "string" },
      effort: { type: "string" },
      "parent-pid": { type: "string" },
      "log-level": { type: "string" }
    },
    allowPositionals: true,
    strict: false
  });

  const candidateConfig = {
    port:
      parseOptionalInteger(values.port as string | undefined, "--port") ??
      parseOptionalInteger(input.env.CLICKY_SIDECAR_PORT, "CLICKY_SIDECAR_PORT") ??
      DEFAULT_SIDECAR_PORT,
    projectDirectory:
      emptyToNull(values.project as string | undefined) ??
      emptyToNull(input.env.CLICKY_PROJECT_DIRECTORY) ??
      input.defaultProjectDirectory,
    sharedToken: emptyToNull(input.env.CLICKY_SIDECAR_TOKEN),
    model: emptyToNull(values.model as string | undefined) ?? emptyToNull(input.env.CLICKY_AGENT_MODEL) ?? DEFAULT_AGENT_MODEL,
    effort: emptyToNull(values.effort as string | undefined) ?? emptyToNull(input.env.CLICKY_AGENT_EFFORT) ?? DEFAULT_AGENT_EFFORT,
    parentProcessId: parseOptionalInteger(values["parent-pid"] as string | undefined, "--parent-pid"),
    hasAnthropicApiKey: emptyToNull(input.env.ANTHROPIC_API_KEY) !== null,
    logLevel: emptyToNull(values["log-level"] as string | undefined) ?? emptyToNull(input.env.CLICKY_SIDECAR_LOG_LEVEL) ?? "info"
  };

  const validation = sidecarConfigSchema.safeParse(candidateConfig);
  if (!validation.success) {
    const issueSummary = validation.error.issues
      .map((issue) => `${issue.path.join(".")}: ${issue.message}`)
      .join("; ");
    throw new SidecarConfigError(`Invalid sidecar configuration: ${issueSummary}`);
  }
  return validation.data;
}
