#!/usr/bin/env bash
#
# Build whisper.cpp as static libraries for macOS (arm64) and stage its public
# headers where SwiftPM's CWhisper module map can see them.
#
# Run once after cloning, and again whenever Vendor/whisper.cpp is updated.
#
# Usage:
#   scripts/build-whisper.sh            # incremental
#   scripts/build-whisper.sh --clean    # wipe the build directory first

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WHISPER_DIR="$ROOT/Vendor/whisper.cpp"
BUILD_DIR="$WHISPER_DIR/build"
INCLUDE_DIR="$ROOT/Sources/CWhisper/include"

if [[ ! -d "$WHISPER_DIR" ]]; then
  echo "error: $WHISPER_DIR missing. Clone it first:" >&2
  echo "  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git Vendor/whisper.cpp" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --clean) echo "==> Cleaning $BUILD_DIR"; rm -rf "$BUILD_DIR" ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- Toolchain -------------------------------------------------------------------
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  ACTIVE="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$ACTIVE" == *"/Xcode"*".app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$ACTIVE"
  else
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app \
                     "$HOME/Downloads/Xcode.app" "$HOME/Downloads/Xcode-beta.app"; do
      [[ -d "$candidate/Contents/Developer" ]] && export DEVELOPER_DIR="$candidate/Contents/Developer" && break
    done
  fi
fi
[[ -n "${DEVELOPER_DIR:-}" ]] || { echo "error: no Xcode found; set DEVELOPER_DIR" >&2; exit 1; }
echo "==> Toolchain: $DEVELOPER_DIR"

# --- Configure -------------------------------------------------------------------
# WHISPER_COREML is switched on now even though no .mlmodelc exists yet: with
# ALLOW_FALLBACK the runtime quietly uses the CPU/Metal encoder when the Core ML
# model is missing, so dropping in the converted encoder at build step 3 needs no
# rebuild of these libraries.
echo "==> Configuring"
cmake -B "$BUILD_DIR" -S "$WHISPER_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_COREML=ON \
  -DWHISPER_COREML_ALLOW_FALLBACK=ON \
  > /dev/null

echo "==> Building"
cmake --build "$BUILD_DIR" --config Release -j"$(sysctl -n hw.ncpu)" > /dev/null

# --- Stage headers ---------------------------------------------------------------
# whisper.h does `#include "ggml.h"`, which resolves relative to whisper.h's own
# directory — but upstream keeps them in two separate include trees. Copying both
# into one flat directory is what makes the module map work without any header
# search path games in Package.swift.
echo "==> Staging headers into Sources/CWhisper/include"
mkdir -p "$INCLUDE_DIR"
cp "$WHISPER_DIR/include/whisper.h" "$INCLUDE_DIR/"
cp "$WHISPER_DIR/ggml/include/"*.h "$INCLUDE_DIR/"

# --- Report ----------------------------------------------------------------------
echo "==> Libraries:"
MISSING=0
for lib in \
  "$BUILD_DIR/src/libwhisper.a" \
  "$BUILD_DIR/ggml/src/libggml.a" \
  "$BUILD_DIR/ggml/src/libggml-base.a" \
  "$BUILD_DIR/ggml/src/libggml-cpu.a" \
  "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" \
  "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"; do
  if [[ -f "$lib" ]]; then
    printf '    %-52s %s\n' "$(basename "$lib")" "$(du -h "$lib" | cut -f1)"
  else
    echo "    MISSING: $lib" >&2
    MISSING=1
  fi
done
[[ -f "$BUILD_DIR/src/libwhisper.coreml.a" ]] && \
  printf '    %-52s %s\n' "libwhisper.coreml.a" "$(du -h "$BUILD_DIR/src/libwhisper.coreml.a" | cut -f1)"

[[ "$MISSING" == "0" ]] || { echo "error: expected libraries missing" >&2; exit 1; }
echo "==> Done. Now run: swift build"
