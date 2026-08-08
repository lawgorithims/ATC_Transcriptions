# Plan: p(m) v1 — a phraseology-prior layer for whisper-small, integrated into the existing correction pipeline (handoff spec)

> **Audience:** a future Claude session executing this without prior context. Everything needed —
> file paths, APIs, schemas, commands, win conditions, gotchas — is in this document. Read top to bottom.

## Context — why this exists and what it must do

This repo (branch work goes to `claude/atc-radio-transcription-t3wigj`)
transcribes noisy VHF ATC radio with fine-tuned Whisper (Python `python-legacy/` + on-device iOS
`ios/` via WhisperKit/CoreML). Honest baselines on the human-verified US gold set
(`python-legacy/docs/RESULTS.md`, 102 clips): **whisper_small_us canonWER 22.8%, CSA 74.5%,
falseCS 13.7%** (falseCS = hypothesis asserts a callsign that CONTRADICTS the reference — the
safety-critical failure); turbo_ft 20.2%; stock lv3 19.6%.

The long-term architecture direction (see Appendix) treats transcription as Bayesian inference under a
**structured message prior p(m)**: ATC phraseology is a formal protocol (near-CFG slot structure
`[callsign][directive][value][unit]`) engineered as a noisy-channel error-correcting code ("niner",
"tree", phonetic alphabet, mandatory readback). **This plan builds p(m) v1 now** — a deterministic,
data-driven phraseology model (lexicon + weighted slot grammar + typed value ontology + acoustic
confusion model) that plugs into the **current whisper-small pipeline without retraining**, as:

1. a **post-decode corrector/rescorer** (Python + Swift, <1 ms, deterministic);
2. a new **ConfidenceGate signal** (phraseology violation → run the LLM; unresolvable safety slot → abstain flag);
3. **grounding + a veto for the existing LLM cleanup layer** (the user's explicit ask: augment the
   two-tier corrector — feed the LLM a structured parse/violation list, and reject LLM edits that
   violate the ontology);
4. *(optional, Python only)* **decode-time shallow fusion** via an HF `LogitsProcessor` inside the
   existing `generate()` call — the strongest "directly into whisper-small" form.

Everything is measured on the existing arch-agnostic scoreboard (`python-legacy/dataset/scoreboard.py`).

## What p(m) v1 is — three layers + a confusion model

**Layer 1 — Lexicon (terminals).** Controlled vocabulary with spoken variants: phonetic alphabet,
number-speak (niner/tree/fife, "point", "decimal"), command verbs, units, facility words, airline
telephony. Seed from existing assets: `ios/ATCTranscribe/Resources/knowledge/phraseology.json`
(phrases/spelling/phonetic/digits), `python-legacy/airport_context/phrases.py`,
`python-legacy/airport_context/airlines.py` (`telephony_map()`), digit maps in
`python-legacy/atc_normalize.py`. Dynamic terminals (runways, fixes, facility names, candidate
callsigns) come per-feed from `airport_configs/` / `airport_context` — NOT baked into the assets.

**Layer 2 — Weighted slot grammar (syntax).** Productions over canonicalized tokens:

```
transmission := [callsign] directive+ [courtesy/readback tail]
directive    := altitude | heading | speed | frequency | squawk | runway_op | approach | altimeter | direct | hold
altitude     := ("climb"|"descend"|"maintain") ["and maintain"] alt_value
alt_value    := NUM_thousands [NUM_hundreds]            # below FL180
              | "flight level" D D D                     # at/above
heading      := ("fly heading"|"turn left heading"|"turn right heading") D D D
frequency    := ("contact"|"monitor") FACILITY freq_value
runway_op    := "cleared to land"|"cleared for takeoff"|"line up and wait"|"hold short of" RWY|"cross" RWY|"taxi via" TWYS
```

Weights = production frequencies **per facility type** (clearance/ground/tower/approach/departure/
center/ctaf — the type is known per feed from config), fitted from the pseudo-label corpus. Unparsed
spans get a per-token open-vocabulary backoff penalty λ_oov — the grammar must be SOFT: non-standard
speech degrades gracefully, never force-fit.

**Layer 3 — Typed ontology (semantics + physical validity).** Per directive: value type, legal range,
quantization, rendering, and (later, on-device) an ADS-B plausibility hook. v1 entries:

```yaml
altitude:  {range_ft: [200, 60000], quantize: 100, forms: [thousands_hundreds, flight_level], fl_transition: 18000}
heading:   {range: [1, 360], digits: 3}
speed:     {range_kt: [90, 350], quantize: 5}
frequency: {range_mhz: [118.0, 136.975], spacing_khz: 25}   # US
squawk:    {digits: 4, digit_range: [0,7], special: [7500, 7600, 7700]}   # octal — an 8 or 9 is IMPOSSIBLE
runway:    {num: [1,36], suffix: [L, C, R], must_exist_in: airport_config.runways}
altimeter: {range_inhg: [28.00, 31.50]}
```

