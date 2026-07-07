# US ATC training-data pipeline (`dataset/`)

Create meaningful, **US-representative** labeled training data for the ATC Whisper
models **without hand transcription**, by pseudo-labeling real LiveATC audio with a
two-model consensus filter (noisy-student self-training). Also attributes each
transmission to a **role (controller vs pilot)**.

See the full design in `../../../.claude/plans/` (the approved plan) — this README is
the operator's quick start.

## ⚠️ Licensing — local use only

LiveATC restricts redistribution. Audio downloaded by this pipeline is for **local
model-training use only**. Do **not** publish or redistribute the raw audio or a
derived audio dataset. Raw audio and segments are written under `data/` (gitignored)
and must never be committed. Only small derived manifests/transcripts are portable —
keep them private (e.g. a private S3 bucket).

## Pipeline

```
archive_downloader  ->  bulk_capture  ->  scored_transcribe + pseudo_label  ->  emit_metadata
   (download blocks)    (VAD segment)      (two-model consensus + filters)       (train metadata)
                         run_pipeline.py orchestrates all of the above, streaming
```

| Module | Role |
|--------|------|
| `feed_prober.py` | **Find active feeds now** by briefly probing streams for speech (no scraping/Cloudflare). |
| `live_recorder.py` | **Record active feeds (Cloudflare-free)** in 30-min chunks; speech-gated. Primary acquisition. |
| `archive_downloader.py` | Download LiveATC 30-min archive blocks to disk (resumable, idempotent). |
| `cf_session.py` | Drive Chromium (Playwright) to clear **Cloudflare** for archive downloads. |
| `speech_gate.py` | Cheap VAD pass to skip silent blocks before the GPU. |
| `bulk_capture.py` | VAD-segment a block into per-transmission 16 kHz WAV clips. |
| `scored_transcribe.py` | Whisper decode that also returns avg-logprob / no-speech / compression. |
| `pseudo_label.py` | Two-model consensus + confidence gates → keep/reject + final label. |
| `emit_metadata.py` | Write `manifest.jsonl` + `transcripts/` + `scores.jsonl`; convert to `train_metadata.json`. |
| `run_pipeline.py` | Streaming orchestrator (download in background, label as blocks land). |
| `eval_set.py` | Reserve a strict, **disjoint** US eval set; score a model (corpus WER/CER). |
| `monitor.py` | Health report: usable data per feed (accepted/hours/roles), reject reasons, storage. |
| `tts_synth.py` | OPTIONAL: synthetic US phraseology + radio degradation (Phase 4). |
| `../atc_diarize.py` | Role attribution (controller vs pilot) + callsign, content-based. |

## Gold evaluation set (human-verified)

The consensus eval set above is model-biased (see Notes). The **gold set** is the
unbiased standing eval: real collector segments, hand-verified by a human against the
audio. Every pipeline stage is gated on not regressing gold canonWER
(see [`../docs/RESULTS.md`](../docs/RESULTS.md) and [`../docs/PIPELINE.md`](../docs/PIPELINE.md)).

| Tool | Role |
|--------|------|
| `gold_builder.py` | `build`: sample a review batch from scored segments regardless of accept/reject verdict (only no-speech and out-of-duration segments are pre-filtered), so gold is not limited to what the models already agree on; renders `review.html`. `ingest`: turn exported corrections into gold rows. Source blocks are appended to `excluded_blocks_gold.txt` so gold can never leak into training. |
| `scoreboard.py` | The standing scoreboard: canonWER / CSA / falseCS per model vs gold. |
| `error_analysis.py` | Error attribution: where models fail on gold, what a post-ASR layer could fix. |
| `slot_metrics.py`, `snap_score.py`, `slot_snap_score.py` | Safety-slot accuracy + snap-stage (CallsignSnap/SlotSnap) scoring on gold. |
| `llm_eval.py` | Measures the LLM correction tier's effect on gold. |

