#!/usr/bin/env python3
"""Train a ṣifah detector from reference recitation — and show why that cannot work.

Run --audit before anything else here. It prints this table, which is the whole story:

    ṣifah                   audio   text ±2
    ghonna                  0.814     1.000
    hams_or_jahr            0.759     1.000
    shidda_or_rakhawa       0.785     1.000
    tafkheem_or_taqeeq      0.892     0.999
    itbaq                   0.845     1.000
    qalqla                  0.771     1.000
    safeer                  0.791     1.000
    istitala                0.913     1.000
    tafashie                0.928     1.000
    tikraar                 0.834     1.000

The right-hand column is a model given no audio whatsoever — only the phoneme identities
either side, which the app already reads off the muṣḥaf. It scores a perfect AUC on every
one of the ten ṣifāt, and beats the audio model on every one of them.

This is not a confound to be controlled away. The labels come from
scripts/export-phonemes.py, which derives them from the Uthmani text and never opens an
audio file, so every label here is a deterministic function of the text by construction.
Reference recitations are correct throughout, so the label never varies while the text is
held still. Training audio against it can only recover the text — and the text is the one
thing the app is never missing. It is also why the Muaalem model's own ṣifāt heads predict
from context rather than sound: they were fitted on labels built the same way.

No feature set rescues this framing, and a better one makes it worse — richer, more
contextual features score higher precisely by recovering the text more completely. The
vowels-only result that once looked like evidence of hearing (audio 0.718 against a
same-symbol control at 0.514) went to 1.000 the moment the control was allowed to see a
single neighbour. A vowel is nasalised because a nūn stands next to it.

What can be learned is the question this corpus cannot pose: same āyah, same reciter, same
text, one recitation intact and one with the ṣifah acoustically removed. There the label
varies with the audio while the text is fixed, a text-only control scores 0.5 by
construction, and the confound is impossible rather than merely watched for. See
`IqraEval --tajweed-negatives`.

    scripts/train-sifat.py --frames DIR --hold-out Minshawy_Murattal --audit

Held-out means held-out *by reciter*: a voice in the test set appears nowhere in training,
which is the only split that predicts what happens when a stranger recites into the app.
Add --curve to sweep the training-voice count, redrawing which voices are used at each size
so the number describes "n voices" rather than one lucky subset.
"""

import argparse
import copy
import importlib.util
import sys
from pathlib import Path

import numpy as np

# read-frames.py is hyphenated, so it cannot be imported by name.
_spec = importlib.util.spec_from_file_location(
    "read_frames", Path(__file__).resolve().parent / "read-frames.py"
)
_frames = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_frames)
load = _frames.load

SYMBOLS = 64  # one-hot width; the vocabulary is 43 and this leaves room


def voice(path, control=False, only=None, span=0, sifa="ghonna"):
    """One reciter's frames: features, and 1 where the text requires the ṣifah.

    Every phoneme is used, not only ن and م. Restricting to those two teaches nothing —
    the phonetiser gives a nūn that carries no ghunnah a different symbol altogether, so
    every ن/م frame in the corpus is maghnoon and the task has one class.
    """
    X, symbols, labels, names = load(path)
    wanted = labels[:, names.index(sifa)]
    # 0 means the phonetiser had no expectation — not evidence either way, so such a frame
    # is dropped rather than folded into the negative class. Otherwise it is the first
    # class against the rest.
    labelled = wanted > 0
    if only is not None:
        labelled &= np.isin(symbols, only)
    if control:
        # The control hears nothing: one-hot phoneme identity, and no audio at all.
        #
        # With span > 0 it also sees the neighbouring symbols, which is the control that
        # matters. A vowel is nasalised because a nasal consonant stands beside it, so
        # anything able to see its neighbours can name the label without listening — and
        # self-attentive encoder states carry exactly that context. Whatever this scores is
        # the floor real audio has to clear before any of it counts as hearing.
        rows = np.flatnonzero(labelled)
        width = 2 * span + 1
        identity = np.zeros((len(rows), SYMBOLS * width), dtype=np.float32)
        for slot, offset in enumerate(range(-span, span + 1)):
            # Frames run in phoneme order, so a neighbour is the adjacent row. Āyah joins
            # make roughly one row in a hundred wrong, which cannot manufacture a result.
            neighbour = np.clip(rows + offset, 0, len(symbols) - 1)
            identity[np.arange(len(rows)), slot * SYMBOLS + symbols[neighbour] % SYMBOLS] = 1.0
        X = identity
    else:
        X = X[labelled]
    return X, (wanted[labelled] == 1).astype(np.float32)


def area_under_curve(scores, truth):
    order = np.argsort(scores)
    ranks = np.empty(len(scores), dtype=np.float64)
    ranks[order] = np.arange(1, len(scores) + 1)
    positive, negative = truth.sum(), (1 - truth).sum()
    if positive == 0 or negative == 0:
        return float("nan")
    return (ranks[truth == 1].sum() - positive * (positive + 1) / 2) / (positive * negative)


