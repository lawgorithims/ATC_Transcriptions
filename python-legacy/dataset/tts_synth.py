"""
OPTIONAL (Phase 4): synthetic US ATC data with perfect labels.

Generates realistic US phraseology from the airport config (real runways /
frequencies / based airlines), using the project's existing spoken-form generators,
then (optionally) synthesizes it with a TTS engine and degrades it with radio
effects so it resembles VHF audio.

Why it COMPLEMENTS pseudo-labels (not replaces): TTS has perfect, exhaustive US
vocabulary coverage and clean labels (great for diluting pseudo-label noise), but
lacks real pilot accents, mic clipping, and stepped-on transmissions. Keep it a
minority of the training mix (~20-30%).

The TEXT generation is fully runnable with no extra dependencies. The TTS step is
pluggable: ``synthesize_piper`` shells out to Piper (offline, free) if installed;
otherwise wire your own ``synthesize`` callable.
"""

from __future__ import annotations

import random
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional

import json

import numpy as np

from airport_context.airlines import telephony_map
from airport_context.callsigns import parse_callsign
from airport_context.spoken import frequency_spoken, runway_spoken, speak_digits

from dataset import normalize

SAMPLE_RATE = 16000


@dataclass
class SynthTransmission:
    text: str          # spoken phraseology (also the TTS input)
    label: str         # normalized label (training target)
    role: str          # "controller" | "pilot"


def _random_callsign() -> str:
    """A random airline (from the telephony map) flight number, or an N-tail."""
    if random.random() < 0.7:
        icao = random.choice(list(telephony_map().keys()))
        number = str(random.randint(1, 4999))
        return f"{icao}{number}"
    # tail number: N + 3-4 alphanumerics
    body = "".join(random.choice("0123456789") for _ in range(random.randint(2, 3)))
    suffix = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(random.randint(1, 2)))
    return f"N{body}{suffix}"


def _spoken_callsign(raw: str) -> str:
    cs = parse_callsign(raw)
    return cs.spoken[0] if cs.spoken else raw


def _heading() -> str:
    return speak_digits(f"{random.randint(1, 360):03d}")


def _altitude() -> str:
    # flight levels / thousands, spoken digit-by-digit
    return speak_digits(f"{random.choice([3, 5, 7, 10, 12, 17, 24, 35]) * 1000}")


def generate_transmissions(
    airport_config: Path, n: int, *, seed: Optional[int] = None
) -> List[SynthTransmission]:
    """Compose ``n`` realistic transmissions from an airport config."""
    if seed is not None:
        random.seed(seed)
    cfg = json.loads(Path(airport_config).read_text(encoding="utf-8"))
    runways = cfg.get("runways") or ["18L", "18R", "36L", "36R"]
    freqs = list((cfg.get("frequencies") or {}).values()) or ["121.9"]

    out: List[SynthTransmission] = []
    for _ in range(n):
        cs = _spoken_callsign(_random_callsign())
        rwy = runway_spoken(random.choice(runways))
        freq = frequency_spoken(random.choice(freqs))
        kind = random.choice(["clearance", "tower_dep", "tower_arr", "approach", "ground", "readback"])

        if kind == "clearance":
            text = f"{cs} cleared to the airport as filed climb and maintain {_altitude()} expect {_altitude()} one zero minutes after departure"
            role = "controller"
        elif kind == "tower_dep":
            text = f"{cs} {rwy} cleared for takeoff fly heading {_heading()}"
            role = "controller"
        elif kind == "tower_arr":
            text = f"{cs} {rwy} cleared to land wind {_heading()} at {speak_digits(str(random.randint(3, 18)))}"
            role = "controller"
        elif kind == "approach":
            text = f"{cs} turn left heading {_heading()} descend and maintain {_altitude()} contact tower {freq}"
            role = "controller"
        elif kind == "ground":
            text = f"{cs} {rwy} taxi to via alpha hold short {rwy}"
            role = "controller"
        else:  # pilot readback
            text = f"cleared for takeoff {rwy} {cs}"
            role = "pilot"

        text = re.sub(r"\s+", " ", text).strip()
        out.append(SynthTransmission(text=text, label=normalize.normalize_transcript(text), role=role))
    return out


