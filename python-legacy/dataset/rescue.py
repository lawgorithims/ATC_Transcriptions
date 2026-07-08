"""Rescue tier + accepted-label auditor: a third, architecture-decorrelated
transcription voice (OpenAI `gpt-4o-mini-transcribe`, "voice C") re-judges the
data engine's decisions — offline, batch, zero coupling to the collector.

Two co-equal arms (approved plan addendum, 2026-07-07):

  * ``run``   — RESCUE: re-examine `low_consensus` rejects (50% of all
    rejections). If C agrees with one Whisper voter (CER <= rescue.max_cer),
    the segment is rescued into a SEPARATE tier `us_pseudo_rescued/` — the
    label is always the agreeing WHISPER side's text, never C's (C judges,
    it does not write: contamination guard AND the defensible posture on
    OpenAI's no-distillation clause).
  * ``audit`` — AUDITOR: C re-decodes ACCEPTED labels and flags
    consensus_cer(C, label) > audit.flag_cer as correlated-Whisper-wrong
    suspects. Under the June "label noise is the binding constraint"
    hypothesis this is plausibly the higher-value arm.

Phase 0 (kill-gate) is DONE: on gold v0, gpt-4o-mini-transcribe scored 28.2%
canonWER (PASS, 1.44x teacher) while gpt-4o-transcribe scored 54.0% (KILLED —
systemic truncation on hard radio). Hence mini as primary, no flagship.

Key from ``~/.openai_key`` (never in the repo). Costs are estimated and
capped per day (rescue.daily_cost_cap_usd); every call lands in the audit
ledger. All I/O is stdlib urllib (project convention, traffic_snapshot.py).

Usage (from python-legacy/):
    python -m dataset.rescue run    --config dataset/config.yaml [--dry-run] [--limit N]
    python -m dataset.rescue audit  --config dataset/config.yaml [--limit N]
    python -m dataset.rescue report --config dataset/config.yaml
    python -m dataset.rescue spotcheck --config dataset/config.yaml --rescued 30 --accepted 20
"""

from __future__ import annotations

import json
import random
import sys
import time
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

import yaml

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from dataset import normalize
from dataset.bulk_capture import SegmentRecord
from dataset.emit_metadata import MetadataWriter
from dataset.gold_builder import _find_clip
from dataset.pseudo_label import LabelDecision
from dataset.traffic_snapshot import load_snapshot

API_URL = "https://api.openai.com/v1/audio/transcriptions"
KEY_PATHS = [Path.home() / ".openai_key"]
EST_USD_PER_MIN = 0.003   # gpt-4o-mini-transcribe, approximate — ledger, not billing


def _defaults(cfg: dict) -> dict:
    r = dict(cfg.get("rescue") or {})
    r.setdefault("model", "gpt-4o-mini-transcribe")
    r.setdefault("max_cer", 0.15)
    r.setdefault("floor_avg_logprob", -1.2)
    r.setdefault("max_no_speech_prob", 0.30)
    r.setdefault("daily_cost_cap_usd", 2.0)
    r.setdefault("min_words", 2)
    r.setdefault("max_words", 60)
    r.setdefault("audit_flag_cer", 0.30)
    return r


def _api_key() -> str:
    for p in KEY_PATHS:
        if p.exists():
            return p.read_text(encoding="utf-8").strip()
    raise FileNotFoundError("~/.openai_key not found — stage the API key first")


def transcribe_c(model: str, wav_path: Path, key: str, retries: int = 5) -> str:
    """One transcription call: temp 0, no prompt, anonymous filename."""
    boundary = uuid.uuid4().hex
    wav = wav_path.read_bytes()
    parts = []
    for name, val in [("model", model), ("temperature", "0"), ("response_format", "json")]:
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{val}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
        f'filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + wav + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    for attempt in range(retries):
        try:
            req = urllib.request.Request(API_URL, data=body, headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}"})
            with urllib.request.urlopen(req, timeout=90) as resp:
                return json.load(resp)["text"]
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(3 * (attempt + 1))
    return ""


def sanity_ok(norm_c: str, r: dict) -> Optional[str]:
    """C-output sanity gates; returns a reject reason or None."""
    words = norm_c.split()
    if not words:
        return "c_empty"
    if not (r["min_words"] <= len(words) <= r["max_words"]):
        return "c_word_count"
    # LLM hallucination signature: a repeated 3-gram (3+ occurrences)
    grams = [" ".join(words[i:i + 3]) for i in range(len(words) - 2)]
    if grams and max(map(grams.count, set(grams))) >= 3:
        return "c_repetition"
    return None


