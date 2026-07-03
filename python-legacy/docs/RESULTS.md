# US Gold Scoreboard

Gold set: `C:\Users\bsusl\atc_training_data\verification_sample\gold_testset.jsonl` (102 human-verified clips). canonWER is the operative metric (format-canonicalized both sides); CSA/falseCS measured on rows with an extractable reference callsign.

| model | n | normWER | canonWER | canonCER | CSA | falseCS | CS rows |
|---|---|---|---|---|---|---|---|
| small_v1 | 102 | 32.2% | **22.8%** | 18.8% | 74.5% | 13.7% | 51 |
| turbo_ft | 102 | 28.9% | **20.2%** | 16.8% | 80.4% | 7.8% | 51 |
| lv3_stock | 102 | 29.7% | **19.6%** | 16.0% | 82.4% | 11.8% | 51 |

## Reading this table (gold v0, 2026-07-03)

- These are the HONEST numbers on real US LiveATC audio. The repo's legacy
  validation split (~95% clean ATCoSIM studio audio) reports 7.83%/12.82% WER for
  the same turbo/small models — ~3x optimistic. That split is retired as a
  quality claim; it remains useful only as a catastrophic-forgetting guard.
- **Stock large-v3 (19.6%) beats the European-fine-tuned turbo (20.2%) on US
  audio.** The existing fine-tune contributes nothing stateside — the case for
  the US data engine in `dataset/`.
- The shipped small model misses 1 in 4 callsigns and asserts a WRONG callsign
  on 13.7% of callsign-bearing transmissions (the safety-critical failure mode).
  Decode-time callsign biasing and US training data both attack this.
- Known v0 limitations: 102 clips (~2% WER resolution at best), no role/callsign
  tags in the gold rows yet (CSA reference extracted from ref text), falseCS
  undercounts inventions whose telephony name is outside the 60-airline map.
  Gold v1 (600-800 transmissions, tagged) fixes all three.

Reproduce: `python -m dataset.scoreboard --gold <gold_testset.jsonl> --hyps
name=<gold_hyps.jsonl> ... --out docs/RESULTS.md` (from `python-legacy/`).