# --- audio side -------------------------------------------------------------

def radio_degrade(audio: np.ndarray, *, snr_db: float = 12.0, seed: Optional[int] = None) -> np.ndarray:
    """Degrade clean TTS audio toward VHF: band-limit, add noise, light clipping.

    Reuses the project's ``AudioPreprocessor`` (aggressive radio band) to band-limit,
    then mixes additive Gaussian noise at the requested SNR and applies soft clipping
    to mimic radio compression/over-deviation.
    """
    from audio_preprocessing import AudioPreprocessor

    rng = np.random.default_rng(seed)
    audio = np.asarray(audio, dtype=np.float32)
    pre = AudioPreprocessor(sample_rate=SAMPLE_RATE, aggressive_radio=True)
    band = pre.preprocess(audio)

    sig_power = float(np.mean(band ** 2)) or 1e-9
    noise_power = sig_power / (10 ** (snr_db / 10.0))
    noise = rng.normal(0.0, np.sqrt(noise_power), size=band.shape).astype(np.float32)
    mixed = band + noise

    # Soft clip (tanh) to imitate radio peak limiting.
    drive = random.uniform(1.5, 3.0)
    mixed = np.tanh(mixed * drive) / np.tanh(drive)
    peak = float(np.max(np.abs(mixed))) or 1.0
    return (mixed / peak * 0.95).astype(np.float32)


def synthesize_piper(
    text: str, out_wav: Path, *, piper_bin: str = "piper", model: Optional[str] = None
) -> Path:
    """Synthesize ``text`` to a 16 kHz WAV with Piper (offline). Raises if absent."""
    out_wav = Path(out_wav)
    out_wav.parent.mkdir(parents=True, exist_ok=True)
    cmd = [piper_bin, "--output_file", str(out_wav)]
    if model:
        cmd += ["--model", model]
    try:
        subprocess.run(cmd, input=text.encode("utf-8"), check=True, capture_output=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(
            "Piper TTS not available. Install piper-tts and pass --piper-bin/--model, "
            "or supply your own `synthesize` callable."
        ) from exc
    return out_wav


def build_synthetic_set(
    airport_config: Path,
    out_root: Path,
    n: int,
    *,
    synthesize: Optional[Callable[[str, Path], Path]] = None,
    seed: Optional[int] = None,
) -> int:
    """Generate ``n`` synthetic examples (text + audio) in the training format.

    ``synthesize(text, wav_path)`` produces clean speech; we then radio-degrade it.
    Defaults to Piper. Writes the same manifest/transcripts layout as the pseudo-label
    pipeline so the data drops straight into training.
    """
    import soundfile as sf

    from dataset.emit_metadata import MetadataWriter

    synth = synthesize or (lambda t, p: synthesize_piper(t, p))
    out_root = Path(out_root)
    audio_dir = out_root / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    writer_dir = out_root
    transcripts = writer_dir / "transcripts"
    transcripts.mkdir(parents=True, exist_ok=True)
    manifest = writer_dir / "manifest.jsonl"

    items = generate_transmissions(airport_config, n, seed=seed)
    written = 0
    with manifest.open("a", encoding="utf-8") as mf:
        for i, item in enumerate(items):
            sid = f"synth_{Path(airport_config).stem}_{i:05d}"
            clean = audio_dir / f"{sid}.clean.wav"
            synth(item.text, clean)
            audio, sr = sf.read(str(clean), dtype="float32")
            if sr != SAMPLE_RATE:
                import librosa

                audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
            degraded = radio_degrade(audio, snr_db=random.uniform(6.0, 18.0))
            wav = audio_dir / f"{sid}.wav"
            sf.write(str(wav), degraded, SAMPLE_RATE)
            clean.unlink(missing_ok=True)
            tpath = transcripts / f"{sid}.txt"
            tpath.write_text(item.label + "\n", encoding="utf-8")
            mf.write(json.dumps({
                "id": sid, "audio_path": str(wav), "transcript_path": str(tpath),
                "role": item.role, "synthetic": True,
            }) + "\n")
            written += 1
    return written
