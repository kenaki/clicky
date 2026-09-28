# Agent sidecar for Clicky voice — Feature Development Doc

> **Living master plan & single source of truth.** Written so a fresh, uncontextualized session can
> pick up any unstarted chunk, execute it, verify it, and mark it done — without the original
> conversation. Keep the Status table + Changelog current.
> **Location:** `.claude/plans/active/agent-sidecar/plan.md` (promoted from backlog at chunk 0's ☑).
> Archive the whole directory to `.claude/plans/archived/agent-sidecar/` when every build-now chunk is ☑.
> Spec input: `brief.md` beside this file. Reference docs: `docs/` (architecture, ipc-protocol, conventions, privacy, decisions).

---

## SESSION HANDOFF — resume here
**State at handoff (2026-09-28, evening):** chunks 0, 2, 3, 4 ☑; 6 and 7 ◐; 1, 5, 8, 9 ☐. Sidecar
typechecks, 68 unit tests pass; the whole Swift target typechecks with `swiftc -typecheck` against Xcode's
built package modules (never `xcodebuild`). Branch `feature/agent-sidecar-prototype`. **Everything is
committed** except Ken's pbxproj signing-team change and `xcuserdata/`, which stay unstaged on purpose.
**Voice:** Kokoro-FastAPI on the Spark is the default (RTF ~0.1); Miso TTS 8B was the earlier choice
(`spark-tts-server/`, `.claude/plans/backlog/spark-tts-server/tech-scout.md`). App: `SparkSpeechSentenceQueue.swift`,
enabled by the `SparkSpeechBaseURL` user default. If the Spark is unreachable, the queue falls back to the
Mac voice quickly instead of waiting out a 240 s request.
**Built 2026-09-28 and committed, NOT yet run by Ken in Xcode (run these first):**
- Transcript card (`CompanionTranscriptPanel.swift`): the window is exactly the card (measured by an
  off-screen copy), always takes clicks and scrolls; × and Escape close it and nothing else hides it;
  reply field sends the next turn; click a line or an earlier answer to hear it again; header play/stop
  and a speed menu (`speechSpeed`, Kokoro's rate).
- Typed questions: "Ask Clicky" field in the menu bar panel (`CompanionAskClickyRow.swift`) and a global
  "speak answers" switch; typed text goes through `handleFinalTranscript`, so it can answer a permission.
- Past conversations: "Past" menu on the Conversation row; the sidecar lists Clicky's SDK sessions per
  workspace (`pastConversations.ts`), resumes one, and sends `session.history` to refill the card.
- LaTeX spike: SwiftMath 1.7.3 draws display equations natively (`CompanionMathEquationView.swift`);
  Debug builds show hard-coded samples under every answer. Nothing sends equations yet.
- Also from the parallel voice session: voice & motion settings, spoken permissions (chunk 6), workspace
  picker, spoken slash commands, sandboxed voice sessions, researchML PHI deny rule.
**Next, in Ken's order:** 1) Ken's Xcode run of the list above; 2) **chunk 5, widened** — circle *and*
highlight (yellow translucent overlay) what Claude is talking about, see the chunk; 3) the follow-ups
under "Next features" below; then chunks 8, 9 and Spark STT (1).
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
| 5 | Circle and highlight in the overlay | ☐ todo | | next; widened 2026-09-28, see chunk |
| 6 | Spoken permissions | ◐ in progress | 2026-09-28 | built; voice, card buttons, or typed; Ken's run |
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
- 2026-09-28 — Live voice/motion controls, panel history + hover scroll, session resume + New conversation; typechecked, resume untested live; awaiting Ken's run.
- 2026-09-28 — Chunk 6 ◐ spoken permissions; workspace picker; spoken slash commands; sandboxed voice sessions + researchML PHI deny rule (decoy-verified). 57 tests.
- 2026-09-28 — Card rework (card-sized window, close, reply, replay, speed, no auto-hide), typed questions + speak switch, Past conversations, SwiftMath LaTeX spike. 68 tests; Ken's run pending.
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
| P-permission-stopgap | Deny every `permission.request` at once until chunk 6 | S2 (safe default) | superseded 2026-09-28 | replaced by chunk 6 |
| P-permission-answer | Answer by the next push-to-talk or the card's buttons, never an auto-opened mic | S3 (consent: memory ken-screen-capture-and-audio-consent) | auto-decided, differs from chunk 6 spec | a yes needs a clear yes and no negation |
| P-sandbox | Voice sessions run shell commands in Claude Code's sandbox, no escape | S3 (privacy: grep -r bypassed Read deny on a decoy) | ☑ Ken asked for the PHI guard | `CLICKY_SANDBOX_COMMANDS`, default true |
| P-workspaces | Workspace picker; one saved session per workspace | S2 (app setting) | ☑ Ken 2026-09-28 | resolves Q-project-dir |
| P-slash-plain-string | Spoken "slash <name>" sent as the plain string, no screenshots | S2 (SDK only expands plain strings, probed) | auto-decided | names from `supportedCommands()` |

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