@dataclass
class RescueVerdict:
    rescued: bool
    reason: str
    label: str = ""              # the agreeing WHISPER side's text (never C's)
    chosen_side: str = ""        # "a" | "b"
    cer_ca: float = 1.0
    cer_cb: float = 1.0


def judge(text_a: str, text_b: str, text_c: str, r: dict) -> RescueVerdict:
    """The decision rule: C as judge between the two Whisper voters."""
    norm_c = normalize.normalize_transcript(text_c)
    why = sanity_ok(norm_c, r)
    if why:
        return RescueVerdict(False, why)
    norm_a = normalize.normalize_transcript(text_a)
    norm_b = normalize.normalize_transcript(text_b)
    cer_ca = normalize.consensus_cer(norm_c, norm_a)
    cer_cb = normalize.consensus_cer(norm_c, norm_b)
    if min(cer_ca, cer_cb) > r["max_cer"]:
        return RescueVerdict(False, "no_agreement", cer_ca=cer_ca, cer_cb=cer_cb)
    side = "a" if cer_ca <= cer_cb else "b"
    return RescueVerdict(True, "rescued",
                         label=norm_a if side == "a" else norm_b,
                         chosen_side=side, cer_ca=cer_ca, cer_cb=cer_cb)


def prescreen(row: dict, r: dict) -> Optional[str]:
    """Gates that never ran on low_consensus rows (ordering fact); banked metrics."""
    nsp = row.get("no_speech_prob_a")
    if nsp is not None and nsp > r["max_no_speech_prob"]:
        return "pre_no_speech"
    for k in ("language_a", "language_b"):
        if row.get(k) not in (None, "en", "english"):
            return "pre_non_english"
    lp = row.get("avg_logprob_a")
    floor = r["floor_avg_logprob"]
    if floor is not None and lp is not None and lp < floor:
        return "pre_logprob_floor"
    return None


def _ledger_rows(out_root: Path):
    """Every row that cost an API call: real-run scores + dry-run verdicts.

    scores.jsonl nests the cost fields under decision.metrics (spread into the
    audit row by MetadataWriter); dryrun_verdicts.jsonl carries them top-level.
    """
    for name in ("scores.jsonl", "dryrun_verdicts.jsonl"):
        p = out_root / name
        if not p.exists():
            continue
        for line in p.read_text(encoding="utf-8").splitlines():
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _spent_today(out_root: Path) -> float:
    today = time.strftime("%Y-%m-%d")
    return sum(row.get("est_cost_usd") or 0.0 for row in _ledger_rows(out_root)
               if row.get("rescue_date") == today)


def _band(cer) -> str:
    if cer is None:
        return "?"
    if cer < 0.30:
        return "0.10-0.30"
    if cer < 0.50:
        return "0.30-0.50"
    return ">=0.50"


