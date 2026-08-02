#!/usr/bin/env python3
"""Export the Muaalem feature front-end, and a reference to verify Swift against.

The model is fed 80-bin Kaldi-style mel filterbanks stacked in pairs. Getting that
wrong feeds the network noise and it will still confidently return something, so the
window and filterbank are exported here rather than re-derived in Swift, and a set of
reference features is written so the Swift implementation can be checked numerically.

Writes:
    Resources/muaalem-frontend.bin                     window + mel filterbank
    Tests/RecitationCoreTests/Resources/
        ikhlas-features.bin                            expected features for the fixture
"""

from __future__ import annotations

import struct
import sys
import wave
from pathlib import Path

import numpy as np
from transformers import AutoFeatureExtractor

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "Resources" / "muaalem-frontend.bin"
FIXTURE = ROOT / "Tests" / "RecitationCoreTests" / "Resources" / "ikhlas-tts.wav"
REFERENCE = ROOT / "Tests" / "RecitationCoreTests" / "Resources" / "ikhlas-features.bin"


def main() -> int:
    fe = AutoFeatureExtractor.from_pretrained("obadx/muaalem-model-v3_2")
    window = np.asarray(fe.window, dtype=np.float32)
    mel = np.asarray(fe.mel_filters, dtype=np.float32)
    print(f"window {window.shape}  mel filters {mel.shape}")
    assert window.shape == (400,), window.shape
    assert mel.shape[1] == 80, mel.shape

    FRONTEND.parent.mkdir(parents=True, exist_ok=True)
    with FRONTEND.open("wb") as f:
        # magic, version, then shapes, so Swift can validate what it loaded.
        f.write(b"MUFE")
        f.write(struct.pack("<i", 1))
        f.write(struct.pack("<ii", *mel.shape))       # frequency bins, mel bins
        f.write(struct.pack("<i", window.shape[0]))
        f.write(window.tobytes())
        f.write(np.ascontiguousarray(mel).tobytes())
    print(f"wrote {FRONTEND} ({FRONTEND.stat().st_size / 1024:.0f} KB)")

    if FIXTURE.exists():
        with wave.open(str(FIXTURE)) as w:
            audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        audio = audio.astype(np.float32) / 32768.0
        features = fe(audio, sampling_rate=16000, return_tensors="np")["input_features"][0]
        rows, dim = features.shape
        with REFERENCE.open("wb") as f:
            f.write(b"MUFR")
            f.write(struct.pack("<ii", rows, dim))
            f.write(np.ascontiguousarray(features, dtype=np.float32).tobytes())
        print(f"wrote {REFERENCE}: {rows} rows x {dim}  "
              f"range [{features.min():.3f}, {features.max():.3f}]")
    else:
        print("fixture missing; skipped reference features", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
