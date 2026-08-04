# Running the experiments

Every measurement quoted in the tajweed code can be reproduced from here. They are worth
re-running rather than trusting: several numbers in this project's history were wrong, and
each was caught by running the check rather than by reading the code.

Setup, once:

```bash
export DEVELOPER_DIR=/Users/km/Downloads/Xcode-beta.app/Contents/Developer
swift build -c release
```

Audio is fetched from everyayah and cached, so the first run of a reciter is slower.
Everything is nice'd in the examples below — these are sustained model inference and this
machine cools passively.

---

## 1. Does a tajweed check work?

The one that matters. It takes correct recitation, breaks one thing in a known place, and
asks whether the checker notices — and how often it complains about recitation that was
never broken.

```bash
nice -n 20 .build/release/IqraEval --calibrate-tajweed --aligned-tajweed --reciter Husary_128kbps --surahs 2,20,36,55,78 --limit 12
```

Reads as:

```
  FALSE FLAGS          5 on correct recitation
    maddWajibMuttasil  3
    qalqalah           2

── with one elongation shortened by half ──
  CAUGHT               7/47  (14.9% )

── with one qalqalah swallowed instead of bounced ──
  CAUGHT               5/13  (38.5% )
```

**Read the two together.** A checker can reach any catch rate by complaining more, so a
catch count means nothing without the false flags beside it. In this app a false accusation
is the worse error, so the false-flag line is the one with a veto.

Swap `--reciter` for any of `Minshawy_Murattal_128kbps`, `Alafasy_128kbps`,
`Abdul_Basit_Murattal_64kbps`, `Husary_Mujawwad_64kbps`, `Saood_ash-Shuraym_128kbps`,
`Abdurrahmaan_As-Sudais_192kbps` — or any everyayah folder name, whether or not it is in
the app's catalogue. Always check a threshold on a reciter it was not tuned on.

## 2. Can a ṣifah be learned from reference recitation?

No, and this prints why. It is the check that retired four earlier investigations.

```bash
nice -n 20 .venv/bin/python scripts/train-sifat.py --frames DIR --hold-out Minshawy_Murattal --audit
```

The right-hand column is a model given **no audio at all**, only the phoneme identities
either side. It reaches a perfect AUC on all ten ṣifāt and beats every audio model. The
labels come from the text and never vary from it, so there is nothing for sound to explain.

Run this column against any new feature set before believing a result from it. A number
from that script means nothing without it.

`DIR` is a directory of frame files; see §3.

## 3. Building the frame corpus

One file per reciter, each about 6,000 labelled phonemes from 80 āyāt, roughly a minute of
inference:

```bash
nice -n 20 .build/release/IqraEval --calibrate-tajweed --training-frames ~/frames/husary.bin --context 3 --reciter Husary_128kbps --surahs 2,4,7,20,36,55,67,78 --limit 10
```

Inspect one:

```bash
.venv/bin/python scripts/read-frames.py ~/frames/husary.bin
```

Two things worth knowing before spending an afternoon generating data. More **āyāt** per
reciter does nothing — six times the data moved held-out AUC from 0.790 to 0.779. More
**voices** did keep helping, up to about nine. Both findings were measured on the
confounded task in §2, so treat them as facts about that task only.

## 4. Everything else the harness measures

| flag | question |
|---|---|
| `--tajweed-negatives` | the ṣifah heads, with the sound removed — they score 0/68 |
| `--goodness` | word-level pronunciation confidence (GOP) |
| `--nasality` | band-ratio nasality against a reciter's own vowels |
| `--reference-madd` | madd judged against a reference recording instead of the reciter's own pace |
| `--judge-sifat` | the ṣifah heads as a detector, kept only to repeat the measurement |
| `--refine` | re-align in short chunks; alignment decays over long āyāt |
| `--check-clock` | frame-rate and timing sanity |

With no tajweed flag at all, `IqraEval` runs the word-matching evaluation instead — word
error rate, false flags, omitted and repeated āyāt, page overshoot:

```bash
nice -n 20 .build/release/IqraEval --reciter Husary_128kbps --surahs 2,20,36,55,78 --limit 12
```

---

## What is still missing

Every threshold in this project is fitted to studio recordings of professional qurrāʾ, who
do not make the mistakes the app exists to catch. The synthetic negatives above are the
best available substitute and they are not the same thing: the manipulation chooses where
the error is, so they show that a checker responds to a change, not that it finds a mistake
a person actually made.

The missing input is a recording of ordinary recitation — one page read normally, one read
with deliberate mistakes — which would let every number here be checked against the thing
it is meant to predict.
