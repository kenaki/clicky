# IPC Protocol: Swift app ↔ agent-sidecar

Version 1. JSON messages over a WebSocket on `127.0.0.1`. One client at a time.

The zod schemas in `agent-sidecar/src/protocol/messages.ts` are the executable form of this
document. When they disagree, the schemas are right and this doc has a bug.

## Transport

- The app spawns the sidecar with `--port <n>` (default 47821) and, optionally, the environment
  variable `CLICKY_SIDECAR_TOKEN`. The sidecar prints `listening on ws://127.0.0.1:<n>` to stdout
  once ready; the app waits for that line before connecting.
- The first message from the app must be `client.hello`. Anything else before it is answered
  with `error` code `hello_required` and the socket is closed.
- The sidecar exits when the socket closes and its parent process id no longer exists.

## Envelope

Every message in both directions:

```json
{
  "protocolVersion": 1,
  "type": "user.utterance",
  "messageId": "b2c1…",
  "sentAtMs": 1790000000000,
  "payload": { }
}
```

`messageId` is a UUID from the sender. `sentAtMs` is Unix time in milliseconds on the sender's
clock; both sides run on the same machine so the clocks agree and hop latency is measurable.

## Shared shapes

**Screenshot**

```json
{
  "screenIndex": 1,
  "label": "screen 1 of 2 — cursor is on this screen (primary focus)",
  "isCursorScreen": true,
  "widthPixels": 1280,
  "heightPixels": 800,
  "jpegBase64": "…"
}
```

`screenIndex` is 1-based and matches the `:screenN` convention upstream used. Coordinates in
`overlay.*` messages are in this screenshot's pixel space, origin top-left. The app owns the
conversion to display points and AppKit coordinates.

## App → sidecar

| type | payload | Notes |
|---|---|---|
| `client.hello` | `{ clientName, token? }` | Must be first. |
| `session.start` | `{ projectDirectory, resumeSessionId?, permissionMode }` | `permissionMode` is one of `default`, `plan`, `acceptEdits`. Starts or resumes the agent session. |
| `user.utterance` | `{ utteranceId, transcript, screenshots: Screenshot[] }` | One voice turn. `screenshots` may be empty for a follow-up that does not need the screen. |
| `user.interrupt` | `{ utteranceId? }` | Stop the current turn. The sidecar calls the SDK's interrupt. |
| `permission.decision` | `{ permissionRequestId, decision, denialReason? }` | `decision` is `allow` or `deny`. |
| `screenshot.captured` | `{ screenshotRequestId, screenshots: Screenshot[] }` | Reply to `screenshot.request`. |

## Sidecar → app

| type | payload | Notes |
|---|---|---|
| `sidecar.hello` | `{ sidecarVersion, protocolVersion }` | Reply to `client.hello`. |
| `session.ready` | `{ sessionId, projectDirectory }` | The SDK init message arrived. `sessionId` is what `claude --resume` takes. |
| `agent.status` | `{ utteranceId, phase, toolName? }` | `phase` is `thinking`, `using_tool`, or `idle`. Drives the spinner and progress narration. |
| `assistant.text_delta` | `{ utteranceId, text }` | Incremental text as Claude writes it. |
| `assistant.turn_complete` | `{ utteranceId, spokenText, sessionId, durationMs, costUsd? }` | `spokenText` is the full final assistant text for this turn, what TTS should read. |
| `overlay.point_at` | `{ x, y, label, screenIndex }` | Fly the cursor to this point. |
| `overlay.circle_region` | `{ x, y, width, height, label, screenIndex }` | Draw a circle or rounded highlight around this rectangle. |
| `overlay.clear` | `{}` | Remove annotations. |
| `screenshot.request` | `{ screenshotRequestId }` | Claude called `take_screenshot`. The app must answer with `screenshot.captured` within 5 s or the tool returns an error to Claude. |
| `permission.request` | `{ permissionRequestId, toolName, input, spokenSummary }` | `spokenSummary` is a one-sentence, ear-friendly description the app can read aloud, for example "want me to edit CompanionManager.swift?". The app must answer within 30 s or the sidecar denies. |
| `error` | `{ code, message, utteranceId? }` | Never fatal to the session unless `code` starts with `session_`. |

## Sequences

**Normal turn**

```
app → user.utterance
sidecar → agent.status {thinking}
sidecar → assistant.text_delta ×N
sidecar → overlay.point_at
sidecar → assistant.turn_complete
```

**Agent looks again**

```
sidecar → screenshot.request
app → screenshot.captured
(turn continues)
```

**Spoken permission**

```
sidecar → agent.status {using_tool, Edit}
sidecar → permission.request {spokenSummary: "want me to edit the panel view?"}
(app speaks it, listens)
app → permission.decision {allow}
```

**Interrupt**

```
app → user.interrupt
sidecar → error {code: "turn_interrupted"}
```

## Error codes

| code | meaning |
|---|---|
| `hello_required` | First message was not `client.hello`. |
| `unauthorized` | Token mismatch. |
| `protocol_version_unsupported` | Bump the client or the sidecar. |
| `malformed_message` | Failed zod validation. `message` contains the issue path. |
| `client_already_connected` | A second client tried to connect. |
| `session_not_started` | `user.utterance` before `session.start`. |
| `session_failed` | The SDK query ended with an error result. Payload `message` has the SDK text. |
| `turn_interrupted` | The turn was stopped by `user.interrupt`. |
| `screenshot_timeout` | The app did not answer `screenshot.request` in time. |
| `permission_timeout` | The app did not answer `permission.request` in time. Treated as deny. |
