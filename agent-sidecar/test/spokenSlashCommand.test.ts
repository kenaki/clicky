import { describe, expect, it } from "vitest";
import { rewriteSpokenSlashCommand } from "../src/agent/spokenSlashCommand.js";

const availableCommandNames = ["teach", "chunk-plan", "rt", "compact"];

describe("rewriteSpokenSlashCommand", () => {
  it("rewrites a spoken slash and keeps the arguments", () => {
    expect(rewriteSpokenSlashCommand("slash teach linear regression", availableCommandNames)).toBe("/teach linear regression");
  });

  it("accepts a typed slash from speech to text", () => {
    expect(rewriteSpokenSlashCommand("/teach gradients", availableCommandNames)).toBe("/teach gradients");
  });

  it("ignores case and trailing punctuation on the name", () => {
    expect(rewriteSpokenSlashCommand("Slash Teach, what is a gradient?", availableCommandNames)).toBe("/teach what is a gradient?");
  });

  it("joins spoken words into a hyphenated name, longest match first", () => {
    expect(rewriteSpokenSlashCommand("slash chunk plan the voice panel", availableCommandNames)).toBe("/chunk-plan the voice panel");
  });

  it("sends a bare command with no arguments", () => {
    expect(rewriteSpokenSlashCommand("slash compact.", availableCommandNames)).toBe("/compact");
  });

  it("leaves unknown names alone", () => {
    expect(rewriteSpokenSlashCommand("slash dance now", availableCommandNames)).toBeNull();
  });

  it("leaves ordinary speech alone", () => {
    expect(rewriteSpokenSlashCommand("teach me linear regression", availableCommandNames)).toBeNull();
    expect(rewriteSpokenSlashCommand("what does slash teach do", availableCommandNames)).toBeNull();
  });
});
