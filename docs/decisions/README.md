# Architecture Decision Records

One file per decision. Numbered, dated, immutable once accepted. To change a decision, write a
new ADR that supersedes the old one and link both ways.

| # | Title | Status |
|---|---|---|
| [0001](0001-agent-sdk-sidecar.md) | Host the Claude Agent SDK in a Node sidecar process | accepted |
| [0002](0002-typescript-for-sidecar.md) | Write the sidecar in TypeScript, not Python | accepted |
| [0003](0003-annotation-tools-not-text-tags.md) | Pointing and circling are tool calls, not text tags | accepted |
| [0004](0004-spark-voice-openai-compatible-endpoints.md) | Speech on the Spark behind OpenAI-compatible endpoints | accepted |
| [0005](0005-websocket-ipc.md) | App and sidecar talk over a localhost WebSocket with a versioned JSON envelope | accepted |
