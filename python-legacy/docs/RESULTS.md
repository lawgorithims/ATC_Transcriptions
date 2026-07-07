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
| medium (769M) | 35.8% | 32.7% | lost with H100 (≈small anyway) |
| turbo (809M) | 34.9% | **28.9%** | local `whisper-turbo-us.tar.gz` — NOT yet on HF/CoreML |
| large-v3 (1.5B) | 26.3% | 190.1% — see `AUTOPSY_us_finetune.md` | n/a |

Takeaways: pseudo-labeling works (small −31.7 pts from ~3.5 h of accepted
labels); parameter count is not the lever (medium-FT ≈ small-FT) — the lever
is base-encoder quality (turbo broke the 32% plateau) and DATA (a fuller
15.4 h snapshot exists in `backup_20260630\`; T2 target 100 h+). Known dead
end: beam search on Whisper for short noisy ATC clips (measured 48.9% vs
greedy 22.8% canon on small-us) — greedy + temperature fallback is optimal
for the Whisper path.

## Architecture bake-off — non-Whisper models on gold v0 (2026-07-04)

Zero-shot / cross-domain runs (NOT the fair fight — different training data;
the fair fight is the same-data fine-tune, queued):

| model | arch | params | canonWER | CSA | sub/INS/DEL |
|---|---|---|---|---|---|
| whisper_lv3_stock | AED (zero-shot) | 1.5B | 19.6% | 82.4% | 8.6 / **7.0** / 4.0 |
| whisper_turbo_us | AED (US FT) | 809M | 20.2% | 80.4% | 11.1 / 3.7 / 5.5 |
| whisper_small_us | AED (US FT) | 244M | 22.8% | 74.5% | 12.8 / 4.9 / 5.0 |
| parakeet_tdt06b_zs | transducer (zero-shot, int8) | 600M | 49.3% | 43.1% | 18.4 / 5.5 / **25.4** |
| w2v2_ls960_atc_eur | SSL+CTC (EUR-ATC FT) | 317M | 55.5% | 17.6% | 26.7 / 2.5 / **26.2** |
| w2v2_xlsr_atc_eur | SSL+CTC (EUR-ATC FT) | 300M | 74.0% | 0.0% | — |

**Zipformer fine-tune PoC (2026-07-05, M4/MPS, pure-PyTorch CTC — no k2):**
`zipctc_us_ft` = zipformer-medium-CR-CTC (66M, LibriSpeech) fine-tuned 8
effective epochs on the same 5,139-clip / 15.4h US pseudo-label set
(gold-window held out), greedy CTC, no augmentation, no LM:

| model | params | canonWER | CSA | falseCS |
|---|---|---|---|---|
| zipctc zero-shot | 66M | 71.1% | 13.7% | 9.8% |
| **zipctc US-FT** | 66M | **35.8%** | 43.1% | **43.1%** |
| whisper-small-us | 244M | 22.8% | 74.5% | 13.7% |

Read: the encoder adapts hard (−35 pts from 15.4 h) and trains fine on Apple
silicon, but at current data scale Whisper's 680k-h pretraining still wins
decisively, and naive CTC greedy is BAD on the safety metric (43% false
callsigns — mangled-but-extractable words). Conclusion: the transducer path's
case rests on (a) T2 data scale (100 h+), (b) decode-time hotword biasing
(which attacks exactly the falseCS failure), (c) a real icefall recipe
(ScaledAdam, SpecAugment, transducer head) on a GPU box. Decision deferred to
the T2 gate, per plan. Training-on-M4 recipe + gotchas: `zipctc.py` (session
scratchpad; k2 Swoosh shim must use F.softplus — logaddexp's MPS kernel emits
intermittent NaNs; Balancer/Whiten may stay enabled; bucket AUDIO not features).

What this establishes:
1. **Domain match dominates architecture.** wav2vec2-CTC fine-tuned on
   EUROPEAN ATC (16.9% WER at home on UWB-ATCC) collapses to 55-74% on US
   radio. Architecture arguments are second-order next to US training data.
2. **Failure modes are structural, as the literature says.** AED (Whisper)
   over-generates — insertions/hallucination (stock lv3 7.0% INS; US
   fine-tuning halves it). Transducer/CTC under-generate — they go quiet on
   hard audio (25%+ DEL, near-zero invention). For a safety display,
   "no transcript" beats a confident wrong one — but only once substitutions
   are fixed by domain training.
3. **Whisper's zero-shot robustness is real** (680k-h weak supervision): every
   non-Whisper model collapsed on US radio audio without US training.
4. Next: the fair fight — fine-tune Parakeet-TDT / Zipformer AND
   whisper-small on the SAME 15.4 h US set, score here incl. CSA with
   decode-time hotword biasing on the transducer arm.

## Error attribution + snap-layer simulation (2026-07-05, `dataset/error_analysis.py`)

Where the errors actually come from (gold v0, canonicalized):

| | whisper-small-us | zipctc-us-ft |
|---|---|---|
| callsign failures | 7 wrong-NUMBER, 0 wrong-airline, 6 missed (of 51) | 21 wrong-NUMBER, 1 wrong-airline, 7 missed |
| callsign-span token errors | 7% | 15% |
| bare-digit token errors | 8% | 17% |
| phonetic-alphabet errors | 22% | 26% |
| phraseology errors | 13% | 24% |
| "other" (filler/fix names/rare words) | **29%** | **54%** |

Findings: (1) both models get the AIRLINE WORD right and garble the DIGITS —
callsign failure is a digit-sequence problem; (2) whisper's WER is dominated
by non-safety-critical "other" words; the zipformer degrades everywhere but
especially general vocabulary (1/45th the pretraining).

**Snap-layer simulation** — deterministic post-ASR stage that snaps the
extracted callsign to the nearest entry in a live candidate list (proxy: the
50-callsign gold inventory ≈ an ADS-B in-range list), abstaining on ambiguity:

| model | CSA raw→snapped | falseCS raw→snapped | missed raw→snapped |
|---|---|---|---|
| whisper-small-us | 75% → 78% | 14% → **2%** | 12% → 20% |
| zipctc-us-ft | 43% → **71%** | 43% → **2%** | 14% → 27% |

A cheap deterministic layer nearly eliminates false callsigns for BOTH
architectures (wrong→abstain is the safe direction) and recovers +28 CSA for
the CTC model (digits are near-misses). Residual ~2% = snapped to a
wrong-but-real aircraft; the "missed" growth is the share only decode-time
biasing (or better acoustics) can recover. Caveats: assumes the true
callsign is in the list (ADS-B coverage), and real airspace adds distractors.

## CallsignSnap stage — IMPLEMENTED and measured (2026-07-05)

`callsign_snap.py` (production reference, 9/9 unit tests) + `dataset/snap_score.py`.
Two channels by design: TEXT rewrites the callsign span only on a confident
unique snap (unverified stays as heard — display honesty); ENTITY verdicts
gate aircraft attribution (unverified = abstain — safety). On gold v0 with
the session-inventory candidate list:

| model | canonWER | textCSA | textFalse | entityCSA | entityFalse | abstain |
|---|---|---|---|---|---|---|
| whisper-small-us | 22.8→22.7% | 74.5→78.4% | 13.7→9.8% | 78.4% | **2.0%** | 19.6% |
| whisper-turbo-us | 20.2→20.1% | 80.4→82.4% | 7.8→5.9% | 82.4% | **2.0%** | 15.7% |
| zipctc-us-ft | 35.8→35.2% | 43.1→**70.6%** | 43.1→15.7% | 70.6% | **2.0%** | 27.5% |

Every model's attribution channel lands at 2.0% false (1 clip of 51 —
snapped onto a wrong-but-real aircraft) with wrong assertions converted to
abstentions. Next: Swift port into the corrector pipeline
(`ADSBService` list + filed flight plan as candidates), behind a protocol so
decode-time biasing can replace it later.

## SlotSnap stage + provider chain (2026-07-06, `slot_snap.py` + `airport_data.py`)

Runway/frequency grounding via the provider chain (curated configs →
OurAirports internet fallback; 17/17 gold facilities resolved, ARTCCs get
empty-context no-ops). Full chain (CallsignSnap → SlotSnap) on gold v0:

| model | canonWER | CSA | falseCS | slot verdicts |
|---|---|---|---|---|
| whisper-small-us | 22.8→22.7% | 74.5→78.4% | 13.7→9.8% | 25 rwy-verified, 4 rwy-unverified, 3 freq-verified, 7 freq-invalid |
| zipctc-us-ft | 35.8→35.2% | 43.1→70.6% | 43.1→15.7% | 20 rwy-verified, 4 rwy-unverified, 2 freq-verified, 5 freq-invalid |

Key finding: **zero runway snaps fired** — gold's 5-6 wrong runways are
wrong-but-REAL designators at those airports (heard 22, truth 31; both
exist), which existence-grounding can verify but not fix. The fix needs
ACTIVITY context (runway encoded in the approach feed name, ATIS, recent-
transmission consistency) — queued. SlotSnap's measured v1 value = verdicts
(trust signals for the gate/UI + LLM veto) and typo-class protection at
arbitrary real-life airports (14/14 unit tests incl. suffix-safety and
anchor-guarded frequencies), not corrections on this gold set. 26 unit tests
green overall; see `docs/PIPELINE.md` for diagrams + stage policies.

## LLM correction tier measured on gold (2026-07-06, `dataset/llm_eval.py`)

Qwen2.5-0.5B-Instruct (fp32 — optimistic vs the on-device q4 GGUF) with the
world-model prompt, WORLD frame primed per clip from the airport ident via
the real provider chain, snap chain first, same-block conversation pairing
(readback slot fired on 32/102 clips), mirrored validator guardrails:

| arm | canonWER | CSA | falseCS | clips changed |
|---|---|---|---|---|
| snaps-only (deterministic) | **22.7%** | 78.4% | 9.8% | — |
| + LLM, world frame | 23.1% | 78.4% | 9.8% | 10 |
| + LLM, transcript-only | 23.1% | 78.4% | 9.8% | 12 |

**Verdict: at 0.5B the LLM tier is net-negative on WER (+0.4) and neutral on
the safety metrics** — the deterministic snaps already own callsign/slot
accuracy, and the residual error mass (unstructured "other" words) is beyond
a tiny model. The world frame does NOT fix that, but it visibly changes the
failure CLASS: minimal-arm edits invent facts ("ray"→"tower",
"cafe"→"anchorage", "follow company"→"follow crj"); world-arm edits are
tamer deletions/cosmetics. Grounding suppresses hallucination; capability is
the binding constraint.

**Byproduct worth more than the headline:** the benchmark caught the 0.5B
model flipping "left"→"right" AND the shipped validator accepting it
(direction words appear in the per-word phraseology vocabulary). Direction/
semantic words (left/right/center/climb/descend/N-S-E-W) are now protected
like digits, with designator-suffix equivalence ("two eight right" → "28R"
still allowed) — in the Swift validator and the harness (218 iOS tests
green). Footnote: the world-arm jsonl above predates the guard; 2 of its 13
edits would now be blocked, so the post-guard world score is ≥ the table.

Where this leaves the tier: keep it gated (the ConfidenceGate already limits
exposure) and treat 0.5B as a no-op-at-best; the world frame's real target
is the CASCADE second pass (a larger remote model with the same frame —
harness ready, endpoint pending) and Apple-FM on device. Re-benchmark per
model with `python -m dataset.llm_eval --arm world|minimal`.

## Red-hat security review + digit-lock (2026-07-07)

A 6-lens adversarial review (spoofed ADS-B, malicious remote endpoint,
poisoned airport data, prompt injection, DoS, trust boundaries) found 14
reachable defects, 3 critical, on the Build-37 correction surface. Two root
causes fixed: (1) CallsignSnap invented callsign digits from UNAUTHENTICATED
airplanes.live traffic — one spoofed ghost one digit off could rewrite the
pilot-visible callsign; (2) the LLM validator let a remote/LLM swap clearance
verbs (land↔hold) and spoken digit words (niner↔tree) past the numeral-only
guard.

The callsign fix disables digit-changing text rewrites entirely; measured
tradeoff on gold (two channels — `snap_score.py`):

| model | textCSA | textFalse | **entity-false** | abstain |
|---|---|---|---|---|
| small, pre-lock | 74.5→78.4% | 13.7→9.8% | 2.0% | 19.6% |
| small, **post-lock** | 74.5→74.5% | 13.7→13.7% | **0.0%** | 25.5% |
| turbo, post-lock | 80.4→80.4% | 7.8→7.8% | **0.0%** | 19.6% |

Reading: the digit-lock GIVES UP the small display-text improvement (3
digit-rewrites that raised textCSA — those cases now show the misheard digit
as heard, honestly) but the safety-relevant ATTRIBUTION channel ("which
aircraft") goes to **0.0% false** — better than before AND now spoof-proof:
uncertain callsigns abstain rather than snap to a single unauthenticated
source. The airline-word fix (safe: digits already match a live aircraft) is
retained. Refinement option (not yet built): permit a digit fix when a SECOND
signal corroborates it (filed callsign, or a prior verified_exact for the same
aircraft this session) — recovers the display win without trusting a lone
ghost.

## Labeler gate + adversarial review round (2026-07-06)

**pm-as-labeler-gate** (`dataset/label_gate.py`, wired into `pseudo_label`
behind `FilterThresholds.slot_gate`): grounds candidate pseudo-labels in the
feed airport's real runways/frequencies + the static ATC ontology.
Retro-measured over the full rescued corpus (7,309 accepted labels):
**7,102 pass (97.2%) · 82 flagged auto-fixable · 207 rejected (2.8%)** —
runway-not-at-airport 95, impossible frequency 106 (truncated "134 62" for
134.625-class mishears), impossible runway/heading 14. The measurement
itself debugged the stage across three rounds (372→311→207) by exposing
false-positive classes: airline flight numbers after facility words
("center american 1786" ≠ 178.6 MHz), GA tail numbers ("tower cessna
twelve sixty five"), and nav-band frequencies being flagged as impossible.

**Adversarial review** (41-agent workflow over all session code): 36
findings raised, 28 confirmed, all critical/major fixed same-day — headline
catches: unparseable runway designators (H1/N/S — ~12k in OurAirports)
entering the snap pool and DELETING runway numbers via snap-to-empty;
"runway 4 right traffic" inventing an L/R suffix; integer-MHz digit
collapse (120.0→"12") breaking the edit≤1 policy; he_ident read from the
wrong OurAirports CSV column in the Swift network fallback; offline mode
flooding the gate with vacuous "unverified callsign" signals. Deferred
with tasks: extract_callsign greedy digit-run, airport-change poller race.
Verification after fixes: 20/20 + 7/7 + 9/9 + 11/11 Python, 205 iOS tests
0 failures, gold replay end-to-end green.

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
