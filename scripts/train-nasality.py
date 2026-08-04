#!/usr/bin/env python3
"""Train the ghunnah detector, and measure what it gains from another reciter.

The question this answers is how many voices a nasality detector needs before it stops
improving. It is worth answering carefully, because the two obvious ways to add data are
not equally useful: six times as many āyāt from the same reciters moved held-out AUC from
0.790 to 0.779 — nothing — while going from one voice to six moved it from 0.693 to 0.803.
Voices carry the variation that matters; āyāt mostly repeat it.

Each frame is one ن or م from a correct recitation, labelled with whether the text asks
for ghunnah there. Held-out means held-out *by reciter*: a voice in the test set appears
nowhere in training, which is the only split that predicts what happens when a stranger
recites into the app.

    scripts/train-nasality.py --frames DIR --hold-out Minshawy_Murattal_128kbps

Add --curve to sweep the training-voice count, redrawing which voices are used at each
size so the number describes "n voices" rather than one lucky subset.
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

def voice(path):
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
    return X[labelled], (ghonna[labelled] == 1).astype(np.float32)


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
    parser.add_argument("--draws", type=int, default=3, help="voice subsets per size")
    parser.add_argument("--min-frames", type=int, default=1000, help="ignore smaller files")
    arguments = parser.parse_args()

    files = sorted(arguments.frames.glob("*.bin"))
    voices = {}
    for path in files:
        name = path.stem.removeprefix("s-")
        try:
            features, labels = voice(path)
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
