# ADR 0002: Write the sidecar in TypeScript, not Python

Date: 2026-09-27. Status: accepted.

## Context

The Agent SDK ships in both languages. Ken's Mac has Node 24 and Python 3.13.

## Decision

TypeScript.

## Reasons

- The TypeScript SDK's in-process tools support the fuller result shapes. Per the SDK docs, the
  Python `@tool` decorator forwards only `content` and `is_error` and drops `structuredContent`,
  binary resources, and audio blocks.
- `persistSession`, the array-form system prompt with a cache boundary, and `resourceLinks` on
  tool results are TypeScript-only.
- Zod schemas serve both as tool input schemas for the SDK and as validators for the IPC protocol,
  so one library covers both boundaries.
- Bundling a Node runtime with a Mac app is a well-worn path.

## Consequences

- Ken's local ML tooling is Python-heavy; that is fine because the Spark's voice servers are
  separate services reached over HTTP, not imported by the sidecar.
