#!/usr/bin/env python3
"""Read the labelled audio frames written by `IqraEval --training-frames`.

Each frame is one phoneme of a correct recitation: the ṣifāt the text requires of it, and
the sound that was actually made. The labels come from the phonetiser and the timing from
forced alignment, so nobody marked up a recording — which is the only reason a corpus of
this size exists at all.

    from read_frames import load
    X, symbols, labels, names = load("frames-husary.bin")
    y = (labels[:, names.index("ghonna")] == 1).astype(float)   # 1 = maghnoon
    # ن is 25 and م is 24: nasal letters, whatever the rule asks of them.

Format, little-endian:

    "IQFR"  magic
    int32   version (1)
    int32   features per frame
    int32   ṣifāt per frame
    int32   frame count
    per frame:
      uint8   symbol         the phoneme, as a model class index
      uint8   label[ṣifāt]   0 no expectation, else the 1-based class
      float32 feature[features]

Feature 0 is the band-ratio nasality contrast in dB, measured against the reciter's own
vowels. The rest are the log-mel window, oldest frame first, 80 bins per frame.
"""

import sys
import numpy as np

# The order the exporter writes, matching `PhonemeScript.Sifa`.
SIFAT = [
    "ghonna", "hams_or_jahr", "shidda_or_rakhawa", "tafkheem_or_taqeeq", "itbaq",
    "qalqla", "safeer", "istitala", "tafashie", "tikraar",
]

# What each class means, 1-based, matching scripts/export-phonemes.py.
CLASSES = {
    "ghonna": ["maghnoon", "not_maghnoon"],
    "hams_or_jahr": ["hams", "jahr"],
    "shidda_or_rakhawa": ["shadeed", "between", "rikhw"],
    "tafkheem_or_taqeeq": ["mofakham", "moraqaq", "least_tafkheem"],
    "itbaq": ["monfateh", "motbaq"],
    "qalqla": ["moqalqal", "not_moqalqal"],
    "safeer": ["safeer", "no_safeer"],
    "istitala": ["mostateel", "not_mostateel"],
    "tafashie": ["motafashie", "not_motafashie"],
    "tikraar": ["mokarar", "not_mokarar"],
}


def load(path):
    """Return (features [n, d], symbols [n], labels [n, sifat], ṣifāt names)."""
    with open(path, "rb") as handle:
        if handle.read(4) != b"IQFR":
            raise ValueError(f"{path} is not a frame file")
        version, features, sifat, count = np.fromfile(handle, dtype="<i4", count=4)
        if version != 2:
            raise ValueError(f"unsupported version {version}; regenerate the file")
        record = np.dtype([
            ("symbol", np.uint8),
            ("labels", np.uint8, sifat),
            ("x", "<f4", features),
        ])
        data = np.fromfile(handle, dtype=record, count=count)
    return data["x"], data["symbol"], data["labels"], SIFAT[:sifat]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    X, symbols, labels, names = load(sys.argv[1])
    print(f"{len(X)} frames, {X.shape[1]} features")
    nasal_letters = np.isin(symbols, [24, 25])
    print(f"  ن or م: {int(nasal_letters.sum())} frames")
    print(f"  contrast feature: mean {X[:, 0].mean():.2f} dB")
    for index, name in enumerate(names):
        counts = np.bincount(labels[:, index], minlength=4)
        described = ", ".join(
            f"{CLASSES[name][c - 1] if c - 1 < len(CLASSES[name]) else c}={counts[c]}"
            for c in range(1, len(counts)) if counts[c]
        )
        print(f"  {name:20s} unlabelled={counts[0]:6d}  {described}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
