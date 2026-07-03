# Autopsy: the "~100% WER US fine-tune" failure (resolved 2026-07-03)

## Verdict

The catastrophic result was **specific to the whisper-large-v3 fine-tune run**,
not the data, not the eval, and not fine-tuning in general. The same 5,410-clip
pseudo-label manifest, same trainer, same session (2026-06-30, H100) produced:

| model | stock (norm WER, gold v0) | US fine-tuned | verdict |
|---|---|---|---|
| whisper-small | 63.9% | **32.2%** | worked (−31.7 pts) |
| whisper-medium | 35.8% | 32.7% | worked |
| whisper-large-v3-turbo | 34.9% | **28.9%** | worked (best US model) |
| whisper-large-v3 | 26.3% | **190.1% (CER 97.8%)** | destroyed |

Source: `atc_training_data/logs/pipeline*.log` (rescued from the H100 before
teardown; see scripts in `atc_training_data/scripts/run_finetune_*.sh`).

## Root cause (large-v3 run only)

Two compounding suspects, both specific to this run:

1. **Self-distillation loop**: large-v3 was consensus teacher A — the model
   that PRODUCED the pseudo-labels. Fine-tuning the teacher on its own labels
   is a known degenerate setup (the 2026-06-30 session's own conclusion:
   "fine-tuning the 1.55B teacher on its own labels is harmful; large-v3 base
   26.3% is the ceiling").
2. **Gradient checkpointing**: the lv3 run was the only one launched with
   grad-ckpt (`run_finetune_largev3.sh`), a known-broken combination with
   Whisper in this repo (`train_distil_whisper.py` disables it: "backward
   through graph twice"). Related fp16 gotcha (bit the turbo run first):
   large-v3/turbo ship fp16 weights → must load `torch_dtype=float32` or
   fp16-AMP dies with "Attempting to unscale FP16 gradients".

A 97.8% CER means garbage/empty output — training-time weight destruction,
not a data or eval artifact. Either suspect suffices; do not fine-tune the
consensus teacher on its own labels, and never grad-ckpt Whisper.

Noisy labels were ruled out directly: a 20-row random audit of the accepted
pseudo-labels found 0 empty / 0 missing / format-correct transcripts (~25-35%
contain local garbles — consensus-shared mishearings of fix names etc. — which
is consistent with a net-positive but improvable label source, and exactly what
the small/turbo results show).

## Consequences / current state

- **Pseudo-labeling works.** 3.5 h of accepted labels halved whisper-small's US
  error (63.9 → 32.2 norm). Scale is the bottleneck, not the method:
  medium-FT ≈ small-FT at this data size.
- **Checkpoint survival** (H100 volume is gone; local rescue copies exist):
  - `whisper-small-us` → SAFE twice over: HF `SingularityUS/ATC-whisper-small-us`
    (ships as app variant `small-v2`) + local `whisper-small-us.tar.gz`.
  - `whisper-turbo-us` (best US model, 20.2% canon WER) → SAFE locally:
    `C:\Users\bsusl\atc_training_data\whisper-turbo-us.tar.gz` (2.8 GB fp32,
    backed up right after training). NOT yet on HF and NOT yet converted —
    the app's `turbo` CoreML variant is still the OLD European fine-tune
    (M4 `~/atc-coreml/turbo` dated Jun 23). Next: verify vs its saved gold
    hyps, push to HF, convert, ship.
  - `whisper-medium-us` → lost (scores survive; ≈small-us anyway).
- Training data survives locally: `C:\Users\bsusl\atc_training_data\` —
  per-box trainset tarballs (Jun 29) + `backup_20260630\trainset_*_20260630.tar.gz`
  (the fuller snapshot: 7,309 accepted clips ≈ 15.4 h across h100/l4_1/l4_2,
  airport-prefixed clip names + relative-path `manifest_rel.jsonl`) +
  `backup_20260630_final\` (4.6 GB incl. ~19k consensus-REJECT segments —
  future SSL-pretraining corpus + reject-mining pool).

## Rules going forward

1. **Never enable gradient checkpointing for Whisper fine-tunes** in this repo.
2. Every scaled run repeats the sanity ladder (tiny overfit on gold; 2 h
   pseudo-label run ≥ stock) — it would have caught this in minutes.
3. **Push checkpoints + eval hyps to HF/local rsync the moment training ends.**
   The two best US models were lost to instance teardown hours after training.
4. Write results into `docs/RESULTS.md` in the same session they're produced.
