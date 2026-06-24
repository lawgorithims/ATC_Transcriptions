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
> fine-tuned models are converted to CoreML, and the **engine + proof-of-life run on the
> M4's real ANE** (12.5× real-time, mean WER 9.1%), and the **live session pipeline runs
> end-to-end** (file-replay → VAD → preprocess → context → transcribe → records, 5
> transmissions on the ANE), and the **SwiftUI console is wired to live transcription** —
> the replay demo transcribes in-app (Cockpit/Day/Night themes), and the **LiveATC live
> internet stream transcribes end-to-end** (AudioToolbox streaming MP3 decode → VAD →
> transcribe → UI, verified live on the KATL tower feed). An **optional on-device
> correction layer** then refines each transcript — a deterministic vocabulary/number
> fixer (verified correcting live in-app) plus an **Apple Foundation Models** LLM stage
> for the errors a dictionary can't reach (mis-heard callsigns, runways, waypoints, ICAO
> phraseology, repeats). Remaining: standalone model bundling, the LLM stage's on-device
> validation (needs an Apple-Intelligence device), and on-device (mic / USB) testing —
> see the table below.

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

## Screenshots (iPad Simulator)

| Cockpit | Day | Night |
| --- | --- | --- |
| ![Cockpit](docs/screenshots/cockpit.png) | ![Day](docs/screenshots/day.png) | ![Night](docs/screenshots/night.png) |

The Replay demo transcribing **live in-app** (Simulator CPU — note the "CPU (Simulator)" badge
and ~2.8 s transcribe times vs ~0.2 s on a device's ANE):

![Live transcription](docs/screenshots/live.png)

The **LiveATC live internet stream** transcribing on-device — a real transmission ("stand
by level") captured from the KATL tower feed (`s1-bos.liveatc.net/katl_twr`), VAD-segmented
and transcribed (1.2 s clip, RTF 0.83 on the Simulator CPU), with auto-reconnect on the
feed's periodic drops:

![LiveATC live stream](docs/screenshots/live_feed.png)

Input method is a dropdown (Internet live feed / Device microphone / USB audio / Replay
demo). The LiveATC link + airport/frequency fields appear **only** for the internet live
feed (left) and are hidden for the microphone / USB inputs (right):

| Internet live feed | Device microphone |
| --- | --- |
| ![Live feed input](docs/screenshots/input_livefeed.png) | ![Mic input](docs/screenshots/input_mic.png) |

The optional **correction layer** refining transcripts live — each edit is shown inline
(`from → to`) and the raw transcript is always preserved. Here the deterministic stage
normalizes spoken numbers (`one zero two three → 1023`, `sixty one thirty four → 6134`);
with Apple Intelligence enabled, the LLM stage additionally fixes mis-heard callsigns,
runway/waypoint names, and ICAO phraseology:

![Correction layer](docs/screenshots/correction.png)

## How the Python modules map to Swift

| Python (repo root / `server/`) | Swift (`ATCTranscribe/`) | Status |
| --- | --- | --- |
| `atc_corrector.py` (deterministic + LLM) | `Core/ATCCorrector.swift`, `Core/StringRatio.swift`, `Core/FoundationModelsCorrector.swift` | ✅ deterministic stage builds, 32 tests pass, corrects live in-app; LLM stage = Apple Foundation Models (builds + degrades gracefully; runs on an Apple-Intelligence device) |
| `atc_context.py` | `Core/ATCContext.swift` | ✅ builds + tests pass |
| `Correction`, `SpeechSegment`, `airport_configs/*.json` | `Models/*.swift` + `Resources/airport_configs/` | ✅ builds + tests pass |
| `atc_stream.py` (VAD/segmentation) | `Audio/VADSegmenter.swift` | ✅ builds + tests pass (energy path) |
| `atc_transcriber.py` (Whisper) | `Transcription/ATCTranscriber.swift` (WhisperKit) | ✅ runs on-device — transcribes the diagnostic clips |
| `audio_preprocessing.py` | `Audio/AudioPreprocessor.swift` + `Biquad`/`STFT` | ✅ builds + tests pass (filters SciPy-parity; `noisereduce` deferred) |
| `server/engine.py` (model mgmt, adaptive) | `Engine/Engine.swift` (`TranscriberEngine`, `WER`) | ✅ engine + proof-of-life (PASS on the ANE, 12.5× real-time) |
| `live_atc_pipeline.py` + `server/session.py` | `Engine/LivePipeline.swift`, `TranscriptionSession.swift` | ✅ pipeline verified end-to-end on the ANE (5 transmissions) |
| `diagnostics/diagnostic.py` (proof-of-life) | `Engine/Engine.swift` + `ATCKitProbe` | ✅ runs natively on the ANE (probe) |
| `server/static/*` (browser UI) | `UI/` (Theme, ConsoleView, Transcript, Sidebar, Settings, AppModel) | ✅ console **wired to live transcription** — replay demo transcribes in-app (verified in the Simulator) |
| `atc_stream.py` capture / mounts | `Audio/` (AudioSource, StreamAudioSource, StreamURLResolver) | ✅ file-replay + **LiveATC live stream verified end-to-end** (AudioToolbox streaming MP3 decode + auto-reconnect); mic/USB implemented, device validation pending |

Behavior parity with the Python is cross-checked two ways: `Tools/parity_check.py`
runs the real Python modules against the exact cases the Swift XCTests assert, and the
XCTests then run those cases on-device in the Simulator.

## Testing strategy — Simulator vs. native ANE

The iOS Simulator has **no Apple Neural Engine** (CoreML silently falls back to CPU), so
it's the wrong place to validate the neural path. Testing is split accordingly:

- **iOS Simulator** (`ATCTranscribe` scheme) — UI + pure-logic XCTests (corrector,
  context, VAD, filters, WER): 25 tests, fast, headless via the Simulator.
- **Native macOS, real ANE** (`ATCKitProbe`) — a command-line *probe* (not XCTest) that
  runs the engine + proof-of-life on the Mac's actual Neural Engine: `bash Tools/probe.sh`.
  Measured **12.5× real-time** on the M4 vs ~1× on the Simulator CPU.

A probe rather than a macOS XCTest target because macOS XCTest needs a GUI test-runner
daemon (`testmanagerd`) that isn't available over headless SSH — a plain executable runs
anywhere.

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
