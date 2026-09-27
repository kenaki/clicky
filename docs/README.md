# Clicky Voice Fork — Documentation

This fork keeps Clicky's screen-as-context and cursor-pointing framework and rebuilds the
brain and the voice pipeline around two things Ken owns: a Claude Agent SDK sidecar on the
Mac and a DGX Spark on the LAN for speech.

Read in this order:

| Doc | What it answers |
|---|---|
| [architecture.md](architecture.md) | What the four components are, how a voice turn flows through them, and where each seam is in the existing Swift code. |
| [prototype-plan.md](prototype-plan.md) | The ways we validate the plan, and the kill criteria. Chunks and live status are in `.claude/plans/active/agent-sidecar/plan.md`; assumptions in `brief.md` beside it. |
| [ipc-protocol.md](ipc-protocol.md) | The message contract between the Swift app and the sidecar. Change this doc, the zod schema, and the Swift Codable together. |
| [privacy.md](privacy.md) | Exactly what is captured, when, where it goes, where it lands on disk, and the commands that list and wipe it. |
| [conventions.md](conventions.md) | The engineering rules for this repo: module boundaries, naming, validation at boundaries, testing, docs upkeep. |
| [decisions/](decisions/) | Architecture Decision Records. One file per decision, never edited after acceptance, superseded by a new one instead. |

The root [AGENTS.md](../AGENTS.md) (symlinked as `CLAUDE.md`) remains the entry point for AI coding
agents. It points here for anything fork-specific.
