# spark-tts-server

Clicky's voice. A small OpenAI-compatible text-to-speech server that runs Miso TTS 8B on the DGX Spark.
The app calls `POST /v1/audio/speech` once per sentence (ADR 0004); the model behind it can change
without touching the app. Why Miso, and how it measured: `.claude/plans/backlog/spark-tts-server/tech-scout.md`.

## API

```
POST /v1/audio/speech  {"input": "Hello.", "voice": "warm", "response_format": "pcm"}
  → audio/pcm: raw 24 kHz mono 16-bit little-endian samples (or "wav" for a WAV file)
GET  /health           → {"status": "ok", "model": "miso-tts-8b", "voices": ["warm"]}
```

`voice` names a reference clip: Miso has no preset voices and continues in the voice of the clip it is
given as context. Unknown names fall back to the default voice. Generations run one at a time; a client
that disconnects cancels its generation within one frame.

## Layout on the Spark

```
~/clicky-voice/
  miso-spike/.venv/      Python 3.12, torch 2.11.0+cu130, Miso deps, fastapi, uvicorn
  miso-spike/MisoTTS/    github.com/MisoLabsAI/MisoTTS at cd7dde1
  server/                this directory's miso_speech_server.py
  voices/warm.wav        24 kHz mono reference clip (Ken's pick from the spike)
  server.log
```

Environment notes (all found in the 2026-09-27 spike):
- Miso pins torch 2.4, which has no aarch64 CUDA build and predates Blackwell: install
  `torch==2.11.0+cu130 torchaudio==2.11.0+cu130` from `https://download.pytorch.org/whl/cu130` and
  override the pin (`uv pip install --override`). moshi's `torch<2.7` cap is overridden the same way.
- bitsandbytes 0.45.5 is x86-only; Miso only uses it for quantized layers, so it is dropped.
- The tokenizer is the gated `meta-llama/Llama-3.2-1B`: accept the license on Hugging Face and run
  `huggingface-cli login` on the Spark once.

## Run

```bash
~/clicky-voice/server/run_on_spark.sh          # on the Spark; ~40 s to load and warm
curl http://<spark>.local:8880/health          # from the Mac
```

Point Clicky at it (kept out of the repo because it names Ken's machine):

```bash
defaults write com.yourcompany.leanring-buddy SparkSpeechBaseURL http://<spark>.local:8880
```

## Performance today

About 221 ms of GPU time per 80 ms of audio (RTF ≈ 2.8), so a sentence arrives roughly 3x its spoken
length after it is sent, in one piece. Optimization levers (CUDA graphs for the 31-pass decoder,
int8/int4 weights, fewer codebooks, per-frame streaming) are listed in the tech-scout doc.
