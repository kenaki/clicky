/**
 * The in-process MCP server that gives Claude eyes and a pointer:
 *   point_at        → overlay flies the cursor to a point
 *   circle_region   → overlay draws a circle around a rectangle
 *   take_screenshot → asks the host for fresh screenshots, returns them as images
 *
 * Handlers never talk to the wire directly; they call the host interface,
 * which the WebSocket server (or the spike's console host) implements.
 */
import { createSdkMcpServer, tool, type McpSdkServerConfigWithInstance } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { describeUnknownError } from "../../protocol/errors.js";
import type { OverlayCommand, Screenshot, ScreenshotBounds } from "../../protocol/sharedShapes.js";
import type { Logger } from "../../logging/logger.js";
import { clampPointToBounds, clampRegionToBounds } from "./coordinateClamping.js";

export const SCREEN_ANNOTATION_SERVER_NAME = "clicky_screen";

/** Pre-approves every tool on the annotation server so they never prompt. */
export const SCREEN_ANNOTATION_ALLOWED_TOOLS: readonly string[] = [`mcp__${SCREEN_ANNOTATION_SERVER_NAME}__*`];

export interface ScreenAnnotationToolHost {
  /** Bounds of the most recent screenshot for a screen, or null if none seen yet. */
  resolveScreenshotBounds(screenIndex: number): ScreenshotBounds | null;
  handleOverlayCommand(command: OverlayCommand): void;
  /** Must resolve with fresh captures or reject; the tool turns a rejection into an error result. */
  requestScreenshots(): Promise<Screenshot[]>;
}

const screenIndexSchema = z
  .number()
  .int()
  .min(1)
  .default(1)
  .describe("1-based index of the screen, from the image label. Defaults to 1, the cursor screen.");

const labelSchema = z
  .string()
  .min(1)
  .max(60)
  .describe("One to three words naming the element, e.g. 'search bar' or 'save button'.");

function describeScreenshotForModel(screenshot: Screenshot): string {
  return `${screenshot.label} (image dimensions: ${screenshot.widthPixels}x${screenshot.heightPixels} pixels, screen index ${screenshot.screenIndex})`;
}

export function createScreenAnnotationToolServer(
  host: ScreenAnnotationToolHost,
  logger: Logger
): McpSdkServerConfigWithInstance {
  const pointAtTool = tool(
    "point_at",
    "Fly the blue cursor to a point on the user's screen and hold it there. Coordinates are pixels in the screenshot image, origin top-left.",
    {
      x: z.number().int().min(0).describe("Horizontal pixel coordinate in the screenshot."),
      y: z.number().int().min(0).describe("Vertical pixel coordinate in the screenshot."),
      label: labelSchema,
      screenIndex: screenIndexSchema
    },
    async (args) => {
      const bounds = host.resolveScreenshotBounds(args.screenIndex);
      const point = bounds ? clampPointToBounds({ x: args.x, y: args.y }, bounds) : { x: args.x, y: args.y };
      logger.info("point_at", { ...point, label: args.label, screenIndex: args.screenIndex, clamped: Boolean(bounds) });
      host.handleOverlayCommand({ kind: "point_at", ...point, label: args.label, screenIndex: args.screenIndex });
      return { content: [{ type: "text", text: `pointing at ${args.label}` }] };
    }
  );

  const circleRegionTool = tool(
    "circle_region",
    "Draw a circle around a rectangular area of the user's screen. Coordinates are pixels in the screenshot image, origin top-left; x,y is the rectangle's top-left corner.",
    {
      x: z.number().int().min(0).describe("Left edge in screenshot pixels."),
      y: z.number().int().min(0).describe("Top edge in screenshot pixels."),
      width: z.number().int().min(1).describe("Width in screenshot pixels."),
      height: z.number().int().min(1).describe("Height in screenshot pixels."),
      label: labelSchema,
      screenIndex: screenIndexSchema
    },
    async (args) => {
      const bounds = host.resolveScreenshotBounds(args.screenIndex);
      const rawRegion = { x: args.x, y: args.y, width: args.width, height: args.height };
      const region = bounds ? clampRegionToBounds(rawRegion, bounds) : rawRegion;
      logger.info("circle_region", { ...region, label: args.label, screenIndex: args.screenIndex, clamped: Boolean(bounds) });
      host.handleOverlayCommand({ kind: "circle_region", ...region, label: args.label, screenIndex: args.screenIndex });
      return { content: [{ type: "text", text: `circling ${args.label}` }] };
    }
  );

  const takeScreenshotTool = tool(
    "take_screenshot",
    "Capture the user's screen(s) right now and return the images. Use this to look again after you changed something, instead of guessing.",
    {},
    async () => {
      try {
        const screenshots = await host.requestScreenshots();
        logger.info("take_screenshot", { screenshotCount: screenshots.length });
        return {
          content: screenshots.flatMap((screenshot) => [
            { type: "text" as const, text: describeScreenshotForModel(screenshot) },
            { type: "image" as const, data: screenshot.jpegBase64, mimeType: "image/jpeg" }
          ])
        };
      } catch (error) {
        logger.warn("take_screenshot failed", { error: describeUnknownError(error) });
        return {
          content: [{ type: "text", text: `could not capture the screen: ${describeUnknownError(error)}` }],
          isError: true
        };
      }
    },
    { annotations: { readOnlyHint: true } }
  );

  return createSdkMcpServer({
    name: SCREEN_ANNOTATION_SERVER_NAME,
    version: "1.0.0",
    instructions: "Tools for pointing at, circling, and re-capturing the user's screen.",
    tools: [pointAtTool, circleRegionTool, takeScreenshotTool],
    // Keep the schemas in the initial prompt so Claude can point on the very first turn
    // instead of discovering the tools through tool search.
    alwaysLoad: true
  });
}
