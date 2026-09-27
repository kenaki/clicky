/**
 * Screenshot capture for the spikes using only macOS built-ins:
 * `screencapture` for the pixels and `sips` to downscale and read dimensions.
 * Matches upstream Clicky's convention of a 1280 px maximum dimension.
 *
 * Privacy rules, see docs/privacy.md:
 *  - one still frame per call, never a recording
 *  - the capture is announced on stdout and the system shutter sound is NOT
 *    silenced, so a capture is never invisible or inaudible
 *  - every temp file this module creates is deleted before returning
 *  - a user-supplied image is never modified in place
 */
import { execFile } from "node:child_process";
import { copyFile, readFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { Screenshot } from "../protocol/sharedShapes.js";

const execFileAsync = promisify(execFile);

export const SPIKE_SCREENSHOT_MAX_DIMENSION = 1280;
export const SPIKE_TEMP_CAPTURE_PREFIX = "clicky-spike-";

async function readImageDimensions(imagePath: string): Promise<{ widthPixels: number; heightPixels: number }> {
  const { stdout } = await execFileAsync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", imagePath]);
  const widthMatch = /pixelWidth:\s*(\d+)/.exec(stdout);
  const heightMatch = /pixelHeight:\s*(\d+)/.exec(stdout);
  if (!widthMatch?.[1] || !heightMatch?.[1]) {
    throw new Error(`could not read image dimensions from sips output: ${stdout}`);
  }
  return { widthPixels: Number.parseInt(widthMatch[1], 10), heightPixels: Number.parseInt(heightMatch[1], 10) };
}

async function deleteQuietly(path: string): Promise<void> {
  await unlink(path).catch(() => undefined);
}

/**
 * Loads a JPEG, downsizing a temporary copy if needed. The original file is
 * left untouched and the copy is deleted before returning.
 */
export async function loadScreenshotFromFile(imagePath: string, screenIndex = 1): Promise<Screenshot> {
  const workingCopyPath = join(tmpdir(), `${SPIKE_TEMP_CAPTURE_PREFIX}resize-${Date.now()}.jpg`);
  await copyFile(imagePath, workingCopyPath);
  try {
    await execFileAsync("sips", ["-Z", String(SPIKE_SCREENSHOT_MAX_DIMENSION), workingCopyPath]);
    const dimensions = await readImageDimensions(workingCopyPath);
    const jpegBytes = await readFile(workingCopyPath);
    return {
      screenIndex,
      label: "user's screen (cursor is here)",
      isCursorScreen: true,
      ...dimensions,
      jpegBase64: jpegBytes.toString("base64")
    };
  } finally {
    await deleteQuietly(workingCopyPath);
  }
}

/**
 * Captures one still frame of the main display. Requires Screen Recording
 * permission for the terminal app. The shutter sound plays on purpose.
 */
export async function captureMainDisplay(): Promise<Screenshot> {
  const capturePath = join(tmpdir(), `${SPIKE_TEMP_CAPTURE_PREFIX}${Date.now()}.jpg`);
  process.stdout.write("\n[capturing ONE screenshot of your main display now]\n");
  await execFileAsync("screencapture", ["-t", "jpg", "-D", "1", capturePath]);
  try {
    return await loadScreenshotFromFile(capturePath, 1);
  } finally {
    await deleteQuietly(capturePath);
  }
}
