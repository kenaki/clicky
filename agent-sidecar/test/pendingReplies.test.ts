import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PendingReplyRegistry } from "../src/server/pendingReplies.js";

describe("PendingReplyRegistry", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("resolves a registered request when its reply arrives", async () => {
    const registry = new PendingReplyRegistry<string>({ timeoutMs: 1000, createTimeoutError: (id) => new Error(`timeout ${id}`) });
    const pending = registry.register("r-1");
    expect(registry.resolve("r-1", "hello")).toBe(true);
    await expect(pending).resolves.toBe("hello");
    expect(registry.pendingCount).toBe(0);
  });

  it("rejects with the timeout error when nobody answers", async () => {
    const registry = new PendingReplyRegistry<string>({ timeoutMs: 1000, createTimeoutError: (id) => new Error(`timeout ${id}`) });
    const pending = registry.register("r-2");
    const assertion = expect(pending).rejects.toThrowError("timeout r-2");
    vi.advanceTimersByTime(1000);
    await assertion;
  });

  it("returns false for a reply nobody is waiting on", () => {
    const registry = new PendingReplyRegistry<string>({ timeoutMs: 1000, createTimeoutError: () => new Error("t") });
    expect(registry.resolve("unknown", "x")).toBe(false);
  });

  it("rejects everything on rejectAll", async () => {
    const registry = new PendingReplyRegistry<string>({ timeoutMs: 1000, createTimeoutError: () => new Error("t") });
    const first = registry.register("a");
    const second = registry.register("b");
    registry.rejectAll(new Error("socket closed"));
    await expect(first).rejects.toThrowError("socket closed");
    await expect(second).rejects.toThrowError("socket closed");
  });
});
