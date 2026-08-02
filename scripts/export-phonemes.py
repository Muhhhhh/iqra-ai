#!/usr/bin/env python3
"""Export the phonetic script of every āyah, with the ṣifāt each phoneme should carry.

This is what lets tajweed be judged letter by letter. The app knows the text; what it
cannot work out on its own is which stretch of audio is the nūn that should be nasalised.
Forced alignment supplies that, but only if the expected phoneme sequence is available
offline — hence this file.

The sequence comes from `quran_transcript`, which is the phonetiser the Muaalem model was
trained against: its output uses exactly the model's 43-symbol vocabulary, so the symbols
here index the model's own phoneme head directly. The per-phoneme ṣifāt come from the
same library, so the expectation and the model's prediction are expressed in one
vocabulary and can be compared without a translation layer in between.

Output: Resources/quran-phonemes.bin

    "QPH1"                      magic
    int32   version (1)
    int32   āyah count
    per āyah:
      uint16 surah, uint16 ayah, uint16 words, uint16 phonemes
      uint8  symbol[phonemes]    class index into the model's phoneme head
      uint8  word[phonemes]      which word of the āyah this phoneme belongs to
      uint8  ghonna[phonemes]    0 unknown, 1 must be nasalised, 2 must not
      uint8  qalqala[phonemes]   0 unknown, 1 must be echoed, 2 must not

Usage:
    .venv/bin/python scripts/export-phonemes.py
"""

import json
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Resources" / "quran-phonemes.bin"

VOCAB_CANDIDATES = [
    Path.home()
    / ".cache/huggingface/hub/models--obadx--muaalem-model-v3_2/snapshots",
]


def find_vocabulary() -> dict:
    for base in VOCAB_CANDIDATES:
        if not base.exists():
            continue
        for path in base.rglob("vocab.json"):
            data = json.loads(path.read_text())
            if "phonemes" in data:
                print(f"==> Vocabulary: {path}")
                return data["phonemes"]
    print(
        "error: the Muaalem vocabulary was not found. Run scripts/convert-tajweed-model.py "
        "first — it downloads the model, and the vocabulary comes with it.",
        file=sys.stderr,
    )
    raise SystemExit(1)


def main() -> int:
    try:
        import quran_transcript as qt
    except ImportError:
        print(
            "error: quran_transcript is not installed. It is the phonetiser the Muaalem "
            "model was trained against:\n    .venv/bin/pip install quran-transcript",
            file=sys.stderr,
        )
        return 1

    vocabulary = find_vocabulary()

    # Ḥafṣ ʿan ʿĀṣim, with the madd lengths the reference recitations use. These are not
    # cosmetic: madd_monfasel and madd_mottasel change how many vowel symbols the
    # phonetiser emits, so the sequence being aligned is riwāyah-specific. Anything
    # measured against this file is measured against Ḥafṣ.
    moshaf = qt.MoshafAttributes(
        rewaya="hafs",
        madd_monfasel_len=4,
        madd_mottasel_len=4,
        madd_mottasel_waqf=4,
        madd_aared_len=4,
    )

    # The library's own names for the two attributes the model can actually judge.
    GHONNA_PRESENT = {"maghnoon"}
    GHONNA_ABSENT = {"not_maghnoon"}
    QALQALA_PRESENT = {"moqalqal"}
    QALQALA_ABSENT = {"not_moqalqal"}

    records = []
    skipped = []
    for surah in range(1, 115):
        ayah_count = qt.Aya(sura_idx=surah, aya_idx=1).get().num_ayat_in_sura
        for ayah in range(1, ayah_count + 1):
            try:
                aya = qt.Aya(sura_idx=surah, aya_idx=ayah)
                spaced = qt.quran_phonetizer(
                    aya.get().uthmani, moshaf, remove_spaces=False
                )
                sifat = spaced.sifat
            except Exception as error:  # noqa: BLE001 — one bad āyah must not lose the rest
                skipped.append((surah, ayah, str(error)[:60]))
                continue

            symbols, words, ghonna, qalqala = [], [], [], []
            word_index = 0
            # `sifat` is one entry per phoneme *group*, and each group carries the
            # characters it covers, so the two are walked together.
            group_index = 0
            for character in spaced.phonemes:
                if character == " ":
                    word_index += 1
                    continue
                identifier = vocabulary.get(character)
                if identifier is None:
                    skipped.append((surah, ayah, f"unknown symbol {character!r}"))
                    symbols = []
                    break
                symbols.append(identifier)
                words.append(min(word_index, 255))

                group = sifat[group_index] if group_index < len(sifat) else None
                value = getattr(group, "ghonna", None) if group else None
                ghonna.append(1 if value in GHONNA_PRESENT else 2 if value in GHONNA_ABSENT else 0)
                value = getattr(group, "qalqla", None) if group else None
                qalqala.append(1 if value in QALQALA_PRESENT else 2 if value in QALQALA_ABSENT else 0)
                group_index += 1

            if not symbols:
                continue
            records.append((surah, ayah, word_index + 1, symbols, words, ghonna, qalqala))

        if surah % 20 == 0:
            print(f"    …{surah}/114 surahs, {len(records)} āyāt")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("wb") as handle:
        handle.write(b"QPH1")
        handle.write(struct.pack("<ii", 1, len(records)))
        for surah, ayah, words, symbols, wordOf, ghonna, qalqala in records:
            handle.write(struct.pack("<HHHH", surah, ayah, words, len(symbols)))
            handle.write(bytes(symbols))
            handle.write(bytes(wordOf))
            handle.write(bytes(ghonna))
            handle.write(bytes(qalqala))

    total = sum(len(r[3]) for r in records)
    nasal = sum(sum(1 for g in r[5] if g == 1) for r in records)
    echoed = sum(sum(1 for q in r[6] if q == 1) for r in records)
    size = OUTPUT.stat().st_size
    print(f"==> {len(records)} āyāt, {total} phonemes, {size / 1e6:.1f} MB")
    print(f"    {nasal} phonemes must be nasalised, {echoed} must be echoed")
    if skipped:
        print(f"==> {len(skipped)} āyāt skipped; first few:")
        for entry in skipped[:5]:
            print("   ", entry)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