def cmd_run(args) -> int:
    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    r = _defaults(cfg)
    storage = Path(cfg["storage_root"]).expanduser()
    src_scores = storage / "us_pseudo" / "scores.jsonl"
    out_root = storage / "us_pseudo_rescued"
    writer = MetadataWriter(out_root)
    key = _api_key()

    from airport_data import default_source
    from dataset import label_gate
    import atc_diarize

    ctx_source = default_source(download=False)
    ctx_cache: dict = {}

    # resume across BOTH real and dry runs — every prior verdict cost money
    attempted = {row["id"] for row in _ledger_rows(out_root) if "id" in row}
    dryrun_path = out_root / "dryrun_verdicts.jsonl"

    rows = [json.loads(l) for l in src_scores.read_text(encoding="utf-8").splitlines()]
    cands = [x for x in rows if x.get("reason") == "low_consensus"
             and x["id"] not in attempted]
    if args.limit:
        cands = cands[: args.limit]
    print(f"low_consensus candidates: {len(cands)} (dry_run={args.dry_run})")

    stats: dict = {"rescued": 0, "examined": 0}
    spent = _spent_today(out_root)
    run_cost = 0.0
    for row in cands:
        if spent >= r["daily_cost_cap_usd"]:
            print(f"daily cost cap reached (${spent:.2f}) — stopping")
            break
        why = prescreen(row, r)
        if why:
            stats[why] = stats.get(why, 0) + 1
            continue
        clip = _find_clip(storage, row["id"], row.get("src_block") or "")
        if clip is None:
            stats["no_clip"] = stats.get("no_clip", 0) + 1
            continue
        stats["examined"] += 1
        try:
            text_c = transcribe_c(r["model"], clip, key)
        except Exception as exc:
            stats["api_error"] = stats.get("api_error", 0) + 1
            print(f"  api error on {row['id']}: {exc}")
            continue
        sidecar = clip.with_suffix(".json")
        seg_meta = json.loads(sidecar.read_text(encoding="utf-8")) if sidecar.exists() else {}
        dur = seg_meta.get("dur_s") or row.get("duration_s") or 8.0
        cost = dur / 60.0 * EST_USD_PER_MIN
        spent += cost
        run_cost += cost

        verdict = judge(row.get("text_a") or "", row.get("text_b") or "", text_c, r)
        label = verdict.label
        gate_reasons: List[str] = []
        cs_fix_info: List[str] = []
        if verdict.rescued:
            airport = (seg_meta.get("airport") or "").upper()
            if airport not in ctx_cache:
                try:
                    ctx_cache[airport] = ctx_source.airport(airport) if airport else None
                except Exception:
                    ctx_cache[airport] = None
            gate = label_gate.assess_label(label, ctx_cache.get(airport))
            gate_reasons = gate.reasons
            if not gate.ok:
                verdict = RescueVerdict(False, "slot_gate", cer_ca=verdict.cer_ca,
                                        cer_cb=verdict.cer_cb)
            else:
                # raw block path: {raw}/{airport}/{feed}/{date}/{src_block}.wav
                raw_hits = list(storage.glob(
                    f"raw_us/*/*/*/{row.get('src_block')}.wav"))
                candidates = load_snapshot(raw_hits[0]) if raw_hits else []
                if candidates:
                    # corroboration = the NON-chosen decode plus C itself
                    other = row.get("text_b") if verdict.chosen_side == "a" else row.get("text_a")
                    fix = label_gate.fix_callsign(
                        label, candidates,
                        corroboration=f"{other or ''} {text_c}")
                    if fix.fixed:
                        label = fix.label
                        cs_fix_info = fix.reasons

        stats["rescued"] += int(verdict.rescued)
        band_key = f"band_{_band(row.get('cer'))}_{'rescued' if verdict.rescued else 'no'}"
        stats[band_key] = stats.get(band_key, 0) + 1

        audit_fields = {
            "rescued_from": "low_consensus",
            "rescue_model": r["model"],
            "text_c": text_c,
            "cer_ca": round(verdict.cer_ca, 4),
            "cer_cb": round(verdict.cer_cb, 4),
            "chosen_side": verdict.chosen_side,
            "original_cer_ab": row.get("cer"),
            "slot_gate_reasons": gate_reasons,
            "callsign_snap": cs_fix_info,
            "est_cost_usd": round(cost, 5),
            "rescue_date": time.strftime("%Y-%m-%d"),
        }
        if args.dry_run:
            # bank the verdict: the band curve needs it, and a later real run
            # must not re-pay for a decode we already have
            with dryrun_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({
                    "id": row["id"], "would_rescue": verdict.rescued,
                    "reason": verdict.reason if not verdict.rescued else "rescued",
                    "label": label, **audit_fields}) + "\n")
        else:
            turn = atc_diarize.classify_turn(label) if verdict.rescued else None
            decision = LabelDecision(
                accepted=verdict.rescued,
                reason=verdict.reason if not verdict.rescued else "rescued",
                label=label,
                text_a=row.get("text_a") or "", text_b=row.get("text_b") or "",
                cer=min(verdict.cer_ca, verdict.cer_cb),
                avg_logprob=row.get("avg_logprob_a") or 0.0,
                role=(turn.role if turn else "unknown"),
                callsign=(turn.callsign if turn else None),
                role_confidence=(turn.confidence if turn else 0.0),
                metrics=audit_fields)
            seg = SegmentRecord(
                seg_id=row["id"], audio_path=str(clip),
                airport=seg_meta.get("airport") or "", feed=seg_meta.get("feed") or "",
                src_block=row.get("src_block") or "",
                offset_s=seg_meta.get("offset_s") or 0.0, dur_s=dur)
            writer.write(seg, decision)

    print(json.dumps(stats, indent=1, sort_keys=True))
    print(f"est. spend this run: ${run_cost:.3f}  (ledgered today: ${spent:.3f})")
    return 0


