#!/usr/bin/env bash
#
# Download the Silero VAD weights used by SileroVoiceActivityDetector.
#
# ~865 KB, in whisper.cpp's GGML format, so it runs through the ggml backend already
# linked for speech recognition — no ONNX Runtime or separate Core ML model needed.
#
# Usage:
#   scripts/fetch-vad-model.sh            # silero-v5.1.2 (default)
#   scripts/fetch-vad-model.sh v6.2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-v5.1.2}"
NAME="ggml-silero-${VERSION}.bin"
DEST="$ROOT/Models/$NAME"
URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/$NAME"

case "$VERSION" in
  v5.1.2|v6.2.0) ;;
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  *) echo "error: unknown version '$VERSION' (expected v5.1.2 or v6.2.0)" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/Models"

if [[ -f "$DEST" ]]; then
  echo "==> $NAME already present ($(du -h "$DEST" | cut -f1))"
  exit 0
fi

echo "==> Downloading $NAME"
curl -L --fail --progress-bar -o "$DEST.partial" "$URL"
mv "$DEST.partial" "$DEST"
echo "==> Saved $DEST ($(du -h "$DEST" | cut -f1))"
