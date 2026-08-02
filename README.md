# Iqra — Quran recitation practice

Listens to your recitation and highlights words that may need review. Fully on-device,
fully offline.

**Status: macOS v1 — build steps 1–5 of 7 complete.** The whole muṣḥaf is practisable:
pick any surah and āyah range, recite, and words that need review are highlighted live.
Everything runs on-device. Still to come: the iOS shell (step 6) and tajweed (v2).

First run — these fetch ~500 MB and are not checked in:

```bash
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git Vendor/whisper.cpp
scripts/build-whisper.sh
scripts/convert-model.sh
scripts/fetch-vad-model.sh
scripts/build-quran-db.py
scripts/run-macos.sh
```

`scripts/fetch-model.sh` grabs stock multilingual weights instead, if you want a
baseline to compare against.

Requires a full Xcode (not just Command Line Tools) — see [scripts/README.md](scripts/README.md).

---

## Structure

```
Sources/RecitationCore/     all logic — the shells stay thin
  Model/                    AudioChunk, AlignedAudioSegment, RecitationResult
  Audio/                    capture protocol, AVAudioEngine impl, session seams
  VAD/                      VoiceActivityDetector protocol + energy placeholder
  ASR/                      SpeechRecognizer protocol, whisper.cpp impl, model locator
  Quran/                    verse types, VerseStore protocol, bundled SQLite store
  Matching/                 Arabic normalisation, token aligner, word verdicts
  Tajweed/                  v2 seam — protocol, note types, no-op default
  Pipeline/                 RecitationPipeline actor, events, session view model
  UI/                       shared SwiftUI: mushaf highlighting

Sources/CWhisper/           module map over the prebuilt whisper.cpp libraries
Resources/quran.sqlite3     the bundled muṣḥaf, built and verified by script
Apps/macOS/                 thin SwiftUI shell + Info.plist + entitlements
Tests/RecitationCoreTests/  87 tests: matcher, pipeline, whisper, VAD, database, layout
Resources/Fonts/            Amiri Quran (SIL OFL)
Vendor/whisper.cpp/         cloned, not checked in
Models/                     fetched weights, not checked in
scripts/                    build, fetch, run; DB tooling documented for later steps
```

`Package.swift` is the single source of truth for the build. Open it directly in Xcode
(`xed .`) for IDE debugging. An `.xcodeproj` becomes necessary at step 6 for the iOS
app target; deferring it avoids maintaining two build definitions in the meantime.

## The pipeline

```
mic (16 kHz mono)
  → VAD detects a pause → emits a segment
    → recognizer transcribes it, with per-token timestamps
      → token alignment against the expected verse text
        → per-word status → live highlighting
```

`RecitationPipeline` is an actor, so inference stays off the main thread. Components
are injected, so swapping one is a change in `AppSettings.makePipeline()` and nowhere
else — that is how whisper replaced the stub recognizer in step 2, and how Silero will
replace the energy VAD in step 4.

whisper.cpp is built as static libraries by `scripts/build-whisper.sh` and exposed to
Swift through the `CWhisper` module map. The model is
`tarteel-ai/whisper-base-ar-quran`, converted to GGML and quantised to q8_0, with a
Core ML encoder running on the Neural Engine — `scripts/convert-model.sh` builds all
three artefacts reproducibly and documents the traps involved. The app reports which
encoder is actually live in the sidebar.

Word timestamps come from DTW over the decoder's cross-attention rather than the
timestamps the model emits, which are unreliable on fine-tuned checkpoints. This is a
correctness requirement, not a refinement: v2 tajweed measures durations over these
boundaries. See [scripts/README.md](scripts/README.md) for the measurements.

### Audio is retained on purpose

`AlignedAudioSegment` keeps the raw PCM buffer and per-token timestamps *after*
transcription, rather than freeing them. v2 tajweed analysis is timing-and-signal math
over exactly that aligned audio — madd duration, qalqalah bursts, ghunnah — so
discarding it would make tajweed require a second recording pass.
`AlignedAudioSegment.audio(for:)` slices out a single word's samples; the review panel
already uses it for playback, and `PipelineTests` asserts the slices are non-empty.

