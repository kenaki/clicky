# ADR 0001: Host the Claude Agent SDK in a Node sidecar process

Date: 2026-09-27. Status: accepted.

## Context

Upstream Clicky calls the Anthropic Messages API directly from Swift through a Cloudflare Worker
that hides the API key. Ken wants the voice companion to behave like Claude Code in his project:
read and edit files, run commands, load CLAUDE.md, skills, and MCP servers, and share sessions
with the terminal. That is the Claude Agent SDK's job, and the SDK exists only for TypeScript
and Python. Swift cannot embed it.

## Decision

Run the Agent SDK in a separate Node process, `agent-sidecar/`, launched by the Swift app and
reached over localhost. The sidecar owns the agent session, the annotation tools, the system
prompt persona, and the API key. The Cloudflare Worker and `ClaudeAPI.swift` are removed.

## Consequences

- One more process to manage: spawn on launch, kill on quit, detect orphaning.
- Auth moves to an Anthropic API key in the sidecar's environment. The SDK docs direct
  third-party apps to API-key authentication rather than claude.ai login, so this bills per
  token rather than against a subscription.
- The sidecar can expose in-process MCP tools to Claude, which is what makes ADR 0003 possible.
- Sessions are written to `~/.claude/projects/`, the same place the CLI uses, so `claude --resume`
  works on a voice session.

## Alternatives considered

- **Swift spawns `claude -p --output-format stream-json` directly.** No Node dependency, but no
  in-process custom tools, no `canUseTool` callback, and reimplementing the stream-json parsing
  in Swift. Kept as the fallback if the sidecar proves fragile (Spike 4 kill criterion).
- **Keep the raw Messages API and add tool use by hand.** Loses CLAUDE.md, skills, MCP, hooks,
  permissions, and sessions. Rebuilding those is the whole product.

## Amendment, 2026-09-27

The consequence above about authentication was wrong for this project. Ken has no Anthropic
API key and wants his Claude Code subscription to be the only billing. The Agent SDK runs the
Claude Code binary, and that binary reads the CLI's stored OAuth login, so no key is needed.
`npm run check-auth` in `agent-sidecar/` makes one tiny request and reports the credential
source; on 2026-09-27 it reached the login path and found the terminal CLI signed out, which
`claude auth login` fixes. An `ANTHROPIC_API_KEY`, if ever set, takes precedence.

The SDK overview notes that third-party developers may not offer claude.ai login in their
products. This is a personal tool running on Ken's own login, not a product offered to others.