**Confusion model (the bridge to correction).** Weighted terminal-confusion pairs describing how the
AM channel + Whisper actually collapse words. Seed table (hand-written, ~40 entries) + weights mined
from **teacher-A vs partner-B consensus disagreements** in the pseudo-label pipeline (align texts
where `pseudo_label.evaluate_segment` recorded both, count substitutions of in-lexicon terms —
`scores.jsonl` has `text_a`/`text_b` for every segment). Examples:
`five↔niner, three↔tree, to↔two, for↔four, "flight lever"→"flight level", heading↔FL ambiguity for
"two four zero" (disambiguated by directive verb), single-digit swaps inside callsigns/squawks`.

## Deliverable 1 — data assets (`python-legacy/pm/data/`, mirrored into the iOS bundle)

Three versioned JSON files, authoritative sources **FAA JO 7110.65** and the **FAA Pilot/Controller
Glossary** (US-primary; ICAO 4444 only for cross-checks):

- `ontology.json` — the Layer-3 table above. Example entry:
  ```json
  {"squawk": {"slots": [{"name": "code", "type": "digits", "count": 4, "digit_range": [0, 7]}],
    "verbs": ["squawk"], "special_values": ["7500", "7600", "7700"]}}
  ```
- `grammar.json` — productions with per-facility weights:
  ```json
  {"altitude": {"patterns": ["(climb|descend|maintain)( and maintain)? {alt_value}"],
    "weights": {"approach": 0.21, "center": 0.28, "tower": 0.02, "ground": 0.0}}}
  ```
- `confusions.json` — `{"pairs": [{"a": "five", "b": "niner", "cost": 1.2}, {"a": "to", "b": "two", "cost": 0.4}, ...]}`

Plus `pm/fit_weights.py` — mines production weights and confusion counts from
`{storage_root}/us_pseudo/manifest.jsonl` + `scores.jsonl` (fields documented in
`dataset/emit_metadata.py:85-99`); ships with smoothing; hand-seeded values are the fallback when the
corpus files aren't reachable (they live on the training box, not in git).

## Deliverable 2 — Python package `python-legacy/pm/`

```
pm/__init__.py
pm/model.py       # loads the three JSON assets; PMContext dataclass
pm/parser.py      # parse(text, facility_type=None) -> Parse
pm/scorer.py      # score(parse, ctx) -> float  (log p(m))
pm/corrector.py   # apply(text, ctx) -> PMResult   ← the main entry point
pm/logits.py      # (M4, optional) HF LogitsProcessor for shallow fusion
pm/apply.py       # CLI: batch-apply to a hyps jsonl
pm/fit_weights.py # weight/confusion mining from pseudo-label corpus
pm/tests/         # unit tests + parity fixtures (JSON in/out pairs shared with Swift)
```

Key APIs (duck-typed to the repo's conventions; reuse, don't re-implement):

```python
@dataclass
class PMContext:
    facility_type: str | None          # from feed config (dataset/config.yaml / airport_configs/)
    runways: list[str]                 # from airport config
    fixes: list[str]
    candidate_callsigns: list[str]     # HONEST sources only: prompt/traffic context; NEVER gold refs

@dataclass
class PMResult:
    raw: str; corrected: str
    parse: list[dict]                  # typed directives: [{"type":"altitude","value":11000,...}]
    edits: list[dict]                  # {"from","to","reason","cost"} — every change justified by a confusion entry
    violations: list[str]              # ontology/grammar violations REMAINING after correction
    score_before: float; score_after: float
    abstain_slots: list[str]           # safety slots (callsign/runway/altitude) still invalid → flag, don't force
```

- `parser.parse` canonicalizes via `atc_normalize.normalize` (spoken→digits; tracked file), extracts
  the callsign span via `atc_diarize.extract_callsign`, then matches grammar productions over the
  canonical tokens. Keep raw↔canonical token alignment so edits render back into the raw-style text.
- `scorer.score`: `Σ log w(production | facility)` + `Σ log v(value | ontology)` + `λ_oov · |unparsed tokens|`.
- `corrector.apply` decision rule: enumerate candidate edit sets from `confusions.json` **within slots
  only**; accept the set maximizing `Δscore − Σ cost(edit)` iff `Δscore ≥ τ_edit + Σ cost`. Hard safety
  rules: every digit change must map to a confusion entry; callsign edits may only SNAP to a
  `candidate_callsigns` entry (edit distance ≤ 1 phoneme-token) or ABSTAIN — **never invent a novel
  callsign** (this is what attacks falseCS without creating it); an impossible value that can't be
  repaired (squawk with an 8) → `violations` + `abstain_slots`, output text unchanged for that slot.

