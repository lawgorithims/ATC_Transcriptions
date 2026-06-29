# Publishing the models for in-app download (HuggingFace)

The app downloads its models **at runtime** (first launch + Settings → Models) instead of
bundling them, so the TestFlight build stays small. The app can only download what's actually
hosted — this runbook is the one-time hosting step. Do it **once** (and again whenever you
re-convert a model). Runs on the Mac after conversion (`Tools/convert_to_coreml.md`).

The download client is `ios/ATCTranscribe/Download/`:
- **Whisper** models: `WhisperKit.download(variant:from:…)` pulls subfolder `<variant>` from a HF
  repo (`ModelCatalog.whisperRepo`, default `SingularityUS/atc-whisperkit`).
- **GGUF** LLM: a direct HF `resolve` URL (`ModelCatalog.llm.directURL`, the public Qwen repo) —
  **already hosted, nothing to publish.**

## 1. Whisper models → an HF repo (the only thing to publish)

WhisperKit expects one **subfolder per variant**, each holding the `.mlmodelc` set + `config.json`
*directly* inside (no extra nesting):

```
SingularityUS/atc-whisperkit
├── small/  { MelSpectrogram, AudioEncoder, TextDecoder[, TextDecoderContextPrefill] }.mlmodelc + config.json
└── turbo/  { … }
```

```bash
pip install -U "huggingface_hub[cli]"
huggingface-cli login                       # a WRITE token from https://huggingface.co/settings/tokens
REPO=SingularityUS/atc-whisperkit           # must match ModelCatalog.whisperRepo (or set ATC_WHISPER_REPO)
huggingface-cli repo create "$REPO" --type model -y   # first time only

# The converter nests the .mlmodelc set under a sanitized-id subdir — upload the dir that
# CONTAINS AudioEncoder.mlmodelc to the bare variant folder so the layout flattens to <repo>/<variant>/.
SRC_SMALL=$(dirname "$(find $HOME/atc-coreml/small -name AudioEncoder.mlmodelc | head -1)")
SRC_TURBO=$(dirname "$(find $HOME/atc-coreml/turbo -name AudioEncoder.mlmodelc | head -1)")

huggingface-cli upload "$REPO" "$SRC_SMALL" small --repo-type model
huggingface-cli upload "$REPO" "$SRC_TURBO" turbo --repo-type model
```

Verify the repo shows `small/AudioEncoder.mlmodelc` etc. at the top of each variant folder.
If the repo is **private**, the app needs a read token — pass one via WhisperKit's `token:`
argument in `LiveModelDownloader.downloadWhisper` (kept out of the default public path here).

## 1b. Stock "Large V2" model — convert + host like the fine-tuned ones

The optional **Large V2** model (`ModelCatalog.cleanturbo`) is the *stock* OpenAI large-v3-turbo (no
ATC fine-tuning), for real-world accuracy comparison against the fine-tuned `turbo`. **Do NOT use
Argmax's prebuilt `argmaxinc/whisperkit-coreml` variant** — on an M2 iPad Air it took minutes to load
and ran the ANE hot / transcribed too slowly to be usable, while the fine-tuned `turbo` (same arch)
runs fine. The fix is to convert the *stock* model through **our own** pipeline so it's
on-device-optimized identically to the fine-tuned models, then host it alongside them:

```bash
# convert stock large-v3-turbo (NO --generate-decoder-context-prefill-data: its consistency test
# fails ~19.7 < 20 PSNR on this model, and our fine-tuned models ship without prefill anyway).
source ~/whisperkittools/.env/bin/activate
whisperkit-generate-model --model-version openai/whisper-large-v3-turbo --output-dir ~/atc-coreml/stockturbo
SRC=$(dirname "$(find ~/atc-coreml/stockturbo -name AudioEncoder.mlmodelc | head -1)")
huggingface-cli upload SingularityUS/atc-whisperkit "$SRC" stockturbo --repo-type model   # ≈1.5 GB
```

`ModelCatalog.cleanVariant` is `stockturbo` and `cleanRepo` defaults to `whisperRepo`
(`SingularityUS/atc-whisperkit`), so the app downloads `<repo>/stockturbo/`. Override with
`ATC_CLEAN_REPO` / `ATC_CLEAN_VARIANT` (env, dev/Simulator) to pin a different build.

## 2. GGUF LLM — nothing to do

`ModelCatalog.llm` points at the public
`https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf`.
To host your own (e.g. an ATC-fine-tuned GGUF), upload it to a public HF repo and set
`ATC_LLM_URL=<resolve-url>` (env, dev/Simulator) or change `directURL` in `ModelCatalog.swift`.

## 3. Sanity-check from the Simulator before shipping

```bash
# point the app at your repo and launch with NO bundled model so the gate appears:
ATC_WHISPER_REPO=SingularityUS/atc-whisperkit xcrun simctl launch booted net.atctranscribe.app
```
The first-launch gate should download `small`, show the progress bar, then "Model ready". If the
download 404s, the repo/variant subfolder name is wrong (it must equal the catalog `variant`).