### Chunk 5 — Circle and highlight in the overlay
- **Goal:** `overlay.circle_region` draws on the right display what Claude is talking about. Ken
  (2026-09-28): "circle things, highlight things, put a yellow overlay on it". Today the app only flies
  the cursor to the region's centre (`CompanionManager.swift`, `case .overlayCircleRegion`).
- **Read first:** `leanring-buddy/OverlayWindow.swift` (bezier flight, multi-monitor mapping);
  `CompanionManager.pointCursorAtAgentScreenshotLocation` (screenshot pixels → display points → AppKit);
  `agent-sidecar/src/agent/tools/screenAnnotationTools.ts`; `voicePersonaPrompt.ts` (pointing section).
- **Steps:** add an optional `style` to `circle_region` and its wire message: `circle` (default, an
  outline) or `highlight` (translucent yellow fill, soft edge, like a highlighter). Additive, protocol
  stays v1. Draw it in the overlay from a published `detectedRegion` on `CompanionManager`, reusing the
  point scaling for the rectangle's corners; several may show at once in one turn. Clear on
  `overlay.clear`, the next push-to-talk, or after `pointingHoldSeconds`. Tell the persona when to use
  each style. Optional, ask Ken: keep a region lit while the transcript card is speaking the sentence
  that introduced it.
- **Verify:** "circle the save button" and "highlight the loss line" each land on target, on a secondary
  monitor too; the highlight never blocks clicks (overlay stays click-through).

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

### Next features (asked for 2026-09-28, not chunked yet)
- **LaTeX in the card:** the prompt tells Claude to put each formula alone in `$$…$$`; a pure sidecar
  step pulls it out of the speech stream (before `SentenceStreamSplitter`) and sends `assistant.math
  { utteranceId, afterSentenceIndex, latex }`; the card renders it with `CompanionMathEquationView`
  and becomes a list of items (sentence, equation). Remove the Debug samples then. Rationale: Ken's
  open-notebook project renders LaTeX with KaTeX; Clicky must split it from speech first.
- **Screen crops in the card:** on `overlay.point_at` / `circle_region`, crop `latestScreenCaptures`
  to the target and show it after the current sentence, caption = the tool's label. No protocol change;
  in memory only (update `docs/privacy.md`). Doubles as a visual check of pointing accuracy (chunk 9).
- **Typed-turn replies:** typed questions still get the spoken persona (short, lowercase); mark a turn as
  typed so Claude may write longer or formatted answers.
- **Optional Clicky-only instructions file** appended after the persona, so the voice can be tuned
  without editing TypeScript.

### Deferred (documented, not built now)
- **Wake word / continuous listening** ⊘ push-to-talk is the product; needs VAD and a privacy story first.
- **Computer use (click/type)** ⊘ out of scope per brief; safety model undecided.
- **Local LLM on the Spark** ⊘ Claude is the brain; revisit only if latency or cost forces it.
- **Bundling Node with the app** ⊘ P-sidecar-spawn; dev uses system Node.

## Verification (end-to-end)
- Sidecar: `cd agent-sidecar && npm run typecheck && npm test` (68 tests). Known noise: `CLAUDE_SDK_CAN_USE_TOOL_SHADOWED` warning at startup is expected.
- Swift: build and run from Xcode only. Known noise: Swift 6 concurrency warnings, deprecated `onChange` in `OverlayWindow.swift`. Do not fix.
- Auth: `npm run check-auth` must report credential source `none` (the login).
- Privacy: `npm run privacy:list` after any capture-related change.

## Open Questions (surface to human; don't guess)
- ~~Q-spark-host~~ — resolved: reachable over SSH (see memory `spark-ssh-access`); never committed.
- ~~Q-project-dir~~ — resolved 2026-09-28: Workspace picker in the menu bar panel (P-workspaces).
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
