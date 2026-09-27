import { describe, expect, it } from "vitest";
import { DEFAULT_AGENT_EFFORT, DEFAULT_AGENT_MODEL, DEFAULT_SIDECAR_PORT, loadSidecarConfig, SidecarConfigError } from "../src/config/sidecarConfig.js";

const baseInput = { argv: [] as string[], env: {} as Record<string, string | undefined>, defaultProjectDirectory: "/tmp/project" };

describe("loadSidecarConfig", () => {
  it("uses defaults when nothing is provided", () => {
    const config = loadSidecarConfig(baseInput);
    expect(config.port).toBe(DEFAULT_SIDECAR_PORT);
    expect(config.projectDirectory).toBe("/tmp/project");
    expect(config.sharedToken).toBeNull();
    expect(config.hasAnthropicApiKey).toBe(false);
    expect(config.model).toBe(DEFAULT_AGENT_MODEL);
    expect(config.effort).toBe(DEFAULT_AGENT_EFFORT);
  });

  it("accepts an effort override and rejects an unknown one", () => {
    expect(loadSidecarConfig({ ...baseInput, argv: ["--effort", "medium"] }).effort).toBe("medium");
    expect(() => loadSidecarConfig({ ...baseInput, env: { CLICKY_AGENT_EFFORT: "turbo" } })).toThrowError(SidecarConfigError);
  });

  it("prefers command-line arguments over environment variables", () => {
    const config = loadSidecarConfig({
      ...baseInput,
      argv: ["--port", "50000", "--project", "/from/argv"],
      env: { CLICKY_SIDECAR_PORT: "40000", CLICKY_PROJECT_DIRECTORY: "/from/env", ANTHROPIC_API_KEY: "sk-test" }
    });
    expect(config.port).toBe(50000);
    expect(config.projectDirectory).toBe("/from/argv");
    expect(config.hasAnthropicApiKey).toBe(true);
  });

  it("rejects a relative project directory", () => {
    expect(() => loadSidecarConfig({ ...baseInput, argv: ["--project", "relative/path"] })).toThrowError(SidecarConfigError);
  });

  it("rejects a non-numeric port", () => {
    expect(() => loadSidecarConfig({ ...baseInput, argv: ["--port", "abc"] })).toThrowError(/--port must be an integer/);
  });

  it("treats an empty token as absent", () => {
    expect(loadSidecarConfig({ ...baseInput, env: { CLICKY_SIDECAR_TOKEN: "   " } }).sharedToken).toBeNull();
  });
});
