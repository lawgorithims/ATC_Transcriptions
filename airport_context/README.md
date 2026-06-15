# Airport Context Pipeline (`airport_context/`)

Automatically fetch and compress the highest-value aviation context for an
airport, and render a compact, **frequency-specific Whisper prompt** for a
speech-to-text call. This is a transcription-assistance system — not a
flight-planning or navigation product.

It is the auto-fetched successor to the hand-curated [`atc_context.py`](../atc_context.py)
+ [`airport_configs/*.json`](../airport_configs/): instead of maintaining JSON per
airport, it ingests real data (airports, runways, frequencies, navaids) into a
local database and builds the prompt from it, adding spoken-form generation,
ranking, candidate-callsign handling, and snapshot logging.

> The prompt should tell the transcription model what words are likely to occur
> on this airport frequency right now — not be a full airport briefing.

**No third-party dependencies** — Python 3.10+ standard library only
(`urllib`, `csv`, `sqlite3`, `math`).

## What it produces

The primary product is a structured **context snapshot**; the `prompt` string is
its final rendering. Request → response (MVP contract):

```jsonc
// request
{ "airport_code": "KMSP", "frequency_type": "tower",
  "prior_transcript": "Delta twelve thirty four, continue runway three zero left.",
  "candidate_callsigns": ["DAL1234", "SKW5670", "N345AB"] }

// response
{ "airport": "KMSP", "frequency_type": "tower",
  "prompt": "ATC aviation radio audio near KMSP Minneapolis. Frequency type: tower. ...",
  "prompt_word_count": 172,
  "context_snapshot": { "airport": {…}, "runways": [...], "facility_names": [...],
                        "fixes": [...], "candidate_callsigns": [...], "phrase_templates": [...],
                        "procedures": [], "weather_terms": [], "prior_transcript": [...] },
  "warnings": ["procedures_unavailable"] }
```

## Architecture

```
Offline (scheduled)                 Runtime (per prompt)
───────────────────                 ────────────────────
OurAirports CSVs                    request → resolve airport
   ↓ ingest                                 → fetch local context (runways/freqs/navaids)
SQLite DB  ──────────────────────►          → format candidate callsigns
(airports, runways,                         → rank · cap · dedupe
 frequencies, navaids,                      → render prompt (budgeted)
 procedures*, weather*,                      → log context_snapshot
 context_snapshots)                  return { prompt, context_snapshot }
                                    (*populated in later phases)
```

## Quick start

```bash
# 1. Build the database (downloads OurAirports CSVs, ~17 MB; US by default)
python -m airport_context.cli ingest                 # or: --country US,CA  /  --country ALL

# 2. Build a prompt
python -m airport_context.cli build --airport KMSP --frequency-type tower \
    --callsigns DAL1234,SKW5670,N345AB \
    --prior "Delta twelve thirty four, continue runway three zero left."

python -m airport_context.cli build --airport KMSP --frequency-type tower --json   # full snapshot
python -m airport_context.cli resolve --airport msp                                # identity only
```

Python API:

```python
from airport_context import build_context

result = build_context({
    "airport_code": "KMSP",
    "frequency_type": "tower",
    "candidate_callsigns": ["DAL1234", "N345AB"],
})
prompt = result["prompt"]            # feed to the transcription call
snapshot = result["context_snapshot"]
```

The `prompt` is model-agnostic: it is the same context string the local
fine-tuned Whisper accepts via `get_prompt_ids` (see
[`atc_transcriber.py`](../atc_transcriber.py)) and that an OpenAI transcription
call accepts as its `prompt`.

## Input contract

| Field | Required | Notes |
|-------|----------|-------|
| `airport_code` | yes | ICAO / FAA-LID / IATA; case- and space-insensitive (`"k m s p"` → `KMSP`) |
| `frequency_type` | no | `clearance·ground·tower·approach·departure·center·ctaf·unknown` (default `unknown`) |
| `prior_transcript` | no | Last 1–3 transmissions; trimmed to ≤150 words |
| `candidate_callsigns` | no | e.g. `["DAL1234","N345AB"]` |
| `max_prompt_words` | no | Default 600, clamped to 150–900 |
| `include_weather` | no | Reserved (weather is a later phase → `weather_unavailable` warning) |

Errors are returned, not raised: `airport_not_found`, `ambiguous_airport`
(with a `candidates` list), `invalid_request`, `database_empty`. Missing
optional data degrades gracefully via `warnings`.

## Data source

[OurAirports](https://ourairports.com/data/) — public-domain (CC0), global,
daily-updated CSVs covering airports, runways, frequencies, and navaids. Every
row is stamped with a `source_cycle` so a later reconciliation against the
authoritative **FAA NASR** subscription (per the spec) is mechanical. The
database and CSV cache live under the git-ignored `data/airport_context/`.

## Spoken-form rules

Generated once at ingestion (runways) or at runtime (callsigns, frequencies):

| Input | Spoken |
|-------|--------|
| Runway `30L` / `04` / `4` | `runway three zero left` / `runway zero four` / `runway four` |
| Frequency `120.95` | `one two zero point niner five` |
| Airline `DAL1234` | `Delta twelve thirty four` · `Delta one two three four` |
| Regional `SKW5670` | `SkyWest fifty six seventy` · `SkyWest five six seven zero` |
| Tail `N345AB` | `November three four five alpha bravo` · `five alpha bravo` |

Airline telephony names live in editable [`data/airlines.json`](data/airlines.json);
spoken airport-name overrides (e.g. `KJFK` → "Kennedy") in
[`data/airport_overrides.json`](data/airport_overrides.json).

## Database schema

`airports`, `runways`, `frequencies`, `navaids` (populated now);
`procedures`, `weather_snapshots` (created, populated in later phases);
`context_snapshots` (one row per build — input, snapshot, prompt, word count —
for debugging and evaluation); `meta` (source cycle, counts). See
[`db.py`](db.py).

## Build phases

- **Phase 1 + callsigns — done.** Resolver, ingestion, spoken forms, phrase
  dictionaries, ranking/caps/dedup, renderer, snapshot logging, candidate
  callsigns.
- **Next:** Phase 2 procedures (FAA d-TPP XML) · Phase 3 weather (AWC METAR) ·
  Phase 5 post-transcription normalization + evaluation.

The empty `procedures`/`weather_terms` snapshot fields and the
`procedures_unavailable` warning are deliberate placeholders for those phases.

## Wiring into the live pipeline

[`live.py`](live.py) provides `AirportModeContext`, an `ATCContext`-compatible
adapter (`build_prompt()` / `update(text)`) that drives the live pipeline's
Whisper prompt from this package. It is opt-in via `--airport`:

```bash
python live_atc_pipeline.py --stream-url https://d.liveatc.net/kdfw1_twr1_e \
    --airport KDFW --frequency-type tower --callsigns DAL1234,N345AB
```

Each transmission's rolling history is fed back as `prior_transcript`; the
rendered prompt is cached and only rebuilt when history changes. The adapter is
thread-safe (the pipeline transcribes on a worker thread, so the SQLite
connection uses `check_same_thread=False` plus a lock). An unknown/ambiguous
airport fails fast with a friendly message *before* the model loads. Without
`--airport`, the pipeline uses the hand-curated feed config exactly as before.

## Tests

```bash
python tests/test_airport_context.py      # stdlib unittest, in-memory fixture, no network
```
