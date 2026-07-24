# ATC_Transcribe

Context-aware transcription of live air-traffic-control radio with a fine-tuned Whisper
model. The repo holds **two implementations** of the same pipeline:

| Folder | What it is | Start here |
| --- | --- | --- |
| [`python-legacy/`](python-legacy/) | The original **Python** implementation: model fine-tuning/training tooling, the airport-context engine, the live ATC pipeline, and a server + browser console (a thin client that talks to a Python host running the model). | [`python-legacy/README.md`](python-legacy/README.md) |
| [`ios/`](ios/) | A native **iOS / iPadOS** port that runs the **entire pipeline on-device** (capture → VAD → preprocessing → airport-context prompt → Whisper via CoreML/WhisperKit → speaker labelling → two-tier on-device correction), with no server. Universal iPhone + iPad. | [`ios/README.md`](ios/README.md) |

> **Status.** The iOS app (product name **CommSight**, bundle `com.flycommsight.atctranscribe`) is the
> actively shipping implementation — currently **TestFlight build 41** (offline ForeFlight hand-off),
> layered on build 40's coded CIFP procedures + voice clearance loader and a fully-remediated
> **23-finding reliability/safety audit** ([`ios/REMEDIATION.md`](ios/REMEDIATION.md)). The full
> pipeline runs on-device; **438+ unit/UI tests** pass on the Simulator and the neural path is
> validated natively on Apple-Silicon Neural Engine (~12.5× real-time). The Python side is retained as
> the **reference / training** implementation. The per-build changelog is
> [`ios/ATCTranscribe/UI/WhatsNew.swift`](ios/ATCTranscribe/UI/WhatsNew.swift).

Both share the same design — VAD segmentation, radio-audio preprocessing, airport-context
prompting, the fine-tuned Whisper models, and a transparent post-ASR correction layer. The
iOS app is a faithful port of the Python modules; the Swift↔Python mapping is documented in
[`ios/README.md`](ios/README.md), and behavior parity is cross-checked by
[`ios/Tools/parity_check.py`](ios/Tools/parity_check.py) against the real Python reference.

