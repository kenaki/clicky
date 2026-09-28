# Agent sidecar for Clicky voice — Feature Development Doc

> **Living master plan & single source of truth.** Written so a fresh, uncontextualized session can
> pick up any unstarted chunk, execute it, verify it, and mark it done — without the original
> conversation. Keep the Status table + Changelog current.
> **Location:** `.claude/plans/active/agent-sidecar/plan.md` (promoted from backlog at chunk 0's ☑).
> Archive the whole directory to `.claude/plans/archived/agent-sidecar/` when every build-now chunk is ☑.
> Spec input: `brief.md` beside this file. Reference docs: `docs/` (architecture, ipc-protocol, conventions, privacy, decisions).

---

## SESSION HANDOFF — resume here
**State at handoff (2026-09-28):** chunks 0, 2, 3, 4 ☑; chunk 7 ◐; 1, 5, 6, 8, 9 ☐. Sidecar typechecks,
50 unit tests pass; Swift typechecks against stub PostHog/Sparkle modules (no `xcodebuild`).
Branch `feature/agent-sidecar-prototype`. Chunk 4, the Spark voice, spark-tts-server/ and docs are
committed (Ken's pbxproj signing-team change is deliberately left unstaged; the project uses
file-system synchronized groups, so new Swift files need no pbxproj edit).
**Voice switched to Kokoro (2026-09-28, Ken):** Kokoro-FastAPI container on the Spark, RTF ~0.1; Miso stopped. Details in the tech-scout. Before that, answers were spoken by Miso TTS 8B on the Spark (Ken chose it over Kokoro despite
RTF 2.8; see `.claude/plans/backlog/spark-tts-server/tech-scout.md`). Server: `spark-tts-server/`,
running on the Spark from `~/clicky-voice` via `run_on_spark.sh` (manual start, not on boot). App:
`SparkSpeechSentenceQueue.swift`, enabled by the `SparkSpeechBaseURL` user default (already set on Ken's Mac).
**Ken's run (2026-09-28) confirmed** in-order playback. Lag is Miso itself: ~15–20 s to first speech,
~14 s gaps, server busy back to back. **In progress: transcript panel** — pinned top right, transparent,
same look as the existing UI, full answer streams in while the voice reads along (current sentence
highlighted). **Built, typechecked, NOT committed — waiting on Ken's Xcode run:** `CompanionTranscriptPanel.swift`
(replaces the unused `CompanionResponseOverlay.swift`); both speech queues report the playing sentence.
Voice reads everything for now; "speak a short version only" is Ken's open choice.
**Next, in Ken's order:** transcript panel → persona/voice polish if needed → later, Miso speed
(CUDA graph for the 31-pass decoder, int8/int4, streaming) → then chunks 5, 6, 8, 9 and Spark STT (1).
**To resume:** 1) read this whole file; 2) read `brief.md` and `docs/conventions.md`; 3) do the next ☐
chunk in dependency order — **one chunk per session**; 4) at the end: verify → commit → update Status +
Changelog → announce "✅ Chunk X complete — safe to clear context" → stop.
**Paste-able resume prompt — re-runnable: paste the SAME text on first run and on every resume after `/clear`:**
> Continue agent-sidecar. Locate its plan by slug — read `.claude/plans/active/agent-sidecar/plan.md` if it
> exists, else `.claude/plans/backlog/agent-sidecar/plan.md` — in full. Figure out where things stand by
> reading the Status table AND cross-checking `git log` (one chunk = one commit), then pick the next
> unstarted chunk in dependency order — don't assume a chunk number. Implement exactly that ONE chunk
> (reuse existing primitives per the Reference index; smallest faithful diff). Verify it with the doc's
> verify steps; if red, fix or report — do not commit red. Commit just that chunk (one chunk = one
> commit). Update the Status table + a one-line (≤25-word) Changelog entry — the commit carries the
> detail, don't re-narrate it. Then announce "✅ Chunk <n> complete and verified — safe to clear context.
> Next: <the chunk you'd do next>" and stop (or continue to the next chunk if I ask). If that was the
> last build-now chunk, archive the feature directory per the Completion section.

