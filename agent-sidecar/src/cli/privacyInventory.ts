/**
 * Lists, and on request deletes, every local copy of a screenshot that the
 * sidecar or its spikes have produced. See docs/privacy.md for the map.
 *
 *   npm run privacy:list
 *   npm run privacy:clean                          # temp captures + Claude Code's extracted images
 *   npm run privacy:clean -- --include-sessions    # also the session transcripts (breaks --resume for them)
 *
 * Only sessions this sidecar created are touched. They are recognised by the
 * screenshot label the sidecar writes into every user message.
 */
import { existsSync } from "node:fs";
import { readdir, readFile, rm, stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { loadSidecarConfig } from "../config/sidecarConfig.js";
import { loadDotEnvIfPresent } from "./environment.js";
import { SPIKE_TEMP_CAPTURE_PREFIX } from "./macScreenCapture.js";

type InventoryKind = "temp capture" | "session transcript" | "extracted image";

interface InventoryItem {
  kind: InventoryKind;
  path: string;
  bytes: number;
  modifiedAt: Date;
  sessionId: string | null;
}

/** Substrings the sidecar writes into every user message that carries a screenshot. */
const SIDECAR_SESSION_MARKERS = ["(image dimensions: ", "screen index "];

/** Claude Code names a project's transcript folder after its absolute path with every non-alphanumeric character replaced by "-". */
export function encodeProjectDirectoryForClaude(projectDirectory: string): string {
  return projectDirectory.replace(/[^A-Za-z0-9]/g, "-");
}

function claudeConfigDirectory(): string {
  return process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude");
}

/** Observed on macOS with Claude Code 2.1.x: images from a session are extracted here. */
function claudeExtractedImagesRoot(): string | null {
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  return uid === null ? null : `/private/tmp/claude-${uid}`;
}

async function listTempCaptures(): Promise<InventoryItem[]> {
  const items: InventoryItem[] = [];
  for (const entry of await readdir(tmpdir())) {
    if (!entry.startsWith(SPIKE_TEMP_CAPTURE_PREFIX) || !entry.endsWith(".jpg")) continue;
    const path = join(tmpdir(), entry);
    const info = await stat(path);
    items.push({ kind: "temp capture", path, bytes: info.size, modifiedAt: info.mtime, sessionId: null });
  }
  return items;
}

async function listSidecarSessions(projectDirectories: string[]): Promise<InventoryItem[]> {
  const items: InventoryItem[] = [];
  for (const projectDirectory of projectDirectories) {
    const transcriptsDirectory = join(claudeConfigDirectory(), "projects", encodeProjectDirectoryForClaude(projectDirectory));
    if (!existsSync(transcriptsDirectory)) continue;
    for (const entry of await readdir(transcriptsDirectory)) {
      if (!entry.endsWith(".jsonl")) continue;
      const path = join(transcriptsDirectory, entry);
      const text = await readFile(path, "utf8");
      if (!SIDECAR_SESSION_MARKERS.every((marker) => text.includes(marker))) continue;
      const info = await stat(path);
      items.push({ kind: "session transcript", path, bytes: info.size, modifiedAt: info.mtime, sessionId: basename(entry, ".jsonl") });
    }
  }
  return items;
}

async function listExtractedImages(sessions: InventoryItem[], projectDirectories: string[]): Promise<InventoryItem[]> {
  const root = claudeExtractedImagesRoot();
  if (root === null) return [];
  const items: InventoryItem[] = [];
  for (const projectDirectory of projectDirectories) {
    for (const session of sessions) {
      if (session.sessionId === null) continue;
      const imagesDirectory = join(root, encodeProjectDirectoryForClaude(projectDirectory), session.sessionId, "images");
      if (!existsSync(imagesDirectory)) continue;
      for (const entry of await readdir(imagesDirectory)) {
        const path = join(imagesDirectory, entry);
        const info = await stat(path);
        items.push({ kind: "extracted image", path, bytes: info.size, modifiedAt: info.mtime, sessionId: session.sessionId });
      }
    }
  }
  return items;
}

function formatItem(item: InventoryItem): string {
  const kilobytes = Math.round(item.bytes / 1024);
  return `${item.kind.padEnd(19)} ${item.modifiedAt.toISOString().slice(0, 16).replace("T", " ")}  ${String(kilobytes).padStart(6)} KB  ${item.path}`;
}

async function main(): Promise<void> {
  const sidecarRootDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  loadDotEnvIfPresent(sidecarRootDirectory);
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    options: { "include-sessions": { type: "boolean", default: false } },
    allowPositionals: true,
    strict: false
  });
  const action = positionals[0] === "clean" ? "clean" : "list";
  const includeSessions = Boolean(values["include-sessions"]);

  const config = loadSidecarConfig({ argv: [], env: process.env, defaultProjectDirectory: process.cwd() });
  const projectDirectories = [...new Set([config.projectDirectory, sidecarRootDirectory, process.cwd()])];

  const tempCaptures = await listTempCaptures();
  const sessions = await listSidecarSessions(projectDirectories);
  const extractedImages = await listExtractedImages(sessions, projectDirectories);
  const everything = [...tempCaptures, ...extractedImages, ...sessions];

  process.stdout.write(`scanned project folders: ${projectDirectories.join(", ")}\n\n`);
  if (everything.length === 0) {
    process.stdout.write("no local screenshot copies found.\n");
    return;
  }
  for (const item of everything) process.stdout.write(formatItem(item) + "\n");
  const totalKilobytes = Math.round(everything.reduce((total, item) => total + item.bytes, 0) / 1024);
  process.stdout.write(`\n${tempCaptures.length} temp captures, ${extractedImages.length} extracted images, ${sessions.length} sidecar session transcripts, ${totalKilobytes} KB total\n`);
  process.stdout.write("note: each transcript embeds its screenshot as base64. Deleting a transcript removes that session from `claude --resume`.\n");

  if (action !== "clean") {
    process.stdout.write("\nrun `npm run privacy:clean` to delete temp captures and extracted images, add `-- --include-sessions` to delete the transcripts too.\n");
    return;
  }

  const toDelete = includeSessions ? everything : [...tempCaptures, ...extractedImages];
  for (const item of toDelete) {
    await rm(item.path, { force: true });
    process.stdout.write(`deleted ${item.path}\n`);
  }
  if (!includeSessions && sessions.length > 0) {
    process.stdout.write(`kept ${sessions.length} session transcript(s); pass --include-sessions to delete them.\n`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`privacy inventory failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
});
