# ADR 0005: App and sidecar talk over a localhost WebSocket with a versioned JSON envelope

Date: 2026-09-27. Status: accepted.

## Context

The sidecar and the app exchange many small bidirectional messages per turn: text deltas,
overlay commands, screenshot requests that need replies, permission requests that need replies.

## Decision

A single WebSocket on `127.0.0.1`, JSON messages in a common envelope with `protocolVersion`,
`type`, `messageId`, `sentAtMs`, and `payload`. Every message is validated with zod on the
sidecar and decoded with `Codable` on the app. Full contract in `docs/ipc-protocol.md`.

## Alternatives considered

- **HTTP plus SSE.** Fine for sidecar-to-app streaming, but replies from the app to the sidecar
  (screenshots, permission decisions) would need a second channel.
- **stdio JSON lines.** Simplest to spawn, but a debugging client cannot attach, and Spike 3
  wants exactly that.
- **gRPC.** Heavy for two processes on one machine.

## Consequences

- `URLSessionWebSocketTask` on the Swift side, `ws` on the Node side.
- Optional shared token on `client.hello` so a stray local process cannot drive the agent.
- Every request-reply pair carries an id and a timeout; see conventions.
