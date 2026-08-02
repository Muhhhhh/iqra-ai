# scripts

## `run-macos.sh`

Builds the macOS app, wraps it in a `.app` bundle, ad-hoc signs it, and launches it.

```bash
scripts/run-macos.sh
```

Flags: `--debug`, `--release` (default), `--no-open`.

**Why the bundle is not optional.** macOS only grants microphone access to a *signed
bundle* whose `Info.plist` carries `NSMicrophoneUsageDescription`. `swift run IqraMac`
produces a bare executable — it gets denied the microphone with no prompt, and has no
menu bar. Always launch through this script.

**Toolchain.** The script needs a full Xcode, not just Command Line Tools: SwiftUI's
`@State` and `@Observable` are macros, and the macro plugins ship inside Xcode. With
CLT only, `RecitationCore` compiles but the app target fails with
`plugin for module 'SwiftUIMacros' not found`. The script auto-detects Xcode in
`/Applications` and `~/Downloads`; override with `DEVELOPER_DIR` if it guesses wrong.

The microphone grant is keyed to the bundle id (`ai.iqra.mac`) plus the signature, so
re-running the script keeps a permission you already granted.

---

## `convert-model.sh`

Builds the Quran-tuned model from `tarteel-ai/whisper-base-ar-quran`:

```bash
scripts/convert-model.sh                # full pipeline (~10 min, mostly Core ML)
scripts/convert-model.sh --skip-coreml  # GGML + quantise only
```

Produces:

| Artefact | Size | Purpose |
|---|---|---|
| `Models/ggml-base-ar-quran-q8_0.bin` | 77 MB | quantised weights the app loads |
| `Models/ggml-base-ar-quran-encoder.mlmodelc` | 79 MB | Core ML encoder for the Neural Engine |
| `Models/work/ggml-model.bin` | 277 MB | unquantised, kept for comparison |

It creates `.venv` and installs the Python dependencies on first run. `numpy` is pinned
below 2.0 because coremltools' torch converter still assumes the 1.x ABI.

### Three traps this script exists to encode

**The config `max_length` trap.** whisper.cpp's `convert-h5-to-ggml.py` writes
`max_length` into the GGML header as the decoder context size. Stock OpenAI checkpoints
omit that field, so the script falls back to `max_target_positions` and is correct.
Tarteel's config *does* set `max_length` — to 1024, a text-generation default unrelated
to the architecture — while the real decoder positional embedding has 448 rows. Left
alone the conversion completes happily and produces a file whisper.cpp refuses to load:

```
tensor 'decoder.positional_embedding' has wrong size in model file
shape: [512, 448, 1], expected: [512, 1024, 1]
```

The script rewrites `max_length` to `max_target_positions` before converting.

**The model-name whitelist.** `convert-h5-to-coreml.py` validates `--model-name`
against a hard-coded list of stock Whisper sizes, so a custom name is rejected outright.
The name only decides output filenames — the architecture comes from the checkpoint — so
the script converts as `base` and renames afterwards.

**The encoder filename.** whisper.cpp strips a trailing `-qX_X` before looking for
`<stem>-encoder.mlmodelc`, so the encoder must *not* carry the quantisation suffix. One
encoder therefore serves every quantisation of the same weights. Getting this wrong is
silent: the libraries are built with `WHISPER_COREML_ALLOW_FALLBACK`, so a missing
encoder just means the model runs on Metal/CPU instead of the ANE. The app shows which
one is live in the sidebar, and a test asserts the filename.

### Measured results

Al-Ikhlāṣ 112:1–4 against the bundled fixture, accuracy = words matched by the aligner:

| Config | Accuracy | Words timestamped | Latency (7.76 s audio) |
|---|---|---|---|
| stock `base` | 5/15 (33%) | 14/14 | 112 ms |
| tarteel q8_0, no DTW | 11/15 (73%) | 5/15 | 175 ms |
| **tarteel q8_0 + DTW** | **11/15 (73%)** | **15/15** | **205 ms** |
| tarteel f32 + DTW | 11/15 (73%) | 15/15 | 220 ms |

Quantisation costs no accuracy while saving 200 MB, so q8_0 is what ships. DTW costs
~17% latency and is non-negotiable — see below. Everything is 35–70x realtime on an M5.