## Matching is deliberately conservative

A false *"you made a mistake"* is worse than a missed one. Recitation feedback carries
trust weight that ordinary text matching does not, so the aligner is biased to
under-report:

- Verdicts are graded. Between the match threshold and the uncertain threshold, a word
  is `.uncertain` — surfaced as a neutral *"check this"*, never as an error.
- Low recognizer confidence never escalates. If the model wasn't sure what it heard,
  the app is not sure it was a mistake.
- Orthography is folded before comparison (`ArabicNormalizer`): diacritics, tatweel,
  alef and ya variants, ta marbuta. The mushaf is Uthmani; ASR output is not.
- A word is *skipped* only if the reciter carried on past it. Stopping after the first
  verse of a seven-verse passage is not "skipping six verses" — everything beyond the
  furthest match is simply unreached, during recording and after it.
- A fully omitted verse reports as one skipped verse, not N skipped words.
- Alignment uses affine gap penalties, so a contiguous run is preferred over the same
  words matched scattered across the passage, and equal-cost matches resolve to the
  *earliest* position. Both matter where the text repeats: Ar-Raḥmān's refrain recurs
  31 times, and matching a late occurrence would report every earlier one as skipped.

Thresholds are exposed in Settings (⌘,) so they can be calibrated rather than guessed.
The tests in `TokenAlignerTests` lock in the bias, not just the happy path.

Tajweed and pronunciation are **not** assessed in v1, and the review panel says so.

## Build order

| # | Step | State |
|---|---|---|
| 1 | Scaffold core + macOS shell, stub pipeline | **done** |
| 2 | whisper.cpp building, transcribe a bundled test WAV | **done** |
| 3 | Model conversion scripts; Tarteel base + Core ML encoder, q8_0 | **done** |
| 4 | Silero VAD for live chunking | **done** |
| 5 | SQLite verse DB → shippable macOS v1 | **done** |
| 6 | iOS shell over the same core → shippable iOS v1 | next |
| 7 | v2 `TajweedAnalyzer`: DSP rules, then neural | **done** |

## What is still a placeholder

The sidebar marks these in orange at runtime.

| Component | Now | Becomes |
|---|---|---|
| `NoOpTajweedAnalyzer` | returns nothing | DSP rules, then the obadx phonetic model |

`InMemoryVerseStore` survives only as a test fixture; the app reads `SQLiteVerseStore`.

`EnergyVoiceActivityDetector` is kept as a fallback for when the Silero weights are
absent, and as a baseline to compare against. It cannot distinguish a held vowel from a
quiet passage, nor speech from noise at all.

### Segmentation, and why it is a correctness feature

`SileroVoiceActivityDetector` runs Silero through whisper.cpp's ggml implementation, so
it reuses the backend already linked for speech recognition — no ONNX Runtime, no second
Core ML model, 865 KB of weights.

Two properties matter more than segmentation quality:

**Noise must never reach the recogniser.** Handed white noise, whisper emits confident
Arabic that was never recited, which downstream becomes fabricated mistakes in someone's
recitation. Three recogniser-level guards were measured against this model and rejected —
`no_speech_prob` rates noise as *more* speech-like than speech (~2e-8 vs ~2e-5), mean
token confidence overlaps (0.68 vs 0.73, so a threshold drops real speech first), and
degenerate word timing catches only some draws. Rejecting non-speech is the VAD's job,
and Silero does it. `SileroVADTests.noiseProducesNoWordsEndToEnd` asserts the assembled
pipeline produces no words, no mistakes and no insertions from noise.

**Segments must open before the speech that triggered them.** A word's onset ramps up
*through* whatever threshold is in use, so without a pre-roll those first frames are
discarded and the recogniser hears a truncated word — which then reads as a *wrong* word
rather than a clipped one. Measured: dropping the onset turned بِسْمِ into من.
`SpeechSegmentAssembler` retains 350 ms of preceding audio, and both detectors share that
one tested implementation.

