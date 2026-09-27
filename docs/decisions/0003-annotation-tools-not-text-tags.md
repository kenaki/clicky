# ADR 0003: Pointing and circling are tool calls, not text tags

Date: 2026-09-27. Status: accepted.

## Context

Upstream asks Claude to append `[POINT:x,y:label:screenN]` to the end of its reply and parses it
with a regex anchored at end-of-string (`CompanionManager.swift:784`). It works, but it fires
only once, only at the end, only for a single point, and any formatting slip breaks it.

## Decision

The sidecar registers an in-process MCP server with three tools:

- `point_at(x, y, label, screenIndex)`
- `circle_region(x, y, width, height, label, screenIndex)`
- `take_screenshot()` which returns fresh image blocks

The persona prompt tells Claude to use them. Their handlers forward `overlay.*` messages to the
app. Coordinates keep upstream's convention: screenshot pixel space, origin top-left.

## Consequences

- Multiple annotations per turn, fired mid-turn, so the cursor can move while Claude is still
  talking.
- Typed, validated arguments; no regex.
- `take_screenshot` lets the agent verify its own edits visually.
- Risk: Claude may point less accurately through a tool than through the end-of-response tag,
  because the tag came with the image in the same turn. Spike 9 measures this against upstream.
- The tools must be listed in `allowedTools` so they never trigger a permission prompt.
