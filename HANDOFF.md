# Handoff: US ATC training-data collection — get it running on the H100

> For the next Claude Code session (running on the user's Mac, with SSH access to the
> GPU box). Read this top-to-bottom, then the approved plan in
> `~/.claude/plans/` if present. Branch: **`claude/whisper-atc-training-data-bv0ap2`**, draft **PR #4**.

## Goal / why

The fine-tuned Whisper ATC models were trained on European data (ATCO2 + ATCoSIM) and
the validation set is ~95% clean studio audio, so real US accuracy is poor and the
reported WER (~7.8%) is misleading. We built a pipeline to create **real US** training
data **without hand transcription** by pseudo-labeling live LiveATC audio with a
two-model consensus filter, plus controller-vs-pilot role attribution.

**The code is done and pushed. The remaining job is to RUN it on the H100, confirm
usable data is being saved to a persistent volume, then iterate (retrain → re-eval).**
The prior session ran in Anthropic's web sandbox, which has **no network route to the
H100** (no ssh, port 22 blocked), so it could only build/push code — it never started
collection. This session (on the user's Mac) **can** SSH in and operate end-to-end.

## The instance

- Scaleway **H100-1-80G**, Ubuntu Noble GPU OS, PAR2. `ssh root@51.159.136.218`
  (public DNS `62020040-d6be-4aeb-a5b0-6e3523ab497d.pub.instances.scw.cloud`).
- SSH key is on the user's Mac (`ipad-sim-key`, ed25519) — already used for their M4.
- 24 cores, 240 GB RAM, **2 block volumes** (use one for persistent data storage).

## What's already built (`python-legacy/dataset/` + `python-legacy/atc_diarize.py`)

Pipeline: **download/record → VAD segment → two-model consensus → pseudo-labels**, with
a streaming orchestrator and continuous loop.

| Module | Role |
|--------|------|
| `archive_downloader.py` | LiveATC archive blocks → disk (resumable). |
| `cf_session.py` | Playwright/Chromium to clear Cloudflare for archive mode. |
| `live_recorder.py` | **Record active feeds (Cloudflare-free)** — the default path. |
| `feed_prober.py` | Detect active feeds by probing streams for speech. |
| `speech_gate.py` | VAD speech-yield gate; skips silent blocks before the GPU. |
| `bulk_capture.py` | VAD-segment a block into per-transmission clips. |
| `scored_transcribe.py` | Whisper decode returning avg-logprob/no-speech/compression. |
| `pseudo_label.py` | Consensus + confidence gates → accept/reject + final label. |
| `emit_metadata.py` | Write `train_metadata`-format labels + `scores.jsonl` audit. |
| `run_pipeline.py` | Streaming orchestrator + continuous loop + `train_metadata.json` export. |
| `eval_set.py` | Reserve a strict, disjoint US eval set; score a model (WER/CER). |
| `monitor.py` | Health report: usable data per feed (accepted/hours/roles), reasons, storage. |
| `tts_synth.py` | OPTIONAL synthetic US phraseology (Phase 4). |
| `../atc_diarize.py` | Controller-vs-pilot role + callsign (content-based, reused by labels). |
| `config.yaml` | All settings: storage_root, models, feeds, thresholds, eval. |
| `launch.sh` | One-shot setup + continuous harvest. |

**Models / consensus:** teacher A = `openai/whisper-large-v3` (beam search + airport
prompt); partner B = fine-tuned `models/whisper-atc-turbo` (prompt-free). Accept a
segment when CER(A,B) ≤ 0.10 plus confidence/duration/degeneracy/no-speech gates;
eval uses strict CER ≤ 0.03. All normalized to the project's training format.

**Feeds (17 training across 12 facilities)** in `airport_configs/` + `config.yaml`:
KDFW (tower + 17C/18R approach), KJFK (3 tower + sector_9s), KBOS, KATL, KSFO,
KLAX (final), KEWR, PAED towers; Centers ZOA/ZAN/ZKC/ZFW. Eval feed = KDFW
`lone_star_approach_17l_final` (kept disjoint from training).

## DO THIS (in order)

1. **SSH in, set up, look at disks:**
   ```bash
   ssh root@51.159.136.218
   apt-get update && apt-get install -y git tmux ffmpeg
   cd ~/ATC_Transcriptions 2>/dev/null || git clone https://github.com/lawgorithims/ATC_Transcriptions.git ~/ATC_Transcriptions
   cd ~/ATC_Transcriptions && git checkout claude/whisper-atc-training-data-bv0ap2 && git pull
   lsblk            # identify the EMPTY block volume (e.g. /dev/sdb) — do NOT mkfs a volume with data
   ```
2. **Mount a block volume for persistent data and set `storage_root`:**
   ```bash
   # ONLY if the volume is empty:
   mkfs.ext4 /dev/sdb && mkdir -p /mnt/atc-data && mount /dev/sdb /mnt/atc-data
   # config.yaml already defaults storage_root: /mnt/atc-data — confirm it matches the mount.
   ```
3. **Get the honest US baseline (Phase 0)** — run at a different time than training so
   the eval set stays time-disjoint:
   ```bash
   cd python-legacy && python3 -m venv .venv && source .venv/bin/activate
   pip install -U pip && pip install -r requirements-live.txt && pip install webrtcvad jiwer
   python scripts/download_model.py    # fetch models/whisper-atc-turbo (partner B)
   python -m dataset.eval_set build --config dataset/config.yaml
   python -m dataset.eval_set score --config dataset/config.yaml --model models/whisper-atc-turbo
   ```
   Expect WER far worse than 7.8% (likely 20–40%+). That gap is the whole point.
4. **Start continuous collection (under tmux):**
   ```bash
   tmux new -s atc
   bash dataset/launch.sh
   ```
5. **Verify usable data is landing (second pane):**
   ```bash
   python -m dataset.monitor --config dataset/config.yaml --watch 30
   ```
   Healthy = ACCEPT counts climbing on busy feeds, accept rate ~20–40%,
   `train_metadata.json` growing on `/mnt/atc-data`.

## Known gotchas / next decisions

- **Feed stream hosts:** new feeds use `https://d.liveatc.net/<mount>`; capture auto-tries
  other edge servers. If the prober shows a known-live feed as inactive, find its real
  stream URL (the feed's `.pls` on liveatc.net) and pin it in the airport config.
- **Live recording only captures during traffic** — run during busy local hours; the
  prober/speech-gate skip idle feeds. Centers/coasts cover most hours.
- **Disk:** raw audio ~0.5 GB/feed-hour. Consider adding an auto-prune of raw blocks
  after they're segmented+labeled (keep clips + manifests) for long unattended runs.
- **Archive mode** (Cloudflare): `pip install playwright && playwright install chromium`,
  set `acquisition.mode: archive`, `cloudflare: true`, and a UTC window.
- **After enough data:** mix `{storage_root}/us_pseudo/train_metadata.json` into the
  existing ATCO2+ATCoSIM training (cap pseudo-labels ~30–50% per batch, keep ATCO2
  share high), re-fine-tune turbo, re-score on the US eval set, then iterate (round 2
  re-labels the same audio with the improved model as partner B).

## Licensing

LiveATC audio is for **local training only** — do not redistribute raw audio or a
derived audio dataset. Raw audio/segments stay on the instance (under `storage_root`);
only small manifests/transcripts are portable.
