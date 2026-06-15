# Phase 2 — Terminal Procedures (FAA d-TPP)

Phase 2 teaches the airport-context pipeline about **terminal procedures** —
instrument approaches, departures (SIDs), arrivals (STARs), and charted visual
approaches. These are the named procedures controllers and pilots say on the
radio ("cleared *ILS or localizer runway three zero left*", "fly the *Gopher One
arrival*", "*Minneapolis Nine departure*"), so seeding them into the Whisper
prompt biases transcription toward the exact phrases that occur on an
approach/departure/clearance frequency.

It adds two new modules — [`procedures.py`](procedures.py) (parse + speak) and
[`ingest_dtpp.py`](ingest_dtpp.py) (download + load) — plus database queries and
frequency-type-aware selection in the builder. One ingest of the current FAA
cycle yields **≈21,400 procedures across ≈3,200 U.S. airports**, with **zero new
third-party dependencies** (stdlib `urllib`, `xml.etree`, `sqlite3`, `re`).

---

## 1. Where it fits

```
Offline (run on the 28-day cycle)              Runtime (per prompt)
─────────────────────────────────             ────────────────────
FAA d-TPP metafile (XML, ~15 MB)               build({airport_code, frequency_type})
        │ ingest_dtpp.run_ingest                       │
        │  • resolve cycle (YYNN)                       │ db.count_procedures > 0 ?
        │  • download (atomic)                          │ db.get_procedures(types)
        │  • iterparse + link to airports               │ _select_procedures()  ← freq-aware,
        │  • normalize type + spoken name               │     round-robin, de-duped
        ▼                                                ▼
   procedures table  ───────────────────────►  "Likely procedures and fixes: …"
   (airport_id, type, name, spoken,                 in the rendered prompt
    runway_ident, chart_code, pdf, …)          + structured context_snapshot["procedures"]
```

The renderer already had a combined **"procedures and fixes"** section from
Phase 1; Phase 2 simply populates it. When d-TPP has not been ingested, the build
still succeeds and emits a `procedures_unavailable` warning.

---

## 2. The data source: FAA d-TPP

The FAA publishes the **digital Terminal Procedures Publication (d-TPP)** once per
28-day [AIRAC](https://en.wikipedia.org/wiki/Aeronautical_Information_Publication#AIRAC)
cycle. Alongside the PDF plates it ships a single **metafile** that indexes every
chart for every U.S. airport:

```
https://aeronav.faa.gov/d-tpp/<CYCLE>/xml_data/d-TPP_Metafile.xml
```

* **Cycle id** is `YYNN` — two-digit year + cycle number 01–13. e.g. `2606` =
  2026, cycle 6, effective 2026-06-11 → 2026-07-09.
* The metafile is **~15 MB of XML**. We parse only the procedure *names and
  metadata*, never the plates.

### XML shape

```xml
<digital_tpp Cycle="2606" from_edate="0901Z  06/11/26" to_edate="0901Z  07/09/26">
  <state_code ID="MN" ...>
    <city_name ID="..." ...>
      <airport_name ID="..." apt_ident="MSP" icao_ident="KMSP" military="N">
        <record>
          <chart_code>IAP</chart_code>
          <chart_name>ILS OR LOC RWY 30L</chart_name>
          <pdf_name>00264IL30L.PDF</pdf_name>
          <amdtdate>...</amdtdate>
        </record>
        ...
      </airport_name>
    </city_name>
  </state_code>
</digital_tpp>
```

We read `icao_ident`/`apt_ident` on `<airport_name>` (to link to our airports
table) and `chart_code` / `chart_name` / `pdf_name` / `amdtdate` on each
`<record>`.

### Chart codes (counts from cycle 2606)

| `chart_code` | meaning | count | normalized type | in prompt? |
|---|---|--:|---|:--:|
| `IAP` | instrument approach (incl. charted visuals) | 11,180 | `IAP` / `CVFP` | ✅ |
| `MIN` | takeoff / alternate minima, DVA, radar minima | 5,371 | `TAKEOFF_MINIMA` / `ALTERNATE_MINIMA` / *(skip)* | ❌ |
| `DP` | departure procedure (SID) | 2,989 | `DP` | ✅ |
| `STR` | standard terminal arrival (STAR) | 2,883 | `STAR` | ✅ |
| `APD` | airport diagram | 905 | `APD` | ❌ |
| `HOT` | hot spots | 291 | *(skip)* | ❌ |
| `ODP` | obstacle departure procedure | 287 | `DP` | ✅ |
| `LAH` | land-and-hold-short | 88 | *(skip)* | ❌ |
| `DAU` | misc | 12 | *(skip)* | ❌ |

Stored types: `IAP`, `DP`, `STAR`, `CVFP`, `APD`, `TAKEOFF_MINIMA`,
`ALTERNATE_MINIMA` (`_KEEP_TYPES`). Only **`IAP`, `DP`, `STAR`, `CVFP`**
(`procedures.PROMPT_TYPES`) are ever injected into a prompt; `APD`/minima are
stored for completeness, and `HOT`/`LAH`/`DAU`/continuation pages/AAUP pages are
dropped entirely.

---

## 3. The `procedures` database table

Created in [`db.py`](db.py) (Phase 1 schema, populated in Phase 2):

| column | notes |
|---|---|
| `id` | PK |
| `airport_id` | FK → `airports.id` |
| `procedure_type` | normalized: `IAP` / `DP` / `STAR` / `CVFP` / `APD` / `TAKEOFF_MINIMA` / `ALTERNATE_MINIMA` |
| `procedure_name` | raw d-TPP `chart_name` (e.g. `ILS OR LOC RWY 30L`) — kept for display/debug |
| `spoken_name` | generated spoken form (e.g. `ILS or localizer runway three zero left`) |
| `runway_ident` | runway the procedure serves (`30L`, `28L/R`), or `NULL` for SIDs/STARs |
| `chart_code` | original d-TPP code (`IAP`/`DP`/`STR`/…) |
| `pdf_filename` | plate filename (`00264IL30L.PDF`) |
| `effective_date` | per-procedure amendment date (`amdtdate`) |
| `source_cycle` | the d-TPP cycle ingested (`2606`) |

`runway_ident` and `spoken_name` are precomputed once at ingestion. The DB lives
under the git-ignored `data/airport_context/`.

---

## 4. `procedures.py` — normalization & spoken-name generation

Pure, I/O-free functions, so they can be unit-tested and audited against the full
chart-name corpus. Inputs are uppercased on entry (FAA names are canonically
uppercase) for robustness.

### Module constants

| name | purpose |
|---|---|
| `PROMPT_TYPES` | `("IAP","DP","STAR","CVFP")` — types eligible for the prompt |
| `_RWY_RE` | matches `RWY <ident>` incl. multi-side (`28L/R`, `16 R/C/L`); `(?!\d)` stops a 3-digit bearing matching as a 2-digit runway |
| `_CONT_RE` | matches a trailing `, CONT.1` continuation suffix |
| `_PAREN_RE` | matches any `(...)` qualifier |
| `_TOKEN_SPOKEN` | tokens that get spoken words: `LOC`→`localizer`, `BC`→`back course`, `OR`→`or`, `CONVERGING`→`converging`, `RWY`→`runway` |
| `_KEEP_TOKENS` | acronyms kept verbatim: `ILS VOR DME NDB TACAN RNAV GPS RNP GLS LDA …` |

### Public functions

**`is_continuation(chart_name) -> bool`**
True for continuation pages (`COULT SEVEN, CONT.1`). Multi-page charts repeat the
base procedure, so continuations are dropped to avoid duplicates.

**`normalize_type(chart_code, chart_name) -> str`**
Maps a d-TPP `chart_code` to a normalized type. `IAP` becomes `CVFP` when the
name contains `VISUAL`; `ODP` folds into `DP`; `STR` becomes `STAR`; `MIN` splits
into `TAKEOFF_MINIMA` / `ALTERNATE_MINIMA` by name; everything else → `OTHER`.

**`extract_runway(chart_name) -> str | None`**
Returns the runway ident (`30L`, `28L/R`) embedded in the name, whitespace-
normalized (`16 R/C/L` → `16R/C/L`), or `None` for SIDs/STARs and circling
approaches.

**`spoken_name(chart_code, chart_name, procedure_type=None) -> str`**
The entry point. Dispatches on the normalized type:

* **`DP` / `STAR`** — strip the `, CONT.n` suffix and `(...)` qualifiers; if a
  `RWY` token is embedded (runway-specific SID), speak it via `runway_spoken`;
  spell any bare sequence digit (`DEVLN 1` → `Devln One`); titlecase the name
  (hyphen-aware: `WILKES-BARRE` → `Wilkes-Barre`); append ` departure` / ` arrival`.
* **`CVFP`** — titlecase the landmark, spell digits (`ROUTE 80` → `Route eight
  zero`), and append the spoken runway.
* **`IAP`** — delegate to `_approach_spoken` (below).
* **`APD`** — literally `"airport diagram"`.
* default — titlecased, parens stripped.

### Private helpers

**`_normalize_parens(s)`** — keeps the meaningful `(GPS)`/`(RNP)` qualifiers by
turning them into bare words (`RNAV (GPS)` → `RNAV GPS`), then drops every other
parenthetical (`(CAT II)`, `(SA CAT I)`, `(CONVERGING)`, …).

**`_titlecase(s)`** — capitalizes each word *and* each hyphen-delimited component,
so place names like `WILKES-BARRE` render `Wilkes-Barre` rather than `Wilkes-barre`.

**`_spell_digits(text)`** — replaces digit runs with aviation digit words
(`80` → `eight zero`), used for bare SID sequence numbers and CVFP landmark digits.

**`_expand_prefix(prefix)`** — turns an approach-type prefix into spoken words,
token by token: `LOC`→`localizer`, `BC`→`back course`, `OR`→`or`; kept acronyms
pass through (`ILS`, `VOR`, `TACAN`, …); a hyphen-number like `VOR-1`→`VOR one`;
and a lone designator letter expands phonetically (`Y`→`Yankee`, `V`→`Victor`).
`/` is treated as a separator (`VOR/DME`→`VOR DME`).

**`_approach_spoken(chart_name)`** — the approach parser. It strips a `, CONT.n`
suffix, normalizes parens, and removes leading `COPTER`/`HI-` markers. Then:
1. If a `RWY <ident>` is present → `_expand_prefix(<before RWY>) + runway_spoken(<ident>)`.
2. Else if it ends in a circling-letter designator (`-A`, ` A`) → prefix + phonetic letter (`Alpha`).
3. Else if it ends in a 3-digit bearing (COPTER approaches) → prefix + spelled digits.
4. Else → expand the whole thing.
A `copter ` prefix is re-attached if it was a helicopter approach.

### A worked example

`spoken_name("IAP", "RNAV (GPS) Y RWY 12L")`:
1. `normalize_type` → `IAP` → `_approach_spoken`.
2. `_normalize_parens` → `RNAV GPS Y RWY 12L`.
3. `_RWY_RE` matches `12L`; prefix = `RNAV GPS Y`.
4. `_expand_prefix("RNAV GPS Y")` → `RNAV GPS Yankee` (acronyms kept, `Y`→`Yankee`).
5. `runway_spoken("12L")` → `runway one two left`.
6. Result: **`RNAV GPS Yankee runway one two left`**.

### Multi-side runways

`runway_spoken` (in [`spoken.py`](spoken.py)) speaks every side of a parallel
runway pair/triple, and `_RWY_RE` captures the full ident:

| ident | spoken |
|---|---|
| `30L` | `runway three zero left` |
| `28L/R` | `runway two eight left right` |
| `16 R/C/L` | `runway one six right center left` |

---

## 5. `ingest_dtpp.py` — offline ingestion

### Cycle resolution

* **`compute_cycle(today)`** — computes the `YYNN` cycle from a known anchor
  (cycle `2606` ↔ 2026-06-11) by stepping 28-day boundaries. Fixed 13 cycles/year;
  exact for the foreseeable future (would drift only at rare 14th-cycle years,
  first in 2043).
* **`cycle_add(cycle, delta)`** — steps a cycle id by N cycles with year rollover
  (`2613` +1 → `2701`).
* **`metafile_url(cycle)`** — builds the FAA URL.
* **`resolve_cycle(cycle=None, …)`** — the dispatcher: an explicit `--cycle` wins;
  otherwise it computes a candidate and HTTP-`HEAD`-probes it and its neighbors
  (`0, -1, +1, -2, +2`), so a date-boundary off-by-one self-corrects to the
  actually-published cycle.

### Download

**`download(cycle, …)`** fetches the metafile to
`data/airport_context/dtpp/d-TPP_Metafile_<cycle>.xml`, reusing the cache unless
`--force`. The write is **atomic**: it streams to a `.part` temp file and only
`os.replace()`s it into place after a complete transfer (and rejects an HTML error
page), so an interrupted download can never leave a truncated "poison" cache that
later runs would fail to parse.

### Load

**`load(conn, xml_path, cycle)`** is the core:
1. Build `{icao→id}`, `{faa_lid→id}`, `{ident→id}` lookups from the airports
   table. **If the airports table is empty it raises** — refusing to run the
   destructive `DELETE FROM procedures` when nothing could be matched (this guards
   against silently wiping a populated table on a mis-ordered run).
2. `DELETE FROM procedures` (full replace — ingestion is idempotent).
3. `ET.iterparse` the XML streaming by `<airport_name>` (constant memory; the
   element is `.clear()`ed after each airport). For each linked airport, walk its
   `<record>`s, **skipping** continuations, AAUP pages, and non-kept types; for
   the rest, compute `normalize_type` + `spoken_name` + `extract_runway` and stage
   a row.
4. `executemany` in batches of 5,000; stamp `meta` (cycle, timestamp, count);
   commit.

Returns `{procedures, airports_with_procedures, unmatched_airports}`.

**`run_ingest(db_path, cache_dir, cycle, force)`** ties it together: resolve →
download → connect → load. Also runnable as `python -m airport_context.ingest_dtpp`.

---

## 6. `db.py` — queries

* **`get_procedures(conn, airport_id, types=None)`** → `list[Procedure]`,
  optionally filtered to given types, ordered by type then name. Uses `?`
  placeholders for the `IN (…)` clause (injection-safe).
* **`count_procedures(conn)`** → total rows; the builder uses it to decide between
  "ingested" and the `procedures_unavailable` warning.

`Procedure` ([`models.py`](models.py)) is a dataclass with
`procedure_type / name / spoken / runway_ident / chart_code` and a
`snapshot_dict()` (`{type, name, spoken, runway}`) for the context snapshot.

---

## 7. `builder.py` — frequency-type-aware selection

Different controllers care about different procedures. Two tables drive selection:

| frequency type | procedure types surfaced | cap |
|---|---|--:|
| `clearance` | SIDs (`DP`) | 10 |
| `ground` | — | 0 |
| `tower` | approaches (`IAP`, `CVFP`) | 6 |
| `approach` | approaches + arrivals (`IAP`, `STAR`, `CVFP`) | 16 |
| `departure` | SIDs + arrivals (`DP`, `STAR`) | 14 |
| `center` | arrivals (`STAR`) | 8 |
| `ctaf` | — | 0 |
| `unknown` | `IAP`, `DP`, `STAR`, `CVFP` | 12 |

**`_select_procedures(aid, frequency_type)`** fetches one bucket per type and
**round-robins** across them (so 16 approach slots aren't all approaches and zero
arrivals), while **de-duplicating by spoken form before the cap** — distinct charts
that collapse to the same phrase (e.g. `ILS RWY 30L (CAT II)` and
`(CAT II - III)` both → `ILS runway three zero left`) fill only one slot, keeping
the structured snapshot clean and not wasting prompt budget.

In `build()`, the procedure read is wrapped so a **transient DB error degrades
gracefully** (empty section + `procedures_unavailable`) rather than propagating —
important because in the live pipeline `build()` runs on the transcription worker
thread, and an unhandled exception there would stall the whole pipeline.

---

## 8. Usage

```bash
# one-time / per-cycle: build the airport DB, then add procedures
python -m airport_context.cli ingest                       # airports/runways/freqs/navaids
python -m airport_context.cli ingest-procedures            # FAA d-TPP (auto-detect cycle)
python -m airport_context.cli ingest-procedures --cycle 2606 --force   # pin / re-download

# build a prompt — procedures appear for approach/departure/clearance/tower
python -m airport_context.cli build --airport KMSP --frequency-type approach
python -m airport_context.cli build --airport KMSP --frequency-type approach --json
```

```python
from airport_context import build_context
snap = build_context({"airport_code": "KSFO", "frequency_type": "approach"})["context_snapshot"]
snap["procedures"]
# [{"type":"IAP","name":"ILS OR LOC RWY 28L","spoken":"ILS or localizer runway two eight left","runway":"28L"}, ...]
```

Example approach-mode output (KSFO):

```
Likely procedures and fixes: GLS runway one niner left; Alwys Three arrival;
Quiet Bridge Visual runway two eight left right; ILS or localizer runway two eight left;
Big Sur Three arrival; … ; OAK; Oakland; OSI; Woodside; …
```

---

## 9. Hardening: adversarial review

The spoken-name generator and ingestion were verified by a multi-agent review
(six parallel SME audits over the full ~4.9k-name corpus + code review, each
finding independently reproduced by a skeptic). It surfaced **20 confirmed
findings**, all fixed and regression-tested. Highlights:

* **Critical** — ingesting with an empty airports table silently wiped the
  procedures table → now refuses before the `DELETE`.
* **High** — multi-runway idents (`28L/R`, `16 R/C/L`) truncated the canonical
  `runway_ident`; equivalent procedures duplicated in the snapshot; an unguarded
  DB read could kill the live worker.
* **Medium/Low** — hyphenated names, leading `CONVERGING`, runway-/digit-qualified
  SIDs, phonetic designator letters (W/V/U/T/X/Y/Z), `VOR-1`, AAUP charts, non-atomic
  download cache, CVFP reachability, an unclosed pipeline connection, lowercase input.

See the Phase 2 commit message for the full list.

---

## 10. Testing

`tests/test_airport_context.py` (stdlib `unittest`, no network) covers:
`normalize_type` / `extract_runway` / `is_continuation`; spoken names for
approaches, SIDs, STARs, CVFP, multi-runway, designator letters, `CONVERGING`,
`VOR-1`, embedded-RWY SIDs, bare digits, hyphenated names, case-insensitive and
3-digit inputs; builder selection per frequency type; snapshot de-dup; the
empty-airports guard; graceful degradation; and cycle math.

```bash
python tests/test_airport_context.py
```

---

## 11. Limitations & future

* **Names only, not plates.** Approach minimums, fixes within a procedure, and
  transitions are not parsed — only the procedure name is injected.
* **Procedure-internal fixes** (e.g. the named waypoints on a STAR) are not
  surfaced; Phase 1 navaids cover nearby VOR/NDB fixes by radius.
* **U.S. only** — d-TPP is FAA. Non-U.S. procedures would need another source.
* **CVFP runway sides** beyond the first slash group and 14th-cycle-year AIRAC
  numbering (2043+) are known low-severity edges; `--cycle` pins the cycle if ever
  needed.

**Next phases:** Phase 3 weather (AWC METAR → spoken weather terms) and Phase 5
post-transcription normalization + evaluation.
