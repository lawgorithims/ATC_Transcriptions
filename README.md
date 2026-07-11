# ATC_Transcribe

Context-aware transcription of live air-traffic-control radio with a fine-tuned Whisper
model. The repo holds **two implementations** of the same pipeline:

| Folder | What it is | Start here |
| --- | --- | --- |
| [`python-legacy/`](python-legacy/) | The original **Python** implementation: model fine-tuning/training tooling, the airport-context engine, the live ATC pipeline, and a server + browser console (a thin client that talks to a Python host running the model). | [`python-legacy/README.md`](python-legacy/README.md) |
| [`ios/`](ios/) | A native **iOS / iPadOS** port that runs the **entire pipeline on-device** (capture → VAD → preprocessing → airport-context prompt → Whisper via CoreML/WhisperKit → two-tier on-device correction), with no server. Universal iPhone + iPad. | [`ios/README.md`](ios/README.md) |

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

Beyond the shared pipeline, the iOS app has grown a full **cockpit EFB**: a moving-map home screen
with offline FAA VFR/IFR charts, airspace, tap-to-identify, search and on-map route editing; coded
**approaches, SIDs and STARs** (FAA CIFP) drawn on the map and loadable into the plan; and a
**voice-driven clearance loader** that hears an ATC clearance addressed to *your* aircraft ("N8925T,
cleared direct BOSOX… cleared ILS runway 4 right") and offers a one-tap load — never firing on
another aircraft. It ships through TestFlight as **CommSight**; the current architecture, feature
set, and the 23-finding reliability/safety audit remediation are documented in
[`ios/README.md`](ios/README.md), [`ios/PIPELINES.md`](ios/PIPELINES.md), and
[`ios/REMEDIATION.md`](ios/REMEDIATION.md).

## Repository layout

```
ATC_Transcribe/
├── python-legacy/   # original Python implementation (server, web console, training, reference)
│   ├── README.md            # full Python guide (quick start, API, models, maintainer notes)
│   ├── server/              # FastAPI host + browser console (static/)
│   ├── airport_context/     # airport/facility context engine
│   ├── diagnostics/         # proof-of-life + benchmarks
│   ├── scripts/             # install / model-download helpers
│   ├── tests/               # Python tests + diagnostic audio snippets
│   └── *.py, config.yaml    # core pipeline modules + config
└── ios/             # native on-device iOS/iPadOS app (Swift, WhisperKit/CoreML)
    ├── README.md            # iOS build/architecture guide
    ├── ATCTranscribe/       # app sources
    ├── ATCTranscribeTests/  # XCTest suite
    └── Tools/               # setup, CoreML conversion, parity check, ANE probe
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
