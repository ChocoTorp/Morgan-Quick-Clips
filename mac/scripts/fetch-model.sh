#!/usr/bin/env bash
# fetch-model.sh — download the Whisper model used for transcription/captions.
#
# The app currently looks for the model at a hard-coded path (see README:
# "Known limitations"). By default this downloads to that path so the app finds it.
# Override with MODEL_DIR=/some/dir ./fetch-model.sh

set -euo pipefail
MODEL_DIR="${MODEL_DIR:-$HOME/.hermes/skills/media/ffmpeg/models}"
MODEL="ggml-base.en.bin"   # English, ~142 MB. Swap for ggml-small.en.bin etc. for more accuracy.
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"

mkdir -p "$MODEL_DIR"
if [ -s "$MODEL_DIR/$MODEL" ]; then
  echo "Model already present: $MODEL_DIR/$MODEL"; exit 0
fi
echo "Downloading $MODEL (~142 MB) to $MODEL_DIR …"
curl -L --fail -o "$MODEL_DIR/$MODEL" "$URL"
echo "Done: $MODEL_DIR/$MODEL"