---

## How to use this document (read first, every session)
1. `brief.md` and the ADRs in `docs/decisions/` are law. Never invent a value → Open Questions.
2. Reuse before create. Smallest faithful diff. Swift code follows upstream's `AGENTS.md` rules; sidecar
   code follows `docs/conventions.md` (layers point inward: `cli → server → agent → protocol`).
3. **Per-chunk workflow:** read referenced files → implement → verify → update Status + Changelog →
   note new Open Questions → **announce it's safe to clear context** → stop. **One chunk per session.**
4. Gotchas that bit already: the Agent SDK reads the *terminal* Claude Code login (`claude auth login`),
   not the desktop app's; plan mode sends non-read-only MCP tools to the permission prompt regardless of
   allow rules; parallel shell calls in a Claude session share one working directory, so scripts use
   absolute paths; `xcodebuild` from a terminal resets TCC permissions, build in Xcode.

### Context-clear checkpoints (one chunk per session)
Every chunk is a checkpoint. At the end of each: (1) verify, (2) mark ☑ + Changelog line, (3) record
decisions/Open Questions, (4) tell the user "✅ Chunk X complete and verified — safe to clear context.
Next: Chunk Y." then **stop**. Don't roll into the next chunk in the same session unless asked.

### Completion & archival
When the **final build-now chunk is ☑ done**: append a Changelog line ("All chunks complete — archived
<date>"), then move the whole feature directory to `.claude/plans/archived/agent-sidecar/` and tell
the user the plan is complete and archived.

### Status table
| Chunk | Title | Status | Owner / session | Notes |
|------:|-------|--------|-----------------|-------|
| 0 | Tracer bullet: screenshot + question through the Agent SDK, tools, session id | ☑ done | 2026-09-27 | 3 runs; 3.2 s to first speech |
| 1 | Spark STT probe | ☐ todo | | Spark reachable; same server pattern as TTS |
| 2 | Spark TTS probe | ☑ done | 2026-09-27 | Miso on Spark, RTF 2.8; see spark-tts-server tech-scout |
| 3 | IPC round trip through the WebSocket server | ☑ done | 2026-09-27 | screenshot + deny paths live; watchdog exits in 2 s |
| 4 | Swift sidecar client, spawn/kill, capture indicator | ☑ done | 2026-09-27 | Ken's Xcode run passed; interim Apple Speech + macOS voice |
| 5 | Circle gesture in the overlay | ☐ todo | | needs 4 |
| 6 | Spoken permissions | ☐ todo | | needs 2, 4 |
| 7 | App-side sentence playback + barge-in | ◐ in progress | 2026-09-28 | order verified; gap check fails on Miso speed |
| 8 | Latency budget, measured table | ☐ todo | | needs 1, 2, 4 |
| 9 | Pointing accuracy vs upstream's tag | ☐ todo | | needs 0 only |
Legend: ☐ todo · ◐ in progress · ☑ done · ⏸ blocked · ⊘ deferred. Notes ≤10 words — a pointer, not a summary.

### Changelog
> One line per chunk, ≤25 words — details live in git. Multi-line only for incidents / scope changes.
- 2026-09-27 — Chunk 0 ☑: three runs, point_at (1111, 9) each time, low effort, sentence streaming; 3.2 s to first speech. Commits ca72cc4…177714c.
- 2026-09-27 — Chunk 3 ◐: hello, second-client refusal, malformed frame, session-not-started verified live; agent round trip pending.
- 2026-09-27 — Privacy: temp-capture leak fixed, `privacy:list`/`clean`, `CLICKY_PERSIST_SESSIONS`, capture indicator added to chunk 4. Commit 97ac5ef.
- 2026-09-27 — Chunk 3 ☑: take_screenshot reply, point_at, spoken deny all live; parent watchdog exits in ~2 s. Turns cost $0.24–0.37.
- 2026-09-27 — Chunk 4 ☑: voice turn end to end in Xcode, cursor flew, border flashed, no orphan sidecar. Fixed `screenIndex` rejected when omitted.
- 2026-09-27 — Chunk 2 ☑ (reshaped by tech-scout): Miso TTS 8B served on the Spark, 221 ms/80 ms frame. Chunk 7 ◐: SparkSpeechSentenceQueue, in-order playback, cancel frees GPU.
- 2026-09-28 — Chunk 7 ◐: Spark requests serialized (out-of-order generation stalled playback); short-sentence merge; conversational persona. 50 tests.
- 2026-09-28 — Chunk 7 ◐: Ken's run plays every sentence in order; gaps ~14 s are Miso RTF 2.8 (server never idle), not the app.
- 2026-09-28 — Transcript panel built (top right, frosted, read-along highlight); typechecked; awaiting Ken's Xcode run.
- 2026-09-28 — Voice switched to Kokoro on the Spark (0.5 s per sentence); `SparkSpeechModel` user default added. Awaiting Ken's Xcode run.
- 2026-09-27 — Ken's workflow integrated: this plan and `brief.md`; `.claude/plans` un-ignored; AGENTS.md follows the project template.

### Produced values (runtime handoffs)
| Key | Value | Producer | Consumed by | Filled? |
|-----|-------|----------|-------------|---------|
| spark_base_url | _(pending — Chunk 1)_ | Chunk 1 | Chunks 2, 4, 6, 8 | ☐ |
Legend: ☐ pending · ☑ filled.

---

## Context — why
See `brief.md`. Build-now: chunks 0–9. Deferred: wake word, computer use, local LLM (below).

## Decisions log
| # | Question | Decision |
|--:|----------|----------|
| 1 | Where does pointing logic live? | Sidecar tools; the Swift app keeps only pixel-to-point scaling (`CompanionManager.swift` ~640–680). |
| 2 | What does TTS read? | `assistant.sentence` messages in order; `turn_complete.spokenText` is for the transcript, never spoken again. |
| 3 | Which permission mode for voice? | `default`: edits prompt, allow-listed tools don't. Plan mode overrode allow rules. |
| 4 | Model and effort for voice turns? | `claude-opus-5-5`, effort `low`; both env-overridable. |

### Decision Register
> Severity & gating per `~/.claude/skills/severity-model.md`. Gate: S3+ surfaced to the user (default mode).
| ID | Decision | Severity (why) | Status | Chosen / default |
|----|----------|----------------|--------|------------------|
| P-layers | Sidecar layers `cli → server → agent → protocol`, inward only | S2 (internal structure) | auto-decided | `docs/conventions.md` |
| P-sentence-stream | Sentence splitting in the sidecar, not the app | S2 (one side owns it, testable) | auto-decided | `assistant.sentence` |
| P-annotation-allow | Annotation tools force-allowed in the permission relay | S2 (harmless tools, our overlay) | auto-decided | `permissionRelay.ts` |
| P-gitignore | Un-ignore `.claude/plans/` and `launch.json` | S2 (repo hygiene) | auto-decided | `.gitignore` |
| P-swift-transport | `URLSessionWebSocketTask` for the Swift client | S2 (stdlib, replaceable) | auto-decided | no third-party dep |
| P-sidecar-spawn | App spawns `node` with the sidecar; requires Node on the Mac for now | S3 (packaging commitment) | ☑ Ken 2026-09-27 | system Node, from source via tsx; bundle later |
| P-sidecar-attach | App attaches to a sidecar already on 47821 before spawning | S2 (dev ergonomics) | ☑ Ken 2026-09-27 | attached sidecar is never stopped by the app |
| P-spawn-from-source | Spawn `src/cli/serve.ts` via `node --import tsx`, not `dist/` | S2 (build output resolves `.env` from `dist/`) | auto-decided | no build step; 0.16 s to listening |
| P-spawn-token | Random per-launch `CLICKY_SIDECAR_TOKEN` for a spawned sidecar | S2 (local hardening) | auto-decided | env wins over `.env` |
| P-project-source | `session.start.projectDirectory` optional; sidecar's own wins | S2 (non-breaking wire change) | auto-decided | fixes Q-project-dir-source |
| P-interim-voice | Apple Speech in, macOS voice out until the Spark | S2 (reversible, Worker never deployed) | auto-decided | replaced in chunks 1, 2, 7 |
| P-permission-stopgap | Deny every `permission.request` at once until chunk 6 | S2 (safe default) | auto-decided | edits never happen by voice yet |

## Conventions / translation notes
- Coordinates: screenshot pixel space, origin top-left; app scales to display points and flips to AppKit bottom-left. Unchanged from upstream.
- Wire contract: `docs/ipc-protocol.md` ⇄ `agent-sidecar/src/protocol/messages.ts` ⇄ Swift `Codable`; change all three in one commit; bump `protocolVersion` on breaking changes.
- Privacy: every capture visible and announced; `docs/privacy.md` updated in the same commit as any capture or storage change.

## Chunks
### Chunk 1 — Spark STT probe
- **Goal:** measure transcription latency and accuracy on the Spark.
- **Read first:** `docs/decisions/0004-spark-voice-openai-compatible-endpoints.md`; `leanring-buddy/OpenAIAudioTranscriptionProvider.swift:156-260` (the multipart shape to mirror).
- **Spec / exact values:** `POST {spark_base_url}/v1/audio/transcriptions`, multipart `file` (WAV, 16 kHz mono PCM16) + `model`; expect JSON `{ text }`. Target < 700 ms for a 5 s clip on the LAN.
- **Reuse:** `agent-sidecar/src/cli/` conventions; `BuddyWAVFileBuilder` semantics for the test clip.
- **Steps:** add `agent-sidecar/src/cli/sparkSttProbe.ts` taking `--url` and `--wav`; post; print latency and text. Record a 5 s clip with `say` piped through `afconvert` for a known transcript.
- **Verify:** three runs under target; transcript matches the spoken text.
- **Produces:** `spark_base_url`.

### Chunk 2 — Spark TTS probe
- **Goal:** measure time to first audio byte and judge the voice.
- **Read first:** ADR 0004; `agent-sidecar/src/cli/tracerBulletSpike.ts` (`SequentialSpeechQueue`, to be re-targeted).
- **Consumes:** `spark_base_url`.
- **Spec / exact values:** `POST {spark_base_url}/v1/audio/speech` with `{ input, voice, response_format: "wav" }`; stream the body; time to first byte < 300 ms; play with `afplay`.
- **Steps:** `agent-sidecar/src/cli/sparkTtsProbe.ts`; then swap `SequentialSpeechQueue` in the spike to call it instead of `say` behind a `--spark` flag.
- **Verify:** three sentences, each under target; Ken accepts the voice.

### Chunk 3 — IPC round trip through the WebSocket server
- **Goal:** one real agent turn through `serve.ts`, including a `screenshot.request` and a `permission.request` reply.
- **Read first:** `docs/ipc-protocol.md`; `agent-sidecar/src/server/sidecarWebSocketServer.ts`; `agent-sidecar/src/cli/ipcClientSpike.ts`.
- **Steps:** `npm run serve -- --project DIR` in one terminal, `npm run spike:ipc-client -- --question "…"` in another (Ken runs both, pastes output). Ask a question that makes Claude call `take_screenshot` and one that needs an edit so both reply paths run.
- **Verify:** `assistant.sentence` events arrive before `turn_complete`; the screenshot reply unblocks the tool; a `deny` reaches Claude as a denial; sidecar exits when the client disconnects and `--parent-pid` is gone.

### Chunk 4 — Swift sidecar client, spawn/kill, capture indicator
- **Goal:** the app talks to the sidecar instead of `ClaudeAPI`, and every capture is visible.
- **Read first:** `leanring-buddy/CompanionManager.swift:586-730` (`sendTranscriptToClaudeWithScreenshot`), `:494` (interrupt), `:640-680` (scaling); `leanring-buddy/ClaudeAPI.swift`; `leanring-buddy/OverlayWindow.swift`; `leanring-buddy/CompanionPanelView.swift:599` (model picker row, pattern for new settings); `docs/ipc-protocol.md`; `docs/privacy.md` § Making every capture visible.
- **Spec / exact values:** `AgentSidecarClient.swift` (`URLSessionWebSocketTask`, `Codable` envelope matching `messages.ts`), `SidecarProcessController.swift` (`Process` running `node …/agent-sidecar/dist/cli/serve.js --port 47821 --project DIR --parent-pid <pid>`, waits for the `listening on` stdout line, terminates on quit). `overlay.point_at` → existing `detectedElementScreenLocation` path. Capture indicator: border flash on the captured display + badge on the cursor bubble while a capture is in flight + last-capture time and count in the panel; agent-initiated captures announced by voice (persona already does this).
- **Reuse:** `CompanionScreenCaptureUtility.captureAllScreensAsJPEG` for both the utterance and `screenshot.request`; `parsePointingCoordinates` becomes dead, delete it.
- **Steps:** build the sidecar (`npm run build`) so `dist/` exists; add the two Swift files; replace the `claudeAPI.analyzeImageStreaming` call; keep AssemblyAI and ElevenLabs for now so one thing changes; add `NSAllowsLocalNetworking` under `NSAppTransportSecurity` only if the loopback WebSocket is refused (verify first).
- **Verify:** push-to-talk end to end with the cursor driven by `overlay.point_at`; the flash and badge show on every capture; quitting the app leaves no `serve.js` process (`pgrep -f serve.js` empty).

### Chunk 5 — Circle gesture in the overlay
- **Goal:** `overlay.circle_region` draws a circle around the region on the right display.
- **Read first:** `leanring-buddy/OverlayWindow.swift` (bezier flight, multi-monitor mapping); `leanring-buddy/CompanionTranscriptPanel.swift` (overlay panel pattern).
- **Steps:** new SwiftUI shape driven by a published `detectedRegion` on `CompanionManager`; reuse the point scaling for the rectangle's corners; fade with the existing transient-hide logic.
- **Verify:** ask "circle the save button"; the circle lands on it, on a secondary monitor too.

### Chunk 6 — Spoken permissions
- **Goal:** `permission.request` → spoken question → yes or no → `permission.decision`.
- **Read first:** `agent-sidecar/src/agent/permissionRelay.ts` (`describeToolUseForSpeech`); `leanring-buddy/BuddyDictationManager.swift:294-330` (start/stop entry points).
- **Consumes:** `spark_base_url`.
- **Steps:** on `permission.request`, speak `spokenSummary`, open a short listening window, map "yes/yeah/do it" to allow and everything else to deny; 30 s timeout denies (sidecar already does).
- **Verify:** an edit is applied only after a spoken yes; silence denies; the denial is spoken back.

### Chunk 7 — App-side sentence playback + barge-in
- **Goal:** speak each `assistant.sentence` as it arrives; a hotkey press stops audio and sends `user.interrupt`.
- **Read first:** `leanring-buddy/ElevenLabsTTSClient.swift`; `leanring-buddy/CompanionManager.swift:494`.
- **Steps:** protocol `BuddyTextToSpeechClient` with a queue (`AVAudioEngine` or `AVQueuePlayer`); Spark backend from chunk 2; interrupt path stops the queue within 200 ms.
- **Verify:** no silent gap over 5 s during a multi-tool turn; interrupt stops audio within 200 ms and the sidecar reports `turn_interrupted`.

### Chunk 8 — Latency budget, measured
- **Goal:** fill the table in `docs/architecture.md` from the envelope timestamps.
- **Read first:** `docs/architecture.md` § Latency budget; `sentAtMs`/`durationMs` fields in `docs/ipc-protocol.md`.
- **Steps:** log per-hop deltas in the app; 10 turns; median per hop; try the levers in Open Questions (smaller screenshot, `settingSources: ['project']`).
- **Verify:** table filled with medians; each lever's effect recorded in one line each.

### Chunk 9 — Pointing accuracy vs upstream's tag
- **Goal:** decide whether tools point as well as the `[POINT:]` tag did (A7).
- **Read first:** ADR 0003; `leanring-buddy/CompanionManager.swift:544-577` (upstream prompt, for the tag baseline).
- **Steps:** 20 fixed screenshots with known targets; run each through the tool path (`spike:tracer-bullet --screenshot`) and a tag-prompt baseline; compare median error as a fraction of width.
- **Verify:** median error under 3 percent of width and no worse than the baseline; else open a decision to add a grounding call.

### Deferred (documented, not built now)
- **Wake word / continuous listening** ⊘ push-to-talk is the product; needs VAD and a privacy story first.
- **Computer use (click/type)** ⊘ out of scope per brief; safety model undecided.
- **Local LLM on the Spark** ⊘ Claude is the brain; revisit only if latency or cost forces it.
- **Bundling Node with the app** ⊘ P-sidecar-spawn; dev uses system Node.

## Verification (end-to-end)
- Sidecar: `cd agent-sidecar && npm run typecheck && npm test` (44 tests). Known noise: `CLAUDE_SDK_CAN_USE_TOOL_SHADOWED` warning at startup is expected.
- Swift: build and run from Xcode only. Known noise: Swift 6 concurrency warnings, deprecated `onChange` in `OverlayWindow.swift`. Do not fix.
- Auth: `npm run check-auth` must report credential source `none` (the login).
- Privacy: `npm run privacy:list` after any capture-related change.

## Open Questions (surface to human; don't guess)
- ~~Q-spark-host~~ — resolved: reachable over SSH (see memory `spark-ssh-access`); never committed.
- **Q-project-dir** — default project directory for voice; panel switch? Default `CLICKY_PROJECT_DIRECTORY`.
- **Q-persist** — transcripts on disk by default? Default true (G-persist ⏸).
- **Q-mcp-noise** — restrict voice sessions to project setting sources? Default: leave, measure in chunk 8. Chunk 3 turns cost $0.24–0.37 each; check what the prompt carries.
- ~~Q-project-dir-source~~ — resolved in chunk 4 (P-project-source). The app omits it; set `CLICKY_PROJECT_DIRECTORY` in `agent-sidecar/.env`, else sessions run in `agent-sidecar/`.
- **Q-onboarding-demo** — the onboarding demo still calls `ClaudeAPI` through the undeployed Worker and fails silently. Port to the sidecar or remove?
- **Q-node-packaging** — dev decided (P-sidecar-spawn); shipping bundle deferred.

## Reference index
- Files touched so far: `agent-sidecar/**`, `docs/**`, `AGENTS.md`, `.gitignore`, `.claude/**`.
- Swift files chunk 4+ will touch: `CompanionManager.swift`, `ClaudeAPI.swift` (delete), `OverlayWindow.swift`, `CompanionTranscriptPanel.swift` (replaced the unused `CompanionResponseOverlay.swift`), `CompanionPanelView.swift`, `ElevenLabsTTSClient.swift`, `Info.plist`, `project.pbxproj` (adding files only).
- Primitives to reuse: `CompanionScreenCaptureUtility.captureAllScreensAsJPEG`; `BuddyPCM16AudioConverter`; `BuddyWAVFileBuilder`; `parsePointingCoordinates` scaling block; `AsyncPushQueue`, `PendingReplyRegistry`, `SentenceStreamSplitter`, `createOutgoingMessage`.
- Deps available: `@anthropic-ai/claude-agent-sdk` 0.3.283, `zod` 4.6.5, `ws` 8.18, Node 24; Swift: ScreenCaptureKit, AVFoundation, Sparkle 2.9, PostHog 3.47.
### Post-exploration refinements (confirmed APIs)
- `CanUseTool` options require `toolUseID` and `requestId` (`sdk.d.ts:213`); result may be `null`.
- `Options.effort`: `'low' | 'medium' | 'high' | 'xhigh' | 'max'` (`sdk.d.ts:688`); `persistSession` TypeScript-only; `systemPrompt` preset form `{ type: 'preset', preset: 'claude_code', append }`.
- Init message `apiKeySource: 'none'` means the Claude Code login is in use; `session_id` is on both the init and result messages.
- `content_block_stop` is the reliable sentence boundary before a tool call; text blocks don't end with whitespace.
