# Code-quality / warnings to-do (NASA "Power of Ten")

Tracker for compiler/analyzer warnings and the rollout of the NASA/JPL "Power of Ten" coding rules.
The speaker-diarization work (MFCC / fusion / SpeakerModel / SpeakerLabeler / SpeakerStudy) is already
compliant and warning-clean; items below are the remaining debt.

## Open (noted for later)

- [ ] **Project-wide `-Werror` + static analyzer (Rule 10).** We did NOT flip
      `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` in `project.yml` because the pre-existing app/UI code base has
      not been swept yet and it would break the build. Plan: fix the remaining warnings below, then enable
      `-Werror` for the `ATCTranscribe` target (and add a `swiftlint`/`xcodebuild analyze` CI step run
      "daily" per Rule 10). Scope: whole `ios/ATCTranscribe` tree.
- [ ] **Power-of-Ten sweep of pre-existing modules.** Rules were applied to code authored/edited in the
      diarization work. Not yet applied to older modules (`VADSegmenter`, `AppModel`, `LivePipeline`
      bodies, SwiftUI views). These use unbounded `.map`/closures and lack the loop-bound asserts. Sweep
      target-by-target when each is next touched.

## Fixed this session

- [x] `AppModel.swift:1093` — `immutable value 'session' was never used` (guard binding). Fixed:
      `guard let session,` → `guard session != nil,` (keeps the nil-check, drops the unused binding).
- [x] `TranscriptView.swift:118–120` — `onChange(of:perform:)` deprecated in iOS 17. Fixed: migrated to
      the two-parameter `onChange(of:) { _, _ in … }` form.

## Stage 5b (ECAPA → Core ML)

DONE this session:
- [x] Export tooling: `python-legacy/dataset/export_ecapa_coreml.py` (torch-vs-CoreML cosine validation).
- [x] **Validated model:** `~/CommSight/atc-coreml/ecapa/ECAPA.mlpackage` (80 MB, fp32) — input
      `features [1,298,80]` (fbank), output `embedding [1,192]` RAW. Reload-from-disk cosine vs torch
      = **1.00000**. Run: `~/CommSight/coreml-venv/bin/python -m dataset.export_ecapa_coreml`.
- [x] `CoreMLSpeakerEmbedder.swift` — NASA-compliant, fail-safe Core ML inference (compiles; inert
      until the model is bundled).

Gotchas discovered (documented so nobody re-hits them):
- Needs **torch ≤ 2.7** (dedicated `~/CommSight/coreml-venv`; the spike venv's torch 2.13 crashes the
  converter on an int-cast op). The waveform/features modes hit un-converting STFT / `mean_var_norm`
  int-cast ops → export only the **embedding** body; do fbank + sentence CMVN in Swift.
- **fp32 is required.** fp16 makes ECAPA's attentive-pooling sums-of-squares overflow (max 65504) →
  all-zero embedding. Do NOT L2-normalize inside the model (same overflow) — Swift normalizes.
- SpeechBrain's lazy-import installs a broken excepthook (k2) that masks real errors — the export
  script now restores `sys.__excepthook__`.

COMPLETED this session (waveform export removed the whole fbank-parity problem):
- [x] **Waveform model** — under torch 2.7 the STFT+fbank+ECAPA converts, so the model takes RAW
      16 kHz audio and Swift needs NO feature front-end (correct by construction; cosine 1.0 vs torch
      on real clips). Made the exporter default to `--mode waveform`.
- [x] `CoreMLSpeakerEmbedder` rewritten for raw audio; `.mlmodelc` compiled + bundled in
      `Resources/Models` (loads in the sim; 4 embedder tests + 2 backend tests green).
- [x] Optional `SpeakerModel(embedder:)` backend with backend-aware thresholds (MFCC ~0.05 vs ECAPA
      ~0.55); `Diarizer` reads `speaker.mergeDist`. Default stays MFCC (all existing tests unchanged).
- [x] Wired to the experimental toggle: `AppModel.acousticFillEnabled` → the embedder is loaded
      OFF-main and INJECTED as `LivePipeline(embedder:)` (red-team fix: was `useECAPA:` with a
      synchronous 80 MB load inside the actor init on the main actor). Default-off, no live latency
      regression. UI test drives it end-to-end. The fill-guard distance is now backend-scaled
      (`SpeakerModel.fillMatchMax`: 0.03 MFCC / 0.45 ECAPA) — a single 0.03 constant previously made
      the ECAPA fill path silently inert.
- [x] `SpeakerStudy` re-run with ECAPA: **EER ~40% at t=0.60** (within-ctrl median 0.51 vs
      ctrl-vs-pilot 0.69) vs MFCC's ~53%. Real improvement, but still can't cleanly separate same-feed
      controller-vs-pilot → acoustic fill stays DEFAULT-OFF; ECAPA is the better *experimental* backend.

Productization notes (for a real ship, not blockers):
- [ ] The bundle grew +80 MB (fp32 model). Shrink via selective precision (fp16 everywhere except the
      overflow-prone attentive-pooling ops), or download-on-demand when the user opts into the toggle.
- [ ] ECAPA adds per-transmission inference (~0.1 s/embed on the sim CPU; the Diarizer fingerprints a
      few pieces/segment). Fine for the opt-in toggle on the ANE; profile before any default-on.

## Policy for new warnings

Any warning encountered while editing is either fixed in the same change or added to "Open" above with the
file:line and reason. Code authored under the Power-of-Ten standard must compile with zero warnings.
