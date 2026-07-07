"""Measure the LLM correction tier's effect on the gold set, world-model prompt + RAG.

Per clip: the airport ident primes the WORLD frame through the real provider chain
(runways / frequencies / fixes / facility name), the deterministic snap chain runs first
(its verdicts become the grounding block), same-block neighbors provide history and the
expected-readback slot, then Qwen2.5-0.5B corrects under the mirrored validator guardrails.

Arms:
  world    — full WORLD frame (the shipped design)
  minimal  — transcript-only frame (same system prompt): isolates the live-data effect

Usage (from python-legacy/):
    python -m dataset.llm_eval --gold <gold_testset.jsonl> \
        --hyps <gold_hyps_small_v1.jsonl> --arm world [--limit 3]
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from airport_data import default_source
from callsign_snap import snap_transcript
from slot_snap import snap_slots
import llm_worldfix as W

from dataset.scoreboard import load_gold, score_pairs, _canon_callsign


def grounding_block(cs_result, slot_edits, ctx) -> str:
    verified, unverified = [], []
    if cs_result is not None:
        if cs_result.verdict in ("verified_exact", "snapped") and cs_result.snapped:
            verified.append(f"callsign {cs_result.snapped}")
        elif cs_result.verdict == "unverified" and cs_result.original:
            unverified.append(f"callsign {cs_result.original}")
    for e in slot_edits:
        if e.verdict in ("verified", "snapped"):
            verified.append(f"{e.slot} {e.snapped or e.original}")
        elif e.verdict in ("unverified", "invalid"):
            unverified.append(f"{e.slot} {e.original}")
    ident = ctx.ident if ctx else "this facility"
    lines = []
    if verified:
        lines.append("Verified against live data (do NOT alter): " + "; ".join(verified) + ".")
    if unverified:
        lines.append(f"Heard but NOT verified at {ident} (fix only with strong evidence): "
                     + "; ".join(unverified) + ".")
    if ctx and ctx.runways:
        lines.append(f"Runways at {ident}: " + ", ".join(ctx.runways[:14]) + ".")
    return "\n".join(lines)


def knowledge_block(ctx, fixes) -> str:
    if ctx is None:
        return ""
    lines = []
    if ctx.name:
        lines.append(f"Facility: {ctx.name} ({ctx.ident}).")
    if ctx.runways:
        lines.append("Runways: " + ", ".join(ctx.runways[:14]))
    if fixes:
        lines.append("Fixes: " + ", ".join(fixes[:12]))
    freqs = [f for f in ctx.frequency_values if 118.0 <= f <= 136.975]
    if freqs:
        lines.append("Frequencies: " + ", ".join(f"{f:g}" for f in freqs[:10]))
    return "\n".join(lines)


def allowed_terms(ctx, fixes) -> set:
    words = {"runway", "tower", "ground", "approach", "departure", "center", "contact",
             "heading", "cleared", "land", "takeoff", "taxi", "hold", "short", "squawk",
             "maintain", "altimeter", "traffic", "frequency", "left", "right"}
    if ctx:
        for r in ctx.runways:
            words.add(r.lower())
        for w in (ctx.name or "").lower().split():
            words.add("".join(c for c in w if c.isalnum()))
    for f in fixes or []:
        words.add(f.lower())
    try:
        from airport_context.airlines import telephony_map
        for name in telephony_map().values():
            for w in str(name).lower().split():
                words.add(w)
    except Exception:
        pass
    return {w for w in words if w}


def config_fixes(ident: str) -> list:
    p = _HERE / "airport_configs" / f"{ident.lower()}.json"
    if not p.exists():
        return []
    cfg = json.loads(p.read_text(encoding="utf-8"))
    return cfg.get("fixes") or cfg.get("waypoints") or []


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--hyps", required=True, type=Path)
    ap.add_argument("--arm", choices=["world", "minimal"], default="world")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--emit-frames", type=Path, default=None,
                    help="write per-clip world frames as JSON for the Swift/Apple-FM "
                         "probe (ATCKitProbe fm-eval) instead of running the local LLM")
    args = ap.parse_args(argv)

    gold = load_gold(args.gold)
    cs_candidates = sorted({c for g in gold.values() if (c := _canon_callsign(g["ref"]))})
    source = default_source(download=False)

    rows = []
    for line in args.hyps.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        h = json.loads(line)
        g = gold.get(h["id"])
        if g:
            rows.append({"id": h["id"], "airport": (g.get("airport") or "").upper(),
                         "ref": g["ref"], "hyp": h["hyp"],
                         "block": h["id"].rsplit("__", 1)[0],
                         "idx": int(h["id"].rsplit("__", 1)[1])})
    rows.sort(key=lambda r: (r["block"], r["idx"]))
    if args.limit:
        rows = rows[: args.limit]

    ctx_cache, fixes_cache = {}, {}
    for r in rows:
        a = r["airport"]
        if a not in ctx_cache:
            try:
                ctx_cache[a] = source.airport(a)
            except Exception:
                ctx_cache[a] = None
            fixes_cache[a] = config_fixes(a)

    if args.emit_frames:
        # Frames for the Apple-FM probe: the deterministic snap chain runs HERE
        # (Python is the chain's reference), the probe runs only the FM corrector.
        # Grounding verified/unverified lines ride inside `knowledge`; the runway
        # list is passed separately so the Swift validator's veto is armed.
        frames, block_prior = [], {}
        for r in rows:
            ctx = ctx_cache[r["airport"]]
            t1, cs = snap_transcript(r["hyp"], cs_candidates)
            base, slot_edits = snap_slots(t1, ctx)
            gb = grounding_block(cs, slot_edits, ctx)
            # drop the runways line (the Swift side renders it from `runways`)
            gb_lines = [l for l in gb.split("\n") if not l.startswith("Runways at")]
            know = knowledge_block(ctx, fixes_cache[r["airport"]])
            if gb_lines:
                know = (know + "\n" if know else "") + "\n".join(gb_lines)
            prior = block_prior.get(r["block"], [])
            frames.append({
                "id": r["id"], "transcript": base, "knowledge": know,
                "readback": prior[-1] if prior else None,
                "history": prior[-2:],
                "airport": r["airport"],
                "runways": (ctx.runways if ctx else []),
                "vocab": sorted(allowed_terms(ctx, fixes_cache[r["airport"]])),
            })
            block_prior.setdefault(r["block"], []).append(base)
        args.emit_frames.write_text(json.dumps(frames, indent=1), encoding="utf-8")
        print(f"wrote {len(frames)} frames -> {args.emit_frames}")
        return 0

    backend = W.QwenBackend()
    print(f"{len(rows)} clips | arm={args.arm}", flush=True)

    out_rows, block_outputs = [], {}
    t0 = time.time()
    readback_used = llm_changed = 0
    for i, r in enumerate(rows):
        ctx = ctx_cache[r["airport"]]
        # deterministic snap chain first (exactly like the app)
        t1, cs = snap_transcript(r["hyp"], cs_candidates)
        base, slot_edits = snap_slots(t1, ctx)

        if args.arm == "world":
            prior = block_outputs.get(r["block"], [])
            frame = W.WorldFrame(
                knowledge=knowledge_block(ctx, fixes_cache[r["airport"]]),
                grounding_block=grounding_block(cs, slot_edits, ctx),
                expected_readback=prior[-1] if prior else None,
                history=prior[-2:],
                transcript=base)
            if prior:
                readback_used += 1
        else:
            frame = W.WorldFrame(transcript=base)

        raw_out = backend.generate(frame)
        edits = W.parse_edits(raw_out)
        grounded_runways = None
        if ctx and ctx.runways:
            grounded_runways = W._runway_keys("runway " + " runway ".join(
                d.lower() for d in ctx.runways))
        final, applied = W.apply_validated(base, edits,
                                           allowed_terms(ctx, fixes_cache[r["airport"]]),
                                           grounded_runways)
        if applied:
            llm_changed += 1
        out_rows.append({"id": r["id"], "ref": r["ref"], "hyp": final,
                         "edits": applied})
        block_outputs.setdefault(r["block"], []).append(final)
        if (i + 1) % 10 == 0:
            print(f"  {i+1}/{len(rows)} ({time.time()-t0:.0f}s, "
                  f"llm-changed={llm_changed})", flush=True)

    refs = [r["ref"] for r in out_rows]
    base_scores = score_pairs("snaps-only", refs, [
        snap_slots(snap_transcript(r["hyp"], cs_candidates)[0], ctx_cache[r["airport"]])[0]
        for r in rows])
    llm_scores = score_pairs(f"+llm-{args.arm}", refs, [r["hyp"] for r in out_rows])

    def pct(x):
        return f"{(x or 0) * 100:.1f}%"

    print(f"\nsnaps-only : canonWER {pct(base_scores.canon_wer)}  CSA {pct(base_scores.csa)}  "
          f"falseCS {pct(base_scores.false_cs_rate)}")
    print(f"+llm-{args.arm:7s}: canonWER {pct(llm_scores.canon_wer)}  CSA {pct(llm_scores.csa)}  "
          f"falseCS {pct(llm_scores.false_cs_rate)}")
    print(f"llm changed {llm_changed}/{len(rows)} clips | readback slot used {readback_used}x "
          f"| {time.time()-t0:.0f}s total")

    out = args.out or args.hyps.with_name(args.hyps.stem + f"_llm_{args.arm}.jsonl")
    out.write_text("\n".join(json.dumps(x) for x in out_rows) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