The fixture is macOS `say` output, which is synthetic MSA rather than recitation and is
therefore out of domain for a model fine-tuned on real qāri' audio. Treat these numbers
as a regression baseline, not as an accuracy estimate for real use.

### Why DTW timestamps are switched on

Fine-tuned models are typically trained on short clips without timestamp tokens, so the
timings they emit degrade badly: this model timestamps the first five words and collapses
the remaining ten onto a single instant at the end of the audio. Deriving alignment by
DTW over the decoder's cross-attention recovers all fifteen.

This matters beyond cosmetics. v2 tajweed measures durations over these word boundaries,
so partial timing would make the feature impossible — and the recogniser's own
anti-hallucination guard keys on degenerate timing, so it was discarding perfectly good
transcriptions before DTW was enabled.

One trap: whisper.cpp **silently disables DTW when flash attention is enabled**, which it
is by default. It logs `dtw_token_timestamps is not supported with flash_attn - disabling`
and carries on, so the only visible symptom is `t_dtw` coming back as `-1`.
`WhisperSpeechRecognizer` therefore sets `flash_attn = false` whenever DTW is requested.

## `fetch-vad-model.sh`

Downloads the Silero VAD weights (~865 KB) used by `SileroVoiceActivityDetector`.

```bash
scripts/fetch-vad-model.sh          # silero-v5.1.2 (default)
scripts/fetch-vad-model.sh v6.2.0
```

These are in whisper.cpp's GGML format, so the detector runs through the ggml backend
already linked for speech recognition. The analysis window length is stored in the model
file and is not exposed by the C API, so `SileroVoiceActivityDetector` probes for it at
load time rather than assuming Silero's usual 512 samples.

Without this model the app falls back to `EnergyVoiceActivityDetector`, which cannot
distinguish speech from noise — and whisper invents Arabic when handed noise. The
Settings pane says so in orange when that is the case.

## `build-quran-db.py`

Builds `Resources/quran.sqlite3` — Uthmani text for all 6,236 āyāt with a word-by-word
breakdown and surah metadata, 5.8 MB.

```bash
scripts/build-quran-db.py            # build and verify
scripts/build-quran-db.py --verify   # re-check an existing database
scripts/build-quran-db.py --force    # rebuild
```

Source: the quran.com API v4 `text_uthmani` field (Tanzil-derived). No API key needed;
114 requests with backoff.

### Verification

This is the text of the Quran, so the script refuses to emit a database that fails any
check rather than shipping something plausible:

- 114 surahs and 6,236 āyāt in total.
- Per-surah āyah counts match a hard-coded table of the Hafs/Kufan numbering **and** the
  API's own `verses_count` — two independent sources agreeing.
- Āyah numbering is contiguous 1..n within every surah.
- No empty verse text.
- The `words` rows rejoin with single spaces to *exactly* the verse text. This is what
  makes the word-by-word breakdown trustworthy rather than merely plausible.
- Exact-byte spot checks on 1:1 and 112:1.
- A SHA-256 of the whole corpus is recorded in the `metadata` table, so a rebuild
  producing different text is immediately visible. The app shows it in Settings → Text.

`SQLiteVerseStore` re-checks the surah and āyah counts when it opens the file, so a
truncated or substituted database fails at startup rather than silently serving wrong
text. It opens read-only.

### Notes

**Normalisation is not stored.** The database holds the Uthmani text as published;
matching-time folding (diacritics, tatweel, alef variants) is applied by Swift's
`ArabicNormalizer` at load. Duplicating that logic in Python would give two
implementations that could drift apart and break word matching with no visible symptom.

**The tatweel.** This rendering carries the dagger alef on a TATWEEL (U+0640), so 1:1 is
ٱلرَّحْمَـٰنِ rather than ٱلرَّحْمَٰنِ. Both are valid renderings of the same word and the
normaliser strips tatweel before matching, but the spot check pins the exact bytes so a
source that changed convention would be caught.

**Certificates.** Python installed from python.org does not use the system keychain and
ships no CA bundle, so HTTPS fails with `CERTIFICATE_VERIFY_FAILED` until you run its
`Install Certificates.command`. The script falls back to `certifi` when that hasn't been
done, but never disables verification — an unauthenticated transport is not acceptable
for fetching scripture.

