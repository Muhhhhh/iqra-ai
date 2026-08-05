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
    int32   version (2)
    int32   āyah count
    per āyah:
      uint16 surah, uint16 ayah, uint16 words, uint16 phonemes
      uint8  symbol[phonemes]    class index into the model's phoneme head
      uint8  word[phonemes]      which word of the āyah this phoneme belongs to
      uint8  sifa[10][phonemes]  one plane per ṣifah, in SIFAT order below;
                                 0 unknown, otherwise the 1-based class
      uint8  idgham[phonemes]    0 none, 1 with ghunnah, 2 without
      uint8  madd[phonemes]      0 none, else 1 normal, 2 muttaṣil, 3 munfaṣil,
                                 4 ʿāriḍ, 5 lāzim — named by the phonetiser, not
                                 inferred from how many counts were written

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



# Diacritics that never stand as a letter of their own.
MARKS = "\u064B\u064C\u064D\u064E\u064F\u0650\u0651\u0652\u0653\u0654\u0655\u0670\u06E1\u0640\u06DF\u06E0\u06E2\u06E5\u06E6\u06EA\u06EB\u06EC\u06ED\u0656\u0657\u0658"
SHADDA = "\u0651"
SUKUN = "\u0652"
TANWIN = "\u064B\u064C\u064D"
GHUNNAH_LETTERS = "\u064A\u0646\u0645\u0648"          # ي ن م و
NO_GHUNNAH_LETTERS = "\u0644\u0631"                     # ل ر


def idgham_characters(uthmani: str) -> dict:
    """Uthmani character offsets that an idghām falls on, and which kind.

    In the muṣḥaf idghām *is* a shadda: مِن رَّبِّهِمْ writes the assimilated nūn as a shadda
    on the ر that swallowed it. What separates it from every other shadda is where it
    sits — on the **first letter of a word**, with the word before ending in nūn sākinah
    or tanwīn. أُمَّة carries a shadda mid-word and is nothing of the kind; ٱلرَّحْمَـٰن carries
    one after ٱل, which is lām shamsiyyah, a different rule with a different sound.

    Determined here rather than from the phonemes because the phonemes cannot tell:
    assimilation merges the words outright — هُدًۭى مِّن رَّبِّهِمْ is one phonetic word — and a
    doubled mīm looks the same whether it came from أُمَّة or from مِن مَّاء.

    Returns {character offset: 1 for bi-ghunnah, 2 for bilā ghunnah}.
    """
    words = []
    start = 0
    for index, character in enumerate(uthmani + " "):
        if character.isspace():
            if index > start:
                words.append((start, uthmani[start:index]))
            start = index + 1

    found = {}
    for position, (offset, word) in enumerate(words):
        if position == 0:
            continue
        previous = words[position - 1][1]
        # The word before has to end in a nūn sākinah or a tanwīn for anything to have
        # been assimilated. A trailing sukūn or mark is skipped over to find the letter.
        stripped = previous.rstrip(MARKS)
        ends_in_nun = stripped.endswith("\u0646")
        has_tanwin = any(mark in previous[-3:] for mark in TANWIN)
        if not (ends_in_nun or has_tanwin):
            continue
        # The first *letter* of this word, and whether it carries a shadda.
        letter_at = None
        for index, character in enumerate(word):
            if character not in MARKS:
                letter_at = index
                break
        if letter_at is None:
            continue
        letter = word[letter_at]
        following = word[letter_at + 1:letter_at + 3]
        if SHADDA not in following:
            continue
        if letter in GHUNNAH_LETTERS:
            found[offset + letter_at] = 1
        elif letter in NO_GHUNNAH_LETTERS:
            found[offset + letter_at] = 2
    return found