CLI for eval (mirrors the scoreboard's hyps convention):

```bash
cd python-legacy
python -m pm.apply --hyps gold_hyps_small_v1.jsonl --out gold_hyps_small_pm.jsonl \
    --gold <gold_testset.jsonl>            # gold used ONLY for airport/feed → facility_type lookup
```

## Deliverable 3 — integration seams

**(a) Python live/pseudo-label path.** `pm.corrector.apply` runs AFTER
`atc_corrector.py:213 DeterministicCorrector` wherever that runs today (live pipeline and
`dataset/pseudo_label.py` final-label step). Bonus (cheap, do it): use `violations`/`abstain_slots`
as an extra pseudo-label REJECT gate — cleaner future training data.

**(b) Optional decode-time shallow fusion (M4, Python only).** `dataset/scored_transcribe.py`
uses HF `WhisperForConditionalGeneration.generate()`; add `logits_processor=[PMLogitsProcessor(ctx)]`
boosting grammar-legal continuations and candidate-callsign token sequences (spoken-form expansions).
Greedy-compatible (the repo's known-good decode is greedy + temperature fallback — beam is a measured
dead end, see RESULTS.md). WhisperKit exposes no logits hook, so on-device stays post-decode.

**(c) iOS port (Swift mirror).** New `ios/ATCTranscribe/Core/PhraseologyPrior.swift`
(NAME MATTERS: `Core/PhraseologyCorrector.swift` ALREADY EXISTS — a small regex multi-word mis-hear
fixer that runs before `DeterministicCorrector`; keep it, do not collide or replace). The prior is NOT
a `Corrector` (it returns structure, not just text) — a separate type invoked in
`Engine/LivePipeline.swift:process` after the inline corrector (~line 227 region), emitting
`CorrectionEdit`s with `backend: "pm"` for UI transparency:

- **Gate:** extend `Core/ConfidenceGate.swift:assess` with signal 5 — `pmViolations` non-empty or
  `Δscore` large-negative → reason "phraseology violation"; `abstain_slots` non-empty → always refine
  and surface the flag. Thresholds live in the existing `Thresholds.forSensitivity` table.
- **LLM grounding:** `ATCCorrectionPrompt.chatMLPrompt` gains a compact block —
  `PARSE: …` / `VIOLATIONS: …` / `CANDIDATES: from=…, to=…` (keep ≤ ~120 tokens; the ChatML prompt has
  its own budget separate from Whisper's 220-token cap).
- **Validator veto (the augmentation of the cleanup layer):** `CorrectionValidator` additionally
  re-parses the LLM's output with the prior and REJECTS any edit that introduces an ontology violation
  or lowers the pm score — composing with (not replacing) its existing rules (numbers preserved,
  `to` must be known/near-miss, traffic-label denylist).
- **Assets:** bundle the same three JSONs under `Resources/knowledge/` (prefix `pm_`), loaded like
  `ATCKnowledgeBase` loads its corpus. Parity between Python and Swift is verified with shared JSON
  fixtures via the existing `ios/Tools/parity_check.py` pattern + a `PhraseologyPriorTests.swift`
  mirroring `pm/tests/` (see `PhraseologyCorrectorTests.swift` for the house style).

## Milestones (execution order, each independently verifiable)

- **M0 — eval unblock (30 min).** `dataset/scoreboard.py:47` imports gitignored `atc_normalization.py`
  (basic normalizer, lives only on the user's machines). Add a try/except fallback to the equivalent in
  `dataset/normalize.py` (which already has `_resolve_canonical` fallback logic) so a fresh checkout can
  score. Do not delete the direct import path — prefer the local file when present.
- **M1 — assets v1 (2–3 days).** Hand-author the three JSONs (sources above; ~10 directive types,
  ~40 confusion pairs). Cross-check every phrase against existing `phraseology.json`/`phrases.py`.
- **M2 — `pm` package + tests (3–5 days).** Parser/scorer/corrector + CLI + unit tests incl. the
  canonical hard cases: "two four zero" heading-vs-FL by verb; squawk-with-8 → abstain; callsign snap
  vs abstain; OOV chatter passes through untouched (coverage metric in `PMResult.parse`).
- **M3 — gold eval (1 day, needs user's machine or gold assets).** Gold set + clips are NOT in the repo
  (local: `C:\Users\bsusl\atc_training_data\verification_sample\gold_testset.jsonl`). Either the user
  runs the commands, or regenerate hyps live:
  `python -m dataset.scoreboard --gold <gold> --clips-root <root> --model <ATC-whisper-small-us HF id or local path> --name small_v1` →
  then `pm.apply` on those hyps → score both rows side by side, append to `docs/RESULTS.md` via `--out`.
  **Win conditions (vs small_v1 = 22.8% canonWER / 74.5% CSA / 13.7% falseCS): falseCS ≤ 8%, CSA ≥ 78%,
  canonWER ≤ 22.8% (hard no-regression bar; expect 1–2 pts improvement from number/format repairs).**
  Also apply to turbo hyps (20.2%) — the layer must help both. Diagnose per-edit: dump every pm edit
  that flipped a token vs the reference to catch harmful rules.
- **M4 — optional shallow fusion (3–5 days, only if M3 leaves deletion/substitution headroom).**
  `pm/logits.py` + a `ScoredTranscriber` flag; re-score. Keep OFF by default until it wins.
- **M5 — Swift port + LLM augmentation (1–2 weeks).** As in Deliverable 3(c); parity fixtures green;
  extend `ATCKitProbe/main.swift`'s gate-calibration dump with the new signal to re-seed
  `Thresholds` (the probe's existing `ATC_BB1` callsign-bias check is the template for an on-device
  "pm never invents a callsign" regression test).
- **M6 — ship + document.** RESULTS.md row(s), README notes in `python-legacy/` and `ios/`, commit and
  push per repo git rules (branch above; draft PR).

## Verification

- Unit: `cd python-legacy && python -m pytest pm/tests/` (new); existing tests must stay green.
- Metric: the scoreboard rows in M3 are the acceptance test; every claim cites the table.
- Parity: `python ios/Tools/parity_check.py` extended with pm fixtures; `PhraseologyPriorTests` in Xcode.
- Safety regression: a fixture set proving (a) pm never outputs a callsign absent from
  `candidate_callsigns` unless it was already in the raw text, (b) squawk/heading/altitude repairs
  only ever move WITHIN legal ranges, (c) OOV/non-standard transmissions pass through byte-identical.

## Gotchas for the future session (hard-won context — read before coding)

1. **`atc_normalization.py` is gitignored** (basic normalizer); `scoreboard.py` imports it at module
   top. M0 fixes this. Same for the whole training toolchain (`train_distil_whisper.py` etc.) — on the
   user's boxes only.
2. **Gold set + clip audio are not in git** — coordinate with the user for M3; do not fabricate hyps.
3. **`PhraseologyCorrector.swift` already exists** and is something else (regex mis-hear fixer,
   pre-DeterministicCorrector). New type = `PhraseologyPrior`. Python-side vocab snapping =
   `atc_corrector.py:213 DeterministicCorrector`.
4. **Honest-eval rule:** `candidate_callsigns` for scored rows may come from feed/airport config or
   live traffic context only — never from gold references (that's the separate oracle-ceiling
   experiment in the long-term plan).
5. **falseCS is the metric that matters most** (safety). pm's callsign policy is snap-or-abstain;
   inventing a callsign to raise CSA is exactly the failure mode this repo is fighting.
6. **Greedy decode is load-bearing** — beam search measurably hurts on short noisy ATC clips
   (RESULTS.md); the shallow-fusion processor must work under greedy + temperature fallback.
7. iOS `Corrector` protocol is `correct(_:history:) async -> Correction`; the prior intentionally does
   NOT conform (different output shape). Emit `CorrectionEdit(backend: "pm")` for the UI.
8. `ASRConfidence.noSpeechProb` is stubbed to 0 in this WhisperKit build; `.unknown == (0,0)` reads as
   confident. pm's violation signal is therefore genuinely additive to the gate, not redundant.
9. Whisper prompt cap is 220 tokens (`ATCTranscriber.maxPromptTokens`) — pm is post-decode and costs
   no prompt budget; the LLM ChatML block is where the parse goes.
10. Keep pm pure/deterministic (no network, no ML deps) so it runs identically in Python, Swift, and
    inside the pseudo-label loop; assets are the single source of truth, fixtures enforce parity.

## Appendix — where this fits the long-term architecture

p(m) v1 is the first shippable component of a larger analysis-by-synthesis inverse-channel program
(designed in the same session that produced this plan): transcription as inference under
`p(x|m,θ_channel)·p(m|grammar, ADS-B, readback)`, with a differentiable VHF-AM channel model,
DDSP voice synthesizer, readback-pair joint decoding (the built-in error-correcting code), mono
co-channel dual-source separation, and self-supervised training on unlabeled radio. The grammar/
ontology/confusion assets built here ARE that system's message prior; the readback decoder (Stage A
there) consumes this package's `parse` output to align payload slots across controller/pilot pairs.
Patent-relevant novelty lives in that combination; p(m) v1 alone is solid engineering, not the claim.
