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

export function warnIfNoApiKey(hasAnthropicApiKey: boolean, logger: Logger): void {
  if (!hasAnthropicApiKey) {
    logger.warn(
      "ANTHROPIC_API_KEY is not set. The Agent SDK docs direct SDK apps to API-key auth; set it in agent-sidecar/.env or the environment."
    );
  }
}

export function readSidecarVersion(): string {
  return process.env.npm_package_version ?? "0.1.0";
}
