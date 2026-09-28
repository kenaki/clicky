# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## This fork (kenaki/clicky)

This is Ken's fork. It keeps upstream's Swift app and screen framework, and replaces the cloud
brain and voice services:

- **Brain**: a Node/TypeScript sidecar in `agent-sidecar/` hosting the **Claude Agent SDK**, with
  custom tools for pointing at and circling the screen. It replaces `ClaudeAPI.swift` and the
  Cloudflare Worker. The Swift app talks to it over a localhost WebSocket.
- **Voice**: speech-to-text and text-to-speech move to Ken's DGX Spark behind OpenAI-compatible
  endpoints, replacing AssemblyAI and ElevenLabs.

Read `docs/README.md` first. `docs/architecture.md` has the component map and the seams in the
Swift code; `docs/ipc-protocol.md` is the app↔sidecar contract; `docs/conventions.md` adds the rules
for the sidecar and the protocol; `docs/privacy.md` says exactly what is captured and where it lands,
keep it accurate. The feature plan and its live status are `.claude/plans/active/agent-sidecar/`
(`brief.md`, `plan.md`), in Ken's workflow layout (`~/claude-workflow`).
The upstream sections below still describe the Swift app accurately until the seams are cut.

### Commands
Install: `cd agent-sidecar && npm install` | Type check: `npm run typecheck` | Test: `npm test` | All gates: `npm run typecheck && npm test` (run before handing off a change) | Start: `npm run serve -- --project /abs/path` | Auth: `npm run check-auth` | Privacy: `npm run privacy:list` | Swift: open `leanring-buddy.xcodeproj`, Cmd+R (never `xcodebuild` from a terminal, it resets TCC permissions)

### The weird thing
- The Agent SDK runs on the *terminal* Claude Code login, separate from the desktop app's. `claude auth status` says `loggedIn: false` until `claude auth login`. No API key, ever.
- Claude Code embeds every screenshot in the session transcript under `~/.claude/projects/`. `docs/privacy.md` maps it; `npm run privacy:list` shows it; `CLICKY_PERSIST_SESSIONS=false` stops it and disables `--resume`.
- Plan mode routes non-read-only MCP tools to the permission prompt despite allow rules. The annotation tools are force-allowed in `agent-sidecar/src/agent/permissionRelay.ts`; voice sessions use mode `default`.
- The Swift target directory is `leanring-buddy/` (upstream typo, intentional). `CLAUDE.md` is a symlink to this file.
- In a Claude session, parallel shell calls share one working directory; scripts use absolute paths.
- Upstream gitignored `.claude/`. It is now `.claude/*` with `plans/` and `launch.json` tracked.

### Never touch without asking
- `agent-sidecar/.env` and anything matching `.env*`, `*.pem`, `*.key`. Never print a secret.
- `~/.claude/settings.json`, hooks, permissions, or anything under `~/.claude/` (global rule).
- `leanring-buddy.xcodeproj/project.pbxproj` beyond adding the files a chunk names.
- The `upstream` remote (farzaa/clicky) and the fork's `main`.
- Anything that captures the screen or plays audio on Ken's Mac from an assistant session.

### Architectural decisions
- Agent SDK in a Node sidecar, not in-process — Swift cannot embed the SDK. ADR 0001.
- TypeScript sidecar — fuller in-process tool results than Python. ADR 0002.
- Pointing via tools, not `[POINT:]` tags — typed, mid-turn, several per turn. ADR 0003. ⚠ accuracy vs upstream unmeasured (chunk 9).
- Spark speech behind OpenAI-compatible endpoints — model swaps never touch the app. ADR 0004.
- Localhost WebSocket, versioned JSON envelope — `docs/ipc-protocol.md`. ADR 0005.
- Claude Code login, never an API key — one bill. ADR 0001 amendment.
- `claude-opus-5-5` at effort `low` for voice turns, sentence-streamed speech — 3.2 s to first speech measured.

### Out of scope
- Clicking or typing on the Mac. Annotate only in v1.
- Wake word or continuous listening. Push-to-talk stays.
- A local LLM. Claude stays the brain.
- Offering this to other users. It runs on Ken's own login.

### Stack & doc references
Verify against live docs before implementing; confirm the **installed** version, not the latest.
- Claude Agent SDK (`@anthropic-ai/claude-agent-sdk` 0.3.283) — docs `https://code.claude.com/docs/en/agent-sdk/`; the installed `node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts` is the ground truth when the docs page truncates.
  - ⚠️ `canUseTool` options require `toolUseID` and `requestId` (`sdk.d.ts:213`); `effort` is `low|medium|high|xhigh|max` (`sdk.d.ts:688`); `persistSession` is TypeScript-only.