Workflow — build on the collector box, review in any browser, ingest locally:

```bash
python -m dataset.gold_builder build --storage-root ~/atc-data --out ~/gold_v1_batch1 --n 150
# open <out>/review.html: verify each clip (fix text, paint roles/unclear spans), Export
python -m dataset.gold_builder ingest --corrections corrections_v3.json \
    --candidates <out>/candidates.json --out gold_testset_v1.jsonl \
    --merge verification_sample/gold_testset.jsonl   # carry the previous gold set (v0) forward
```

The review page autosaves to browser localStorage; **Export** downloads a
corrections JSON checkpoint (the page always names it `corrections_v1.json` —
rename to `corrections_vN.json` per checkpoint yourself). Each export is a full
snapshot of the review session, so a later export **supersedes** earlier ones —
always ingest from the latest, never merge exports. Only `good`/`corrected`
rows become gold (`bad`/`unreviewed` are skipped), so a mid-review checkpoint
ingests cleanly.

### ⚠️ Gold data is local-only (same licensing rule as the audio)

Corrections exports, `candidates.json`, and ingested `gold_testset_*.jsonl` all
contain LiveATC-derived transcripts — per the licensing note at the top they are
**never committed** (the repo `.gitignore` blocks them). The tooling is tracked;
the data's canonical home is the local training-data store (`atc_training_data/`).

**Status (2026-07-07):**

- **Gold v0** — 102 verified clips
  (`atc_training_data/verification_sample/gold_testset.jsonl`); the set behind the
  standing scoreboard in `docs/RESULTS.md`.
- **Gold v1 batch 1** — 150 candidates built 2026-07-06 into
  `atc_training_data/gold_v1_batch1/` (clips + `candidates.json` + `review.html`).
  Review in progress: 32/150 verified (8 good, 17 corrected, 7 unusable — status `bad`); latest
  checkpoint `corrections_v3.json`. Ingested as
  `atc_training_data/gold_testset_v1.jsonl` = v0's 102 rows + 25 new verified
  (127 total). Unlike v0, v1 rows carry per-speaker `turns`, role/callsign tags,
  and `[unclear]`→`<unk>` spans, which unlock CSA on verified tags and the
  Phase-5 role metrics. Target (per `docs/RESULTS.md`): 600–800 tagged
  transmissions.

## Start collecting ASAP (one command)

On the GPU box, inside `tmux`:

```bash
cd ATC_Transcriptions/python-legacy
bash dataset/launch.sh      # installs deps + model, then loops forever:
                            # probe feeds -> record active -> segment -> consensus -> label
```

`launch.sh` runs the pipeline with `acquisition.loop: true`, so the models load once
and it keeps cycling the configured feeds, recording only the ones that are active
right now (push-to-talk feeds are silent without traffic). Check which feeds are live
before/while running:

```bash
python -m dataset.feed_prober --feed-config airport_configs/kdfw.json --seconds 90
python -m dataset.feed_prober --feed-config airport_configs/kjfk.json --seconds 90
```

Add more airports by dropping a config in `airport_configs/` (real LiveATC mounts) and
listing its feeds in `config.yaml`; the prober/speech-gate will ignore any that are
dead or silent.

## Persistent storage + verifying usable data

**Save to a block volume, not the ephemeral root disk.** Set `storage_root` in
`config.yaml` to a mounted volume so the data (raw audio, segments, pseudo-labels,
`train_metadata.json`) survives instance teardown:

```bash
lsblk                                   # find your block device, e.g. /dev/sdb
mkfs.ext4 /dev/sdb                       # ONE TIME (skip if already formatted)
mkdir -p /mnt/atc-data && mount /dev/sdb /mnt/atc-data
# set  storage_root: /mnt/atc-data  in dataset/config.yaml
```
The pipeline checks the storage root is writable on startup and **warns** if it's on
the ephemeral root disk. After every harvest pass it refreshes
`{storage_root}/us_pseudo/train_metadata.json` so training-ready data is always current.

