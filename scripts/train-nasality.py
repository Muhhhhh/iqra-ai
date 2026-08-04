#!/usr/bin/env python3
"""Train the ghunnah detector, and check that it is hearing rather than reading.

Each frame is one phoneme of a correct recitation, labelled with whether the text asks for
ghunnah there. That label is a fact about the text, and over the whole corpus it is very
nearly the same fact as which letter it is: ن and م are 100% maghnoon, every other
consonant is 0%. A model given audio scores AUC 0.814 on it — and a control given no audio
at all, only the phoneme identity the app already knows from the muṣḥaf, scores 0.960. The
aggregate task is letter recognition wearing a tajweed costume.

What survives is the vowels. Symbols 32, 33 and 34 carry ghunnah 13–17% of the time, so
identity cannot answer for them and audio has to. There the control falls to 0.514, chance,
and audio reaches 0.718. That gap is the only measured evidence that any of this hears
nasality, and it is the number to improve. It is also the right shape for the app: nasal
coarticulation spreads into neighbouring vowels, so how nasal a vowel sounds is the
acoustic evidence for whether the ghunnah beside it was actually made.

    scripts/train-nasality.py --frames DIR --hold-out Minshawy_Murattal --symbols 32,33,34

Always run --control alongside any new feature set. An aggregate score that goes up while
the control goes up with it means nothing.

Held-out means held-out *by reciter*: a voice in the test set appears nowhere in training,
which is the only split that predicts what happens when a stranger recites into the app.
Add --curve to sweep the training-voice count, redrawing which voices are used at each size
so the number describes "n voices" rather than one lucky subset.
"""

import argparse
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

def voice(path, control=False, only=None):
    """One reciter's frames: features, and 1 where the text requires ghunnah.

    Every phoneme is used, not only ن and م. Restricting to those two teaches nothing —
    the phonetiser gives a nūn that carries no ghunnah a different symbol altogether, so
    every ن/م frame in the corpus is maghnoon and the task has one class. The contrast
    worth learning is between the sounds the text nasalises and the sounds it does not,
    wherever they fall.
    """
    X, symbols, labels, names = load(path)
    ghonna = labels[:, names.index("ghonna")]
    # 1 maghnoon, 2 not_maghnoon, 0 no expectation — an unlabelled frame is not evidence
    # either way, so it is dropped rather than folded into the negative class.
    labelled = ghonna > 0
    if only is not None:
        # Restricting to symbols whose ghunnah is not settled by identity. Over the whole
        # corpus the label and the letter are nearly the same fact, so an aggregate score
        # measures letter recognition; on these frames it cannot.
        labelled &= np.isin(symbols, only)
    if control:
        # The control hears nothing: one-hot phoneme identity and no audio at all.
        #
        # Ghunnah is largely a property of which letter it is, so a detector fed audio can
        # reach a respectable AUC while doing nothing but recognising nūns — which is
        # useless for judging recitation, since the app already knows the letter from the
        # text. This model can only guess from identity. Whatever it scores is the floor
        # the audio has to clear before any of it counts as hearing.
        identity = np.zeros((labelled.sum(), 64), dtype=np.float32)
        identity[np.arange(labelled.sum()), symbols[labelled] % 64] = 1.0
        X = identity
    else:
        X = X[labelled]
    return X, (ghonna[labelled] == 1).astype(np.float32)


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
    # The classes are lopsided — roughly one nasalised phoneme in five — so the loss is
    # weighted, or the model earns most of its accuracy by never predicting ghunnah.
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
    """What the detector would cost in use: how wrong its confident calls are.

    AUC ranks; it does not say what happens at the one threshold that ships. A tajweed
    warning is an accusation about someone's recitation of the Qurʾān, so the number that
    decides whether this is usable is the share of flags that are wrong — not the share
    of errors that are caught.
    """
    # The held-out recitation is correct throughout, so every required-ghunnah frame that
    # scores too low is a phoneme the app would have accused wrongly. Fixing that rate
    # first and asking what discrimination survives is the right order: the tolerance for
    # false accusation is set by what the app is for, not by what the model can manage.
    nasal = np.sort(scores[truth == 1])
    plain = scores[truth == 0]
    print("       if this share of correct ghunnahs is wrongly flagged…")
    print("       …this share of absent ghunnahs would be caught")
    for accused in (0.01, 0.02, 0.05, 0.10, 0.20):
        threshold = nasal[int(accused * len(nasal))]
        caught = float((plain < threshold).mean())
        print(f"        {accused:4.0%}  →  {caught:5.1%}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", required=True, type=Path, help="directory of .bin files")
    parser.add_argument("--hold-out", required=True, help="reciter to test on, by file stem")
    parser.add_argument("--curve", action="store_true", help="sweep the training-voice count")
    parser.add_argument("--control", action="store_true",
                        help="train on phoneme identity alone, with no audio")
    parser.add_argument("--symbols", help="comma-separated symbol ids to keep")
    parser.add_argument("--draws", type=int, default=3, help="voice subsets per size")
    parser.add_argument("--min-frames", type=int, default=1000, help="ignore smaller files")
    arguments = parser.parse_args()

    only = ([int(v) for v in arguments.symbols.split(",")] if arguments.symbols else None)
    files = sorted(arguments.frames.glob("*.bin"))
    voices = {}
    for path in files:
        name = path.stem.removeprefix("s-")
        try:
            features, labels = voice(path, arguments.control, only)
        except ValueError as error:
            print(f"    skipping {name}: {error}")
            continue
        if len(features) < arguments.min_frames:
            continue
        voices[name] = (features, labels)

    held = [n for n in voices if arguments.hold_out in n]
    if not held:
        print(f"error: no frame file matches {arguments.hold_out!r}", file=sys.stderr)
        print(f"  have: {', '.join(sorted(voices))}", file=sys.stderr)
        return 1
    test = [voices.pop(name) for name in held]
    names = sorted(voices)

    total = sum(len(f) for f, _ in voices.values())
    rate = np.concatenate([l for _, l in voices.values()]).mean()
    print(f"==> {len(names)} training voices, {total} nasal frames, {rate:.1%} maghnoon")
    print(f"    held out: {', '.join(held)} ({sum(len(f) for f, _ in test)} frames)")

    sizes = range(1, len(names) + 1) if arguments.curve else [len(names)]
    for size in sizes:
        scores, predicted, actual = [], None, None
        for draw in range(arguments.draws if size < len(names) else 1):
            rng = np.random.default_rng(draw)
            chosen = rng.choice(len(names), size=size, replace=False)
            train = [voices[names[i]] for i in chosen]
            area, predicted, actual = fit_and_score(train, test, seed=draw)
            scores.append(area)
        spread = f" ± {np.std(scores):.3f}" if len(scores) > 1 else ""
        print(f"    {size:2d} voices   AUC {np.mean(scores):.3f}{spread}")
    report(predicted, actual)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
