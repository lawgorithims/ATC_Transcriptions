# OpenAI rescue-tier pilot — results & verdict (2026-07-07)

Third-voice experiment per the approved plan addendum: can `gpt-4o-mini-transcribe`
("voice C", judge-never-writer) convert `low_consensus` rejects into usable
training labels, and can it audit the accept lane for correlated-Whisper-wrong
labels? Both arms were run to their falsifiable gates in one day for ~$1.25.

## Phase 0 — model selection (kill-gate, full gold v0)

| model | canonWER on gold | verdict |
|---|---|---|
| whisper-large-v3 (teacher) | 19.6% | reference |
| **gpt-4o-mini-transcribe** | **28.2%** | **PASS (1.44× teacher) → voice C** |
| gpt-4o-transcribe (flagship) | 54.0% | KILLED — systemic truncation on hard radio |

## Phase 1 — rescue arm: **FAIL, arm killed**

Dry-run over all 2,357 banked `low_consensus` rejects on the M4
(`dataset/rescue.py run --dry-run`, $0.70):

- Pre-screen (banked metrics, free): 454 removed (363 no-speech, 58 logprob floor, 33 non-English).
- 1,903 judged by C → **103 rescued (5.4%)** at the 0.15 threshold.
- **Band gate: 6.7%** rescue rate in the CER(A,B) 0.30–0.50 band vs the **≥10%** pilot gate → fail.
- Yield if enabled: **11.6 minutes** of audio (~7% on top of the accept lane), 18% of it ≤4-word phatic filler; 19/103 are wins-by-default against a degenerate partner decode (repetition loop / truncation), not genuine 3-way votes.

Adversarial span-level verification (253-agent review: every rescued label
reviewed, every flag re-judged by two independent skeptics):

- **Rescued tier: 48/103 (47%) confirmed materially defective** — wrong callsign
  digits passing on boilerplate agreement, runway L/R flips (label "27R" where C
  hears "27L" twice), garbled frequency spans, truncated trailing readbacks.
- **Marginal tier (0.15–0.20): 61/84 (73%) defective** — the threshold cannot be
  loosened to pass the rate gate; that band is noise floor.

**Root cause**: utterance-level CER ≤ 0.15 cannot protect safety spans. On a
15-word transmission a wrong airline word or one flipped runway letter costs
~0.05–0.10 CER — the agreement test is dominated by phraseology boilerplate
exactly where it matters least. (The accept lane has the same geometry but a
partner-consensus + slot-gate stack in front of it; the rescue lane by
construction samples the cases where that stack already said no.)

**Decision**: `rescue.enabled` stays `false` permanently; the `run` subcommand is
retained only as the measurement harness that produced this result. No T1 A/B —
11.6 min of 47%-defective labels cannot move a 25h mix, so the A/B would burn a
training run to confirm arithmetic.

## Phase 3 — auditor arm: **KEEP (promoted)**

C re-decodes ACCEPTED labels; `consensus_cer(C, label) > 0.30` flags a suspect
(`dataset/rescue.py audit`):

- Worst decile of the accept lane (highest CER(A,B) first): **63/100 flagged**.
- Unbiased random sample: **30/100 flagged** → post-stratified ≈ **32% of the
  whole accept lane** has a third voice materially disagreeing.
- Flag quality is mixed by design (C truncates on hard radio), but confirmed
  catches include correlated-Whisper hallucinations ("no adverse road reports"),
  junk labels ("love you man"), and one safety-critical semantic flip: an
  accepted label reading "cleared to take off" where C hears "line up and wait".

**Next**: full-lane audit (all accepted rows) is running; at the T1 retrain
(+25h accepted) run the decisive A/B — accepted-only vs accepted-minus-flagged
— on gold canonWER + CSA. That directly tests the June "label noise is the
binding constraint" hypothesis for ~$0.50 of API spend per audit cycle.

## Phase 2 — blinded human spot-check (pending)

50-clip blind package (30 rescued + 20 accepted, tiers hidden):
`atc_training_data/rescue_spotcheck/review.html`. Calibrates auditor-flag
precision against a human pilot's ear. Evidence bundle for this whole pilot:
`atc_training_data/rescue_pilot/` (local-only per gold-data policy).

## Operational notes

- Key at `~/.openai_key` (untracked, both boxes); estimated-cost ledger with a
  $2/day cap across real+dry runs; idempotent resume (a re-run never re-pays
  for a banked verdict).
- The M4 accept gate is `thresholds.max_cer: 0.30` (number-canon, per
  config.yaml) — not the 0.10 code default. Accepted rows have median
  CER(A,B) 0.154, which is why the auditor arm has real surface to work on.