- zod (`zod` 4.6.5, the SDK's peer) — `tool()` takes a raw zod shape.
- ws (`ws` 8.18) — ESM named exports `WebSocketServer`, `WebSocket`.
- Node 24 — `process.loadEnvFile`, global `WebSocket` client, `util.parseArgs`.
- macOS: ScreenCaptureKit `SCScreenshotManager.captureImage` (14.2+); Sparkle 2.9; PostHog 3.47 (`Package.resolved`).

### Git commits
- Claude may commit and push to feature branches on `origin` (kenaki/clicky) when Ken asks in the session. Never to `main`, never to `upstream`. Otherwise stage and hand off.
- Messages in the global format: one imperative subject, a few one-line plain-English bullets, one test-status line. No ticket ids, no co-author trailer.

### Docs
- Per-area docs in `docs/` (architecture, IPC protocol, conventions, privacy, ADRs). `docs/prototype-plan.md` is rationale only.
- Plans: `.claude/plans/{backlog,active,archived}/<slug>/`; current feature `active/agent-sidecar/`. Findings: `to-fix/`.

### agent-sidecar quick reference

```bash
cd agent-sidecar
npm install
cp .env.example .env            # set CLICKY_PROJECT_DIRECTORY; auth is your Claude Code login, no API key
claude auth login               # once, if `claude auth status` says loggedIn false
npm run check-auth              # one tiny request; prints which credentials the SDK used
npm run typecheck && npm test
npm run spike:tracer-bullet -- --question "where is the search bar" --speak   # Spike 0
npm run serve -- --port 47821 --project /path/to/project                       # WebSocket server
```

Layers, dependencies pointing inward only: `cli → server → agent → protocol` (plus `config`,
`logging`, `util`). See `docs/conventions.md`.


## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1283 | Central state machine. In this fork, voice turns go to the agent sidecar (`sendTranscriptToClaudeWithScreenshot` → `handleAgentSidecarMessage`); every agent capture goes through `captureScreensVisiblyForAgent`. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~826 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionTranscriptPanel.swift` | ~360 | Frosted, click-through panel pinned top right of the cursor's screen: the user's question and the answer streaming in sentence by sentence, with a blue bar on the sentence being spoken. Fades 6 s after the last word. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `AgentSidecarMessages.swift` | ~205 | Codable form of `docs/ipc-protocol.md`: outgoing envelope and payloads, incoming messages decoded by type. |
| `AgentSidecarClient.swift` | ~197 | `URLSessionWebSocketTask` client for the sidecar: hello handshake with a deadline, typed senders, receive loop on the main actor. |
| `SidecarProcessController.swift` | ~223 | Attach to a sidecar already on port 47821, or spawn one from source (`node --import tsx … serve.ts --parent-pid`) with a per-launch token; stops only what it spawned. |
| `SystemSpeechSentenceQueue.swift` | ~87 | macOS voice: speaks answers when no Spark voice server is configured, and always speaks error fallbacks. Reports which sentence is playing, like the Spark queue. |
| `SparkSpeechSentenceQueue.swift` | ~230 | Spark voice: POSTs each sentence to `SparkSpeechBaseURL` + `/v1/audio/speech` as 24 kHz PCM, plays in enqueue order on one `AVAudioEngine` player node, stop cancels requests and drops queued audio. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

## Key Files (agent-sidecar, this fork)

| File | Purpose |
|------|---------|
| `agent-sidecar/src/cli/serve.ts` | Entry point the Swift app spawns. Prints `listening on ws://127.0.0.1:<port>` to stdout when ready; logs go to stderr. Parent-pid watchdog. |
| `agent-sidecar/src/cli/checkAuth.ts` | Makes one tiny request and reports the credential source (`none` means the Claude Code login). |
| `agent-sidecar/src/cli/ipcClientSpike.ts` | Spike 3 throwaway client that drives the WebSocket server like the Swift app will. |
| `agent-sidecar/src/cli/tracerBulletSpike.ts` | Spike 0. Screenshot + typed question into a real Agent SDK session from the terminal; prints tool calls, timings, and the session id for `claude --resume`. |
| `agent-sidecar/src/cli/privacyInventory.ts` | `npm run privacy:list` and `privacy:clean`: every local copy of a screenshot, listed or deleted. |
| `agent-sidecar/src/cli/macScreenCapture.ts` | `screencapture` + `sips` helpers for the spike; 1280 px max like upstream. |
| `agent-sidecar/src/server/sidecarWebSocketServer.ts` | Localhost WebSocket transport, single client, hello handshake, frame routing. |
| `agent-sidecar/src/server/connectionSessionHost.ts` | Adapts session events to wire messages; parks screenshot and permission requests until the app replies. |
| `agent-sidecar/src/server/pendingReplies.ts` | Request-id to promise registry with per-request timeouts. |
| `agent-sidecar/src/agent/agentSession.ts` | One streaming-input Agent SDK session; attributes SDK messages to the utterance in flight; interrupt and close. |
| `agent-sidecar/src/agent/tools/screenAnnotationTools.ts` | In-process MCP server: `point_at`, `circle_region`, `take_screenshot`. |
| `agent-sidecar/src/agent/tools/coordinateClamping.ts` | Pure clamping of tool coordinates to screenshot bounds. |
| `agent-sidecar/src/agent/sentenceStreamSplitter.ts` | Pure streaming sentence splitter behind `assistant.sentence`, so speech starts on the first sentence. |
| `agent-sidecar/src/agent/permissionRelay.ts` | `canUseTool` bridge; builds the spoken one-sentence permission question. |
| `agent-sidecar/src/agent/voicePersonaPrompt.ts` | Clicky's voice persona, appended to the `claude_code` preset; tool-based pointing instructions. |
| `agent-sidecar/src/protocol/messages.ts` | zod schemas for every wire message; the executable form of `docs/ipc-protocol.md`. |
| `agent-sidecar/src/protocol/sharedShapes.ts` | Screenshot, overlay command, permission shapes shared by layers. |
| `agent-sidecar/src/protocol/errors.ts` | Error classes with stable wire codes. |
| `agent-sidecar/src/config/sidecarConfig.ts` | argv + env to validated config. Only module that reads env. |
| `agent-sidecar/src/logging/logger.ts` | Structured stderr logger. |
| `agent-sidecar/src/util/asyncPushQueue.ts` | Async iterable queue feeding the SDK's streaming input. |
| `agent-sidecar/test/*.test.ts` | vitest unit tests for the pure layers. |
| `spark-tts-server/miso_speech_server.py` | FastAPI server on the DGX Spark: Miso TTS 8B behind OpenAI-compatible `/v1/audio/speech`, voice from a reference clip, one generation at a time, cancels on client disconnect. `README.md` beside it has the Spark layout and install notes. |
