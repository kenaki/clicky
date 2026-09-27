/**
 * Entry point the Swift app spawns. Prints exactly one line to stdout once
 * ready ("listening on ws://127.0.0.1:<port>"); everything else goes to stderr.
 */
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadSidecarConfig, SidecarConfigError } from "../config/sidecarConfig.js";
import { createLogger, resolveLogLevelFromEnvironment } from "../logging/logger.js";
import { SidecarWebSocketServer } from "../server/sidecarWebSocketServer.js";
import { assertProjectDirectoryExists, loadDotEnvIfPresent, readSidecarVersion, warnIfNoApiKey } from "./environment.js";

const PARENT_WATCHDOG_INTERVAL_MS = 2_000;

function isProcessAlive(processId: number): boolean {
  try {
    process.kill(processId, 0);
    return true;
  } catch {
    return false;
  }
}

async function main(): Promise<void> {
  const sidecarRootDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  loadDotEnvIfPresent(sidecarRootDirectory);

  const config = loadSidecarConfig({
    argv: process.argv.slice(2),
    env: process.env,
    defaultProjectDirectory: process.cwd()
  });
  const logger = createLogger("sidecar", { minimumLevel: resolveLogLevelFromEnvironment(config.logLevel) });

  assertProjectDirectoryExists(config.projectDirectory);
  warnIfNoApiKey(config.hasAnthropicApiKey, logger);

  const server = new SidecarWebSocketServer({
    port: config.port,
    sharedToken: config.sharedToken,
    sidecarVersion: readSidecarVersion(),
    model: config.model,
    logger: logger.child("server")
  });

  let isShuttingDown = false;
  const shutdown = async (reason: string): Promise<void> => {
    if (isShuttingDown) return;
    isShuttingDown = true;
    logger.info("shutting down", { reason });
    await server.stop();
    process.exit(0);
  };

  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));

  if (config.parentProcessId !== null) {
    const parentProcessId = config.parentProcessId;
    setInterval(() => {
      if (!isProcessAlive(parentProcessId)) {
        void shutdown(`parent process ${parentProcessId} is gone`);
      }
    }, PARENT_WATCHDOG_INTERVAL_MS).unref();
  }

  const { port } = await server.start();
  logger.info("ready", { port, projectDirectory: config.projectDirectory, tokenRequired: config.sharedToken !== null });
  process.stdout.write(`listening on ws://127.0.0.1:${port}\n`);
}

main().catch((error: unknown) => {
  const message = error instanceof SidecarConfigError ? error.message : error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`sidecar failed to start: ${message}\n`);
  process.exit(1);
});