def fit_and_score(train, test, seed):
    import torch

    torch.manual_seed(seed)
    torch.set_num_threads(2)  # passive cooling; this is not the slow part anyway

    X = np.concatenate([f for f, _ in train])
    y = np.concatenate([l for _, l in train])
    mean, deviation = X.mean(0), X.std(0) + 1e-6
    features = torch.from_numpy((X - mean) / deviation)
    target = torch.from_numpy(y).unsqueeze(1)

    model = torch.nn.Sequential(
        torch.nn.Linear(features.shape[1], 64), torch.nn.ReLU(),
        torch.nn.Dropout(0.2), torch.nn.Linear(64, 1),
    )
    # The classes are lopsided — for most ṣifāt the minority is a fifth or less — so the
    # loss is weighted, or the model earns its accuracy by never predicting the ṣifah.
    weight = float((1 - y).sum() / max(y.sum(), 1))
    loss = torch.nn.BCEWithLogitsLoss(pos_weight=torch.tensor(weight))
    optimiser = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-4)

    generator = torch.Generator().manual_seed(seed)
    for _ in range(30):
        for batch in torch.randperm(len(features), generator=generator).split(256):
            optimiser.zero_grad()
            loss(model(features[batch]), target[batch]).backward()
            optimiser.step()

    Xt = np.concatenate([f for f, _ in test])
    yt = np.concatenate([l for _, l in test])
    model.eval()
    with torch.no_grad():
        predicted = model(torch.from_numpy((Xt - mean) / deviation)).squeeze(1).numpy()
    return area_under_curve(predicted, yt), predicted, yt


def report(scores, truth):
    """What the detector would cost in use, rather than how well it ranks.

    AUC ranks; it says nothing about the one threshold that would ship. The held-out
    recitation is correct throughout, so a frame the text requires the ṣifah on that scores
    too low is a phoneme the app would have accused wrongly. Fixing that rate first is the
    right order: what the app is for decides the tolerance, not what the model can manage.
    """
    present = np.sort(scores[truth == 1])
    absent = scores[truth == 0]
    if len(present) == 0 or len(absent) == 0:
        return
    print("       if this share of correct recitation is wrongly flagged…")
    print("       …this share of a missing ṣifah would be caught")
    for accused in (0.01, 0.02, 0.05, 0.10, 0.20):
        threshold = present[int(accused * len(present))]
        print(f"        {accused:4.0%}  →  {float((absent < threshold).mean()):5.1%}")


def _say(quiet, *text):
    if not quiet:
        print(*text)


def run(arguments, quiet=False):
    """Fit on the training voices and return the held-out AUC."""
    only = [int(v) for v in arguments.symbols.split(",")] if arguments.symbols else None

    voices = {}
    for path in sorted(arguments.frames.glob("*.bin")):
        features, labels = voice(
            path, arguments.control, only, arguments.control_span, arguments.sifa
        )
        if len(features) >= arguments.min_frames:
            voices[path.stem.removeprefix("s-")] = (features, labels)

    held = [n for n in voices if arguments.hold_out in n]
    if not held:
        raise SystemExit(
            f"error: no frame file matches {arguments.hold_out!r}\n"
            f"  have: {', '.join(sorted(voices))}"
        )
    test = [voices.pop(name) for name in held]
    names = sorted(voices)

    total = sum(len(f) for f, _ in voices.values())
    rate = np.concatenate([l for _, l in voices.values()]).mean()
    _say(quiet, f"==> {len(names)} training voices, {total} frames, {rate:.1%} positive")
    _say(quiet, f"    held out: {', '.join(held)} ({sum(len(f) for f, _ in test)} frames)")

    sizes = range(1, len(names) + 1) if arguments.curve else [len(names)]
    area, predicted, actual = float("nan"), None, None
    for size in sizes:
        scores = []
        for draw in range(arguments.draws if size < len(names) else 1):
            rng = np.random.default_rng(draw)
            chosen = rng.choice(len(names), size=size, replace=False)
            area, predicted, actual = fit_and_score(
                [voices[names[i]] for i in chosen], test, seed=draw
            )
            scores.append(area)
        spread = f" ± {np.std(scores):.3f}" if len(scores) > 1 else ""
        _say(quiet, f"    {size:2d} voices   AUC {np.mean(scores):.3f}{spread}")
        area = float(np.mean(scores))
    if not quiet and predicted is not None:
        report(predicted, actual)
    return area


def audit(arguments) -> int:
    """Every ṣifah, audio against a control that sees only the surrounding letters.

    A mode rather than a note in a commit message, because this project has spent five
    investigations on models that turned out to be reading rather than listening. A number
    from this file means nothing without the column beside it.
    """
    print(f"{'ṣifah':<22}{'audio':>9}{'text ±2':>10}")
    for name in _frames.SIFAT:
        row = []
        for control in (False, True):
            settings = copy.copy(arguments)
            settings.audit, settings.sifa, settings.control = False, name, control
            settings.control_span, settings.curve = 2, False
            score = run(settings, quiet=True)
            row.append(f"{score:.3f}" if score == score else "—")
        print(f"{name:<22}{row[0]:>9}{row[1]:>10}")
    print("\nA control that never hears the audio should not win. Where it does, the")
    print("label is a fact about the text and nothing was learned about sound.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", required=True, type=Path, help="directory of .bin files")
    parser.add_argument("--hold-out", required=True, help="reciter to test on, by file stem")
    parser.add_argument("--audit", action="store_true",
                        help="every ṣifah, audio against a text-only control")
    parser.add_argument("--sifa", default="ghonna", help="which ṣifah to learn")
    parser.add_argument("--control", action="store_true",
                        help="train on phoneme identity alone, with no audio")
    parser.add_argument("--control-span", type=int, default=0,
                        help="neighbouring symbols the control may see, each side")
    parser.add_argument("--curve", action="store_true", help="sweep the training-voice count")
    parser.add_argument("--symbols", help="comma-separated symbol ids to keep")
    parser.add_argument("--draws", type=int, default=3, help="voice subsets per size")
    parser.add_argument("--min-frames", type=int, default=200, help="ignore smaller files")
    arguments = parser.parse_args()

    if arguments.audit:
        return audit(arguments)
    run(arguments)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
