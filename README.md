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

**Segments must be long enough to decode.** `trailingSilence` defaults to 1.6 s, not the
0.6 s carried over from the microphone work. Reciters pause constantly — at waqf marks,
between āyāt, for breath — and every one of those pauses was closing a segment. Whisper
is much worse on short fragments, because it has no context to decode against. This was
the largest single accuracy defect in the pipeline, and it was invisible until anything
was measured on real recitation. See below.

## Measuring against real recitation

Until `Tools/IqraEval` existed, every accuracy figure here came from one synthetic TTS
clip — no madd, no tajweed, no melodic line, no breath pauses. It is not the signal the
app receives, and it flattered the pipeline badly.

The harness uses reference recitations from everyayah.com, whose text is known exactly
from the bundled database: 6,236 aligned audio/text pairs, no labelling. Mistakes are
introduced by splicing whole āyāt, which needs no word boundaries in the reference audio
and so adds no alignment assumptions of its own:

| case | audio | what it proves |
|---|---|---|
| clean | three āyāt straight through | anything flagged is a **false alarm** |
| skip | middle āyah removed | an omission with recitation on both sides is caught |
| wrong | middle āyah replaced with another | reading the wrong text is caught |
| repeat | middle āyah recited twice | self-correction is not reported as added words |

```bash
swift build -c release --product IqraEval && .build/release/IqraEval --trailing-silence 0.6,1.6
```

The false-flag rate is the number that governs this app: a pipeline that catches
everything by flagging everything is worse than useless, so detection rates are never
reported without it alongside. Measured over 74 passages of Al-Husary's murattal:

| trailing silence | WER | falsely flagged words | clean passages, nothing flagged | omitted āyah caught |
|---|---|---|---|---|
| 0.6 s | 57.6% | 23.9% | 1/19 | 8/19 |
| 1.6 s | 43.0% | 10.9% | 7/19 | 15/19 |
| 2.5 s | 37.5% | 10.5% | 7/19 | 13/19 |

Detection improved *with* the false-flag rate rather than against it, because both
failures had one cause: fragments too short to transcribe. Past 1.6 s the curve flattens,
and every further tenth of a second is feedback the reciter waits for after they stop.

Those figures come from short muffaṣal surahs. On long surahs — Al-Baqarah, An-Nisā',
Al-A'rāf — the false-flag rate is roughly **34%**, and no clean passage came back
unmarked at all. Longer āyāt, denser text and a faster reading are all harder, and any
claim about accuracy has to say which material it was measured on.

The default eval set spans both for a reason. Drawn only from the short surahs, it
contained **17 words carrying a dagger alef** across eleven surahs, and was therefore
blind to a spelling ambiguity affecting **11% of the Quran** (9,301 words) — a defect a
user reported from the app before any measurement here caught it. An eval set that does
not contain the failure cannot measure the fix.

### What the errors are, and what does not fix them

Aggregate word error rate cannot tell "the model misheard every other word" from "whole
stretches never reached it", and those call for opposite fixes. The breakdown, over nine
passages of Al-Baqarah, An-Nisā' and Al-A'rāf:

| | share of errors |
|---|---|
| substitutions — misheard | 49% |
| **deletions — never transcribed at all** | **45%** |
| insertions — invented | 5% |

Nearly half the loss is words the recogniser never produced. That is the thing to fix,
and it is why most of the ideas below did not help: they address how well words are
matched, not whether they arrive.

Five changes were measured. Two were kept:

- **Segment length cap 12 s → 20 s.** Whisper's native window is 30 s, so a shorter cap
  is a self-imposed cut mid-phrase. WER 54.8% → 53.3%, falsely flagged words 29.2% →
  28.9%. 30 s gained nothing further: with a 1.6 s pause closing segments, almost none
  run that long.
- **DTW alignment heads must match the weights.** They were hardcoded to the base preset.
  Pointed at the wrong heads whisper.cpp does not fail — it returns wrong timings, the
  degenerate-timing guard concludes the audio was never speech, and the whole
  transcription is discarded. large-v3-turbo returned **nothing at all for 169 of 169
  segments**, which reads exactly like a model that cannot transcribe recitation. This
  broke every model size except base, which is precisely what the model picker offers.

Three were measured and rejected:

- **A bigger model.** Stock `small` (69.7% WER), `medium` (62.4%) and `large-v3-turbo`
  (56.5%) are all *worse* than the 74M-parameter Quran-tuned base at 54.8% — which also
  runs 20× faster. Fine-tuning on recitation matters more than parameter count. A larger
  *Quran-tuned* checkpoint would be worth having; a larger general one is not.
