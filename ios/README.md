# ATC_Transcribe — iOS / iPadOS app (native, on-device)

A native Swift port of the [ATC_Transcribe](../README.md) browser console. Unlike
the web console (a thin client that talks to a Python host running the model), this
app runs the **entire pipeline on the device** — capture → VAD → preprocessing →
airport-context prompt → fine-tuned Whisper (CoreML/WhisperKit) → optional correction
— with no server. Universal: iPhone + iPad (iPad-first cockpit/EFB layout).

> **Status: the foundation builds, is tested, and the model runs on-device.** The
> scaffold, deterministic core (context + corrector), and VAD segmenter compile and
> pass a 20-test XCTest suite on the iOS Simulator, and `ATCTranscriber` loads the
> converted CoreML model and **transcribes the diagnostic ATC clips correctly**. Both
> fine-tuned models are converted to CoreML (verified on the Neural Engine). Remaining:
> audio preprocessing, engine/session, live audio input, and the SwiftUI console — see
> the table below.

This folder is self-contained and intended to split out into its own repository.

## Quick start (fresh macOS / Apple Silicon)

Requires **full Xcode** installed (App Store / xip — too large to script). Then:

```bash
bash Tools/setup.sh          # uv+Python 3.11, whisperkittools, xcodegen, iOS sim runtime
bash Tools/setup.sh --models # + convert both Whisper models to CoreML (~30 min)
bash Tools/setup.sh --build  # + generate the Xcode project and compile it
bash Tools/setup.sh --all    # everything in one shot
```

`setup.sh` is idempotent and installs entirely into user space (no sudo).

## How the Python modules map to Swift

| Python (repo root / `server/`) | Swift (`ATCTranscribe/`) | Status |
| --- | --- | --- |
| `atc_corrector.py` | `Core/ATCCorrector.swift`, `Core/StringRatio.swift` | ✅ builds + tests pass |
| `atc_context.py` | `Core/ATCContext.swift` | ✅ builds + tests pass |
| `Correction`, `SpeechSegment`, `airport_configs/*.json` | `Models/*.swift` + `Resources/airport_configs/` | ✅ builds + tests pass |
| `atc_stream.py` (VAD/segmentation) | `Audio/VADSegmenter.swift` | ✅ builds + tests pass (energy path) |
| `atc_transcriber.py` (Whisper) | `Transcription/ATCTranscriber.swift` (WhisperKit) | ✅ runs on-device — transcribes the diagnostic clips |
| `audio_preprocessing.py` | `Audio/AudioPreprocessor.swift` + `Biquad`/`STFT` | ✅ builds + tests pass (filters SciPy-parity; `noisereduce` deferred) |
| `server/engine.py`, `server/session.py` | `Engine/*.swift` | ⏳ todo |
| `diagnostics/diagnostic.py` (proof-of-life) | `Engine/ProofOfLife.swift` | ⏳ todo |
| `server/static/*` (browser UI) | `UI/*.swift` (SwiftUI) | ⏳ todo |
| live mic / LiveATC stream / replay | `Audio/StreamCapture.swift` (AVAudioEngine / AVPlayer) | ⏳ todo |

Behavior parity with the Python is cross-checked two ways: `Tools/parity_check.py`
runs the real Python modules against the exact cases the Swift XCTests assert, and the
XCTests then run those cases on-device in the Simulator.

## Models

The two fine-tuned checkpoints convert to WhisperKit CoreML format (see
`Tools/convert_to_coreml.md`, automated by `setup.sh --models`):

| App model | Source | Output folder (contains the `.mlmodelc` set) |
| --- | --- | --- |
| `turbo` | HF `SingularityUS/ATC-whisper-turbo-v1` | `$OUT_DIR/turbo/<sanitized-id>/` (~1.5 GB) |
| `small` | HF weights + `openai/whisper-small` config/tokenizer¹ | `$OUT_DIR/small/<sanitized-id>/` (~465 MB) |

¹ The small HF repo ships only `model.safetensors` (no config/tokenizer), so `setup.sh`
reconstructs a complete model dir from the matching base. Permanent fix: upload
`config.json` + tokenizer to the small repo, then convert it directly.

Each folder holds `MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc`,
`TextDecoder.mlmodelc`, the context-prefill data, and `config.json`. The app points
WhisperKit's `modelFolder` at one of these (the engine picks turbo vs small by device
capability, mirroring the web console's adaptive downgrade). The exact subfolder name
is the sanitized model id — locate it with `find $OUT_DIR -name AudioEncoder.mlmodelc`.

## Building manually (what `setup.sh --build` runs)

```bash
~/.xcodegen/xcodegen/bin/xcodegen generate     # writes ATCTranscribe.xcodeproj (git-ignored)

# compile app + tests
xcodebuild -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO build-for-testing

# run the unit tests on a simulator
xcodebuild test-without-building -project ATCTranscribe.xcodeproj -scheme ATCTranscribe \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

For a real device, set `DEVELOPMENT_TEAM` (and a provisioning profile) in `project.yml`
and use a `platform=iOS,id=<udid>` destination.

## Why XcodeGen

`.xcodeproj` is a fragile generated bundle that can't be hand-edited reliably on
Windows. `project.yml` is the human-authored source of truth; `xcodegen generate`
produces the `.xcodeproj` on the Mac. The generated project is git-ignored.
