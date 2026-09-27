# Privacy: what is captured, where it goes, where it lands

Written 2026-09-27 after the first spike runs, from an inventory of the disk, not from memory.
Keep it that way: when a capture or storage path changes, update this file in the same commit.

## What is captured

| Source | What | When | Never |
|---|---|---|---|
| Swift app | One still frame per connected display, JPEG, max 1280 px, via `SCScreenshotManager.captureImage`. Held in memory only. | When you release the push-to-talk key. Later, also when the agent calls `take_screenshot`. | Never a video stream. Never written to disk by the app. |
| Swift app | Microphone audio | Only while the push-to-talk key is held. | Never when the key is up. |
| Sidecar spikes | One still frame of the main display via `screencapture`. | When you run a spike without `--screenshot`, and when the agent calls `take_screenshot` during a spike. | No microphone at all in the spikes. |

Agent-initiated captures are the ones that can feel like surveillance, because you did not press
anything. Two rules apply to them: the persona tells Claude to say out loud that it is taking
another look before it calls the tool, and the app must show the visible indicator below.

## Where a screenshot goes

1. To Anthropic, inside the request the Claude Code binary makes. This is the same as upstream
   Clicky, which sent screenshots to the same API through its Cloudflare Worker. Their handling
   is governed by Anthropic's terms for your account; this document does not restate them.
2. Nowhere else over the network. The Spark, when it exists, receives audio only.

## Where a screenshot lands on disk

Found on 2026-09-27 with Claude Code 2.1.282 on macOS. Paths use the encoded project folder
name, which is the absolute path with every non-alphanumeric character replaced by `-`.

| Location | Written by | Contents | Controlled by |
|---|---|---|---|
| `~/.claude/projects/<encoded project dir>/<session id>.jsonl` | Claude Code, via the Agent SDK | The session transcript, with every screenshot embedded as base64. This is what makes `claude --resume` work. | `CLICKY_PERSIST_SESSIONS` in `agent-sidecar/.env`, or `--ephemeral` on the spike. `false` writes nothing. |
| `/private/tmp/claude-<uid>/<encoded project dir>/<session id>/images/N.jpg` | Claude Code | The same screenshots extracted as files. | Same switch; nothing is extracted for an unpersisted session. Deleted by `npm run privacy:clean`. |
| `$TMPDIR/clicky-spike-*.jpg` | The spike, before 2026-09-27 | Raw captures the first spike version forgot to delete. | Fixed: captures are deleted before the spike continues. `npm run privacy:clean` removes old ones. |

The Swift app writes nothing. Upstream's `CompanionScreenCaptureUtility` keeps JPEG data in
memory and hands it to the API client.

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

Requirements for the Swift app, tracked in Spike 4 of `prototype-plan.md`:

- A visible indicator at the instant of every capture: a brief border flash on the captured
  display and a badge on the cursor bubble that stays up while a screenshot is in flight.
- The menu bar panel shows the time of the last capture and how many captures the current
  session has made.
- Agent-initiated captures are announced by voice before they happen and use the same indicator.
- No setting can make a capture silent and invisible at the same time.

In the spikes today: the capture is announced on stdout and the macOS shutter sound is not
suppressed.

## Your session with Claude Code

Separate from all of the above: when you use Claude Code itself to work on this repo, that
conversation is a Claude Code session with its own transcript, and anything you paste or
screenshot into it follows Claude Code's normal rules, not this document.