**Confirm each feed is producing usable data** with the monitor:

```bash
python -m dataset.monitor --config dataset/config.yaml            # one-shot
python -m dataset.monitor --config dataset/config.yaml --watch 30 # live dashboard
```
It shows accepted examples + audio hours + controller/pilot mix **per feed**, the
global accept rate and reject-reason breakdown, free disk, and flags any configured
feed that's recording but yielding nothing (tune thresholds) or not active at all.

## Quick start (manual)

```bash
cd python-legacy
pip install -r requirements-live.txt   # torch, transformers, librosa, soundfile, pyyaml ...
pip install webrtcvad jiwer            # VAD + WER
# ffmpeg on PATH required for live recording

# 0) Establish the honest US baseline (the number that actually matters)
python -m dataset.eval_set build  --config dataset/config.yaml
python -m dataset.eval_set score  --config dataset/config.yaml --model models/whisper-atc-turbo

# 1+2) Harvest + pseudo-label training data (streamed)
python -m dataset.run_pipeline --config dataset/config.yaml

# Inspect why segments were kept/rejected (tune thresholds here)
python -m dataset.run_pipeline --config dataset/config.yaml --summary

# 3) Convert accepted labels to the training format
python -c "from dataset.emit_metadata import to_train_metadata; \
print(to_train_metadata('data/us_pseudo/manifest.jsonl', 'data/us_pseudo/train_metadata.json'), 'examples')"
```

Then mix `data/us_pseudo/train_metadata.json` into the existing
`(ATCO2 + ATCoSIM)` training data (cap pseudo-labels at ~30–50% of each batch; keep
the ATCO2 real-VHF share high) and re-fine-tune with the existing training script.
Re-score on the US eval set; iterate (round 2 re-labels the same audio with the
improved model as partner B).

## Acquisition: live (default) vs archive

LiveATC's archive **website is behind Cloudflare**, and each 30-min block has no
guarantee of speech (it can be silent radio). Two paths, both feeding the same
segment → consensus → label stages:

- **`mode: live` (recommended, Cloudflare-free).** Records currently-active feeds off
  the Icecast edge servers (the existing ffmpeg path), in 30-min chunks, keeping only
  chunks with real speech (`min_block_speech_s`). Run during busy local hours under
  `tmux`/cron. Cross-check what's live now at **skylistening.com/liveatc** and pick
  busy towers/approaches. Needs `ffmpeg` on PATH.
- **`mode: archive` (historical / "interesting" recordings).** Pulls 30-min blocks from
  the archive over a UTC window. Set `cloudflare: true` to clear the challenge via a
  headless Chromium (`pip install playwright && playwright install chromium`). More
  fragile; use for targeted pulls. If the first blocks all come back `404`, paste me a
  real archive mp3 URL and I'll fix the `template`.

Either way the **speech gate** (`speech_gate.py`) drops near-silent blocks before the
GPU, so dead air never costs transcription time.

## Configuration

Everything is driven by `config.yaml`: acquisition mode + window/feeds, model paths,
acceptance thresholds, and a separate **eval** window kept disjoint from training.
Times are UTC; archive windows must fall within LiveATC's ~30-day retention.

## Notes

- Transcripts are normalized (lowercase, no punctuation, no articles) to match the
  project's training format. `normalize.py` prefers the canonical (local-only)
  `atc_normalization` when present and otherwise uses an equivalent fallback.
- The consensus eval set is **model-biased** — use its WER as a *relative* before/after
  signal, not an absolute. Swap in a hand-labeled or LDC ATCC eval for an unbiased number.
- Role tags can be embedded for a future "emit-the-speaker" experiment via
  `to_train_metadata(..., tagged_roles=True)` (writes a separate `*.role.txt` variant).
```