Silero's threshold defaults to 0.35 rather than its usual 0.5, for the same reason: the
cost is asymmetric. Letting a little extra audio through costs milliseconds of inference;
clipping a word fabricates a mistake.

## The muṣḥaf view

The page is the real Madani layout: 604 pages, fifteen lines, **canonical line breaks** —
page 3 line 7 ends on the same word here as in a printed copy. The page is laid out into
a fixed canvas and scaled to fit rather than reflowed to the window, because reflowing
would break exactly the thing a ḥāfiẓ navigates by. Lines are stretched flush to both
margins; surah headers and the basmala get their own lines, placed from the layout data
(including the case where a header sits on the last line of the previous page).

Practice is page-by-page, which is how memorisation works and also keeps alignment
bounded — a page is ~80 words rather than a whole surah.

Tapping a word shows its gloss, transliteration and the āyah translation
(Saheeh International).

### Typeface

Choosing this was not cosmetic. The Uthmani text uses 29 combining and special marks, and
most Arabic faces drop the ones they lack *silently*. Measured coverage across the fonts
macOS ships:

| Font | Coverage |
|---|---|
| Geeza Pro, Damascus | 100% |
| Mishafi Gold | 84% |
| DecoType Naskh, Baghdad, Al Bayan | 31% |
| **Mishafi** | **25%** |

Mishafi is the trap — the name suggests the muṣḥaf, and it would lose every waqf mark and
dagger alef with no missing-glyph box to warn you. The app bundles **Amiri Quran**
(SIL OFL, 134 KB), verified at 100% coverage with zero fallback runs on real verses.

Feedback is carried in the ink rather than in boxes: correct words are undecorated,
unrecited text is dimmed so the page illuminates as you recite, and only words needing a
second look get colour and a thin rule. A page of green would imply the app had certified
the recitation, and it has not.

## The bundled text

`scripts/build-quran-db.py` builds `Resources/quran.sqlite3` from the quran.com API —
Uthmani text for all 6,236 āyāt with a word-by-word breakdown, 5.8 MB.

This is scripture, so the script is built to refuse rather than guess. It asserts 114
surahs, 6,236 āyāt, per-surah counts against a hard-coded table, contiguous āyah
numbering, no empty verses, and that the stored words rejoin to *exactly* the verse text.
It records a SHA-256 of the corpus, so a future rebuild producing different text is
visible rather than silently shipped, and `--verify` re-checks a built file. The app
surfaces the source and checksum in Settings → Text. `SQLiteVerseStore` re-checks the
headline counts when it opens the database, opens it read-only, and never writes.

One thing worth knowing: this Uthmani rendering carries the dagger alef on a tatweel, so
1:1 is ٱلرَّحْمَـٰنِ rather than ٱلرَّحْمَٰنِ. Both are valid; `ArabicNormalizer` strips
tatweel before matching, and a test pins the exact bytes so a source that quietly changed
convention would be caught.

### Scale

Passages are now whole surahs rather than a few āyāt, and the pipeline realigns after
every speech segment. Al-Baqarah is 6,607 words. Release timings on an M5:

| Passage | Recited | Realignment | Peak memory |
|---|---|---|---|
| Yā-Sīn (749 words) | 10% | 15 ms | — |
| Yā-Sīn | in full | 118 ms | — |
| Al-Baqarah (6,607 words) | 10% | 892 ms | — |
| Al-Baqarah | in full | 8.5 s | 62 MB |

Getting there needed the aligner rewritten: words are converted to character arrays once
rather than m×n times, the inner edit distance reuses scratch buffers, similarity is
computed on the fly rather than stored, and the costs are two rolling rows with one byte
of backtrace direction per cell. That cut peak memory 24× (1.48 GB → 62 MB, measured
under identical conditions) with byte-identical verdicts. The āyah range picker warns
above 1,500 words rather than forbidding a long passage — revising a long surah is a real
thing to want.

## Tajweed (v2)

Tajweed has two halves, and they are not equally reliable. The app treats them
differently on purpose.

