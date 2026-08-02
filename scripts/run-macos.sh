#!/usr/bin/env bash
#
# Build the macOS app, wrap it in a proper .app bundle, ad-hoc sign it, and launch it.
#
# The bundle is not optional: macOS only grants microphone access (TCC) to a signed
# bundle with NSMicrophoneUsageDescription in its Info.plist. `swift run IqraMac`
# produces a bare executable, which is silently denied the mic and has no menu bar.
#
# Usage:
#   scripts/run-macos.sh            # release build, launch
#   scripts/run-macos.sh --debug    # debug build
#   scripts/run-macos.sh --no-open  # build the bundle but don't launch

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="release"
OPEN_APP=1
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIGURATION="debug" ;;
    --release) CONFIGURATION="release" ;;
    --no-open) OPEN_APP=0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- Toolchain -------------------------------------------------------------------
# SwiftUI's @State/@Observable are macros, and the macro plugins ship inside Xcode.
# A Command Line Tools-only toolchain compiles RecitationCore fine but fails on the
# app target with "plugin for module 'SwiftUIMacros' not found".
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  ACTIVE="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$ACTIVE" == *"/Xcode"*".app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$ACTIVE"
  else
    for candidate in \
      /Applications/Xcode.app \
      /Applications/Xcode-beta.app \
      "$HOME/Downloads/Xcode.app" \
      "$HOME/Downloads/Xcode-beta.app"; do
      if [[ -d "$candidate/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$candidate/Contents/Developer"
        break
      fi
    done
  fi
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  echo "error: no Xcode found. Install Xcode, or set DEVELOPER_DIR to its Contents/Developer." >&2
  echo "       Command Line Tools alone cannot build the SwiftUI app target." >&2
  exit 1
fi
echo "==> Toolchain: $DEVELOPER_DIR"

# --- Build -----------------------------------------------------------------------
echo "==> Building IqraMac ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product IqraMac

BIN_PATH="$(swift build -c "$CONFIGURATION" --product IqraMac --show-bin-path)"
EXECUTABLE="$BIN_PATH/IqraMac"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: built executable not found at $EXECUTABLE" >&2
  exit 1
fi

# --- Assemble the bundle ---------------------------------------------------------
APP="$ROOT/build/Iqra.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/IqraMac"
cp "$ROOT/Apps/macOS/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM emits a resource bundle next to the binary when a target has resources.
# Copy any that exist so they resolve at runtime.
for bundle in "$BIN_PATH"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# The muṣḥaf typeface (Amiri Quran, SIL OFL). Registered into the process at runtime;
# without it the app falls back to Geeza Pro, which is complete but plain.
if [[ -f "$ROOT/Resources/Fonts/AmiriQuran.ttf" ]]; then
  cp "$ROOT/Resources/Fonts/AmiriQuran.ttf" "$APP/Contents/Resources/"
  cp "$ROOT/Resources/Fonts/OFL.txt" "$APP/Contents/Resources/AmiriQuran-OFL.txt" 2>/dev/null || true
  echo "==> Bundling muṣḥaf font"
fi

# The King Fahd Complex per-page fonts (QCF v1) — Uthman Taha's calligraphy, one font
# per muṣḥaf page. 92 MB, and the reason the pages look like a printed muṣḥaf rather than
# a Naskh approximation. Without them the app falls back to Amiri Quran + Unicode text.
if [[ -d "$ROOT/Resources/Fonts/QCF" ]]; then
  mkdir -p "$APP/Contents/Resources/QCF"
  cp -c "$ROOT/Resources/Fonts/QCF/"*.TTF "$APP/Contents/Resources/QCF/" 2>/dev/null \
    || cp "$ROOT/Resources/Fonts/QCF/"*.TTF "$APP/Contents/Resources/QCF/"
  echo "==> Bundling calligraphic page fonts ($(ls "$APP/Contents/Resources/QCF" | wc -l | tr -d ' ') files, $(du -sh "$ROOT/Resources/Fonts/QCF" | cut -f1))"
fi

# The Muaalem pronunciation model and its feature front-end. Without them tajweed falls
# back to measuring madd duration, which cannot judge ghunnah or qalqalah.
for package in "$ROOT"/Models/muaalem-*.mlpackage "$ROOT"/Models/muaalem-*.mlmodelc; do
  [[ -e "$package" ]] || continue
  cp -Rc "$package" "$APP/Contents/Resources/" 2>/dev/null || cp -R "$package" "$APP/Contents/Resources/"
  echo "==> Bundling tajweed model ($(basename "$package"), $(du -sh "$package" | cut -f1))"
  break
done
if [[ -f "$ROOT/Resources/muaalem-frontend.bin" ]]; then
  cp "$ROOT/Resources/muaalem-frontend.bin" "$APP/Contents/Resources/"
fi

# The Quran database. Without it the app has no text to practise against.
if [[ -f "$ROOT/Resources/quran.sqlite3" ]]; then
  cp -c "$ROOT/Resources/quran.sqlite3" "$APP/Contents/Resources/" 2>/dev/null \
    || cp "$ROOT/Resources/quran.sqlite3" "$APP/Contents/Resources/"
  echo "==> Bundling Quran database ($(du -h "$ROOT/Resources/quran.sqlite3" | cut -f1))"
else
  echo "==> No Quran database — run scripts/build-quran-db.py" >&2
fi

# Whisper weights must live *inside* the bundle: the app is sandboxed, so it cannot
# read the repo's Models/ directory. `cp -c` uses an APFS clone, so copying ~141 MB
# on every run is effectively free.
# Prefer the Quran-tuned conversion; fall back to whatever stock weights are present.
# The Core ML encoder must ship alongside, or whisper.cpp silently runs the encoder on
# Metal/CPU instead of the Neural Engine.
BUNDLED=0
if [[ -f "$ROOT/Models/ggml-base-ar-quran-q8_0.bin" ]]; then
  MODELS=("$ROOT/Models/ggml-base-ar-quran-q8_0.bin")
elif compgen -G "$ROOT/Models/ggml-*.bin" > /dev/null; then
  # Exclude the Silero VAD weights, which are bundled separately below.
  MODELS=()
  for candidate in "$ROOT"/Models/ggml-*.bin; do
    [[ "$(basename "$candidate")" == ggml-silero-* ]] || MODELS+=("$candidate")
  done
else
  MODELS=()
fi

if (( ${#MODELS[@]} )); then
  echo "==> Bundling model"
  for model in "${MODELS[@]}"; do
    cp -c "$model" "$APP/Contents/Resources/" 2>/dev/null || cp "$model" "$APP/Contents/Resources/"
    printf '    %-46s %s\n' "$(basename "$model")" "$(du -h "$model" | cut -f1)"
    BUNDLED=1
    # whisper.cpp strips a trailing -qX_X when deriving the encoder path.
    stem="$(basename "$model" .bin)"
    stem="${stem%-q[0-9]_[0-9]}"
    encoder="$ROOT/Models/${stem}-encoder.mlmodelc"
    if [[ -d "$encoder" ]]; then
      cp -Rc "$encoder" "$APP/Contents/Resources/" 2>/dev/null || cp -R "$encoder" "$APP/Contents/Resources/"
      printf '    %-46s %s\n' "$(basename "$encoder")" "$(du -sh "$encoder" | cut -f1)"
    else
      echo "    (no Core ML encoder — the encoder will run on Metal/CPU)"
    fi
  done
  # Silero VAD weights. Without these the app falls back to the energy gate, which
  # cannot distinguish speech from noise.
  for vad in "$ROOT"/Models/ggml-silero-*.bin; do
    [[ -e "$vad" ]] || continue
    cp -c "$vad" "$APP/Contents/Resources/" 2>/dev/null || cp "$vad" "$APP/Contents/Resources/"
    printf '    %-46s %s\n' "$(basename "$vad")" "$(du -h "$vad" | cut -f1)"
  done
else
  echo "==> No models in Models/ — the app will fall back to the scripted recognizer."
  echo "    Run scripts/convert-model.sh to build the Quran-tuned model."
fi

# --- Sign ------------------------------------------------------------------------
# Ad-hoc signature ("-") is enough for local development. TCC keys the microphone
# grant to the bundle identifier plus this signature, so re-running the script keeps
# the permission you already granted; changing the bundle id would re-prompt.
echo "==> Ad-hoc signing"
codesign --force --sign - \
  --entitlements "$ROOT/Apps/macOS/Resources/Iqra.entitlements" \
  --options runtime \
  "$APP" >/dev/null 2>&1 || {
    echo "warning: signing with entitlements failed; retrying without hardened runtime" >&2
    codesign --force --sign - \
      --entitlements "$ROOT/Apps/macOS/Resources/Iqra.entitlements" \
      "$APP"
  }

codesign --verify --deep --strict "$APP" && echo "==> Signature OK"

# --- Launch ----------------------------------------------------------------------
if [[ "$OPEN_APP" == "1" ]]; then
  echo "==> Launching"
  open "$APP"
  echo
  if [[ "$BUNDLED" == "1" ]]; then
    if compgen -G "$APP/Contents/Resources/ggml-silero-*.bin" > /dev/null; then
      echo "Whisper is transcribing for real, with Silero segmenting the audio."
    else
      echo "Whisper is transcribing for real, but no Silero VAD model is bundled, so"
      echo "segmentation falls back to the energy gate. Run scripts/fetch-vad-model.sh."
    fi
  else
    echo "No model bundled: transcription falls back to the scripted stub, so the"
    echo "highlighting will not reflect what you recited. Run scripts/convert-model.sh."
  fi
else
  echo "==> Built (not launched): $APP"
fi
