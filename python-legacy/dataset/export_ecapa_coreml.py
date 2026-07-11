#!/usr/bin/env python3
"""export_ecapa_coreml.py — Stage 5b: export SpeechBrain ECAPA-TDNN to Core ML for on-device
(Apple Neural Engine) speaker embeddings, so the live iOS app can compute the SAME 192-dim voice
fingerprint the offline pipeline uses instead of the weak mean-MFCC (which a corpus study showed
cannot separate same-feed speakers).

Approach: wrap the full SpeechBrain path — Fbank features → sentence mean/var norm → ECAPA-TDNN
embedding → L2 normalize — into one module that takes a RAW 16 kHz mono waveform of fixed length
(pad/crop on the Swift side). Feeding raw audio guarantees the Swift front-end can't drift from the
model's expected features. Trace with TorchScript, convert with coremltools, save an .mlpackage, and
VALIDATE by cosine-comparing the Core ML output to the original torch output on random + real audio.

Run under the spike venv (speechbrain + torch + coremltools):
    ~/CommSight/spike-venv/bin/python -m dataset.export_ecapa_coreml \
        --out ~/CommSight/atc-coreml/ecapa/ECAPA.mlpackage
"""
import argparse
import os
import sys
import numpy as np

# SpeechBrain's lazy-import shim installs an excepthook that itself fails on a missing optional dep
# (k2), which masks the real error on any uncaught exception. Restore the default so tracebacks are
# readable and the process exits cleanly.
sys.excepthook = sys.__excepthook__


CLIP_SECONDS = 3.0
SR = 16_000
CLIP_SAMPLES = int(CLIP_SECONDS * SR)   # fixed waveform length; Swift pads/crops to this
N_MELS = 80
N_FRAMES = 298                          # fbank frames for CLIP_SAMPLES @ 25ms/10ms; Swift pads/crops

# Export modes:
#   "waveform" — one model: raw audio -> embedding (needs STFT/fbank ops; fails on untested torch).
#   "features" — mean/var-norm + ECAPA-TDNN, input = 80-dim fbank [1,T,80] (Swift computes fbank).
#   "embedding"— ECAPA-TDNN only, input = normalized fbank (Swift computes fbank + sentence CMVN).


def load_ecapa(device):
    """Load the SpeechBrain ECAPA encoder (feature extractor + norm + embedding model)."""
    import torch  # noqa: F401
    try:
        from speechbrain.inference.speaker import EncoderClassifier
    except Exception:
        from speechbrain.pretrained import EncoderClassifier
    clf = EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir=os.path.expanduser("~/CommSight/spike-venv/ecapa"),
        run_opts={"device": device},
    )
    clf.eval()
    assert clf is not None, "ECAPA load failed"
    return clf


def build_wrapper(clf, mode):
    """A traceable module whose input depends on `mode` (see the mode table above)."""
    import torch
    assert mode in ("waveform", "features", "embedding"), f"bad mode {mode}"

    class ECAPA(torch.nn.Module):
        def __init__(self, encoder, mode):
            super().__init__()
            self.mode = mode
            self.compute_features = encoder.mods.compute_features
            self.mean_var_norm = encoder.mods.mean_var_norm
            self.embedding_model = encoder.mods.embedding_model

        def forward(self, x):
            lengths = torch.ones(x.shape[0], device=x.device)
            feats = self.compute_features(x) if self.mode == "waveform" else x
            if self.mode != "embedding":
                feats = self.mean_var_norm(feats, lengths)   # sentence mean/var norm
            emb = self.embedding_model(feats, lengths)       # [B, 1, 192]
            return emb.squeeze(1)                            # [B, 192] RAW (see note)
            # NOTE: we deliberately do NOT L2-normalize inside the model. ECAPA embeddings have
            # norm ~377, so the sum-of-squares (~1.4e5) OVERFLOWS fp16 (max 65504) → norm=inf →
            # emb/inf = 0 (a dead all-zero model). Cosine distance is scale-invariant, so Swift
            # L2-normalizes the raw embedding in Float precision instead.

    return ECAPA(clf, mode).eval()


def _example_input(mode):
    import torch
    if mode == "waveform":
        return torch.randn(1, CLIP_SAMPLES), "waveform", (1, CLIP_SAMPLES)
    return torch.randn(1, N_FRAMES, N_MELS), "features", (1, N_FRAMES, N_MELS)


def convert(wrapper, out_path, mode):
    """Trace + convert to a Core ML mlprogram for the given input mode."""
    import torch
    import coremltools as ct

    example, in_name, in_shape = _example_input(mode)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name=in_name, shape=in_shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        # FLOAT32: ECAPA's attentive statistical pooling accumulates sums-of-squares over time that
        # OVERFLOW fp16 (max 65504) → NaN/inf → an all-zero embedding. fp32 keeps it faithful
        # (verified cosine 1.0 vs torch). ~80 MB — trivial next to the Whisper CoreML bundle.
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = f"ECAPA-TDNN speaker embedding ({mode} input, RAW 192-dim; L2-norm in Swift)"
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    mlmodel.save(out_path)
    assert os.path.exists(out_path), f"save failed: {out_path}"
    return mlmodel


def cosine(a, b):
    a = np.asarray(a).ravel(); b = np.asarray(b).ravel()
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))


def validate(wrapper, mlmodel, mode, n_random=5):
    """Cosine-compare Core ML vs torch on random inputs; must be ~1.0 for a faithful export."""
    import torch
    worst = 1.0
    for i in range(n_random):
        example, in_name, in_shape = _example_input(mode)
        x = (np.random.randn(*in_shape).astype(np.float32) * 0.1)
        with torch.no_grad():
            ref = wrapper(torch.tensor(x)).cpu().numpy()
        got = mlmodel.predict({in_name: x})["embedding"]
        c = cosine(ref, got)
        worst = min(worst, c)
        print(f"  sample {i}: cosine(torch, coreml) = {c:.5f}")
    print(f"WORST cosine = {worst:.5f}  ({'OK' if worst > 0.99 else 'MISMATCH — investigate'})")
    return worst


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export ECAPA-TDNN to Core ML (Stage 5b)")
    ap.add_argument("--out", default=os.path.expanduser("~/CommSight/atc-coreml/ecapa/ECAPA.mlpackage"))
    # "waveform" is the BEST recipe under torch 2.7 (the int-cast crash was torch-2.13-specific):
    # the full STFT + fbank + norm + ECAPA converts, so the model takes RAW 16 kHz audio and Swift
    # needs no feature front-end at all (correct by construction). "embedding" is the fallback
    # (Swift computes fbank). fp32 is required either way — fp16 overflows the attentive-pooling
    # sums-of-squares → an all-zero model.
    ap.add_argument("--mode", default="waveform", choices=["waveform", "features", "embedding"])
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args(argv)
    print(f"loading ECAPA (device={args.device}, mode={args.mode})…")
    clf = load_ecapa(args.device)
    wrapper = build_wrapper(clf, args.mode)
    print(f"converting → {args.out}…")
    mlmodel = convert(wrapper, args.out, args.mode)
    print("validating (torch vs Core ML)…")
    worst = validate(wrapper, mlmodel, args.mode)
    print(f"DONE. {args.out}")
    return 0 if worst > 0.99 else 1


if __name__ == "__main__":
    raise SystemExit(main())
