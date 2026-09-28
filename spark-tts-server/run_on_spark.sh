#!/usr/bin/env bash
# Starts the Miso speech server on the Spark in the background, logging to ~/clicky-voice/server.log.
# Layout on the Spark (see README.md): ~/clicky-voice/{miso-spike/.venv, miso-spike/MisoTTS, server, voices}.
# Not started on boot yet; run this again after a reboot.
set -euo pipefail

CLICKY_VOICE_DIRECTORY="$HOME/clicky-voice"
PYTHON="$CLICKY_VOICE_DIRECTORY/miso-spike/.venv/bin/python"
LOG_FILE="$CLICKY_VOICE_DIRECTORY/server.log"

if pgrep -f "[m]iso_speech_server.py" >/dev/null; then
  echo "already running (pid $(pgrep -f "[m]iso_speech_server.py"))"
  exit 0
fi

setsid nohup "$PYTHON" -W ignore "$CLICKY_VOICE_DIRECTORY/server/miso_speech_server.py" \
  --miso-code "$CLICKY_VOICE_DIRECTORY/miso-spike/MisoTTS" \
  --voice-name warm \
  --voice-audio "$CLICKY_VOICE_DIRECTORY/voices/warm.wav" \
  --voice-transcript "Honestly, that's a really good question, and I think you're closer than you realize." \
  --port 8880 \
  >"$LOG_FILE" 2>&1 </dev/null &

echo "started; follow with: tail -f $LOG_FILE"
