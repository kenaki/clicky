/**
 * Minimal structured logger. One line per event, prefixed by component.
 *
 * Logs go to stderr on purpose: stdout is reserved for the single
 * "listening on ws://..." line the Swift app waits for before connecting.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface Logger {
  debug(message: string, context?: Record<string, unknown>): void;
  info(message: string, context?: Record<string, unknown>): void;
  warn(message: string, context?: Record<string, unknown>): void;
  error(message: string, context?: Record<string, unknown>): void;
  child(component: string): Logger;
}

export interface LoggerOptions {
  minimumLevel?: LogLevel;
  writeLine?: (line: string) => void;
}

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40
};

function formatContext(context: Record<string, unknown> | undefined): string {
  if (!context || Object.keys(context).length === 0) {
    return "";
  }
  try {
    return " " + JSON.stringify(context);
  } catch {
    return " [context not serializable]";
  }
}

export function createLogger(component: string, options: LoggerOptions = {}): Logger {
  const minimumLevel = options.minimumLevel ?? "info";
  const writeLine = options.writeLine ?? ((line: string) => process.stderr.write(line + "\n"));

  const emit = (level: LogLevel, message: string, context?: Record<string, unknown>) => {
    if (LEVEL_ORDER[level] < LEVEL_ORDER[minimumLevel]) {
      return;
    }
    const timestamp = new Date().toISOString();
    writeLine(`${timestamp} [${component}] ${level.toUpperCase()} ${message}${formatContext(context)}`);
  };

  return {
    debug: (message, context) => emit("debug", message, context),
    info: (message, context) => emit("info", message, context),
    warn: (message, context) => emit("warn", message, context),
    error: (message, context) => emit("error", message, context),
    child: (childComponent) => createLogger(`${component}:${childComponent}`, { minimumLevel, writeLine })
  };
}

export function resolveLogLevelFromEnvironment(rawValue: string | undefined): LogLevel {
  if (rawValue === "debug" || rawValue === "info" || rawValue === "warn" || rawValue === "error") {
    return rawValue;
  }
  return "info";
}
