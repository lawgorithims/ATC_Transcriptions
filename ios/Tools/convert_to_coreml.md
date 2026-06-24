# Converting the fine-tuned ATC Whisper models to CoreML (for WhisperKit)

> **This runs on macOS (the Scaleway M4), not Windows.** CoreML conversion needs
> `coremltools` **and** `coremlcompiler` (which ships inside Xcode). There is no
> usable `coremltools` on Windows — `pip` there resolves only to a 2020 beta
> (`coremltools 4.0b3`), confirmed empirically. So conversion + the iOS app build
> both happen on the Mac, which is why Xcode on the M4 is the shared unlock.

## What we're converting

Both checkpoints are stock Whisper architectures (verified from their `config.json`),
already published on the Hugging Face Hub, so WhisperKit's converter pulls them
directly — no need to upload the local 3.2 GB file:

| App model | HF repo (`--model-version`) | Arch | mel | vocab |
| --- | --- | --- | --- | --- |
| `small`  | `SingularityUS/ATC-whisper-v1`       | whisper-small (768d, 12/12) | 80  | 51865 |
| `turbo`  | `SingularityUS/ATC-whisper-turbo-v1` | large-v3-turbo (1280d, 32/4) | 128 | 51866 |

## Prerequisites on the M4

1. **Full Xcode** (not just Command Line Tools — `coremlcompiler` lives in Xcode):
   ```bash
   # after installing Xcode from the App Store / xip:
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   xcrun --find coremlcompiler        # must print a path
   ```
2. **Python 3.11** (Homebrew): `brew install python@3.11` (already in the M4 bootstrap).

## Convert (driver script)

`convert_to_coreml.sh` (next to this file) automates the steps below. Copy it to the
M4 and run:

```bash
bash convert_to_coreml.sh
# overridable: OUT_DIR=~/atc-coreml PREFILL=1 SMALL_REPO=... TURBO_REPO=... bash convert_to_coreml.sh
```

## Convert (manual, what the script does)

```bash
# 1. whisperkittools in its own venv
git clone https://github.com/argmaxinc/whisperkittools ~/whisperkittools
python3.11 -m venv ~/whisperkittools/.env && source ~/whisperkittools/.env/bin/activate
pip install -U pip && pip install -e ~/whisperkittools

# 2. see all optimization flags (quantization, prefill, etc.)
whisperkit-generate-model -h

# 3. convert each model (float16 by default). --generate-decoder-context-prefill-data
#    builds the prefill assets that make prompt conditioning (our airport context!) fast.
whisperkit-generate-model --model-version SingularityUS/ATC-whisper-v1 \
  --output-dir ~/atc-coreml/small --generate-decoder-context-prefill-data
whisperkit-generate-model --model-version SingularityUS/ATC-whisper-turbo-v1 \
  --output-dir ~/atc-coreml/turbo --generate-decoder-context-prefill-data
```

The conversion traces the PyTorch model, runs `coremltools`, compiles to `.mlmodelc`,
and (because CoreML executes during verification) needs the macOS CoreML runtime —
another reason it can't be done on Windows/Linux.

## Output

The output dir contains a model folder with the split CoreML models WhisperKit loads:

```
~/atc-coreml/small/<...>/
├── MelSpectrogram.mlmodelc
├── AudioEncoder.mlmodelc
├── TextDecoder.mlmodelc
├── TextDecoderContextPrefill.mlmodelc   # when --generate-decoder-context-prefill-data
└── config.json
```

(Confirm the exact nesting on first run — `find ~/atc-coreml -name '*.mlmodelc'` —
and record it so the app's `modelFolder` path is right.)

## Getting the models into the app

Two options, decided in the WhisperKit-wiring phase:

1. **Bundle** the converted folder(s) as app resources and point WhisperKit at them:
   ```swift
   let config = WhisperKitConfig(modelFolder: Bundle.main.path(forResource: "small", ofType: nil))
   let pipe = try await WhisperKit(config)
   ```
   Simplest; increases app size (fp16 small is a few hundred MB, turbo more — quantize
   to shrink, mirroring the turbo→small adaptive choice on-device).
2. **Host + download on first launch** (like WhisperKit's default HF download) — keeps
   the binary small; needs network on first run.

## Notes

- Quantization flags (e.g. 4-bit) shrink the models a lot; weigh size vs. the WER we
  measured (turbo 7.83% vs small 12.82%) when deciding what ships.
- The M4 is an **ephemeral** Scaleway box — a ~40 GB Xcode install is lost if it's
  recreated. Consider snapshotting it or keeping it persistent for this project.
