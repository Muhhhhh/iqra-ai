#!/usr/bin/env bash
#
# Convert the Tarteel Quran-tuned Whisper model into the three artefacts the app needs:
#
#   Models/ggml-base-ar-quran-q8_0.bin           quantised GGML weights (~77 MB)
#   Models/ggml-base-ar-quran-encoder.mlmodelc   Core ML encoder for the Neural Engine
#   Models/work/ggml-model.bin                   unquantised GGML, kept for comparison
#
# Reproducible from a clean checkout. Everything is fetched into Models/, which is not
# checked in.
#
# Usage:
#   scripts/convert-model.sh                 # full pipeline
#   scripts/convert-model.sh --skip-coreml   # GGML + quantise only (much faster)
#   scripts/convert-model.sh --clean         # discard previous artefacts first
#
# Prerequisites: see scripts/README.md. The Python environment is created automatically
# in .venv on first run.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HF_REPO="tarteel-ai/whisper-base-ar-quran"
MODEL_NAME="base-ar-quran"
SRC_DIR="$ROOT/Models/src/whisper-base-ar-quran"
WORK_DIR="$ROOT/Models/work"
WHISPER_DIR="$ROOT/Vendor/whisper.cpp"
VENV="$ROOT/.venv"
QUANT_TYPE="q8_0"

SKIP_COREML=0
KEEP_F16=0
for arg in "$@"; do
  case "$arg" in
    --skip-coreml) SKIP_COREML=1 ;;
    # Keep the unquantised fp16 weights alongside the quantised ones, so the cost of
    # quantisation can be measured rather than assumed.
    --keep-f16) KEEP_F16=1 ;;
    --clean) echo "==> Cleaning"; rm -rf "$WORK_DIR" "$ROOT/Models/ggml-${MODEL_NAME}"* ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ -d "$WHISPER_DIR" ]] || { echo "error: $WHISPER_DIR missing; run scripts/build-whisper.sh first" >&2; exit 1; }

# --- Toolchain -------------------------------------------------------------------
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  ACTIVE="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$ACTIVE" == *"/Xcode"*".app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$ACTIVE"
  else
    for c in /Applications/Xcode.app /Applications/Xcode-beta.app \
             "$HOME/Downloads/Xcode.app" "$HOME/Downloads/Xcode-beta.app"; do
      [[ -d "$c/Contents/Developer" ]] && export DEVELOPER_DIR="$c/Contents/Developer" && break
    done
  fi
fi
[[ -n "${DEVELOPER_DIR:-}" ]] || { echo "error: no Xcode found; set DEVELOPER_DIR" >&2; exit 1; }

# --- Python environment ----------------------------------------------------------
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "==> Creating Python environment in .venv"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi

if ! "$VENV/bin/python" -c "import torch, coremltools, whisper, transformers" 2>/dev/null; then
  echo "==> Installing conversion dependencies (this takes a few minutes)"
  # numpy is pinned below 2 because coremltools' torch converter still assumes the
  # 1.x ABI and fails to trace otherwise.
  "$VENV/bin/pip" install --quiet torch coremltools openai-whisper ane_transformers \
    transformers huggingface_hub "numpy<2"
fi

# --- Fetch ------------------------------------------------------------------------
if [[ ! -f "$SRC_DIR/pytorch_model.bin" ]]; then
  echo "==> Downloading $HF_REPO (~279 MB)"
  "$VENV/bin/python" - <<PY
from huggingface_hub import snapshot_download
snapshot_download("$HF_REPO", local_dir="$SRC_DIR",
                  allow_patterns=["*.json","*.txt","pytorch_model.bin"])
PY
else
  echo "==> Model already downloaded"
fi

# --- Normalise the config ----------------------------------------------------------
# whisper.cpp's convert-h5-to-ggml.py writes `max_length` into the GGML header as the
# decoder context size (n_text_ctx). For stock OpenAI checkpoints that field is absent
# and the script falls back to `max_target_positions`, which is correct. Tarteel's
# config *does* set max_length — to 1024, a text-generation default that has nothing to
# do with the architecture — while the real decoder positional embedding is 448 rows.
#
# Left alone, this produces a GGML file that whisper.cpp refuses to load:
#   "tensor 'decoder.positional_embedding' has wrong size ... expected: [512, 1024, 1]"
"$VENV/bin/python" - <<PY
import json, pathlib
p = pathlib.Path("$SRC_DIR/config.json")
cfg = json.loads(p.read_text())
architectural = cfg["max_target_positions"]
if cfg.get("max_length") != architectural:
    print(f"==> Correcting config.json: max_length {cfg.get('max_length')} -> {architectural}")
    cfg["max_length"] = architectural
    p.write_text(json.dumps(cfg, indent=2))
