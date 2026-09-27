/**
 * Shapes shared by several message types and by the agent layer.
 * The zod schemas validate wire input; the inferred types are used everywhere.
 */
import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

export const screenshotSchema = z.object({
  /** 1-based, matching upstream Clicky's `:screenN` convention. */
  screenIndex: z.number().int().min(1),
  /** Human-readable label, e.g. "screen 1 of 2 — cursor is on this screen". */
  label: z.string(),
  isCursorScreen: z.boolean(),
  widthPixels: z.number().int().positive(),
  heightPixels: z.number().int().positive(),
  jpegBase64: z.string().min(1)
});
export type Screenshot = z.infer<typeof screenshotSchema>;

/** The subset of Agent SDK permission modes the voice app is allowed to request. */
export const permissionModeSchema = z.enum(["default", "plan", "acceptEdits"]);
export type VoicePermissionMode = z.infer<typeof permissionModeSchema>;

export type AgentPhase = "thinking" | "using_tool" | "idle";

export interface ScreenshotBounds {
  widthPixels: number;
  heightPixels: number;
}

/** Coordinates are in the screenshot's pixel space, origin top-left. */
export interface PointAtCommand {
  x: number;
  y: number;
  label: string;
  screenIndex: number;
}

export interface CircleRegionCommand {
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
  screenIndex: number;
}

export type OverlayCommand =
  | ({ kind: "point_at" } & PointAtCommand)
  | ({ kind: "circle_region" } & CircleRegionCommand);

export interface PermissionRequest {
  permissionRequestId: string;
  toolName: string;
  input: Record<string, unknown>;
  /** One ear-friendly sentence the app can read aloud. */
  spokenSummary: string;
}

export type PermissionDecision =
  | { decision: "allow" }
  | { decision: "deny"; denialReason?: string | undefined };
