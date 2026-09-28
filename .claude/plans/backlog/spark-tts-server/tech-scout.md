# Spark TTS server — Technology Landscape (Tech-Scout)

> **Outward research output and the chosen tech direction.** The pipeline's technology reference:
> `frame-goal` and the orchestrator read this. Researched 2026-09-27 by four parallel web-research
> agents (models, servers, Spark runtime, transport/playback/deployment) plus a follow-up on Miso TTS.
> **Location:** `.claude/plans/backlog/spark-tts-server/tech-scout.md` → moves with the feature directory.
> **Slug:** `spark-tts-server`. Parent feature: `.claude/plans/active/agent-sidecar/` (chunks 2 and 7 consume this).

---

## Feature → capabilities
Clicky's voice: every `assistant.sentence` the sidecar emits is spoken by a model on Ken's DGX Spark.
- **Synthesize** one English sentence (5–30 words) to natural, expressive speech.
- **Serve** it over `POST /v1/audio/speech` in the OpenAI shape (ADR 0004), so models swap without app changes.
- **Stream** audio back fast enough that speech starts < ~300 ms after the sentence is sent.
- **Play** sentences back to back on the Mac with no gaps, and stop within 200 ms on a hotkey press (chunk 7).
- **Speak code-ish text** (file names, camelCase, numbers) intelligibly.
- **Run unattended** on the Spark: starts on boot, LAN only, health-checked.
- Later, **host STT** (`/v1/audio/transcriptions`) on the same box (chunk 1).

## Constraints (the rails research was filtered by)
| Rail | Source | Note |
|------|--------|------|
| OpenAI-shaped `/v1/audio/speech` | codebase (ADR 0004) | model choice is a server-side decision |
| Plain TTS model, not a conversational framework or speech-to-speech model | user (2026-09-27) | Claude stays the brain; push-to-talk already does turn-taking |
| Balanced: natural and expressive, first audio < ~300 ms per sentence | user | measured Mac → Spark → first byte |
| English only; no voice cloning needed | user | |
| Local only; audio never leaves the LAN | codebase (`docs/privacy.md`) | the Spark receives audio only; here it receives text, returns audio |
| Personal use | codebase (CLAUDE.md out of scope) | non-commercial licenses acceptable, flagged |
| DGX Spark: GB10, aarch64, Blackwell sm_121, CUDA 13, ~273 GB/s unified memory | user + research | bandwidth caps autoregressive decode; aarch64 wheels are the main risk |
| Ken can SSH to the Spark | user | hostname given at spike time, never committed (`docs/conventions.md`) |
| Sentence-at-a-time input | codebase (`sentenceStreamSplitter.ts`) | token-streaming TTS inputs bring no gain |

## Technology categories
1. **TTS model** — the voice.
2. **Serving layer** — the HTTP server exposing `/v1/audio/speech`.
3. **Runtime on the Spark** — PyTorch/ONNX/TensorRT/LLM engine on aarch64 + sm_121.
4. **Audio format and transport** — what crosses the LAN.
5. **Mac playback** — gapless queue with fast stop (chunk 7).
6. **Latency strategy** — pipelining, warm-up.
7. **Deployment and ops** — how it runs on the Spark.
8. **Text normalization for speech** — non-obvious: no model handles code identifiers.

---

## Per-category options
> ✅ fits · ⚠ risk · ❌ violates a rail. "Spark" latency means measured on a DGX Spark; everything else
> is other hardware and does not transfer (273 GB/s vs ~3.3 TB/s on an H100).

