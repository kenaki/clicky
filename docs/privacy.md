# Privacy: what is captured, where it goes, where it lands

Written 2026-09-27 after the first spike runs, from an inventory of the disk, not from memory.
Keep it that way: when a capture or storage path changes, update this file in the same commit.

## What is captured

| Source | What | When | Never |
|---|---|---|---|
| Swift app | One still frame per connected display, JPEG, max 1280 px, via `SCScreenshotManager.captureImage`. Held in memory only, sent to the sidecar as base64. | When you release the push-to-talk key, and when the agent calls `take_screenshot`. | Never a video stream. Never written to disk by the app. |
| Swift app | Microphone audio | Only while the push-to-talk key is held. | Never when the key is up. |
| Sidecar spikes | One still frame of the main display via `screencapture`. | When you run a spike without `--screenshot`, and when the agent calls `take_screenshot` during a spike. | No microphone at all in the spikes. |

Agent-initiated captures are the ones that can feel like surveillance, because you did not press
anything. Two rules apply to them: the persona tells Claude to say out loud that it is taking
another look before it calls the tool, and the app must show the visible indicator below.

## Where a screenshot goes

1. To Anthropic, inside the request the Claude Code binary makes. This is the same as upstream
   Clicky, which sent screenshots to the same API through its Cloudflare Worker. Their handling
   is governed by Anthropic's terms for your account; this document does not restate them.
2. Nowhere else over the network. The Spark never receives screenshots.

The Spark voice server (`spark-tts-server/`) receives the **text of each spoken sentence** of Claude's
answers over plain HTTP on the home network, and returns audio. It keeps nothing on disk; its log
(`~/clicky-voice/server.log` on the Spark) records the first 60 characters of each sentence with its
timing. Nothing leaves the LAN.

## Where a screenshot lands on disk

Found on 2026-09-27 with Claude Code 2.1.282 on macOS. Paths use the encoded project folder
name, which is the absolute path with every non-alphanumeric character replaced by `-`.

| Location | Written by | Contents | Controlled by |
|---|---|---|---|
| `~/.claude/projects/<encoded project dir>/<session id>.jsonl` | Claude Code, via the Agent SDK | The session transcript, with every screenshot embedded as base64. This is what makes `claude --resume` work. | `CLICKY_PERSIST_SESSIONS` in `agent-sidecar/.env`, or `--ephemeral` on the spike. `false` writes nothing. |
| `/private/tmp/claude-<uid>/<encoded project dir>/<session id>/images/N.jpg` | Claude Code | The same screenshots extracted as files. | Same switch; nothing is extracted for an unpersisted session. Deleted by `npm run privacy:clean`. |
| `$TMPDIR/clicky-spike-*.jpg` | The spike, before 2026-09-27 | Raw captures the first spike version forgot to delete. | Fixed: captures are deleted before the spike continues. `npm run privacy:clean` removes old ones. |

The Swift app writes no captures or transcript text. Upstream's `CompanionScreenCaptureUtility`
keeps JPEG data in memory and hands it to the API client. The only thing it stores about a
conversation is the session id (see Sessions).

## Commands

```bash
cd agent-sidecar && npm run privacy:list
```

Lists every local copy above with size and date, scanning the configured project folder, the
sidecar folder, and the current folder. Only sessions this sidecar created are listed; they are
recognised by the screenshot label the sidecar writes into every user message.

```bash
cd agent-sidecar && npm run privacy:clean
```

Deletes temp captures and Claude Code's extracted images. Session transcripts are kept unless
you add `-- --include-sessions`, because deleting them removes those sessions from `claude --resume`.

## Making every capture visible

Built in chunk 4. Every capture the agent receives goes through one function,
`captureScreensVisiblyForAgent` in `CompanionManager.swift`, which:

- flashes a blue border on every display at the instant of capture (every display is captured);
- shows a camera badge beside the cursor while the capture is in flight, held for at least 0.8 s;
- counts the capture and records its time, which the menu bar panel shows as
  "Screen captures: N · last 4:21 PM" for the current agent session;
- brings the overlay on screen first if it was hidden, so the indicator cannot be skipped.

The app's own overlay windows are excluded from the capture, so the flash never appears in a
screenshot. Agent-initiated captures are also announced by voice before they happen (the
persona says so first). No setting can make a capture silent and invisible at the same time.

In the spikes today: the capture is announced on stdout and the macOS shutter sound is not
suppressed.

## Sessions

Added 2026-09-28. The app remembers the last agent session id in its user defaults
(`AgentSidecarLastSessionId`) and asks the sidecar to resume it on the next launch, so Claude
remembers the conversation. Resuming sends that session's history, screenshots included, back to
Claude as context, the same as every later turn within one session already does. It works only
while the transcript above exists (`CLICKY_PERSIST_SESSIONS=true`); if the resume fails, the id is
forgotten and a fresh session starts. "New" beside Conversation in the menu bar panel forgets the
id and ends the session. The transcript panel keeps this run's text in memory only.

"Past" beside Conversation lists the workspace's saved Clicky sessions: the sidecar reads their
titles from the transcripts above (read-only, through the SDK's `listSessions`) and sends only the
titles and dates to the app over localhost. Reopening one resumes it as above, and the sidecar also
reads its last 12 question and answer texts (no screenshots) to show on the transcript card. The
same text is loaded quietly when the app resumes at launch. Nothing new is written anywhere.

## Workspaces and folders the agent must never read

Added 2026-09-28. The agent works in the folder picked under Workspace in the menu bar panel, and
that folder's `.claude/settings.json` applies. A folder with private data inside a workspace
needs two things, both verified on a decoy folder with Claude Code 2.1.282:

1. A deny rule in the workspace's `.claude/settings.json`, e.g. `"Read(/phi_do_not_read/**)"`
   (a leading `/` anchors at the workspace). This stops the Read tool only.
2. The sandbox, which the sidecar turns on for every voice session (`CLICKY_SANDBOX_COMMANDS`,
   default true, no escape hatch). Claude Code searches with shell `grep -r`, `find` and `cat`,
   and read-only commands run without asking; without the sandbox, `grep -r` from the workspace
   root printed the decoy's contents. With it, those commands get "Operation not permitted".

`~/vitalcue/researchML` has both for `phi_do_not_read/`. Screenshots are separate: the agent sees
whatever is on screen when you ask.

## Your session with Claude Code

Separate from all of the above: when you use Claude Code itself to work on this repo, that
conversation is a Claude Code session with its own transcript, and anything you paste or
screenshot into it follows Claude Code's normal rules, not this document.
