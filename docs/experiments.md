# Running the experiments

Every tajweed figure quoted in this repository can be reproduced from here. They are worth
re-running rather than trusting: several numbers in this project's history were wrong, and
each was caught by running the check rather than by reading the code.

```bash
export DEVELOPER_DIR=/Users/km/Downloads/Xcode-beta.app/Contents/Developer
swift build -c release
```

Audio is fetched from everyayah and cached, so the first run of a reciter is slower.
Everything is nice'd below — these are sustained model inference and the machine this was
written on cools passively.

---

## The two questions

Every check here is asked one of two ways, and which one decides everything about it.

**Is the sound there?** Force two readings of the āyah onto the same audio — the phonemes
the text calls for, and the same with the rule broken — and see which fits better. This is
how qalqalah, ikhfāʾ and idghām are judged. It cannot be confounded by the text, because
both readings carry the same words in the same context, and it asks a discrete question so
a sound briefer than one frame is not automatically invisible.

**How long did it last?** Read a duration off the alignment and compare it to the reciter's
own pace. This is how madd is judged, and it works only where the sound is longer than the
model's 40 ms frame.

A third way — classify the ṣifah from a corpus of correct recitation — is impossible, and
§4 shows why in one command.

---

## 1. Does a check work?

The one that matters. It takes correct recitation, breaks one thing in a known place, and
asks whether the checker notices — and how often it complains about recitation that was
never broken.

```bash
nice -n 20 .build/release/IqraEval --calibrate-tajweed --aligned-tajweed --reciter Husary_128kbps --surahs 2,20,36,55,78 --limit 12
```

**Read the false flags and the catches together.** A checker reaches any catch rate by
complaining more, so a catch count means nothing without the false flags beside it. In this
app a false accusation is the worse error, so the false-flag line has a veto.

**Run it on more than one reciter.** Madd's false flags run 1, 1, 4, 5 and 13 per 58 āyāt
across five qurrāʾ, and its catch rate 28%, 9%, 9%, 5%, 12% — the 28% belongs to Al-Husary,
who happens to be the default. A single-reciter figure for a duration check describes the
reciter.

**Treat every catch rate here as an upper bound.** The mistakes are synthetic — audio this
repository compressed or excised itself — and that has misled badly before: qalqalah judged
by duration scored 12 of 39 against excisions and **zero** against a page recited with every
bounce deliberately swallowed. It was detecting the edit. Only §3 tests a real mistake.

## 2. Where is the floor?

What a check says about recitation that is certainly correct. Run it on reciters it was not
tuned on; a threshold that only holds for one voice is not a threshold.

```bash
nice -n 20 .build/release/IqraEval --calibrate-tajweed --hypothesis --rule ikhfa --reciter Husary_128kbps --surahs 2,20,36,55,78 --limit 12
```

`--rule` takes `qalqalah`, `ikhfa`, `iqlab`, `idgham`. Any everyayah folder works as
`--reciter`, in or out of the app's catalogue.

A floor that is *bimodal* is the signal to stop. Madd measured this way put three qurrāʾ
near zero and three near three quarters, which describes the reciter rather than the
recitation, and that killed the transfer.

## 3. Against a real mistake

The only evidence that counts, and the only kind this repository cannot manufacture. One
page recited properly, then again with a single rule broken on purpose:

```bash
nice -n 20 .build/release/IqraEval --calibrate-tajweed --replay ~/recordings-folder
```

Recordings come from the app — Settings ▸ Matching ▸ Recordings ▸ *Keep my recitation on
this Mac* — and land in Application Support as a WAV and a JSON.

Ikhfāʾ is the only rule tested this way so far: 0 of 7 on the clean pass, 7 of 7 with the
nūns said plainly, Fisher exact p = 0.0006.

`--clips ~/somewhere` writes each flagged moment as its own labelled WAV. The one question
no measurement here can answer is whether a flag was *right*; twelve one-second clips can
be put to someone who knows in two minutes.

## 4. Can a ṣifah be learned from reference recitation?

No, and this prints why. It is the check that retired four earlier investigations.

```bash
nice -n 20 .venv/bin/python scripts/train-sifat.py --frames DIR --hold-out Minshawy_Murattal --audit
```

The right-hand column is a model given **no audio at all** — only the phoneme identities
either side, which the app already reads off the muṣḥaf. It reaches a perfect AUC on all ten
ṣifāt and beats every audio model. The labels come from the text and never vary from it, so
there is nothing for sound to explain.

Run that column against any new feature set before believing a result from it. `DIR` is a
directory of frame files; see §5.

## 5. Building the frame corpus

One file per reciter, about 6,000 labelled phonemes from 80 āyāt, roughly a minute:

```bash
nice -n 20 .build/release/IqraEval --calibrate-tajweed --training-frames ~/frames/husary.bin --context 3 --reciter Husary_128kbps --surahs 2,4,7,20,36,55,67,78 --limit 10
```

```bash
.venv/bin/python scripts/read-frames.py ~/frames/husary.bin
```

More **āyāt** per reciter does nothing — six times the data moved held-out AUC from 0.790 to
0.779. More **voices** kept helping to about nine. Both were measured on the confounded task
in §4, so they are facts about that task only.

## 6. Everything else

| flag | question |
|---|---|
| `--ghunnah-hold` | the ghunnah hold check: 54 false flags, 0 of 24 caught |
| `--invert-ghunnah` | the same read backwards — 47 and 3 of 24, so the measurement runs opposite to the mistake |
| `--madd-shortfall N` | sweep the madd threshold |
| `IQRA_FINE=1` | 20 ms frames, by interleaving two runs half a frame apart |
| `IQRA_AGREE=1` | keep only verdicts that survive a 20 ms shift — changed nothing, so the flags are systematic rather than noisy |
| `--tajweed-negatives` | the model's own ṣifāt heads, with the sound removed: 0 of 68 |
| `--goodness` | word-level pronunciation confidence |
| `--refine` | re-align in short chunks |

With no tajweed flag at all, `IqraEval` runs the word-matching evaluation — word error rate,
false flags, omitted and repeated āyāt, page overshoot:

```bash
nice -n 20 .build/release/IqraEval --reciter Husary_128kbps --surahs 2,20,36,55,78 --limit 12
```

`--max-segment` and `--trailing-silence` take comma-separated lists and sweep. Shortening
segments to feel more responsive costs a great deal: 20s → 8s took word errors from 19.1% to
27.6% and false flags from 2.16% to 3.73%, while the median segment barely moved. The app
shows provisional readings instead.

---

## What is still missing

Every threshold here is fitted to studio recordings of professional qurrāʾ, who do not make
the mistakes the app exists to catch, and every catch rate but ikhfāʾ's comes from audio this
repository edited itself.

Two things would change that, and neither is more compute:

- **A qārī listening to the flagged moments** and saying which were right. `--clips` prepares
  it. It is the only route to knowing whether a false-flag rate is real.
- **Paired readings from ordinary reciters** — one page normal, one with a single rule broken
  — recorded on ordinary hardware. Madd has never been tested against a real rushed
  elongation; idghām has never been tested at all.