### Category: TTS model
| Option | What it is | Maturity | Advantages | Disadvantages | License | Spark evidence | Compat |
|--------|-----------|----------|------------|---------------|---------|----------------|:------:|
| **Miso TTS 8B ("Miso One")** | CSM-style RVQ transformer, Llama backbone, Mimi codes ([repo](https://github.com/MisoLabsAI/MisoTTS)) | open weights 2026; no streaming, quantization, or server in repo | most expressive; infers emotion from text | 8B decode on 273 GB/s: est. ≤ ~17 steps/s at bf16 vs ~12.5 frames/s needed (inference, not measured); 110 ms figure is Miso's hosted H100 API ([wavect](https://wavect.io/blog/miso-tts-self-hosted-vs-api/)); needs torchaudio (broken on Spark ARM+CUDA); Python 3.10 pin; watermark on by default | modified MIT ([rundown](https://www.therundown.ai/tools/miso-one)) | none found | ⚠ latency rail at risk |
| **Kokoro-82M v1.0** | StyleTTS2 + ISTFTNet, 54 voices ([HF](https://huggingface.co/hexgrad/Kokoro-82M)) | Jan 2025; 11.5M downloads/month | tiny, fast; runs on a Spark with GPU ([forum](https://forums.developer.nvidia.com/t/running-kokoro-tts-on-nvidia-dgx-spark-arm64-gb10/368846)); number/URL normalization; IPA overrides | least expressive of the set; Spark first-audio time unpublished | Apache-2.0 | runs; ~4 s warm-up | ✅ |
| **NVIDIA Magpie 357M** | codec TTS with frame stacking ([HF blog](https://huggingface.co/blog/nvidia/magpie-tts-multilingual-voice-agents)) | open weights Aug 2026; NIM | 53 ms on Spark (NVIDIA claim), P50 186 ms streaming ([Daily](https://www.daily.co/blog/building-voice-agents-with-nvidia-open-models/)); real text normalization | a month old; NIM speaks `/v1/audio/synthesize_online`, needs a shim; older NIM notes had Spark audio issues | NVIDIA Open Model License | vendor + partner | ✅/⚠ |
| **Qwen3-TTS 0.6B** | dual-track LM + 12 Hz codec ([repo](https://github.com/QwenLM/Qwen3-TTS)) | Jan 2026, 13.6k★ | expressive; Spark server exists ([dgx-spark-faster-qwen3-tts](https://github.com/mARTin-B78/dgx-spark-faster-qwen3-tts)) | measured 280 ms on Spark before LAN ([faster-qwen3-tts](https://github.com/andimarafioti/faster-qwen3-tts)); two English presets | Apache-2.0 | measured | ⚠ at budget |
| **Orpheus 3B** | Llama-3B + SNAC | stalled since May 2025 | emotion tags | ~91 tok/s needed; 3B on 273 GB/s borderline real time | Apache code, Llama weights | none | ⚠ |
| Chatterbox Turbo, Kyutai 1.6B, Voxtral-4B | — | — | — | above budget in user reports / no aarch64 evidence / non-commercial 4B | — | none | ⚠ |
**Recommended:** Kokoro-82M for reliability. **Ken chose: spike Miso first, Kokoro as fallback** (T-model).

### Category: Serving layer
| Option | Advantages | Disadvantages | License | Compat |
|--------|------------|---------------|---------|:------:|
| **Kokoro-FastAPI** v0.9.0 ([repo](https://github.com/remsky/Kokoro-FastAPI)) | exact request shape; streams `pcm`; closes stream on client disconnect; arm64 GPU image (cu129) | Kokoro only; image vs GB10 unverified (an older issue reported x86-only, [#401](https://github.com/remsky/Kokoro-FastAPI/issues/401)); no auth | Apache-2.0 | ✅ |
| **Own FastAPI wrapper** (~150 lines) | any model incl. Miso; exact contract; can add STT | we own aarch64 dependency pain | ours | ✅ (required for Miso) |
| **LocalAI** `latest-nvidia-l4t-arm64-cuda-13` ([docs](https://localai.io/docs/reference/nvidia-l4t/)) | official Spark image; TTS + STT | heavy; Kokoro streaming unsupported; backends break on arm64+CUDA 13 | MIT | ⚠ |
| **speaches** | TTS + STT in one | releases stalled; STT falls back to CPU on arm64 ([#620](https://github.com/speaches-ai/speaches/issues/620)) | MIT | ⚠ |
| **vLLM-Omni** | best streaming engineering | big models only, source builds on Spark | Apache-2.0 | ⚠ |
| **NVIDIA Speech NIM** | officially on Spark | non-OpenAI TTS shape; NGC key | NVIDIA terms | ⚠ |
**Recommended:** own FastAPI wrapper for Miso; Kokoro-FastAPI if the fallback is taken.

### Category: Runtime on the Spark
| Option | Advantages | Disadvantages | Compat |
|--------|------------|---------------|:------:|
| **PyTorch ≥ 2.9 cu130 aarch64 wheels** | sm_121 binary-compatible with sm_120 per a PyTorch maintainer ([forum](https://discuss.pytorch.org/t/dgx-spark-gb10-cuda-13-0-python-3-12-sm-121/223744)); lightest | pip/uv can silently resolve `+cpu`; warning noise | ✅ |
| **NGC PyTorch container ≥ 25.10** (26.08 current) | NVIDIA-supported on GB10 | 25.12 lacked torchaudio; `pip install torchaudio` clobbers torch ([forum](https://forums.developer.nvidia.com/t/incompatibility-of-torchaudio-in-ngc-pytorch-container-25-12-on-dgx-spark-blackwell-gb10/357745)) | ✅ |
| ONNX Runtime GPU | fast for Kokoro-onnx | no stable aarch64 CUDA 13 wheel ([ort#27944](https://github.com/microsoft/onnxruntime/issues/27944)) | ⚠ |
| llama.cpp (LLM-based TTS) | builds for sm_121; quantization | only helps Llama-backbone models with a GGUF path | ⚠ (possible Miso lever) |
| SGLang / TensorRT-LLM | — | no sm_121 binaries / beta, ptxas failures | ❌ |
**Recommended:** PyTorch cu130 wheels in eager mode, `torch.cuda.is_available()` asserted at startup, soundfile instead of torchaudio for I/O, no torch.compile.

### Category: Audio format and transport
| Option | Advantages | Disadvantages | Compat |
|--------|------------|---------------|:------:|
| **Streamed PCM** (`response_format: "pcm"`, 24 kHz s16le, chunked) | lowest first-audio; no decoder; gapless | rate not self-describing | ✅ |
| WAV per sentence | simplest, self-describing | waits for full sentence | ✅ fallback |
| MP3/Opus | small | encoder padding breaks gapless; LAN bandwidth irrelevant | ⚠ |
| SSE / WebSocket | incremental | non-standard for local servers; breaks ADR 0004 | ❌ v1 |
**Chosen:** streamed PCM, WAV fallback. Kokoro and Mimi (Miso's codec) are both 24 kHz, matching OpenAI's PCM default.

### Category: Mac playback (chunk 7)
**Recommended:** one always-running `AVAudioEngine` + `AVAudioPlayerNode`, `scheduleBuffer` per ~40–100 ms of PCM; Int16→Float32 in-app, mixer resamples; `stop()` drops queued buffers (~10 ms). Same surface as `SystemSpeechSentenceQueue`. Rejected: `AVAudioPlayer` per sentence (no streaming, gaps), `AVQueuePlayer` (needs files), AudioQueue (older C API, no gain). ([dev.to](https://dev.to/joostmbakker/how-i-got-sub-200ms-time-to-first-audio-streaming-llm-responses-on-ios-462o))

### Category: Latency strategy
Request each sentence the moment it arrives, 2–3 in flight, schedule strictly by `sentenceIndex`; one long-lived `URLSession`; warm the connection on hotkey press and the model with a one-word synthesis at launch; barge-in cancels tasks, stops the node, bumps a turn id. Phrase cache rejected (Claude's wording varies).

### Category: Deployment and ops
**Chosen:** Docker Compose on the Spark (`restart: unless-stopped`, NVIDIA runtime, `/health` check, model cache volume, log rotation), port published on the LAN IP only because Docker-published ports bypass ufw ([baeldung](https://www.baeldung.com/linux/docker-container-published-port-ignoring-ufw-rules)). Optional bearer token (Caddy in front, or in our wrapper). Rejected: bare venv + systemd (dependency drift).

### Category: Text normalization for speech
No model documents camelCase or file-extension handling. **Recommended:** a pure, unit-tested `speakableText` pass in the sidecar before `assistant.sentence` goes out for speech (e.g. `CompanionManager.swift` → "Companion Manager dot swift", `ws://` → "web socket"), leaving `spokenText` for the transcript unchanged. Kokoro and Magpie add their own number normalization on top.

## Innovative / non-obvious options
- **Miso TTS 8B** — Ken's pick to test: the most human-sounding open model found, but built for H100-class serving; on the Spark it is a bandwidth experiment. A llama.cpp or fp8 path for its Llama backbone is the lever if bf16 is too slow (unverified that one exists).
- **Kyutai Pocket TTS (100M, MIT)** — ~200 ms first chunk on CPU ([repo](https://github.com/kyutai-labs/pocket-tts)); could run on the Grace cores and leave the GPU free. No Spark report.
- **NVIDIA Magpie** — the best measured Spark latency; worth a second spike if Kokoro sounds too flat.
- **Kyutai TTS 1.6B / VibeVoice / Dia2** — accept streamed text; only pay off if Clicky ever streams tokens instead of sentences.

---

## Chosen stack
| Category | Chosen | Why | Rejected (and why) |
|----------|--------|-----|--------------------|
| TTS model | **Spike Miso TTS 8B first; Kokoro-82M if it fails the gate** | Ken wants the most human voice; Kokoro is the proven fallback | Magpie (kept as later spike), Qwen3 (at budget), Orpheus/Voxtral/Kyutai (bandwidth, license, no aarch64) |
| Serving | **Own FastAPI wrapper** for Miso; **Kokoro-FastAPI** on fallback | Miso has no server; Kokoro-FastAPI fits exactly | LocalAI/speaches (heavy or stalled), NIM (non-OpenAI shape) |
| Runtime | PyTorch cu130 aarch64, eager, soundfile I/O | lowest-risk path on sm_121 | ONNX GPU (no wheel), SGLang/TRT-LLM (no sm_121) |
| Transport | Streamed PCM 24 kHz, WAV fallback | lowest first audio, gapless | MP3/Opus, SSE, WebSocket |
| Playback | AVAudioEngine + one player node | streams, gapless, fast stop | AVAudioPlayer, AVQueuePlayer, AudioQueue |
| Deployment | Docker Compose, LAN-IP bind, `/health` | boot start, GPU access, contained deps | venv + systemd |
| Text normalization | sidecar `speakableText` pass | no model handles code tokens | per-model normalization only |

## Decision Register
> Severity & gating per `~/.claude/skills/severity-model.md`. Gate: S3+ surfaced (default mode).
| ID | Decision | Severity (why) | Status | Chosen / default |
|----|----------|----------------|--------|------------------|
| T-framework | Plain TTS model, not a conversational framework | S3 (architecture) | resolved (Ken) | plain TTS behind OpenAI shape |
| T-model | Which TTS model | S3 (voice quality vs latency, contested) | spike-needed (Ken: test Miso first) | Miso if it passes the gate, else Kokoro |
| T-server | Serving layer | S3 (new dependency) | resolved (Ken: no preference → recommended) | own wrapper for Miso; Kokoro-FastAPI on fallback |
| T-transport | Audio over the LAN | S3 (wire format) | resolved (Ken) | streamed PCM, WAV fallback |
| T-deploy | How it runs on the Spark | S3 (ops commitment) | resolved (Ken) | Docker Compose |
| T-runtime | PyTorch cu130 eager + soundfile | S2 (inside the container) | auto-decided | revisit if Miso needs llama.cpp |
| T-playback | AVAudioEngine player node | S2 (app-internal, chunk 7) | auto-decided | |
| T-normalize | Sidecar `speakableText` pass | S2 (pure function, testable) | auto-decided | |
| T-miso-gate | Pass line for the Miso spike | S3 (decides the model) | resolved 2026-09-27: Miso failed (221 ms/frame, RTF 2.8); **Ken: stay with Miso, optimize** | see "Miso spike results" |

## Deep compatibility findings (chosen stack vs codebase)
- **App:** `leanring-buddy/Info.plist` has no `NSAppTransportSecurity > NSAllowsLocalNetworking` and no `NSLocalNetworkUsageDescription`; both are needed for plain HTTP to the Spark, and macOS shows a Local Network prompt on first use (requests fail until allowed; show an error, don't go silent).
- **App:** the new player replaces `SystemSpeechSentenceQueue` behind the same three members (`enqueueSentence`, `stopImmediately`, `isSpeaking`), so `CompanionManager` barely changes; sentences need their `sentenceIndex` passed through for in-order scheduling.
- **Sidecar:** `assistant.sentence` is already per-sentence and ordered; `speakableText` slots in before it is sent, leaving `turn_complete.spokenText` untouched. Wire change? No: speak the same field, normalized in place, or add an optional `speakableText` field (decide in frame-goal).
- **Config:** base URL, voice, and sample rate become app settings (ADR 0004 already says base URL is a setting). A model swap to a non-24 kHz model needs the rate setting changed too — a small hole in "model swaps never touch the app".
- **Risk (Miso):** no streaming in the repo → first audio = whole-sentence synthesis time unless we add frame-level streaming from Mimi decode ourselves.
- **Risk (Miso):** torchaudio on aarch64 + CUDA is broken or CPU-only in several reports; Python 3.10 + `uv sync` may resolve CPU torch. Expect to patch dependencies.
- **Risk (Miso):** bandwidth estimate says ~1× real time at bf16 at best; no quantization path documented.
- **Risk (all):** no one has published Kokoro's first-audio time on a Spark either; measure both the same way.
- **Risk (ops):** Docker ports bypass ufw; bind to the LAN IP.
- **spike-needed (Miso gate), proposed:** on the Spark, after warm-up, a 15-word English sentence:
  1. GPU actually used (`torch.cuda.is_available()`, nvidia-smi shows load).
  2. Time to first audio: **pass ≤ 300 ms**, **Ken's call 300–800 ms** (relax the rail for the voice), **fail > 800 ms**.
  3. Real-time factor < 1.0 (synthesis faster than playback), else sentences queue up.
  4. Ken listens to three sentences including a code-ish one and judges the voice against Kokoro.
- **spike-needed (fallback):** same measurements for Kokoro-FastAPI's arm64 GPU image on GB10.

## Miso spike results (2026-09-27, measured on the Spark)
Setup: `~/clicky-voice/miso-spike` on the Spark; torch 2.11.0+cu130 (Miso pins 2.4, no aarch64 CUDA build);
bitsandbytes dropped (x86-only pin, only used for quantized layers); moshi's `torch<2.7` cap overridden;
tokenizer is the gated `meta-llama/Llama-3.2-1B` (Ken accepted the license and logged in on the Spark).
Load 36.8 s, 17.9 GB GPU memory, warm-up 1.9 s.

| Sentence | Words | Audio | Whole sentence | First frame | Per frame | RTF |
|---|---|---|---|---|---|---|
| plain | 18 | 5.6 s | 15.9 s | 237 ms | 221 ms | 2.84 |
| code | 13 | 7.3 s | 20.5 s | 226 ms | 221 ms | 2.81 |
| warm | 14 | 3.8 s | 10.9 s | 226 ms | 221 ms | 2.84 |

Per-frame split: backbone (7.0B) 72 ms, one pass; decoder (0.3B) 31 passes × 4.64 ms = 144 ms. Bandwidth
floors at bf16 (arithmetic, not measured): backbone ~51 ms, decoder ~68 ms. Budget: 80 ms per frame (12.5 Hz).
Verdict against the gate: fail. **Ken chose to stay with Miso and optimize** rather than fall back to Kokoro.

Optimization levers, in order (estimates, to be measured one at a time):
1. CUDA-graph the 31-pass decoder loop incl. sampling: 144 → ~70–80 ms.
2. Weight-only int8/int4 (backbone first, then decoder): backbone 72 → ~25–40 ms.
3. If still over budget: generate fewer codebooks (16 or 8 of 32), trading fidelity.
4. Stream Mimi decode per frame so first audio ≈ prefill + a few frames; the watermark step works on whole
   clips today and has to be reworked or dropped for streaming (check the license).
Voice: no presets; a British warm voice means an audio-prompt context segment, re-prefilled every sentence.

**Connected 2026-09-27 (Ken: no optimization for now, just connect).** Voice reference = the spike's
`miso_warm.wav` (Ken judged `miso_plain` broken). `spark-tts-server/miso_speech_server.py` runs from the
spike venv via `run_on_spark.sh` on port 8880 (not Docker, not on boot yet). Measured from the Mac: 13 words
→ 3.68 s audio in 10.6 s; a disconnected request cancels within one frame and the next starts at once.
Clicky: `SparkSpeechSentenceQueue.swift`, enabled by the `SparkSpeechBaseURL` user default.

**First live run (2026-09-28):** Ken heard only one sentence. Cause: Clicky sent all five sentences at
once and the server's one-at-a-time lock took them in arbitrary order (4 and 5 before 2), so in-order
playback stalled; the first sentence "sure." came back as 0.08 s of near silence. Fixed: the app sends one
sentence at a time (next request as soon as the previous audio arrives); the sidecar joins sentences under
4 words to the next; the persona now asks for 8–15-word conversational sentences. Awaiting Ken's run.
Open: Miso speed (levers above), start the server on boot (Docker Compose was the plan; it runs from the
spike venv today), and whether to raise quality with a longer or better voice reference.

## Kokoro on the Spark (2026-09-28, Ken: switch to Kokoro to try it; Miso stopped, kept on disk)
Kokoro-FastAPI `v0.9.0-cu129-arm64` in Docker (`clicky-kokoro`, `--gpus all`, port 8880 on the LAN IP, no
restart policy). Runs on cuda (sm_121 capability warning is harmless); 0.9 GB GPU memory; warm-up 3.6 s.
Measured from the Mac, warm, `stream: false`, pcm: 6.2 s audio in 0.47 s, 4.1 s in 0.73 s, 0.8 s in 0.33 s
(RTF ~0.08–0.18). App: `SparkSpeechModel` = `kokoro`, `SparkSpeechVoice` = `af_heart` (user defaults).
Ken likes the voices. Back to Miso: `docker stop clicky-kokoro`, `run_on_spark.sh`, delete both defaults.

## Handoff → frame-goal
Tech direction is chosen, with one spike deciding the model. Next: run `frame-goal` on `spark-tts-server`.
It will read this landscape as the chosen tech direction and frame the goal/architecture around it; then
`chunk-plan` decomposes, starting with the Miso spike on the Spark.
