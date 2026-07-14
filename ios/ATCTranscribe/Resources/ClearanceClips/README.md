# Clearance Test Bench — audio clips

The Clearance Test Bench (Settings → tap the version 7× → **Clearance test bench**) runs each
scenario in **transcript-injection mode** by default: the scripted ATC text is fed straight through
the live parser → ownship gate → plan amendment, deterministically, with no audio. That validates
everything *after* speech-to-text — which is what regresses when we add features.

**Audio-clip mode** is the slot for testing the *speech model itself* end-to-end (VAD → Whisper →
correction → detector) on real radio audio. It is wired to reuse the existing `.replay` audio path
(`ArrayAudioSource`), the same one the demo clips use, so a bundled clip plays through the identical
pipeline a live feed would.

## Adding clips

1. Drop mono WAV files here (any sample rate — decoded to 16 kHz mono on load, like `Resources/DemoClips`).
2. Reference each clip from a scenario's `ScriptedTransmission(clip:)` field in
   `Diagnostics/ClearanceScenarioCatalog.swift` — the target clearance clip plus, ideally, a couple of
   decoy filler clips to other aircraft.
3. Regenerate the Xcode project (`xcodegen`) so the new resources are bundled.

### What makes a good clip

- A **real** ATC transmission that gives **our test aircraft's callsign** an actionable clearance
  (direct-to a fix/airport, or a SID/STAR/approach) — and matches the scenario's `airport` context so
  the fix/procedure grounds against CIFP.
- Because a controllable, callsign-matching clip is hard to source, curate from the collected US ATC
  corpus (the collector's 10.95h) rather than trying to catch one live. Trim to the single exchange.
- Keep decoy clips genuinely to *other* aircraft — the fail-safe scenarios prove the app ignores them.

## Why audio mode is non-deterministic

Whisper output varies slightly run-to-run, so an audio scenario asserts *observationally* (did a
sensible suggestion fire?) rather than pinning exact text. Transcript mode remains the strict
regression gate; audio mode is the ASR reality check when swapping speech models.

No clips are bundled yet — the bench runs transcript mode until clips are added here.
