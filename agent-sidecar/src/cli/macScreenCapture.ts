/**
 * Screenshot capture for the spike using only macOS built-ins:
 * `screencapture` for the pixels and `sips` to downscale and read dimensions.
 * Matches upstream Clicky's convention of a 1280 px maximum dimension.
 */
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { Screenshot } from "../protocol/sharedShapes.js";

const execFileAsync = promisify(execFile);

export const SPIKE_SCREENSHOT_MAX_DIMENSION = 1280;

async function readImageDimensions(imagePath: string): Promise<{ widthPixels: number; heightPixels: number }> {
  const { stdout } = await execFileAsync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", imagePath]);
  const widthMatch = /pixelWidth:\s*(\d+)/.exec(stdout);
  const heightMatch = /pixelHeight:\s*(\d+)/.exec(stdout);
  if (!widthMatch?.[1] || !heightMatch?.[1]) {
    throw new Error(`could not read image dimensions from sips output: ${stdout}`);
  }
  return { widthPixels: Number.parseInt(widthMatch[1], 10), heightPixels: Number.parseInt(heightMatch[1], 10) };
}

/** Loads an existing JPEG and downsizes it in place if needed. */
export async function loadScreenshotFromFile(imagePath: string, screenIndex = 1): Promise<Screenshot> {
  await execFileAsync("sips", ["-Z", String(SPIKE_SCREENSHOT_MAX_DIMENSION), imagePath]);
  const dimensions = await readImageDimensions(imagePath);
  const jpegBytes = await readFile(imagePath);
  return {
    screenIndex,
    label: "user's screen (cursor is here)",
    isCursorScreen: true,
    ...dimensions,
    jpegBase64: jpegBytes.toString("base64")
  };
}

/** Captures the main display. Requires Screen Recording permission for the terminal app. */
export async function captureMainDisplay(): Promise<Screenshot> {
  const imagePath = join(tmpdir(), `clicky-spike-${Date.now()}.jpg`);
  await execFileAsync("screencapture", ["-x", "-t", "jpg", "-D", "1", imagePath]);
  return loadScreenshotFromFile(imagePath, 1);
}
