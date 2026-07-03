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

The lv3 run was the only one launched with **gradient checkpointing**
(`run_finetune_largev3.sh`: "fine-tune large-v3 (grad-ckpt, bs8, 3ep)").
Whisper + HF gradient checkpointing is a known-broken combination in this
codebase — `train_distil_whisper.py` disables it with the comment "causes
backward through graph twice error with Whisper" — and large-v3 fine-tuning in
fp16 is additionally NaN-prone. A 97.8% CER means the model emitted
garbage/empty output: training-time weight destruction, not a data or eval
artifact. The turbo run in the same "big" pipeline also failed once
(`TURBO_TRAIN_FAILED`, OOM-class) and succeeded when re-run standalone without
grad-ckpt.

Noisy labels were ruled out directly: a 20-row random audit of the accepted
pseudo-labels found 0 empty / 0 missing / format-correct transcripts (~25-35%
contain local garbles — consensus-shared mishearings of fix names etc. — which
is consistent with a net-positive but improvable label source, and exactly what
the small/turbo results show).

## Consequences / current state

- **Pseudo-labeling works.** 3.5 h of accepted labels halved whisper-small's US
  error (63.9 → 32.2 norm). Scale is the bottleneck, not the method:
  medium-FT ≈ small-FT at this data size.
- **Checkpoint survival** (H100 volume is gone):
  - `whisper-small-us` → SAFE: HF `SingularityUS/ATC-whisper-small-us`, ships
    as app variant `small-v2` (CoreML on HF `atc-whisperkit/small-v2`).
  - `whisper-turbo-us` (best US model, 20.2% canon WER) → **LOST**. Only its
    gold hypotheses survive (`atc_training_data/gold_hyps/gold_hyps_turbo_ft.jsonl`).
    The app's `turbo` CoreML variant is still the OLD European fine-tune
    (M4 `~/atc-coreml/turbo` dated Jun 23, i.e. pre-US-training).
  - `whisper-medium-us` → LOST (scores survive).
- Training data survives locally: `C:\Users\bsusl\atc_training_data\` (16 GB —
  h100 + l4_1 + l4_2 manifests/segments/scores, 3,513 accepted rows rescued;
  the June-30 runs used a 5,410-clip merged manifest whose builder
  (`build_trainmanifest_v2.py`, gold-window-held-out) lived only on the H100
  and needs ~30 lines of recreation).

## Rules going forward

1. **Never enable gradient checkpointing for Whisper fine-tunes** in this repo.
2. Every scaled run repeats the sanity ladder (tiny overfit on gold; 2 h
   pseudo-label run ≥ stock) — it would have caught this in minutes.
3. **Push checkpoints + eval hyps to HF/local rsync the moment training ends.**
   The two best US models were lost to instance teardown hours after training.
4. Write results into `docs/RESULTS.md` in the same session they're produced.
