import { describe, expect, it } from "vitest";
import { ProtocolError } from "../src/protocol/errors.js";
import { createOutgoingMessage, parseIncomingMessage } from "../src/protocol/messages.js";
import { PROTOCOL_VERSION } from "../src/protocol/sharedShapes.js";

function envelope(type: string, payload: unknown, overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({ protocolVersion: PROTOCOL_VERSION, messageId: "m-1", sentAtMs: 1, type, payload, ...overrides });
}

describe("parseIncomingMessage", () => {
  it("parses a user.utterance and defaults screenshots to an empty list", () => {
    const message = parseIncomingMessage(envelope("user.utterance", { utteranceId: "u-1", transcript: "hello" }));
    expect(message.type).toBe("user.utterance");
    if (message.type === "user.utterance") {
      expect(message.payload.screenshots).toEqual([]);
    }
  });

  it("parses a session.start and defaults the permission mode", () => {
    const message = parseIncomingMessage(envelope("session.start", { projectDirectory: "/tmp/project" }));
    if (message.type !== "session.start") throw new Error("wrong type");
    expect(message.payload.permissionMode).toBe("default");
  });

  it("rejects an unknown message type with a malformed_message code", () => {
    expect(() => parseIncomingMessage(envelope("nope.nothing", {}))).toThrowError(ProtocolError);
    try {
      parseIncomingMessage(envelope("nope.nothing", {}));
    } catch (error) {
      expect((error as ProtocolError).code).toBe("malformed_message");
    }
  });

  it("rejects a wrong protocol version", () => {
    expect(() => parseIncomingMessage(envelope("user.interrupt", {}, { protocolVersion: 99 }))).toThrowError(/protocolVersion/);
  });

  it("rejects text that is not JSON", () => {
    expect(() => parseIncomingMessage("{not json")).toThrowError(/not valid JSON/);
  });

  it("rejects a screenshot with a non-positive width", () => {
    const payload = {
      screenshotRequestId: "s-1",
      screenshots: [{ screenIndex: 1, label: "x", isCursorScreen: true, widthPixels: 0, heightPixels: 10, jpegBase64: "AAAA" }]
    };
    expect(() => parseIncomingMessage(envelope("screenshot.captured", payload))).toThrowError(/widthPixels/);
  });
});

describe("createOutgoingMessage", () => {
  it("wraps the payload in an envelope with the protocol version and a clock timestamp", () => {
    const message = createOutgoingMessage("agent.status", { utteranceId: "u-1", phase: "thinking" }, () => 4242);
    expect(message.protocolVersion).toBe(PROTOCOL_VERSION);
    expect(message.type).toBe("agent.status");
    expect(message.sentAtMs).toBe(4242);
    expect(message.messageId).toMatch(/[0-9a-f-]{36}/);
    expect(message.payload).toEqual({ utteranceId: "u-1", phase: "thinking" });
  });
});
