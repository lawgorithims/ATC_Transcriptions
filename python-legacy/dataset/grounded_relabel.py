"""Grounded RE-LABELER (idea 4, quarantined) — post-process the collector's EXISTING
`us_pseudo/scores.jsonl` into a separate `us_grounded/manifest.jsonl`. No re-decode, no GPU,
no change to the running collector: it only reads the two decodes (`text_a`/`text_b`) already
stored per clip + the block's ADS-B `traffic.json`, snaps both callsigns to the real traffic,
and merges them to `<unk>` on disagreement (`assemble_grounded_label`).

Why this recovers data: the live consensus gate REJECTS a clip whole when the two models
disagree past `max_cer`. Here a partial disagreement instead survives as a label with the
disputed span marked `<unk>` (for the Phase-3 LLM gap-fill), so partial-agreement clips the
collector discards become usable — with model uncertainty explicit, never guessed.

Quarantine: writes ONLY under `us_grounded/`; `us_pseudo/` is never touched.

Run:  python -m dataset.grounded_relabel            # full pass, prints stats
      python -m dataset.grounded_relabel --limit 500 --dry   # sample, no write
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from dataset.grounded_label import UNK, agreement_ratio, assemble_grounded_label  # noqa: E402

DATA = Path("/Users/bsusl/CommSight/atc-data")
SCORES = DATA / "us_pseudo" / "scores.jsonl"
OUT_DIR = DATA / "us_grounded"
SEG_DIR = DATA / "segments"
RAW_DIR = DATA / "raw_us"

# Reuse the collector's own accept-gate signals so we never grade up junk the pipeline rejects.
MAX_NO_SPEECH = 0.30
MAX_COMPRESSION = 2.4
MIN_DUR, MAX_DUR = 0.8, 12.0
MIN_AGREEMENT = 0.60   # >=60% of merged words must be agreed (rest are <unk>)
MIN_REAL_WORDS = 2     # at least 2 non-<unk> words


def load_traffic_index() -> dict:
    """block_id -> list[str] spoken ADS-B callsigns present while that block recorded."""
    idx: dict = {}
    for tj in glob.glob(str(RAW_DIR / "**" / "*.traffic.json"), recursive=True):
        try:
            d = json.load(open(tj))
        except Exception:
            continue
        block = os.path.basename(tj)[: -len(".traffic.json")]
        sp = d.get("spoken") or []
        if sp:
            idx[block] = sp
    return idx


def load_segment_index() -> dict:
    """(block_id, idx) -> wav path, for resolving a clip id to its audio."""
    idx: dict = {}
    for wav in glob.glob(str(SEG_DIR / "*" / "*" / "*" / "*.wav")):
        p = Path(wav)
        idx[(p.parent.name, p.stem)] = wav
    return idx


def _gates_ok(r: dict) -> bool:
    ta, tb = (r.get("text_a") or "").strip(), (r.get("text_b") or "").strip()
    if not ta or not tb:
        return False
    try:
        if float(r.get("no_speech_prob_a", 0) or 0) > MAX_NO_SPEECH:
            return False
        if float(r.get("compression_ratio_a", 0) or 0) > MAX_COMPRESSION:
            return False
        dur = float(r.get("duration_s", 0) or 0)
        if not (MIN_DUR <= dur <= MAX_DUR):
            return False
    except (TypeError, ValueError):
        return False
    return True


def relabel(limit: int = 0, write: bool = True) -> dict:
    traffic = load_traffic_index()
    segs = load_segment_index()
    st = dict(seen=0, gated_out=0, low_agreement=0, no_audio=0,
              kept=0, clean=0, needs_fill=0, grounded=0, unk_words=0, tot_words=0,
              accepted_in_pseudo=0)
    out_f = None
    if write:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        out_f = open(OUT_DIR / "manifest.jsonl", "w")
    for line in open(SCORES):
        if not line.strip():
            continue
        r = json.loads(line)
        st["seen"] += 1
        if str(r.get("accepted")) == "True":
            st["accepted_in_pseudo"] += 1
        if limit and st["seen"] > limit:
            st["seen"] -= 1
            break
        if not _gates_ok(r):
            st["gated_out"] += 1
            continue
        cands = traffic.get(r.get("src_block")) or []
        label = assemble_grounded_label(r["text_a"], r["text_b"], cands)
        if not label:
            st["gated_out"] += 1
            continue
        toks = label.split()
        n_unk = toks.count(UNK)
        real = len(toks) - n_unk
        if real < MIN_REAL_WORDS:
            st["low_agreement"] += 1
            continue
        agr = real / len(toks)
        if agr < MIN_AGREEMENT:
            st["low_agreement"] += 1
            continue
        block, _, idx = str(r["id"]).rpartition("__")
        audio = segs.get((block, idx))
        if not audio:
            st["no_audio"] += 1
            continue
        rec = dict(audio=audio, text=label, id=r["id"], src_block=r.get("src_block"),
                   agreement=round(agr, 3), unk=n_unk, grounded=bool(cands),
                   dur_s=float(r.get("duration_s", 0) or 0))
        if out_f:
            out_f.write(json.dumps(rec) + "\n")
        st["kept"] += 1
        st["unk_words"] += n_unk
        st["tot_words"] += len(toks)
        st["clean" if n_unk == 0 else "needs_fill"] += 1
        if cands:
            st["grounded"] += 1
    if out_f:
        out_f.close()
    return st


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry", action="store_true", help="don't write us_grounded, just report")
    a = ap.parse_args()
    s = relabel(limit=a.limit, write=not a.dry)
    print("\n=== grounded relabel ===")
    print(f"  scanned            : {s['seen']}")
    print(f"  (accepted in pseudo): {s['accepted_in_pseudo']}   <- current pipeline yield")
    print(f"  gated out (quality) : {s['gated_out']}")
    print(f"  dropped low-agree   : {s['low_agreement']}")
    print(f"  no audio on disk    : {s['no_audio']}")
    print(f"  KEPT                : {s['kept']}   <- grounded yield")
    print(f"    clean (no <unk>)  : {s['clean']}   (immediately trainable)")
    print(f"    needs LLM fill    : {s['needs_fill']}   (has <unk>)")
    print(f"    ADS-B grounded    : {s['grounded']}")
    if s['tot_words']:
        print(f"  <unk> word rate     : {100*s['unk_words']/s['tot_words']:.1f}%")
    if not a.dry:
        print(f"  wrote               : {OUT_DIR/'manifest.jsonl'}")
