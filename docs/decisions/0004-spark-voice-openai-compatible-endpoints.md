# ADR 0004: Speech on the Spark behind OpenAI-compatible endpoints

Date: 2026-09-27. Status: accepted.

## Context

Ken has a DGX Spark on the LAN for local inference and wants speech recognition and synthesis
off the cloud. The Mac must talk to whatever runs there without caring which model it is.

## Decision

The Swift app speaks to two HTTP endpoints shaped like OpenAI's audio API:

- `POST /v1/audio/transcriptions` multipart WAV in, JSON `{ text }` out
- `POST /v1/audio/speech` JSON `{ input, voice, response_format }` in, audio bytes out

Base URL is a setting. "Local Mac" and "DGX Spark" are two values of that one setting.

## Reasons

- Nearly every serious local server already speaks this shape: `speaches` and whisper.cpp for
  STT, Kokoro-FastAPI and Orpheus servers for TTS, `mlx-audio` on the Mac for both.
- Upstream's `OpenAIAudioTranscriptionProvider` already posts this exact multipart shape, so the
  STT side is a URL change plus dropping the key requirement.
- Model choice (Parakeet vs Whisper, Kokoro vs Orpheus) becomes a server-side decision that never
  touches the app.

## Consequences

- Push-to-talk stays upload-on-release rather than streaming. Partial transcripts are not
  displayed by upstream anyway. If streaming STT is wanted later, that is a new provider behind
  the existing `BuddyTranscriptionProvider` protocol.
- Plain HTTP on the LAN needs `NSAllowsLocalNetworking` under App Transport Security in
  Info.plist, and macOS will show a Local Network permission prompt on first use.
