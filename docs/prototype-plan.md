# Prototype Plan: how we validate the plausibility

The assumptions, the spike-by-spike table, and the live status moved on 2026-09-27 into Ken's
workflow layout: `brief.md` (assumptions, decision register) and `plan.md` (chunks, status,
changelog) under `.claude/plans/active/agent-sidecar/`. This file keeps only the rationale: the
ways we can prototype, and the kill criteria.

## Ways to prototype

These are the approaches available. The spike list below picks from them.

**Tracer bullet with no Swift changes.** A CLI script on the Mac: `screencapture` for the
screenshot, a typed or pre-recorded transcript, the sidecar's agent session, tool calls printed
to the terminal, the reply spoken with macOS `say`. Exercises the riskiest new code, the Agent
SDK integration, without touching Xcode or TCC permissions. This is chunk 0 of the plan.

**Stand-ins to isolate one risk at a time.** Apple Speech stands in for Spark STT. macOS `say`
stands in for Spark TTS. `claude -p` stands in for the sidecar. Each stand-in lets one real
component be swapped in and measured alone.

**Bottom-up component spikes.** One spike per assumption, each a short script with a number
at the end. Chunks 1 through 3, 8 and 9.

**Wizard-of-Oz for the voice UX.** Type transcripts instead of speaking, and listen to real
agent responses through TTS, to learn what progress narration is needed before building
anything for it. Part of chunks 0 and 7.

**Measure first.** Every hop timestamps from day one (see conventions). The latency budget in
architecture.md becomes a measured table, not a guess. Chunk 8.

**Vertical slice last.** Only after the components pass do we wire the Swift app to the sidecar.
Chunk 4 onward.

## Kill criteria

Stop and rethink if any of these happen:

- Chunk 0 cannot get Claude to call the annotation tools reliably even with explicit instruction. Then the pointing design reverts to text tags and the sidecar is only worth it for the Claude Code environment features.
- Chunks 1 and 2 both fail their latency targets on the Spark and on the Mac. Then the voice loop stays on the cloud services and the project narrows to the Agent SDK brain.
- Chunk 7 shows that tool-using turns cannot be made to feel responsive by voice. Then voice becomes read-only questions and pointing, and edits stay in the terminal.
