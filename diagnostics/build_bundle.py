"""
Build a self-contained ~100-sample benchmark bundle from the held-out
ATCO2+ATCoSIM validation split (data/atc_combined/val_metadata.json).

Output (default diagnostics/bundle/):
    audio/<id>.wav            # copied audio files
    bench_metadata.json       # [{id, audio, reference, source}, ...]

The bundle is fully self-contained: references are inlined (read from the
transcript .txt files) so the target machine needs no transcript files or
original directory layout. Selection is seeded-random for reproducibility.
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def source_of(sample_id: str) -> str:
    sid = sample_id.lower()
    if sid.startswith("atcosim"):
        return "atcosim"
    if sid.startswith("atco2"):
        return "atco2"
    return "other"


def main() -> int:
    p = argparse.ArgumentParser(description="Build a benchmark bundle from the val split.")
    p.add_argument("--data-dir", default=str(ROOT / "data"))
    p.add_argument("--metadata", default="atc_combined/val_metadata.json")
    p.add_argument("--out", default=str(ROOT / "diagnostics" / "bundle"))
    p.add_argument("--n", type=int, default=100)
    p.add_argument("--seed", type=int, default=0)
    args = p.parse_args()

    data_dir = Path(args.data_dir)
    meta_path = data_dir / args.metadata
    entries = json.loads(meta_path.read_text(encoding="utf-8"))
    print(f"Loaded {len(entries)} validation entries from {meta_path}")

    out = Path(args.out)
    audio_out = out / "audio"
    audio_out.mkdir(parents=True, exist_ok=True)

    order = list(range(len(entries)))
    random.Random(args.seed).shuffle(order)

    bundle = []
    sources = {}
    total_bytes = 0
    for idx in order:
        if len(bundle) >= args.n:
            break
        item = entries[idx]
        audio_path = data_dir / item["audio_path"]
        transcript_path = data_dir / item["transcript_path"]
        if not audio_path.exists() or not transcript_path.exists():
            continue
        reference = transcript_path.read_text(encoding="utf-8").strip()
        if not reference:
            continue
        sid = item["id"]
        dest = audio_out / f"{sid}.wav"
        shutil.copyfile(audio_path, dest)
        total_bytes += dest.stat().st_size
        src = source_of(sid)
        sources[src] = sources.get(src, 0) + 1
        bundle.append({
            "id": sid,
            "audio": f"audio/{sid}.wav",
            "reference": reference,
            "source": src,
        })

    (out / "bench_metadata.json").write_text(
        json.dumps(bundle, indent=2), encoding="utf-8"
    )

    print(f"Wrote {len(bundle)} samples to {out}")
    print(f"  Sources: {sources}")
    print(f"  Audio total: {total_bytes / 1_048_576:.1f} MB")
    if len(bundle) < args.n:
        print(f"  NOTE: only {len(bundle)} valid samples found (requested {args.n}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
