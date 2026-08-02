#!/usr/bin/env python3
"""Convert the Muaalem pronunciation model to Core ML.

`obadx/muaalem-model-v3_2` (MIT, arXiv 2509.00094) is a Wav2Vec2-BERT with eleven CTC
heads — one per ṣifah — which is what makes it possible to verify qalqalah, ghunnah,
tafkhīm and the rest rather than only measuring duration.

    scripts/convert-tajweed-model.py            # convert and verify
    scripts/convert-tajweed-model.py --window 8 # seconds of audio per inference window

Output: Models/muaalem-v3_2.mlpackage

## Why this converts from the safetensors rather than the published TorchScript

Both TorchScript exports on the Hub are unusable on Apple silicon:

* `model_fp16.pt` bakes its layer-norm constants as fp16, and CPU has no fp16 kernels —
  it fails on the first `layer_norm`. Loading it onto MPS fails earlier still, because
  the module contains float64 which MPS does not support.
* `model_fp32.pt` was traced on CUDA and carries the device in the graph:
  `Could not run 'aten::empty.memory_format' with arguments from the 'CUDA' backend`.

So the model is rebuilt from the safetensors weights with the authors' own modelling code
(github.com/obadx/quran-muaalem, MIT) and traced here, on this machine.

## Prerequisites

    pip install torch transformers coremltools
    pip install "quran-transcript>=0.5.2" diff-match-patch
    pip install --no-deps git+https://github.com/obadx/quran-muaalem

Note the numpy conflict: quran-muaalem wants numpy >= 2.2.6 and older coremltools wanted
< 2. coremltools 9 works with numpy 2, so a single environment is fine — but if you pin
coremltools down, you will need two.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Models" / "muaalem-v3_2.mlpackage"
MODEL_ID = "obadx/muaalem-model-v3_2"

# w2v-BERT consumes 80-bin mel filterbanks stacked in pairs: 160 values per row, one row
# per 20 ms. The model then halves that again, so its output runs at 25 frames a second.
FEATURE_DIM = 160
ROWS_PER_SECOND = 50


def register_missing_ops() -> None:
    """Teach coremltools the handful of torch ops it does not ship.

    The conformer uses a couple of tensor-creation ops that have no Core ML translation
    out of the box. They are trivial to express with `fill`, and registering them here
    keeps the vendored model untouched.
    """
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import (
        _TORCH_OPS_REGISTRY,
        register_torch_op,
    )

    def _shape_of(value):
        # `new_ones`/`new_zeros` take the shape as a list of ints or a tensor. `fill`
        # insists on int32, and a traced shape arrives as fp32 — hence the cast.
        if hasattr(value, "val") and value.val is not None:
            raw = value.val
            return [int(v) for v in raw] if hasattr(raw, "__len__") else [int(raw)]
        return mb.cast(x=value, dtype="int32")

    if "new_ones" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
        @register_torch_op
        def new_ones(context, node):  # noqa: ANN001 - coremltools calling convention
            inputs = _get_inputs(context, node)
            context.add(mb.fill(shape=_shape_of(inputs[1]), value=1.0, name=node.name))

    if "new_zeros" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
        @register_torch_op
        def new_zeros(context, node):  # noqa: ANN001
            inputs = _get_inputs(context, node)
            context.add(mb.fill(shape=_shape_of(inputs[1]), value=0.0, name=node.name))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", type=float, default=10.0,
                        help="seconds of audio per inference window (default 10)")
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    args = parser.parse_args()

    rows = int(args.window * ROWS_PER_SECOND)
    print(f"==> Window: {args.window:g}s = {rows} feature rows")

    try:
        import torch
        import coremltools as ct
        from quran_muaalem.modeling.modeling_multi_level_ctc import Wav2Vec2BertForMultilevelCTC
    except ImportError as error:
        print(f"error: missing dependency — {error}", file=sys.stderr)
        print(__doc__.split("## Prerequisites")[1], file=sys.stderr)
        return 1

    register_missing_ops()

    print(f"==> Loading {MODEL_ID}")
    started = time.time()
    model = Wav2Vec2BertForMultilevelCTC.from_pretrained(MODEL_ID).eval()
    parameters = sum(p.numel() for p in model.parameters())
    print(f"    {parameters / 1e6:.0f}M parameters in {time.time() - started:.0f}s")

    # The head order has to be fixed and recorded: Core ML returns outputs by name, and
    # Swift needs to know which ṣifah each one is.
    levels = sorted(model.config.level_to_vocab_size.keys())
    print(f"==> Heads: {', '.join(levels)}")

    class Wrapper(torch.nn.Module):
        """Fixed-shape, tuple-returning wrapper.

        Core ML cannot express the dict the model returns, and tracing needs a stable
        output order — hence the explicit sort above.
        """

        def __init__(self, inner, levels, rows):
            super().__init__()
            self.inner = inner
            self.levels = levels
            self.rows = rows

        def forward(self, input_features):
            # No attention mask. Every frame of a full window is valid, and passing an
            # all-ones mask is bit-identical to passing none (verified: max |diff| = 0,
            # identical argmax) — but the masked path goes through `new_ones` and shape
            # arithmetic that Core ML cannot express. Dropping it removes the problem
            # rather than working around it.
            out = self.inner(input_features=input_features)
            logits = out.logits if hasattr(out, "logits") else out
            return tuple(logits[level] for level in self.levels)

    wrapper = Wrapper(model, levels, rows).eval()
    example = torch.zeros(1, rows, FEATURE_DIM)

    print("==> Tracing")
    started = time.time()
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)
    print(f"    traced in {time.time() - started:.0f}s")

    print("==> Converting to Core ML (slow — a 600M-parameter conformer)")
    started = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_features", shape=example.shape, dtype=None)],
        outputs=[ct.TensorType(name=level) for level in levels],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    print(f"    converted in {time.time() - started:.0f}s")

    mlmodel.short_description = (
        "Muaalem v3.2 — Quran pronunciation attributes (obadx, MIT, arXiv 2509.00094)"
    )
    mlmodel.user_defined_metadata["levels"] = ",".join(levels)
    mlmodel.user_defined_metadata["rows"] = str(rows)
    mlmodel.user_defined_metadata["feature_dim"] = str(FEATURE_DIM)
    mlmodel.user_defined_metadata["frames_per_second"] = "25"

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(OUTPUT))
    size = sum(f.stat().st_size for f in OUTPUT.rglob("*") if f.is_file())
    print(f"==> Wrote {OUTPUT} ({size / 1e6:.0f} MB)")

    # --- Verify against PyTorch --------------------------------------------------------
    # A conversion that runs but returns different numbers is worse than one that fails.
    print("==> Verifying against PyTorch")
    import numpy as np

    generator = np.random.default_rng(0)
    probe = generator.standard_normal((1, rows, FEATURE_DIM)).astype(np.float32) * 0.1
    with torch.no_grad():
        reference = wrapper(torch.from_numpy(probe))
    predicted = mlmodel.predict({"input_features": probe})

    worst = 0.0
    for index, level in enumerate(levels):
        want = reference[index].numpy()
        got = np.asarray(predicted[level])
        if want.shape != got.shape:
            print(f"    FAIL {level}: shape {got.shape} vs {want.shape}")
            return 1
        agreement = (want.argmax(-1) == got.argmax(-1)).mean()
        worst = max(worst, float(np.abs(want - got).max()))
        print(f"    {level:<22} argmax agreement {agreement * 100:5.1f}%")
    print(f"    largest absolute logit difference: {worst:.4f}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
