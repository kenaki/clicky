# Agent sidecar for Clicky voice — Goal Brief

> **Discovery output & the validated goal.** Written so the framing survives a context reset and so
> `chunk-plan` can consume it as its spec input. This is the "what & why", not the "how".
> **Location:** `.claude/plans/active/agent-sidecar/brief.md` (in `active/` because chunk 0 is ☑).
> **Slug:** `agent-sidecar`. Plan: `plan.md` in this directory.
> Written 2026-09-27 by hand from the session that made the decisions, not by running `frame-goal`.

---

## Problem / real need
Ken wants a voice companion on his Mac that sees the screen, points at and circles things, and does
real work in his codebase the way Claude Code does, sharing sessions with the terminal. Speech must
run on his own DGX Spark and the model must bill on his Claude Code subscription. Upstream Clicky
has the screen and cursor framework but a fixed cloud stack (AssemblyAI, ElevenLabs, Claude through a
Cloudflare Worker) and a raw Messages API brain with no tools, files, or sessions.

## Success criteria
- Hold ctrl+option, ask about the screen: the cursor lands on the right element and the answer is
  spoken, first sentence audible under 3 s after key release. Measured 3.2 s in chunk 0 run 3.
- The same conversation continues in a terminal with `claude --resume <id>`, and back.
- Claude can edit files in the configured project; every edit asks by voice first.
- Speech-to-text and text-to-speech run on the Spark; no AssemblyAI or ElevenLabs key anywhere.
- No API key: the sidecar runs on the Claude Code login. Verified 2026-09-27, `apiKeySource: none`.
- Every screen capture is visible; `npm run privacy:list` accounts for every local copy.

## Constraints & non-goals
- **Constraints:** Agent SDK ships in TypeScript and Python only, so the brain is a separate process
  (ADR 0001). Swift app keeps upstream's rules: build in Xcode, never `xcodebuild`. Claude Code login
  only, never an API key. macOS 14.2+ for ScreenCaptureKit. Spark speech behind OpenAI-compatible
  endpoints (ADR 0004).
- **Non-goals:** clicking or typing on the Mac (annotate only); wake word or continuous listening
  (push-to-talk stays); a local LLM (Claude stays the brain); offering this to other users (personal
  tool on Ken's own login).

## Assumptions (surfaced)
| # | Assumption | Status |
|---|---|---|
| A1 | Streaming-input SDK accepts image blocks and Claude calls the annotation tools with usable coordinates | confirmed, 3 of 3 runs, identical coordinates |
| A2 | A sidecar session resumes from a terminal with `claude --resume` | unconfirmed; transcripts exist under `~/.claude/projects/`, resume not yet tried |
| A3 | Spark STT under 700 ms for a 5 s clip | unconfirmed; Spark hostname unknown |
| A4 | Spark TTS under 300 ms to first byte | unconfirmed |
| A5 | Swift can spawn, talk to, and kill the sidecar cleanly | partly; transport verified with a Node client, Swift side unbuilt |
| A6 | Agent-length turns are tolerable by voice with narration | partly; sentence streaming built, unmeasured in the app |
| A7 | Tool-call coordinates at least as accurate as upstream's text tag | unconfirmed; n=3 on one screenshot |
| A8 | Spoken permission prompts feel natural and are safe enough | unconfirmed |

## Architectural findings (the decision-axis depth)
- **Already exists:** the whole push-to-talk → screenshot → LLM → TTS → pointing pipeline in
  `leanring-buddy/CompanionManager.swift:586`; a provider protocol in `BuddyTranscriptionProvider.swift`;
  an 81-line TTS client of which three members are used, `ElevenLabsTTSClient.swift`; one-still-per-
  display capture held in memory, `CompanionScreenCaptureUtility.swift`.
- **Where the relevant flow lives:** seams table in `docs/architecture.md`.
- **Load-bearing constraints:** the SDK spawns the Claude Code binary and reads the terminal CLI's
  login, which is separate from the desktop app's. Sessions land in `~/.claude/projects/<encoded cwd>/`
  with every screenshot embedded (`docs/privacy.md`). Plan mode routes non-read-only MCP tools to the
  permission callback despite allow rules (force-allowed in `agent-sidecar/src/agent/permissionRelay.ts`).
  Upstream gitignored `.claude/`, fixed 2026-09-27.
- **Feasibility:** chunk 0 passes. Floor is about 2.5 s to first text with a cold session and a 278 KB
  image; the app keeps the session warm.

## Solution direction
- **Chosen:** the Swift app keeps UI, capture, overlay, and audio. A Node sidecar hosts the Agent SDK
  with in-process `point_at`, `circle_region`, and `take_screenshot` tools, reached over a localhost
  WebSocket. The Spark serves STT and TTS behind OpenAI-shaped endpoints. Claude runs on the Claude
  Code login. Map: `docs/architecture.md`.
- **Rejected alternatives:** Swift spawning `claude -p` directly (no in-process tools, no permission
  callback); raw Messages API plus hand-rolled tools (rebuilds Claude Code); API-key billing (Ken has
  none and wants one bill); Python sidecar (drops `structuredContent` and `persistSession`).

## Decision Register
> Severity = max of: reversibility · blast radius · commitment · risk · genuineness of tradeoff.
> S1 trivial · S2 low · S3 significant · S4 critical. Gate: S3+ surfaced to the user (default mode).
> Status: auto-decided · ⏸ awaiting-you · spike-needed · resolved · overridden.

| ID | Decision | Severity (why) | Status | Chosen / default |
|----|----------|----------------|--------|------------------|
| G-sidecar | Agent SDK in a Node sidecar, not in-process or `claude -p` | S3 (new process boundary, load-bearing) | resolved | sidecar; ADR 0001 |
| G-typescript | TypeScript, not Python, for the sidecar | S2 (contained, swappable) | auto-decided | TypeScript; ADR 0002 |
| G-tools-not-tags | Pointing via MCP tools instead of `[POINT:]` text | S3 (changes the app contract) | resolved | tools; ADR 0003; accuracy check in chunk 9 |
| G-spark-openai | Spark speech behind OpenAI-compatible endpoints | S3 (API contract for the app) | resolved | ADR 0004 |
| G-websocket | Localhost WebSocket with a versioned JSON envelope | S3 (app↔sidecar contract) | resolved | ADR 0005 |
| G-login-auth | Claude Code login, never an API key | S4 (billing and terms) | resolved | login; ADR 0001 amendment; terms are Ken's call |
| G-persist | Session transcripts on disk by default, embedding screenshots | S3 (privacy vs resume) | ⏸ awaiting-you | default true; `CLICKY_PERSIST_SESSIONS` |
| G-annotate-only | No clicking or typing on the Mac in v1 | S3 (safety, scope) | resolved | annotate only |

## Open Questions (surface to human; don't guess)
- **Q-spark-host** — Spark hostname and what speech servers run on it. Blocks chunks 1 and 2.
- **Q-project-dir** — which project the agent works in by default; switchable from the panel? Default: `CLICKY_PROJECT_DIRECTORY`.
- **Q-persist** — keep transcripts by default? See G-persist.
- **Q-mcp-noise** — all global MCP servers load into voice sessions (7 seen, 2 needing auth). Restrict `settingSources` to `project` for voice?

## Handoff → chunk-plan
`plan.md` in this directory was written by hand from the spike list. Run `chunk-plan` on
`agent-sidecar` to re-decompose chunks 4–9 at implementation depth before the Swift work starts.