# What the phonetiser calls each madd, in the order the app's own rule enum expects.
MADD_KINDS = {
    "NormalMaddRule": 1,
    "MottaselMaddRule": 2,
    "MonfaselMaddRule": 3,
    "AaredMaddRule": 4,
    "LazemMaddRule": 5,
    "LazemHarfMaddRule": 5,
}


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

            uthmani = aya.get().uthmani
            # Which Uthmani character produced each phoneme, so a fact read off the text
            # can be attached to the exact sound it became. Idghām can only be found this
            # way: the phonemes have lost the word boundary it happens at.
            source = {}
            for character_index, mapping in enumerate(spaced.mappings):
                if mapping.deleted or not mapping.pos:
                    continue
                for phoneme_index in range(mapping.pos[0], mapping.pos[1]):
                    source.setdefault(phoneme_index, character_index)
            idgham_at = idgham_characters(uthmani)

            # The madd the phonetiser itself names, rather than one guessed from length.
            # Munfaṣil, muttaṣil and ʿāriḍ are all four counts, so nothing downstream can
            # tell them apart — and the app was calling every one of them wājib muttaṣil.
            madd_at = {}
            for mapping in spaced.mappings:
                for rule in (mapping.tajweed_rules or []):
                    kind = MADD_KINDS.get(type(rule).__name__)
                    if kind and mapping.pos:
                        for phoneme_index in range(mapping.pos[0], mapping.pos[1]):
                            madd_at[phoneme_index] = kind

            symbols, words = [], []
            planes = {name: [] for name, _ in SIFAT}
            idgham_plane, madd_plane = [], []
            word_index = 0

            # `sifat` is one entry per phoneme *group*, and a group spans however many
            # characters that sound is written with — قُ is one group of two characters,
            # للَ one group of three. Advancing the group once per character therefore
            # desynchronises the labels from the symbols after the very first multi-
            # character group, and every ṣifah after it describes some later phoneme.
            #
            # The symptom was silent and total: exported frames showed stops, fricatives
            # and nasals all at identical mean energy, while the same alignment measured
            # directly put vowels 3.4 units above stops. Labels that are shifted are
            # indistinguishable from audio that carries no information.
            group_index = 0
            remaining = len(sifat[0].phonemes) if sifat else 0
            for phoneme_index, character in enumerate(spaced.phonemes):
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
                idgham_plane.append(idgham_at.get(source.get(phoneme_index, -1), 0))
                madd_plane.append(madd_at.get(phoneme_index, 0))

                if remaining == 0 and group_index + 1 < len(sifat):
                    group_index += 1
                    remaining = len(sifat[group_index].phonemes)
                group = sifat[group_index] if group_index < len(sifat) else None
                for name, classes in SIFAT:
                    value = getattr(group, name, None) if group else None
                    planes[name].append(classes.index(value) + 1 if value in classes else 0)
                remaining = max(0, remaining - 1)

            if not symbols:
                continue
            records.append((surah, ayah, word_index + 1, symbols, words, planes,
                            idgham_plane, madd_plane))

        if surah % 20 == 0:
            print(f"    …{surah}/114 surahs, {len(records)} āyāt")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("wb") as handle:
        handle.write(b"QPH1")
        handle.write(struct.pack("<ii", 2, len(records)))
        for surah, ayah, words, symbols, wordOf, planes, idgham, madd in records:
            handle.write(struct.pack("<HHHH", surah, ayah, words, len(symbols)))
            handle.write(bytes(symbols))
            handle.write(bytes(wordOf))
            for name, _ in SIFAT:
                handle.write(bytes(planes[name]))
            handle.write(bytes(idgham))
            handle.write(bytes(madd))

    total = sum(len(r[3]) for r in records)
    nasal = sum(sum(1 for g in r[5]["ghonna"] if g == 1) for r in records)
    idghams = sum(sum(1 for x in r[6] if x) for r in records)
    echoed = sum(sum(1 for q in r[5]["qalqla"] if q == 1) for r in records)
    size = OUTPUT.stat().st_size
    print(f"==> {len(records)} āyāt, {total} phonemes, {size / 1e6:.1f} MB")
    print(f"    {nasal} phonemes must be nasalised, {echoed} must be echoed")
    print(f"    {len(SIFAT)} ṣifāt exported per phoneme")
    print(f"    {idghams} phonemes carry an idghām")
    if skipped:
        print(f"==> {len(skipped)} āyāt skipped; first few:")
        for entry in skipped[:5]:
            print("   ", entry)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
