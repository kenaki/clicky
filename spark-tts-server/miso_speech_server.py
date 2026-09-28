"""
OpenAI-compatible text-to-speech server for Clicky, running Miso TTS 8B on the DGX Spark.

  POST /v1/audio/speech   {"model", "input", "voice", "response_format": "pcm" | "wav"}
                          → 24 kHz mono 16-bit audio (pcm = raw little-endian samples, wav = with header)
  GET  /health            → {"status": "ok", "model": ..., "voices": [...]}

The contract is ADR 0004 (docs/decisions/0004-spark-voice-openai-compatible-endpoints.md); the app
never cares which model sits behind it. Miso has no preset voices: a voice is a short reference clip
passed as conversation context, so every sentence continues in that voice.

One GPU, one model: generations run one at a time. A client that disconnects (Clicky's barge-in
cancels its requests) stops its generation within one frame, and requests that were still waiting
are skipped, so the GPU is free for the next turn right away.

Miso generates slower than real time on the Spark today (about 221 ms per 80 ms frame, measured
2026-09-27; see .claude/plans/backlog/spark-tts-server/tech-scout.md), so each sentence arrives as
one whole clip after roughly 3x its spoken length. Streaming comes with the optimization work.
"""
import argparse
import asyncio
import io
import logging
import os
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

os.environ["NO_TORCH_COMPILE"] = "1"

import numpy
import soundfile
import torch
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

logger = logging.getLogger("miso-speech-server")

PCM_SAMPLE_RATE = 24_000
MAXIMUM_INPUT_CHARACTERS = 600
DISCONNECT_POLL_SECONDS = 0.1


class GenerationCancelled(Exception):
    """Raised inside the frame loop when the client that asked for this audio has gone away."""


@dataclass
class VoiceReference:
    """A named voice: the words spoken in the reference clip and the clip itself."""

    name: str
    transcript: str
    audio_path: Path


class SpeechRequest(BaseModel):
    model: str = "miso-tts-8b"
    input: str
    voice: str = "warm"
    response_format: str = "pcm"
    speed: float = 1.0  # accepted for OpenAI compatibility; Miso has no speed control


class MisoSpeechEngine:
    """Owns the loaded model, the voice references, and the one-at-a-time generation lock."""

    def __init__(self, miso_code_directory: Path, voice_references: list[VoiceReference]):
        sys.path.insert(0, str(miso_code_directory))
        from generator import Segment, load_miso_8b  # Miso's own code, not a package

        self._segment_type = Segment
        loading_started = time.perf_counter()
        self._generator = load_miso_8b("cuda")
        logger.info("model loaded in %.1f s", time.perf_counter() - loading_started)

        self.voice_segments_by_name = {
            voice_reference.name: self._load_voice_segment(voice_reference) for voice_reference in voice_references
        }
        self.default_voice_name = voice_references[0].name
        self.generation_lock = asyncio.Lock()
        self._cancel_current_generation = threading.Event()
        self._install_cancellation_check()

    def _load_voice_segment(self, voice_reference: VoiceReference):
        audio_samples, sample_rate = soundfile.read(voice_reference.audio_path, dtype="float32")
        if sample_rate != PCM_SAMPLE_RATE:
            raise ValueError(f"{voice_reference.audio_path} is {sample_rate} Hz; voice references must be {PCM_SAMPLE_RATE} Hz")
        if audio_samples.ndim > 1:
            audio_samples = audio_samples.mean(axis=1)
        logger.info("voice %r: %.1f s reference", voice_reference.name, len(audio_samples) / sample_rate)
        return self._segment_type(speaker=0, text=voice_reference.transcript, audio=torch.from_numpy(audio_samples))

    def _install_cancellation_check(self) -> None:
        # Miso's generate() has no cancel hook, so check between frames by wrapping the per-frame call.
        original_generate_frame = self._generator._model.generate_frame

        def generate_frame_unless_cancelled(*args, **kwargs):
            if self._cancel_current_generation.is_set():
                raise GenerationCancelled()
            return original_generate_frame(*args, **kwargs)

        self._generator._model.generate_frame = generate_frame_unless_cancelled

    def cancel_current_generation(self) -> None:
        self._cancel_current_generation.set()

    def synthesize(self, text: str, voice_name: str) -> numpy.ndarray:
        """Blocking. Returns float32 mono samples at 24 kHz. Call with generation_lock held."""
        self._cancel_current_generation.clear()
        voice_segment = self.voice_segments_by_name.get(voice_name) or self.voice_segments_by_name[self.default_voice_name]
        # Cap the audio length so a missed end-of-speech can't run for the full 90 s default.
        word_count = len(text.split())
        maximum_audio_milliseconds = min(30_000, 2_000 + 700 * word_count)
        with torch.inference_mode():
            audio = self._generator.generate(
                text=text,
                speaker=0,
                context=[voice_segment],
                max_audio_length_ms=maximum_audio_milliseconds,
            )
        return audio.float().cpu().numpy()


