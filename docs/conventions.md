# Conventions

These rules apply to everything in this fork. Clicky's upstream rules in the root `AGENTS.md`
still apply to the Swift code; this file adds the rules for the sidecar, the protocol, and the docs.

## Naming, everywhere

Inherited from upstream and extended to TypeScript:

- Optimize for clarity over concision. A reader with zero context should understand a name on first read.
- No single-character names. No abbreviations that are not universally known (`id`, `url`, `json` are fine; `txt`, `cfg`, `msg` are not).
- Pass values under the same name they had in the caller. Do not rename `screenshotRequestId` to `id` at a function boundary.
- Booleans read as predicates: `isCursorScreen`, `hasDeliveredFinalTranscript`, `shouldSpeakProgress`.
- Functions are verbs: `sendUtterance`, `forwardOverlayCommand`, `awaitPermissionDecision`.

## Sidecar module boundaries

```
src/
  protocol/   Pure. Message types and zod schemas. Imports nothing from other layers. No I/O.
  config/     Loads and validates environment into a typed config object. No I/O beyond env.
  agent/      Wraps the Agent SDK: session lifecycle, tools, system prompt. Imports protocol + config.
  server/     WebSocket transport. Translates wire messages to agent calls and back. Imports agent + protocol.
  cli/        Entry points and spikes. Wires config, agent, server together. Imports everything.
```

Dependencies point inward only: `cli → server → agent → protocol`. `protocol` never imports
`agent`; `agent` never imports `server`. If you find yourself needing the reverse, pass a
callback or an interface down instead.

## Validate at every boundary

- Every message off the WebSocket is parsed with its zod schema before any code touches it. Unknown or malformed messages are answered with an `error` message and logged, never thrown across the socket.
- Every tool call argument from Claude is already zod-validated by the SDK; still clamp coordinates to the screenshot bounds before forwarding.
- Every environment variable goes through `config/`. Nothing reads `process.env` directly elsewhere.

## Errors

- Define error classes per failure domain (`ProtocolError`, `SessionError`, `TransportError`). Carry a `code` string the Swift side can switch on.
- Never swallow. Catch only to add context or to convert to a wire `error` message.
- A failure in one utterance must not kill the session. A failure in the session must not kill the process without a clear log line saying why.

## Concurrency and lifecycle

- One agent session per process. The WebSocket accepts one client at a time; a second connection is refused with a clear error.
- The sidecar exits when the socket closes and the parent process is gone, so a crashed app never leaves an orphan.
- Every request that expects a reply (`screenshot.request`, `permission.request`) carries an id and a timeout. Timeouts resolve as a deny or an error result to Claude, never as a hang.

## Logging and measurement

- Structured, one line per event, prefixed with the component: `[server]`, `[session]`, `[tools]`.
- Every hop timestamps. The `sentAtMs` field on the envelope plus the `durationMs` fields on completions are how Spike 8 measures the latency budget. Do not remove them to "simplify".
- No secrets in logs. Screenshot payloads are logged by size only.

## Testing

- Pure logic gets unit tests with vitest: protocol parsing, coordinate clamping, sentence splitting, config validation.
- Spikes are scripts under `src/cli/`, not tests. They cost API money and need a human to judge the result.
- The Swift target keeps upstream's rule: build in Xcode, never `xcodebuild` from a terminal, because it resets TCC permissions.

## Protocol changes

A wire change touches three places in one commit:

1. `docs/ipc-protocol.md`
2. `agent-sidecar/src/protocol/messages.ts`
3. The Swift `Codable` types in the sidecar client

Bump `protocolVersion` on any breaking change. The sidecar rejects a `client.hello` with a
version it does not support.

## Documentation upkeep

- Architectural decisions get an ADR in `docs/decisions/` before the code lands. ADRs are immutable once accepted; supersede, do not edit.
- `.claude/plans/active/agent-sidecar/plan.md` is the living status board. Update its Status table and Changelog when a chunk runs, one line, ≤25 words, numbers not narrative.
- `docs/architecture.md` is updated when a component or a seam changes.
- Root `AGENTS.md` keeps its self-update rules and gets a new row in Key Files for every new source file.

## Privacy rules

- A screen capture is one still frame, taken when the user acts or when the agent asks after
  announcing it. Never a stream.
- Every capture is visible and audible: the spikes print a notice and keep the shutter sound;
  the app must show the indicator described in `docs/privacy.md`. No setting may make a capture
  both silent and invisible.
- Nothing this repo writes to disk keeps a screenshot: temp files are deleted before the code
  continues, and image payloads are logged by size only. What Claude Code itself persists is
  documented in `docs/privacy.md` and controlled by `CLICKY_PERSIST_SESSIONS`.
- When a capture or storage path changes, update `docs/privacy.md` in the same commit.
- Never run speech or capture on the user's machine from an assistant session without asking.

## Secrets and git

- No API keys, tokens, or hostnames of Ken's machines in the repo. `.env` is ignored; `.env.example` documents the shape.
- Work on feature branches named `feature/<description>` or `spike/<description>`. Never push to the upstream `farzaa/clicky` remote; add your own remote and push there.
- Commits in imperative mood explaining why.