**Where a rule applies** follows from the Uthmani orthography and is derived exactly:
a shadda on nūn is ghunnah, a sākin qāf is qalqalah, a madd letter meeting a hamza in the
same word is madd wājib. `TajweedRuleDetector` implements ghunnah, qalqalah, the four
nūn-sākinah rules (iẓhār, idghām, iqlāb, ikhfāʾ) and the four madd types, following Hafs.
Words on the page are tinted by the strongest rule they carry — available before a single
word is recited, because it does not depend on the audio at all. 18 tests check it against
āyāt whose rules any student of tajweed knows.

Two traps found while building it: Swift's `Character` is a grapheme cluster, so a letter
and its diacritics are one element and every rule found nothing until it was rewritten on
Unicode scalars; and the muṣḥaf usually omits the sukun on a sākin nūn, so requiring one
missed most occurrences.

**Whether it was executed correctly** is checked by the Muaalem model
(`obadx/muaalem-model-v3_2`, MIT, arXiv 2509.00094) — a Wav2Vec2-BERT with a CTC head for
each ṣifah, so it reports frame by frame whether what it heard was nasalised, echoed,
heavy or light. `MuaalemTajweedAnalyzer` asks it only whether the attribute the *text*
requires was actually present, which is a narrower question than grading a recitation and
keeps every claim anchored to something the orthography demands.

One head covers four rules by inversion: ikhfāʾ, iqlāb and idghām hide the nūn *with*
nasalisation, while iẓhār exists precisely to pronounce it without — so the same `ghonna`
head confirms one group and refutes the other. Qalqalah has its own head. Madd is still
measured by duration against the reciter's own pace, because the model has no elongation
head and claiming one would be inventing a signal.

Getting the model on-device took some work, recorded in
[scripts/convert-tajweed-model.py](scripts/convert-tajweed-model.py): both published
TorchScript exports are unusable on Apple silicon (one bakes fp16 constants CPU cannot
run, the other was traced on CUDA), and the Core ML conversion failed three times on ops
originating in attention-mask expansion — resolved by dropping the mask after verifying an
all-ones mask is bit-identical to none. Converted, quantised to int8 (1.8 GB → 946 MB) and
verified against PyTorch at 100% argmax agreement on ten of eleven heads.

The feature front-end is the part most able to fail silently: a model fed wrong features
returns confident nonsense. So the window and mel filterbank are exported verbatim from
the Python extractor rather than re-derived in Swift, and `MuaalemFeatureTests` checks the
Swift output against reference features from that same extractor (max difference < 0.02 on
values spanning ±4).

It is still **off by default**, notes are capped at `.moderate` confidence, and the app
stays silent unless the model is confidently against the rule. **Nothing here has been
calibrated against expert reciters or reviewed by a qārī**, and the UI says so.

## Reference recitation

Flagged āyāt can be played back in a reciter's voice — Al-Husary murattal by default, with
Abdul Basit, Minshawi, Alafasy, Sudais and Shuraim selectable. Āyāt are fetched
individually from everyayah.com when played or when a page is downloaded, and cached
permanently, so a page fetched once works offline afterwards.

## Offline guarantee

Nothing that *judges* a recitation touches the network: the speech model, the voice
detection, the tajweed model, the muṣḥaf and the verse database are all bundled and run
on-device. The sandbox is granted `com.apple.security.network.client` for exactly one
purpose — fetching reference recitation when the user asks for it. `.server` remains
absent.

## Using the app

- **⌘R** start/stop · **⌘⇧R** reset · **⌘↓ / ⌘↑** next/previous flagged word ·
  **⌘+ / ⌘−** text size · **⌘,** settings
- Sidebar → *Input* switches between the real microphone and a scripted source that
  needs no mic permission.
- Sidebar → *Recognizer* switches between whisper and the scripted stub. With the stub
  selected, *Scripted recitation* picks which mistake it makes, so every verdict path
  stays reachable: wrong word, added word, skipped word, skipped verse.
- Clicking a word in the mushaf selects it in the review panel, and vice versa. Words
  with retained audio get a play button.
