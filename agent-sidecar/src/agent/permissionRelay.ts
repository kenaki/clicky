/**
 * Bridges the Agent SDK's `canUseTool` prompt to the host, which in the real
 * app means: speak the question, listen for yes or no, answer. A timeout or
 * any host failure is a deny, never a hang and never an implicit allow.
 */
import { basename } from "node:path";
import type { CanUseTool } from "@anthropic-ai/claude-agent-sdk";
import { randomUUID } from "node:crypto";
import { describeUnknownError } from "../protocol/errors.js";
import type { PermissionDecision, PermissionRequest } from "../protocol/sharedShapes.js";
import type { Logger } from "../logging/logger.js";
import { SCREEN_ANNOTATION_SERVER_NAME } from "./tools/screenAnnotationTools.js";

const SCREEN_ANNOTATION_TOOL_PREFIX = `mcp__${SCREEN_ANNOTATION_SERVER_NAME}__`;

export interface PermissionRelayHost {
  requestPermission(request: PermissionRequest): Promise<PermissionDecision>;
}

function readStringField(input: Record<string, unknown>, fieldName: string): string | null {
  const value = input[fieldName];
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function firstWords(text: string, wordCount: number): string {
  const words = text.trim().split(/\s+/);
  const excerpt = words.slice(0, wordCount).join(" ");
  return words.length > wordCount ? `${excerpt} and so on` : excerpt;
}

/**
 * Turns a tool call into one sentence a person can answer with yes or no.
 * Exported for tests; the wording is what the user will hear.
 */
export function describeToolUseForSpeech(toolName: string, input: Record<string, unknown>): string {
  const filePath = readStringField(input, "file_path") ?? readStringField(input, "path") ?? readStringField(input, "notebook_path");
  const fileName = filePath ? basename(filePath) : null;

  switch (toolName) {
    case "Edit":
    case "MultiEdit":
    case "NotebookEdit":
      return fileName ? `want me to edit ${fileName}?` : "want me to edit a file?";
    case "Write":
      return fileName ? `want me to write ${fileName}?` : "want me to write a file?";
    case "Read":
      return fileName ? `want me to read ${fileName}?` : "want me to read a file?";
    case "Bash": {
      const command = readStringField(input, "command");
      return command ? `want me to run ${firstWords(command, 8)}?` : "want me to run a command?";
    }
    case "WebFetch":
    case "WebSearch":
      return "want me to look something up on the web?";
    default: {
      const mcpMatch = /^mcp__([^_]+(?:_[^_]+)*)__(.+)$/.exec(toolName);
      if (mcpMatch) {
        const serverName = mcpMatch[1]?.replaceAll("_", " ") ?? "a";
        const bareToolName = mcpMatch[2]?.replaceAll("_", " ") ?? "tool";
        return `want me to use the ${serverName} tool ${bareToolName}?`;
      }
      return `want me to use ${toolName}?`;
    }
  }
}

export function createPermissionRelay(host: PermissionRelayHost, logger: Logger): CanUseTool {
  return async (toolName, input, options) => {
    // Pointing and circling only draw on our own overlay. Plan mode routes tools it
    // cannot prove harmless to this callback even when an allow rule matches, so
    // approve them here rather than ever asking the user "may I point?".
    if (toolName.startsWith(SCREEN_ANNOTATION_TOOL_PREFIX)) {
      return { behavior: "allow", updatedInput: input };
    }

    const request: PermissionRequest = {
      permissionRequestId: randomUUID(),
      toolName,
      input,
      spokenSummary: describeToolUseForSpeech(toolName, input)
    };
    logger.info("permission requested", { toolName, permissionRequestId: request.permissionRequestId });

    if (options.signal.aborted) {
      return { behavior: "deny", message: "the request was cancelled before the user could answer" };
    }

    try {
      const decision = await host.requestPermission(request);
      if (decision.decision === "allow") {
        logger.info("permission allowed", { toolName });
        return { behavior: "allow", updatedInput: input };
      }
      logger.info("permission denied", { toolName, denialReason: decision.denialReason });
      return { behavior: "deny", message: decision.denialReason ?? "the user said no" };
    } catch (error) {
      logger.warn("permission request failed, denying", { toolName, error: describeUnknownError(error) });
      return { behavior: "deny", message: `no answer from the user: ${describeUnknownError(error)}` };
    }
  };
}
