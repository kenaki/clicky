import { describe, expect, it } from "vitest";
import { createPermissionRelay, describeToolUseForSpeech } from "../src/agent/permissionRelay.js";
import { createLogger } from "../src/logging/logger.js";

const silentLogger = createLogger("test", { writeLine: () => {} });

describe("describeToolUseForSpeech", () => {
  it("names the file for edits", () => {
    expect(describeToolUseForSpeech("Edit", { file_path: "/a/b/CompanionManager.swift" })).toBe("want me to edit CompanionManager.swift?");
  });
  it("shortens long shell commands", () => {
    const summary = describeToolUseForSpeech("Bash", { command: "npm run build && npm test -- --coverage --reporter verbose" });
    expect(summary).toBe("want me to run npm run build && npm test -- --coverage and so on?");
  });
  it("reads mcp tool names into words", () => {
    expect(describeToolUseForSpeech("mcp__github__create_issue", {})).toBe("want me to use the github tool create issue?");
  });
  it("falls back to the tool name", () => {
    expect(describeToolUseForSpeech("SomethingNew", {})).toBe("want me to use SomethingNew?");
  });
});

describe("createPermissionRelay", () => {
  const abortOptions = { signal: new AbortController().signal, toolUseID: "tool-use-1", requestId: "request-1" };

  it("maps an allow decision to the SDK allow shape with the original input", async () => {
    const relay = createPermissionRelay({ requestPermission: async () => ({ decision: "allow" }) }, silentLogger);
    const result = await relay("Edit", { file_path: "/x.ts" }, abortOptions);
    expect(result).toEqual({ behavior: "allow", updatedInput: { file_path: "/x.ts" } });
  });

  it("maps a deny decision to the SDK deny shape with the reason", async () => {
    const relay = createPermissionRelay({ requestPermission: async () => ({ decision: "deny", denialReason: "not now" }) }, silentLogger);
    const result = await relay("Bash", { command: "rm -rf /" }, abortOptions);
    expect(result).toEqual({ behavior: "deny", message: "not now" });
  });

  it("denies when the host throws, for example on timeout", async () => {
    const relay = createPermissionRelay({ requestPermission: async () => { throw new Error("timed out"); } }, silentLogger);
    const result = await relay("Write", {}, abortOptions);
    if (!result || result.behavior !== "deny") throw new Error("expected a deny result");
    expect(result.message).toContain("timed out");
  });

  it("denies immediately when the request was already aborted", async () => {
    const abortController = new AbortController();
    abortController.abort();
    let hostCalled = false;
    const relay = createPermissionRelay({ requestPermission: async () => { hostCalled = true; return { decision: "allow" }; } }, silentLogger);
    const result = await relay("Write", {}, { signal: abortController.signal, toolUseID: "tool-use-2", requestId: "request-2" });
    expect(result?.behavior).toBe("deny");
    expect(hostCalled).toBe(false);
  });
});
