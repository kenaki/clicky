/**
 * Shared startup chores for the CLI entry points: load `.env` if present,
 * confirm the project directory exists, warn when no API key is configured.
 */
import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { SidecarConfigError } from "../config/sidecarConfig.js";
import type { Logger } from "../logging/logger.js";

export function loadDotEnvIfPresent(sidecarRootDirectory: string): void {
  const dotEnvPath = resolve(sidecarRootDirectory, ".env");
  if (!existsSync(dotEnvPath)) return;
  try {
    process.loadEnvFile(dotEnvPath);
  } catch (error) {
    throw new SidecarConfigError(`could not load ${dotEnvPath}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

export function assertProjectDirectoryExists(projectDirectory: string): void {
  if (!existsSync(projectDirectory) || !statSync(projectDirectory).isDirectory()) {
    throw new SidecarConfigError(`project directory does not exist or is not a directory: ${projectDirectory}`);
  }
}

/**
 * The sidecar runs on the Claude Code login by default, the same credentials
 * the `claude` CLI uses in a terminal. An ANTHROPIC_API_KEY, if present, takes
 * precedence inside the Claude Code binary, so say which one is in play.
 */
export function logCredentialSource(hasAnthropicApiKey: boolean, logger: Logger): void {
  if (hasAnthropicApiKey) {
    logger.info("using ANTHROPIC_API_KEY from the environment; unset it to use the Claude Code login instead");
    return;
  }
  logger.info(
    "using the Claude Code login (no ANTHROPIC_API_KEY set); if requests fail to authenticate, run `claude auth login` in a terminal"
  );
}

export function readSidecarVersion(): string {
  return process.env.npm_package_version ?? "0.1.0";
}
