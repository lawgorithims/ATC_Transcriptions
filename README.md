# ATC_Transcribe

Context-aware transcription of live air-traffic-control radio with a fine-tuned Whisper
model. The repo holds **two implementations** of the same pipeline:

| Folder | What it is | Start here |
| --- | --- | --- |
| [`python-legacy/`](python-legacy/) | The original **Python** implementation: model fine-tuning/training tooling, the airport-context engine, the live ATC pipeline, and a server + browser console (a thin client that talks to a Python host running the model). | [`python-legacy/README.md`](python-legacy/README.md) |
| [`ios/`](ios/) | A native **iOS / iPadOS** port that runs the **entire pipeline on-device** (capture → VAD → preprocessing → airport-context prompt → Whisper via CoreML/WhisperKit → optional on-device correction), with no server. Universal iPhone + iPad. | [`ios/README.md`](ios/README.md) |

Both share the same design — VAD segmentation, radio-audio preprocessing, airport-context
prompting, the fine-tuned Whisper models, and a transparent post-ASR correction layer. The
iOS app is a faithful port of the Python modules; the Swift↔Python mapping is documented in
[`ios/README.md`](ios/README.md), and behavior parity is cross-checked by
[`ios/Tools/parity_check.py`](ios/Tools/parity_check.py) against the real Python reference.

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
