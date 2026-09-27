/**
 * Pure helpers that keep annotation coordinates inside the screenshot they
 * refer to. Claude occasionally returns a coordinate one or two pixels past
 * the edge; clamping beats rejecting the whole annotation.
 */
import type { ScreenshotBounds } from "../../protocol/sharedShapes.js";

export interface Point {
  x: number;
  y: number;
}

export interface Region {
  x: number;
  y: number;
  width: number;
  height: number;
}

function clampNumber(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}

export function clampPointToBounds(point: Point, bounds: ScreenshotBounds): Point {
  return {
    x: clampNumber(Math.round(point.x), 0, bounds.widthPixels),
    y: clampNumber(Math.round(point.y), 0, bounds.heightPixels)
  };
}

/**
 * Clamps a rectangle so it lies entirely inside the bounds and keeps at least
 * a 1x1 size. A region whose origin is past the edge collapses to the edge.
 */
export function clampRegionToBounds(region: Region, bounds: ScreenshotBounds): Region {
  const clampedX = clampNumber(Math.round(region.x), 0, Math.max(bounds.widthPixels - 1, 0));
  const clampedY = clampNumber(Math.round(region.y), 0, Math.max(bounds.heightPixels - 1, 0));
  const maximumWidth = bounds.widthPixels - clampedX;
  const maximumHeight = bounds.heightPixels - clampedY;
  return {
    x: clampedX,
    y: clampedY,
    width: clampNumber(Math.round(region.width), 1, Math.max(maximumWidth, 1)),
    height: clampNumber(Math.round(region.height), 1, Math.max(maximumHeight, 1))
  };
}

export function isPointInsideBounds(point: Point, bounds: ScreenshotBounds): boolean {
  return point.x >= 0 && point.y >= 0 && point.x <= bounds.widthPixels && point.y <= bounds.heightPixels;
}