def cmd_audit(args) -> int:
    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    r = _defaults(cfg)
    storage = Path(cfg["storage_root"]).expanduser()
    manifest = storage / "us_pseudo" / "manifest.jsonl"
    out = storage / "us_pseudo_rescued" / "audit_accepted.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    key = _api_key()

    done = set()
    if out.exists():
        for line in out.read_text(encoding="utf-8").splitlines():
            try:
                done.add(json.loads(line)["id"])
            except Exception:
                pass

    rows = [json.loads(l) for l in manifest.read_text(encoding="utf-8").splitlines()]
    # oversample the uncertain band the plan calls out (cer 0.02-0.10 is easy;
    # the risk mass sits just under the 0.10 accept gate)
    rows.sort(key=lambda x: -(x.get("cer") or 0))
    rows = [x for x in rows if x["id"] not in done][: args.limit or 100]
    print(f"auditing {len(rows)} accepted labels (highest-CER first)")

    suspects = 0
    with out.open("a", encoding="utf-8") as fh:
        for row in rows:
            clip = Path(row["audio_path"])
            if not clip.exists():
                continue
            try:
                text_c = transcribe_c(r["model"], clip, key)
            except Exception as exc:
                print(f"  api error on {row['id']}: {exc}")
                continue
            label = Path(row["transcript_path"]).read_text(encoding="utf-8").strip()
            cer = normalize.consensus_cer(
                normalize.normalize_transcript(text_c), label)
            flag = cer > r["audit_flag_cer"]
            suspects += int(flag)
            fh.write(json.dumps({
                "id": row["id"], "flag": flag, "cer_c_label": round(cer, 4),
                "label": label, "text_c": text_c,
                "accept_cer_ab": row.get("cer"),
                "audit_date": time.strftime("%Y-%m-%d")}) + "\n")
    print(f"suspects flagged: {suspects}/{len(rows)} "
          f"(cer_c_label > {r['audit_flag_cer']}) -> {out}")
    return 0


def cmd_report(args) -> int:
    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    storage = Path(cfg["storage_root"]).expanduser()
    rows = list(_ledger_rows(storage / "us_pseudo_rescued"))
    if not rows:
        print("no rescue runs yet")
        return 0
    resc = [x for x in rows if x.get("accepted") or x.get("would_rescue")]
    spend = sum(x.get("est_cost_usd") or 0 for x in rows)
    print(f"attempted={len(rows)} rescued={len(resc)} est_spend=${spend:.2f}")
    from collections import Counter
    print("outcomes:", dict(Counter(x.get("reason") for x in rows)))
    for name, subset in (("rescued", resc), ("all judged", rows)):
        bands = Counter(_band(x.get("original_cer_ab")) for x in subset)
        print(f"{name} by original CER(A,B) band:", dict(sorted(bands.items())))
    return 0


def cmd_spotcheck(args) -> int:
    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    storage = Path(cfg["storage_root"]).expanduser()
    import shutil

    out_dir = storage / "rescue_spotcheck"
    (out_dir / "clips").mkdir(parents=True, exist_ok=True)

    def sample(manifest: Path, n: int, tier: str):
        rows = [json.loads(l) for l in manifest.read_text(encoding="utf-8").splitlines()]
        random.shuffle(rows)
        out = []
        for row in rows[:n]:
            src = Path(row["audio_path"])
            if not src.exists():
                continue
            dst = out_dir / "clips" / f"{row['id']}.wav"
            shutil.copyfile(src, dst)
            out.append({"id": row["id"], "tier": tier,
                        "clip": f"clips/{row['id']}.wav",
                        "label": Path(row["transcript_path"]).read_text(encoding="utf-8").strip()})
        return out

    items = (sample(storage / "us_pseudo_rescued" / "manifest.jsonl", args.rescued, "rescued")
             + sample(storage / "us_pseudo" / "manifest.jsonl", args.accepted, "accepted"))
    random.shuffle(items)
    blind = [{k: v for k, v in it.items() if k != "tier"} for it in items]
    (out_dir / "blind.jsonl").write_text(
        "\n".join(json.dumps(x) for x in blind), encoding="utf-8")
    (out_dir / "answer_key.jsonl").write_text(
        "\n".join(json.dumps(x) for x in items), encoding="utf-8")
    print(f"spot-check package: {len(items)} items -> {out_dir} "
          f"(review blind.jsonl; tiers in answer_key.jsonl)")
    return 0


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="OpenAI rescue tier + accepted-label auditor")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "audit", "report", "spotcheck"):
        p = sub.add_parser(name)
        p.add_argument("--config", required=True, type=Path)
        if name == "run":
            p.add_argument("--dry-run", action="store_true")
            p.add_argument("--limit", type=int, default=0)
        if name == "audit":
            p.add_argument("--limit", type=int, default=100)
        if name == "spotcheck":
            p.add_argument("--rescued", type=int, default=30)
            p.add_argument("--accepted", type=int, default=20)
    args = ap.parse_args(argv)
    return {"run": cmd_run, "audit": cmd_audit,
            "report": cmd_report, "spotcheck": cmd_spotcheck}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
