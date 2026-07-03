# US Gold Scoreboard

Gold set: `C:\Users\bsusl\atc_training_data\verification_sample\gold_testset.jsonl` (102 human-verified clips). canonWER is the operative metric (format-canonicalized both sides); CSA/falseCS measured on rows with an extractable reference callsign.

| model | n | normWER | canonWER | canonCER | CSA | falseCS | CS rows |
|---|---|---|---|---|---|---|---|
| small_v1 | 102 | 32.2% | **22.8%** | 18.8% | 74.5% | 13.7% | 51 |
| turbo_ft | 102 | 28.9% | **20.2%** | 16.8% | 80.4% | 7.8% | 51 |
| lv3_stock | 102 | 29.7% | **19.6%** | 16.0% | 82.4% | 11.8% | 51 |

## June-30 US fine-tune record (norm WER, from rescued H100 logs)

| model | stock | US fine-tuned (5,410 pseudo-label clips) | checkpoint |
|---|---|---|---|
| small (244M) | 63.9% | **32.2%** | HF `ATC-whisper-small-us` (ships as small-v2) |
| medium (769M) | 35.8% | 32.7% | lost with H100 |
| turbo (809M) | 34.9% | **28.9%** | **lost with H100** (hyps survive) |
| large-v3 (1.5B) | 26.3% | 190.1% — see `AUTOPSY_us_finetune.md` | n/a |

Takeaways: pseudo-labeling works (small −31.7 pts from 3.5 h of accepted
labels); at this data scale model size buys almost nothing (medium-FT ≈
small-FT) — data volume is the bottleneck, as planned (T2 = 100 h+).

## Reading this table (gold v0, 2026-07-03)

- These are the HONEST numbers on real US LiveATC audio. The repo's legacy
  validation split (~95% clean ATCoSIM studio audio) reports 7.83%/12.82% WER —
  ~3x optimistic. That split is retired as a quality claim; it remains useful
  only as a catastrophic-forgetting guard.
- Model identities: `small_v1` = whisper-small-us (ships as app `small-v2`);
  `turbo_ft` = whisper-turbo-us (June-30 US retrain — weights LOST with the
  H100, see AUTOPSY); `lv3_stock` = stock openai/whisper-large-v3. The app's
  current `turbo` CoreML variant is the older European fine-tune and has no
  gold score yet.
- **Stock large-v3 (19.6%, 1.5B) only barely beats the US-fine-tuned turbo
  (20.2%, 809M) trained on just 3.5 h of accepted pseudo-labels** — domain data
  closes a 7x size gap; more of it should invert the ordering.
- The shipped small model misses 1 in 4 callsigns and asserts a WRONG callsign
  on 13.7% of callsign-bearing transmissions (the safety-critical failure mode).
  Decode-time callsign biasing and US training data both attack this.
- Known v0 limitations: 102 clips (~2% WER resolution at best), no role/callsign
  tags in the gold rows yet (CSA reference extracted from ref text), falseCS
  undercounts inventions whose telephony name is outside the 60-airline map.
  Gold v1 (600-800 transmissions, tagged) fixes all three.

Reproduce: `python -m dataset.scoreboard --gold <gold_testset.jsonl> --hyps
name=<gold_hyps.jsonl> ... --out docs/RESULTS.md` (from `python-legacy/`).
