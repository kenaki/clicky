# Prototype Plan

The plan in [architecture.md](architecture.md) rests on a handful of assumptions. This document
lists every way we can test them cheaply, then the spikes we will actually run, in order, with
pass/fail criteria. Update the status table as spikes run.

## The assumptions we are testing

| # | Assumption | If false |
|---|---|---|
| A1 | The Agent SDK accepts screenshots as image blocks in streaming input mode and Claude will call custom annotation tools with usable coordinates. | Fall back to text tags parsed from the final response, as upstream does. |
| A2 | An Agent SDK session started by the sidecar can be resumed from a terminal with `claude --resume`. | Lose the "talk, then continue in the terminal" feature. Still viable. |
| A3 | Speech-to-text on the Spark returns a transcript in well under a second for a five-second clip. | Use Apple Speech on the Mac instead; the Spark then only does TTS or nothing. |
| A4 | Text-to-speech on the Spark starts playing a sentence in under 300 ms. | Use Kokoro on the Mac via MLX, or Apple's synthesizer. |
| A5 | A Swift app can spawn, talk to, and cleanly shut down a Node sidecar over localhost. | Have Swift spawn `claude -p --output-format stream-json` directly and lose in-process tools. |
| A6 | Agent-length turns, with tool calls, are tolerable in a voice interface given progress narration. | Constrain the agent to read-only tools by voice and reserve edits for the terminal. |
| A7 | Coordinates from tool calls are at least as accurate as upstream's end-of-response tag. | Add a second grounding call, as upstream's dead `ElementLocationDetector` did. |
| A8 | Spoken permission prompts via `canUseTool` feel natural and are safe enough. | Run in plan mode by voice and apply edits only from the terminal. |

## Ways to prototype

These are the approaches available. The spike list below picks from them.

**Tracer bullet with no Swift changes.** A CLI script on the Mac: `screencapture` for the
screenshot, a typed or pre-recorded transcript, the sidecar's agent session, tool calls printed
to the terminal, the reply spoken with macOS `say`. Exercises the riskiest new code, the Agent
SDK integration, without touching Xcode or TCC permissions. This is Spike 0.

**Stand-ins to isolate one risk at a time.** Apple Speech stands in for Spark STT. macOS `say`
stands in for Spark TTS. `claude -p` stands in for the sidecar. Each stand-in lets one real
component be swapped in and measured alone.

**Bottom-up component spikes.** One spike per assumption, each a short script with a number
at the end. Spikes 1 through 3 and 8 and 9.

**Wizard-of-Oz for the voice UX.** Type transcripts instead of speaking, and listen to real
agent responses through TTS, to learn what progress narration is needed before building
anything for it. Part of Spike 0 and Spike 7.

**Measure first.** Every hop timestamps from day one (see conventions). The latency budget in
architecture.md becomes a measured table, not a guess. Spike 8.

**Vertical slice last.** Only after the components pass do we wire the Swift app to the sidecar.
Spike 4 onward.

## The spikes

Each spike is one script or one small branch. "Needs" lists what must exist first.

| # | Spike | Tests | Needs | Pass criteria |
|---|---|---|---|---|
| 0 | Tracer bullet: `agent-sidecar` CLI sends a screenshot plus a typed question into a streaming-input Agent SDK session with the `claude_code` preset and clicky's persona appended; `point_at`, `circle_region`, `take_screenshot` are real tools whose handlers print. Prints the session id. | A1, A2, A6 | Anthropic API key. | Claude calls `point_at` with coordinates inside the image bounds on a "where is X" question at least 8 of 10 times. `claude --resume <id>` in a terminal continues the conversation. Time to first text delta logged. |
| 1 | Spark STT: post a 5 s WAV to the Spark's `/v1/audio/transcriptions`, time it, check the words. | A3 | Spark hostname; an STT server on it. | Under 700 ms end to end on the LAN, transcript correct. |
| 2 | Spark TTS: post one sentence to `/v1/audio/speech`, time to first byte, play with `afplay`. | A4 | Spark hostname; a TTS server on it. | Under 300 ms to first byte, voice acceptable to Ken. |
| 3 | IPC seam: run the sidecar WebSocket server; a throwaway Node client sends `client.hello`, `session.start`, one `user.utterance` with a screenshot, and prints every event including `overlay.*` and `permission.request`. | A5 | Spike 0. | Full round trip, including answering a `screenshot.request` and a `permission.request`. |
| 4 | Swift integration: `AgentSidecarClient.swift` replaces `ClaudeAPI` in `sendTranscriptToClaudeWithScreenshot`. App spawns the sidecar at launch. AssemblyAI and ElevenLabs stay for now so only one thing changes. | A5 | Spike 3. | Push-to-talk works end to end with the cursor pointing driven by `overlay.point_at`. Quitting the app kills the sidecar. |
| 5 | Circle gesture: new overlay animation for `overlay.circle_region`. | new UI | Spike 4. | A circle draws around the right element on the right monitor. |
| 6 | Spoken permissions: `canUseTool` → `permission.request` → TTS asks → user says yes or no → `permission.decision`. | A8 | Spikes 2 and 4. | An edit is applied only after a spoken yes. A timeout denies. |
| 7 | Progress narration and barge-in: speak short status lines from streamed assistant text during tool use; hotkey press interrupts the turn and stops playback. | A6 | Spike 4. | No silent gap longer than 5 s during a multi-tool turn. Interrupt stops audio within 200 ms. |
| 8 | Latency budget: instrument every hop with the envelope timestamps and produce the measured table for architecture.md. | all | Spikes 1, 2, 4. | Table filled in. |
| 9 | Pointing accuracy: 20 fixed screenshots with known target coordinates; compare tool-call coordinates to ground truth and to upstream's tag method. | A7 | Spike 0. | Median error under 3 percent of screen width, no worse than upstream. |

Spikes 0, 1, and 2 are independent and can run in parallel once the Spark is reachable. Spikes 1
and 2 can be started today with stand-ins on the Mac to build the harness, then pointed at the Spark.

## Status

| Spike | Status | Date | Result |
|---|---|---|---|
| 0 | code written, typechecks, not yet run | 2026-09-27 | Needs ANTHROPIC_API_KEY in agent-sidecar/.env. Run `npm run spike:tracer-bullet -- --question "where is the search bar"`. |
| 1 | not started | | |
| 2 | not started | | |
| 3 | transport verified; agent round trip pending | 2026-09-27 | Hello handshake, second-client refusal, malformed-frame handling, and session-not-started guard pass against the live server with no API call. Full round trip with `npm run spike:ipc-client` needs an API key. |
| 4 | not started | | |
| 5 | not started | | |
| 6 | not started | | |
| 7 | not started | | |
| 8 | not started | | |
| 9 | not started | | |

## Kill criteria

Stop and rethink if any of these happen:

- Spike 0 cannot get Claude to call the annotation tools reliably even with explicit instruction. Then the pointing design reverts to text tags and the sidecar is only worth it for the Claude Code environment features.
- Spike 1 and 2 both fail their latency targets on the Spark and on the Mac. Then the voice loop stays on the cloud services and the project narrows to the Agent SDK brain.
- Spike 7 shows that tool-using turns cannot be made to feel responsive by voice. Then voice becomes read-only questions and pointing, and edits stay in the terminal.