def encode_audio(audio_samples: numpy.ndarray, response_format: str) -> tuple[bytes, str]:
    clipped_samples = numpy.clip(audio_samples, -1.0, 1.0)
    if response_format == "wav":
        wav_buffer = io.BytesIO()
        soundfile.write(wav_buffer, clipped_samples, PCM_SAMPLE_RATE, format="WAV", subtype="PCM_16")
        return wav_buffer.getvalue(), "audio/wav"
    # OpenAI's "pcm": raw 24 kHz 16-bit signed little-endian mono, no header.
    pcm_samples = (clipped_samples * 32767).astype("<i2")
    return pcm_samples.tobytes(), "audio/pcm"


def create_app(engine: MisoSpeechEngine) -> FastAPI:
    app = FastAPI(title="Clicky Miso speech server")

    @app.get("/health")
    async def health():
        return {"status": "ok", "model": "miso-tts-8b", "voices": sorted(engine.voice_segments_by_name)}

    @app.post("/v1/audio/speech")
    async def create_speech(speech_request: SpeechRequest, request: Request):
        text = speech_request.input.strip()
        if not text:
            return JSONResponse({"error": {"message": "input is empty"}}, status_code=400)
        if len(text) > MAXIMUM_INPUT_CHARACTERS:
            return JSONResponse({"error": {"message": f"input is over {MAXIMUM_INPUT_CHARACTERS} characters"}}, status_code=400)
        if speech_request.response_format not in ("pcm", "wav"):
            return JSONResponse({"error": {"message": "response_format must be pcm or wav"}}, status_code=400)

        async with engine.generation_lock:
            # A request can wait here for seconds; skip it if Clicky already cancelled it.
            if await request.is_disconnected():
                logger.info("skipped (client gone before start): %r", text[:60])
                return Response(status_code=499)

            generation_started = time.perf_counter()
            generation_task = asyncio.create_task(asyncio.to_thread(engine.synthesize, text, speech_request.voice))
            while not generation_task.done():
                await asyncio.wait({generation_task}, timeout=DISCONNECT_POLL_SECONDS)
                if not generation_task.done() and await request.is_disconnected():
                    engine.cancel_current_generation()
            try:
                audio_samples = generation_task.result()
            except GenerationCancelled:
                logger.info("cancelled after %.1f s: %r", time.perf_counter() - generation_started, text[:60])
                return Response(status_code=499)

        generation_seconds = time.perf_counter() - generation_started
        audio_seconds = len(audio_samples) / PCM_SAMPLE_RATE
        logger.info(
            "%d words -> %.2f s audio in %.2f s (RTF %.2f): %r",
            len(text.split()), audio_seconds, generation_seconds, generation_seconds / max(audio_seconds, 0.01), text[:60],
        )
        audio_bytes, media_type = encode_audio(audio_samples, speech_request.response_format)
        return Response(
            content=audio_bytes,
            media_type=media_type,
            headers={"X-Generation-Seconds": f"{generation_seconds:.2f}", "X-Audio-Seconds": f"{audio_seconds:.2f}"},
        )

    return app


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--miso-code", type=Path, required=True, help="Path to the MisoTTS repository checkout")
    parser.add_argument("--voice-name", default="warm")
    parser.add_argument("--voice-audio", type=Path, required=True, help="24 kHz mono WAV of the reference voice")
    parser.add_argument("--voice-transcript", required=True, help="The exact words spoken in --voice-audio")
    # "::" listens on IPv6 and IPv4; the Spark's .local name resolves to IPv6 from the Mac.
    parser.add_argument("--host", default="::")
    parser.add_argument("--port", type=int, default=8880)
    return parser.parse_args()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    arguments = parse_arguments()
    if not torch.cuda.is_available():
        sys.exit("CUDA is not available: this PyTorch build is CPU-only or the GPU is not visible.")
    engine = MisoSpeechEngine(
        miso_code_directory=arguments.miso_code,
        voice_references=[VoiceReference(arguments.voice_name, arguments.voice_transcript, arguments.voice_audio)],
    )
    # Warm the CUDA kernels so the first real sentence doesn't pay for it.
    engine.synthesize("Hello there.", engine.default_voice_name)
    logger.info("warm; listening on [%s]:%d", arguments.host, arguments.port)
    uvicorn.run(create_app(engine), host=arguments.host, port=arguments.port, log_level="warning")


if __name__ == "__main__":
    main()
