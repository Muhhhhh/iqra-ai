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
      uint8  sifa[10][phonemes]  one plane per ṣifah, in SIFAT order below;
                                 0 unknown, otherwise the 1-based class

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

    # Every ṣifah the phonetiser labels, and the classes each can take. Exported in
    # full rather than the two the app happens to use today: forced alignment turns each
    # of these into labelled audio for free, which is the raw material for training a
    # detector that hears a ṣifah rather than predicting it from context.
    SIFAT = [
        ("ghonna", ["maghnoon", "not_maghnoon"]),
        ("hams_or_jahr", ["hams", "jahr"]),
        ("shidda_or_rakhawa", ["shadeed", "between", "rikhw"]),
        ("tafkheem_or_taqeeq", ["mofakham", "moraqaq", "least_tafkheem"]),
        ("itbaq", ["monfateh", "motbaq"]),
        ("qalqla", ["moqalqal", "not_moqalqal"]),
        ("safeer", ["safeer", "no_safeer"]),
        ("istitala", ["mostateel", "not_mostateel"]),
        ("tafashie", ["motafashie", "not_motafashie"]),
        ("tikraar", ["mokarar", "not_mokarar"]),
    ]

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

            symbols, words = [], []
            planes = {name: [] for name, _ in SIFAT}
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
                for name, classes in SIFAT:
                    value = getattr(group, name, None) if group else None
                    planes[name].append(classes.index(value) + 1 if value in classes else 0)
                group_index += 1

            if not symbols:
                continue
            records.append((surah, ayah, word_index + 1, symbols, words, planes))

        if surah % 20 == 0:
            print(f"    …{surah}/114 surahs, {len(records)} āyāt")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("wb") as handle:
        handle.write(b"QPH1")
        handle.write(struct.pack("<ii", 1, len(records)))
        for surah, ayah, words, symbols, wordOf, planes in records:
            handle.write(struct.pack("<HHHH", surah, ayah, words, len(symbols)))
            handle.write(bytes(symbols))
            handle.write(bytes(wordOf))
            for name, _ in SIFAT:
                handle.write(bytes(planes[name]))

    total = sum(len(r[3]) for r in records)
    nasal = sum(sum(1 for g in r[5]["ghonna"] if g == 1) for r in records)
    echoed = sum(sum(1 for q in r[5]["qalqla"] if q == 1) for r in records)
    size = OUTPUT.stat().st_size
    print(f"==> {len(records)} āyāt, {total} phonemes, {size / 1e6:.1f} MB")
    print(f"    {nasal} phonemes must be nasalised, {echoed} must be echoed")
    print(f"    {len(SIFAT)} ṣifāt exported per phoneme")
    if skipped:
        print(f"==> {len(skipped)} āyāt skipped; first few:")
        for entry in skipped[:5]:
            print("   ", entry)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