- **Unquantised weights.** fp16 against q8_0: 54.8% WER and 28.9% false flags, identical
  to three decimal places. Quantisation costs nothing here, so the smaller file stays.
- **Phonetic edit distance.** Charging ت/ط, س/ص, ذ/ز/ظ, ق/ك, ء/ع half a substitution,
  on the theory that these are recogniser confusions rather than misrecitations, changed
  the false-flag rate by nothing at all (28.89% → 28.89%) and slightly increased invented
  additions. At 55% WER the mismatches are not near-misses. Worth re-testing if
  transcription ever improves; not worth the loss of ص/س sensitivity now.
- **N-best rescoring.** Decoding each segment several ways and letting the expected text
  pick between them — the safe way to use the known text, since every hypothesis is one
  the audio actually produced. WER barely moved (57.8% → 57.4%), false flags got *worse*
  (28.9% → 32.5%), and it cost 4× the compute. Available in the harness as `--nbest` for
  re-testing.

**These numbers are not good.** One word in nine is still falsely flagged on short
surahs, one in three on long ones, and only about a third of short clean passages come
back completely unmarked. That is the honest state of word
matching on real recitation, and it is why the app's language is "check this" rather than
"wrong", and why the muṣḥaf never presents a verdict as final.

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

## Calibrating tajweed against real recitation

`IqraEval --calibrate-tajweed` measures what the Muaalem model says when a rule **is**
applied correctly. It needs no labelled errors, which is what makes it possible at all: a
reference recitation by a qārī applies every rule the text requires, so running the model
across hundreds of them gives its output distribution on correct recitation. A threshold
placed in that distribution's low tail then means something that can be stated — "below
what expert recitation produces, and here is the fraction of expert recitation it would
wrongly question".

It is one-sided. It cannot report a detection rate, because nothing measured contains a
mistake. It answers the prior question: whether the model separates anything at all.

**It found that audio tajweed checking had never worked.** Two bugs, both silent:

1. **The model's output was being read as the wrong type.** Core ML returns float16; the
   code read `Float`. Every logit was assembled from halves of two different values.
2. **The buffer is strided.** A `[1, 250, 3]` output has strides `[8000, 32, 1]` — each
   frame's three logits padded to 32 elements for the Neural Engine — and the read
   assumed packed layout bounded by the logical element count.

Softmax over the resulting nonsense gave a flat third across every class. Across 251 rule
occurrences, the probability of the required attribute and of its contrary both read
34.3%. A uniform distribution is indistinguishable, from outside, from a model with no
opinion — so the analyzer never said anything about any rule in any recitation, which
looks exactly like "tajweed checking finds nothing wrong". The same model in Python, on
the same features, puts 0.90–0.95 on its chosen class.

**Then it found the statistic was wrong.** Muaalem is a CTC network: it labels almost
every frame blank and spikes where it has something to say. The analyzer averaged over
the whole word. A ghunnah is one spike on one nūn inside a word of six letters, and the
other letters carry the contrary label perfectly correctly — so the average measured how
much of the word is *not* a ghunnah, which is most of it in every recitation. Over 216
correct occurrences:

| rule | mean over word (median) | peak in word — p5 / p25 / median |
|---|---|---|
| ghunnah | 20.0% | 0.0% / 97.2% / 100.0% |
| ikhfāʾ | 25.0% | 1.8% / 99.8% / 100.0% |
| qalqalah | 14.3% | 0.0% / 94.1% / 99.9% |
| idghām | 14.3% | 0.0% / 0.0% / 94.9% |
| iqlāb | 14.3% | 0.0% / 0.3% / 100.0% |

The shipped mean-based test would have questioned **145 of 216 correct occurrences — 67%
of Al-Husary's own recitation.** The verdict is now taken from the peak, and idghām and
iqlāb are excluded from audio checking entirely: they show no spike at all in a quarter of
occurrences a qārī recited correctly, which is a property of the model rather than of the
recitation. Both are still detected in the text and coloured on the page.

**Even so it stays off by default.** At the current thresholds, 11.6% of correct
occurrences of the rules it does judge would be questioned — about one in nine. The
remaining tail is occurrences where the model spikes nowhere in the word, most likely
because the word's timing is wrong or the rule crosses into the next word, and no
threshold fixes that. What is still missing before this could be trusted:

- **Recitation with known errors in it.** Everything above is one-sided.
- **A qārī.** Nothing here has been reviewed by one.
- **A stated riwāyah.** Calibration is on Ḥafṣ ʿan ʿĀṣim and does not transfer; madd
  lengths differ legitimately between readings, and a model calibrated on one will call
  another wrong.

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
