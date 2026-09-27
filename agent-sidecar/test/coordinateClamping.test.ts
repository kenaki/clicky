import { describe, expect, it } from "vitest";
import { clampPointToBounds, clampRegionToBounds, isPointInsideBounds } from "../src/agent/tools/coordinateClamping.js";

const bounds = { widthPixels: 1280, heightPixels: 800 };

describe("clampPointToBounds", () => {
  it("leaves an inside point alone, rounding to integers", () => {
    expect(clampPointToBounds({ x: 10.4, y: 20.6 }, bounds)).toEqual({ x: 10, y: 21 });
  });
  it("pulls an outside point back to the edge", () => {
    expect(clampPointToBounds({ x: 1300, y: -5 }, bounds)).toEqual({ x: 1280, y: 0 });
  });
});

describe("clampRegionToBounds", () => {
  it("shrinks a region that overflows the right and bottom edges", () => {
    expect(clampRegionToBounds({ x: 1200, y: 700, width: 200, height: 200 }, bounds)).toEqual({ x: 1200, y: 700, width: 80, height: 100 });
  });
  it("keeps at least a 1x1 region when the origin is past the edge", () => {
    expect(clampRegionToBounds({ x: 5000, y: 5000, width: 10, height: 10 }, bounds)).toEqual({ x: 1279, y: 799, width: 1, height: 1 });
  });
});

describe("isPointInsideBounds", () => {
  it("treats the far edge as inside", () => {
    expect(isPointInsideBounds({ x: 1280, y: 800 }, bounds)).toBe(true);
    expect(isPointInsideBounds({ x: 1281, y: 800 }, bounds)).toBe(false);
  });
});
