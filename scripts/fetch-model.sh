#!/usr/bin/env bash
#
# Download a stock Whisper GGML model into Models/.
#
# These are the upstream multilingual weights, used until build step 3 produces the
# Quran-tuned Tarteel conversion. Models are not checked in: they are large, and the
# shipping app will bundle the converted model instead.
#
# Usage:
#   scripts/fetch-model.sh          # base (~141 MB, default)
#   scripts/fetch-model.sh tiny     # ~75 MB
#   scripts/fetch-model.sh small    # ~466 MB

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT/Models"
SIZE="${1:-base}"

case "$SIZE" in
  tiny|base|small|medium) ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) echo "error: unknown size '$SIZE' (expected tiny|base|small|medium)" >&2; exit 2 ;;
esac

NAME="ggml-${SIZE}.bin"
DEST="$MODELS_DIR/$NAME"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$NAME"

mkdir -p "$MODELS_DIR"

if [[ -f "$DEST" ]]; then
  echo "==> $NAME already present ($(du -h "$DEST" | cut -f1)); nothing to do."
  exit 0
fi

echo "==> Downloading $NAME"
echo "    from $URL"
curl -L --fail --progress-bar -o "$DEST.partial" "$URL"
mv "$DEST.partial" "$DEST"

echo "==> Saved $DEST ($(du -h "$DEST" | cut -f1))"
echo
echo "No Core ML encoder yet — whisper.cpp falls back to the Metal/CPU encoder."
echo "Build step 3 adds the converted encoder (<stem>-encoder.mlmodelc) alongside this file."