The iOS correction layer goes beyond the Python original: it is **two-tier** — an instant
deterministic fixer (numbers, vocabulary, repetition) plus a **decoupled, CPU-only RAG
"context-fixer" LLM** (llama.cpp, or Apple Foundation Models) that runs in the background so it
never slows transcription, behind output guardrails and a **confidence gate** that only invokes
it when a transmission looks suspicious. The full rationale is in
[`ios/README.md` → Correction pipeline](ios/README.md#correction-pipeline).

The deterministic tier now includes two **context-grounded snap stages** — live in the iOS app and
**byte-parity-locked to the Python reference** (`ios/Tools/parity_check.py` + `SnapParityTests`):
`CallsignSnap` (snap-or-abstain against live ADS-B traffic + the filed flight plan; false callsign
attributions 13.7% → 2.0% on the gold set) and `SlotSnap` (runway/frequency verification against the
airport's real runways and published frequencies). Grounding data flows through a provider chain —
flight plan → curated/offline map data → live position → **OurAirports internet fallback** (the only
source in LiveATC/demo mode). Diagrams, stage policies, and measured findings:
[`python-legacy/docs/PIPELINE.md`](python-legacy/docs/PIPELINE.md); standing metrics:
[`python-legacy/docs/RESULTS.md`](python-legacy/docs/RESULTS.md).

Beyond the shared pipeline, the iOS app has grown into a full **cockpit EFB** built around a
moving-map home screen. This part is native to the iOS app (no Python origin):

- **Moving map + offline charts** — the app opens to a chart map with the live transcript, flight
  plan, and status as draggable/resizable floating cards. Base layers switch between VFR sectional,
  IFR-low, standard, and satellite (offline-cached FAA raster tiles, built by the self-hosted
  [`charts/`](charts/) pipeline), with Class B/C/D airspace, navaids, and live traffic overlaid.
  **Tap** any object to identify it, **search** by id/name, **long-press** to drop a waypoint, and
  edit the route on the map.
- **Coded procedures (FAA CIFP)** — **approaches, SIDs, and STARs** draw as georeferenced overlays,
  load into the flight plan, and **ground the corrector** (a heard procedure/fix is verified against
  what the airport actually publishes).
- **FAA approach/departure plates** — view the full d-TPP plate offline (cached on first open), and
  optionally **superimpose** a hand-aligned plate as a reference overlay on the map.
- **Voice-driven clearance loader** — interprets an ATC clearance addressed to *your own* aircraft
  ("N8925T, cleared direct BOSOX… cleared ILS runway 4 right") and offers a **one-tap load**;
  ownship-aware, so it never fires on another aircraft or a retracted clearance.
- **ForeFlight hand-off** — send an ATC-amended plan to ForeFlight over its offline URL scheme, or
  share a Garmin **`.fpl`** — no internet required.
- **NASA hazard awareness (EONET)** — wildfires, severe storms, volcanoes and other events shown as a
  map layer, with **route-corridor and vicinity alerts** against your filed plan.
- **Airport Climate card (NASA POWER / MERRA-2)** — a 16-sector windrose, prevailing winds,
  density-altitude percentiles, and favored-runway / crosswind stats. This is historical
  **climatology, not current weather**; one ~2 MB download per airport, then fully offline.
- **Per-line speaker labels** — each transmission carries one fused label: "ATC" for a controller,
  the callsign (or "Pilot") for an aircraft.
- **Hardware / in-flight offline** — a [`stratux-pi/`](stratux-pi/) Raspberry Pi gateway turns a
  Stratux receiver into a single cockpit device: **cockpit audio** over Wi-Fi plus ADS-B **traffic**
  and **GPS** from Stratux's own API, so the whole thing works in flight with no internet.

The current architecture, feature set, and the audit remediation are documented in
[`ios/README.md`](ios/README.md), [`ios/PIPELINES.md`](ios/PIPELINES.md), and
[`ios/REMEDIATION.md`](ios/REMEDIATION.md).

## Repository layout

```
ATC_Transcribe/                  # repository root (product name: CommSight)
├── ios/             # native on-device iOS/iPadOS app (Swift, WhisperKit/CoreML) — the shipping product
│   ├── README.md            # iOS build/architecture guide
│   ├── ATCTranscribe/       # app sources: Audio, Core, Engine, Aircraft, Hazards, Download, UI, Models, Resources
│   ├── ATCTranscribeTests/  # XCTest unit + parity suite
│   ├── ATCTranscribeUITests/# UI + screenshot tests
│   └── Tools/               # setup, CoreML conversion, parity check, ANE probe, ship-to-TestFlight
├── python-legacy/   # original Python implementation (server, web console, training, reference)
│   ├── README.md            # full Python guide (quick start, API, models, maintainer notes)
│   ├── server/              # FastAPI host + browser console (static/)
│   ├── airport_context/     # airport/facility context engine
│   ├── dataset/             # gold-set builder + scorers + offline speaker-cluster pass
│   ├── diagnostics/         # proof-of-life + benchmarks
│   ├── scripts/             # install / model-download helpers
│   ├── tests/               # Python tests + diagnostic audio snippets
│   └── *.py, config.yaml    # core pipeline modules + config
├── charts/          # self-hosted FAA chart-tile pipeline + tile server (VFR sectional / IFR-low → MBTiles/XYZ)
└── stratux-pi/      # Raspberry Pi cockpit-audio gateway for a Stratux receiver (audio + traffic + GPS, offline)
```

> **Note:** the Python code was relocated under `python-legacy/` (from the repo root) to keep
> the repository clean now that the on-device iOS port exists. Nothing was removed — git
> history is preserved through the move. Run Python commands from inside `python-legacy/`.

## Models

Two fine-tuned checkpoints (weights hosted on Hugging Face, not in git): a default **small**
and a more accurate **large-v3-turbo**. See [`python-legacy/README.md`](python-legacy/README.md)
for the Python side and [`ios/README.md`](ios/README.md) for the CoreML-converted variants the
app loads.

## Evaluation

Model and pipeline quality is tracked against a **human-verified gold set** of real US ATC
transmissions (canonWER + callsign-safety metrics); the standing numbers live in
[`python-legacy/docs/RESULTS.md`](python-legacy/docs/RESULTS.md). The repo tracks the
tooling — batch builder + browser review page + ingest
([`dataset/gold_builder.py`](python-legacy/dataset/gold_builder.py)) and the scorers
([`dataset/scoreboard.py`](python-legacy/dataset/scoreboard.py) and friends) — while the
gold **data** (review exports, candidate batches, ingested test sets) is LiveATC-derived
and therefore **local-only, never committed**, per the licensing note in
[`python-legacy/dataset/README.md`](python-legacy/dataset/README.md). That README's
"Gold evaluation set" section documents the build → human-review → ingest workflow and
the current gold v0/v1 status.

## Known limitations & caveats

These are documented design limitations, not defects — worth knowing before you rely on a feature:

- **Speaker labelling is content-role fusion, not voice biometrics.** A corpus study over ~14k real
  clips found that on-device mean-MFCC features **cannot** reliably separate the controller from
  pilots on the *same* feed (EER ~53%), so the acoustic voice-clustering fill is **default-off** and
  the shipped label leans on the reliable content-role signal. Treat the per-line label as a strong
  hint, not ground truth. (Rationale in
  [`ios/ATCTranscribe/Engine/SpeakerLabeler.swift`](ios/ATCTranscribe/Engine/SpeakerLabeler.swift).)
- **The Airport Climate card is climatology, not a forecast.** It is NASA POWER / MERRA-2 *historical*
  reanalysis (windrose, density-altitude, crosswind stats) — never current or forecast weather.
- **Charts are self-hosted.** The public FAA rasters are public-domain, but the tile set is built and
  hosted by the [`charts/`](charts/) pipeline; there is no dependency on third-party chart-tile
  services (which are dead or hobby efforts). A missing/stale tile host means no chart base layer.
- **The AI context-fixer is a background, best-effort tier.** It runs CPU-only at `.background` QoS
  behind a confidence gate and a bounded queue, so under load its refinements are *dropped*, not
  queued. The raw + deterministic transcript is always the source of truth; a skipped refinement only
  costs a possible improvement, never a wrong edit.
- **Gold evaluation data is local-only.** The scoring *tooling* is tracked, but the LiveATC-derived
  gold audio/transcripts are never committed (licensing) — reproducing the standing metrics requires
  building the gold set locally per [`python-legacy/dataset/README.md`](python-legacy/dataset/README.md).
