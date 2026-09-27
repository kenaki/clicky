# Architecture

## Goal

A voice companion that lives in the menu bar, sees the screen, can point at and circle things
on it, and can do real work in Ken's codebase the way Claude Code does, sharing sessions with
the terminal. Speech recognition and synthesis run on Ken's own DGX Spark. The language model
is Claude, reached through the Claude Agent SDK.

## Components

```
┌──────────────────────────── MacBook ────────────────────────────┐
│                                                                  │
│  clicky.app (Swift)                agent-sidecar (Node/TS)       │
│  ┌────────────────────────┐        ┌───────────────────────────┐ │
│  │ hotkey (ctrl+option)   │  ws    │ WebSocket server          │ │
│  │ mic capture            │◄──────►│ AgentSession (Agent SDK)  │ │
│  │ screenshots (SCKit)    │localhost│ tools: point_at,         │ │
│  │ overlay: point, circle │        │        circle_region,     │ │
│  │ audio playback         │        │        take_screenshot    │ │
│  └───┬───────────────▲────┘        └─────────────┬─────────────┘ │
│      │ audio         │ audio                     │ HTTPS         │
└──────┼───────────────┼───────────────────────────┼───────────────┘
       │ HTTP          │                           │
┌──────▼───────────────┴────┐              ┌───────▼────────────┐
│ DGX Spark (LAN)            │              │ Anthropic API       │
│ /v1/audio/transcriptions   │              │ (via Agent SDK,     │
│ /v1/audio/speech           │              │  API key)           │
└────────────────────────────┘              └─────────────────────┘
```

| Component | Runs on | Responsibility | Replaces |
|---|---|---|---|
| `clicky.app` | Mac | Hotkey, microphone, screenshots, overlay animations, audio playback, settings. Owns all macOS permissions. | Stays. Loses `ClaudeAPI.swift` and the Worker URLs. |
| `agent-sidecar` | Mac, child process of the app | Hosts one long-lived Agent SDK session with `cwd` set to Ken's project. Defines annotation tools. Relays permission prompts. | `ClaudeAPI.swift`, `worker/`, the system prompt and `[POINT:...]` regex in `CompanionManager.swift`. |
| Spark voice server | DGX Spark | Speech-to-text and text-to-speech behind OpenAI-compatible HTTP endpoints. | AssemblyAI streaming, ElevenLabs. |
| Anthropic API | Cloud | Claude. Billed per token against an API key held by the sidecar. | The Worker's `/chat` proxy. |

## One voice turn, end to end

1. User holds ctrl+option. `BuddyDictationManager` taps the mic and buffers 16 kHz PCM16.
2. User releases. The app posts a WAV to the Spark transcription endpoint and gets text back.
3. The app captures every display with `CompanionScreenCaptureUtility` (JPEG, max 1280 px, labeled).
4. The app sends `user.utterance` with the transcript and screenshots to the sidecar over the WebSocket.
5. The sidecar feeds a user message with text and image blocks into the streaming-input Agent SDK query.
6. Claude works. Along the way it may:
   - emit text, which the sidecar forwards as `assistant.text_delta`;
   - call `point_at` or `circle_region`, which the sidecar forwards as `overlay.*` messages;
   - call `take_screenshot`, which the sidecar turns into a `screenshot.request` and blocks on the reply;
   - call a built-in tool like `Edit` or `Bash` in Ken's project, which either runs under the allow rules or goes to `canUseTool`, which the sidecar forwards as `permission.request`;
   - the app speaks the permission question, hears yes or no, and replies `permission.decision`.
7. The turn ends. The sidecar sends `assistant.turn_complete` with the spoken text and the session id.
8. The app sends the spoken text to the Spark speech endpoint, sentence by sentence, and plays it.
9. Later, `claude --resume <session id>` in a terminal picks up the same conversation.

## Why this shape

- **Sidecar, not in-process.** The Agent SDK ships in TypeScript and Python only. See [ADR 0001](decisions/0001-agent-sdk-sidecar.md).
- **Tools, not text tags, for pointing.** Tool calls fire mid-turn, carry typed arguments, and let the agent look again after acting. See [ADR 0003](decisions/0003-annotation-tools-not-text-tags.md).
- **OpenAI-compatible endpoints on the Spark.** Every serious local STT/TTS server speaks them, so the Mac and the Spark are interchangeable presets. See [ADR 0004](decisions/0004-spark-voice-openai-compatible-endpoints.md).
- **The Claude Code system prompt preset plus an appended persona.** So CLAUDE.md, skills, MCP servers, and permission rules from Ken's project all load, and the voice persona layers on top.

## Seams in the existing Swift code

These are the exact places the new pieces attach. Line numbers are from the upstream commit `a80fa80`.

| Seam | File | Notes |
|---|---|---|
| STT provider protocol | `leanring-buddy/BuddyTranscriptionProvider.swift` | `BuddyTranscriptionProvider` and `BuddyStreamingTranscriptionSession`. Factory picks by the `VoiceTranscriptionProvider` Info.plist key. |
| STT upload template | `leanring-buddy/OpenAIAudioTranscriptionProvider.swift` | Already buffers WAV at 16 kHz and posts multipart to an OpenAI-shaped endpoint. Generalize the URL and drop the key requirement to target the Spark. |
| TTS client | `leanring-buddy/ElevenLabsTTSClient.swift` | 81 lines. The app uses only `speakText`, `stopPlayback`, `isPlaying`. Put a protocol in front and add a Spark backend. |
| LLM call | `leanring-buddy/CompanionManager.swift:586` `sendTranscriptToClaudeWithScreenshot` | Replace the `claudeAPI.analyzeImageStreaming` call with a sidecar client call. |
| Pointing parse | `leanring-buddy/CompanionManager.swift:784` `parsePointingCoordinates` | Becomes dead once pointing arrives as `overlay.point_at`. Keep the pixel-to-point scaling below it (lines ~640-680); the tools use the same coordinate convention. |
| Voice persona | `leanring-buddy/CompanionManager.swift:544` | Moves to the sidecar as the `append` text on the `claude_code` preset. |
| Screenshot capture | `leanring-buddy/CompanionScreenCaptureUtility.swift` | Unchanged. Also serves `screenshot.request` from the sidecar. |
| Interruption | `leanring-buddy/CompanionManager.swift:494` | A new hotkey press cancels the response task and stops playback. Extend to send `user.interrupt`. |
| Overlay | `leanring-buddy/OverlayWindow.swift` | Has a triangle that flies to a point. Needs a new circle/highlight gesture. |

## Coordinate convention

Screenshots are sent to Claude at their captured pixel size (max dimension 1280) with a label
stating the dimensions. Claude returns coordinates in that pixel space, origin top-left. The
Swift app scales to display points and converts to AppKit's bottom-left origin. The annotation
tools keep exactly this convention so the existing scaling code stays.

## Latency budget (targets, to be measured in Spike 8)

| Hop | Target |
|---|---|
| Release key to transcript back from Spark | < 500 ms |
| Screenshot capture, all displays | < 150 ms |
| First text delta from Claude | < 2 s |
| Spark TTS time-to-first-audio per sentence | < 300 ms |
| Tool-using agent turn | seconds to minutes. Needs progress narration, not a spinner. |

## Open questions

- Spark hostname and what is already running on it.
- Which project directory the agent works in by default, and whether it is switchable from the panel.
- Annotate-only (point, circle) versus also clicking and typing on the Mac. First version is annotate-only.