else:
    print("==> config.json already correct")
PY

# --- GGML conversion ----------------------------------------------------------------
echo "==> Converting HuggingFace -> GGML"
mkdir -p "$WORK_DIR"
SITE="$("$VENV/bin/python" -c 'import whisper, os; print(os.path.dirname(os.path.dirname(whisper.__file__)))')"
( cd "$WHISPER_DIR" && "$VENV/bin/python" models/convert-h5-to-ggml.py "$SRC_DIR" "$SITE" "$WORK_DIR" >/dev/null )
[[ -f "$WORK_DIR/ggml-model.bin" ]] || { echo "error: GGML conversion produced nothing" >&2; exit 1; }

# --- Quantise -----------------------------------------------------------------------
QUANT_BIN="$WHISPER_DIR/build-tools/bin/whisper-quantize"
if [[ ! -x "$QUANT_BIN" ]]; then
  echo "==> Building whisper-quantize"
  # A separate build directory from build-whisper.sh: the quantize tool lives under
  # examples/, which the library build deliberately disables.
  cmake -B "$WHISPER_DIR/build-tools" -S "$WHISPER_DIR" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON >/dev/null 2>&1
  cmake --build "$WHISPER_DIR/build-tools" --target whisper-quantize -j"$(sysctl -n hw.ncpu)" >/dev/null
fi

if [[ "${KEEP_F16:-0}" == "1" ]]; then
  cp "$WORK_DIR/ggml-model.bin" "$ROOT/Models/ggml-${MODEL_NAME}-f16.bin"
  echo "==> Kept unquantised weights: Models/ggml-${MODEL_NAME}-f16.bin ($(du -h "$ROOT/Models/ggml-${MODEL_NAME}-f16.bin" | cut -f1))"
fi

echo "==> Quantising to $QUANT_TYPE"
"$QUANT_BIN" "$WORK_DIR/ggml-model.bin" "$ROOT/Models/ggml-${MODEL_NAME}-${QUANT_TYPE}.bin" "$QUANT_TYPE" \
  | grep -E "model size|quant size"

# --- Core ML encoder ----------------------------------------------------------------
if [[ "$SKIP_COREML" == "1" ]]; then
  echo "==> Skipping Core ML encoder (--skip-coreml)"
else
  echo "==> Converting encoder to Core ML (slow)"
  # convert-h5-to-coreml.py validates --model-name against a hard-coded list of stock
  # Whisper sizes, so a custom name is rejected. The name only decides output filenames;
  # the architecture comes from the checkpoint. So convert as "base" and rename after.
  ( cd "$WHISPER_DIR" && "$VENV/bin/python" models/convert-h5-to-coreml.py \
      --model-name base --model-path "$SRC_DIR" --encoder-only True >/dev/null 2>&1 )

  PACKAGE="$WHISPER_DIR/models/coreml-encoder-base.mlpackage"
  [[ -d "$PACKAGE" ]] || { echo "error: Core ML conversion produced nothing" >&2; exit 1; }

  echo "==> Compiling .mlpackage -> .mlmodelc"
  xcrun coremlc compile "$PACKAGE" "$ROOT/Models/" >/dev/null
  # whisper.cpp strips a trailing -qX_X before looking for the encoder, so one encoder
  # serves every quantisation of these weights.
  rm -rf "$ROOT/Models/ggml-${MODEL_NAME}-encoder.mlmodelc"
  mv "$ROOT/Models/coreml-encoder-base.mlmodelc" "$ROOT/Models/ggml-${MODEL_NAME}-encoder.mlmodelc"
  rm -rf "$PACKAGE" "$WHISPER_DIR/models/hf-base.pt"
fi

# --- Report --------------------------------------------------------------------------
echo
echo "==> Artefacts:"
for f in "$ROOT/Models/ggml-${MODEL_NAME}-${QUANT_TYPE}.bin" "$ROOT/Models/ggml-${MODEL_NAME}-encoder.mlmodelc"; do
  [[ -e "$f" ]] && printf '    %-46s %s\n' "$(basename "$f")" "$(du -sh "$f" | cut -f1)"
done
echo
echo "Verify with:  swift test --filter Whisper"
echo "Run the app:  scripts/run-macos.sh"
