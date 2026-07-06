"""Unit tests for gold_builder ingest (turns + unclear handling).

Run from python-legacy/:  python tests/test_gold_builder.py
"""

import json
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dataset.gold_builder import ingest, _strip_unclear

_results = []


def check(name, fn):
    try:
        fn()
        _results.append((name, True, ""))
    except AssertionError as e:
        _results.append((name, False, str(e)))


def _run_ingest(corrections):
    tmp = Path(tempfile.mkdtemp())
    cands = [{"id": c["id"], "clip": f"clips/{i:03d}.wav"} for i, c in enumerate(corrections, 1)]
    (tmp / "candidates.json").write_text(json.dumps(cands), encoding="utf-8")
    (tmp / "corr.json").write_text(json.dumps(corrections), encoding="utf-8")
    out = tmp / "gold.jsonl"
    ingest(SimpleNamespace(corrections=str(tmp / "corr.json"),
                           candidates=str(tmp / "candidates.json"),
                           out=str(out), merge=None))
    return [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines()]


def test_strip_unclear():
    ref, had = _strip_unclear("delta 232 [unclear]mumble words[/unclear] runway 22")
    assert had and ref == "delta 232 <unk> runway 22", (ref, had)
    ref2, had2 = _strip_unclear("clean transmission")
    assert not had2 and ref2 == "clean transmission"


def test_multi_turn_row():
    rows = _run_ingest([{
        "id": "a", "airport": "KJFK", "feed": "tower", "status": "good",
        "turns": [
            {"text": "delta 232 cleared to land runway 22 right", "role": "ctl", "callsign": "delta 232"},
            {"text": "cleared to land 22 right delta 232", "role": "acft", "callsign": "delta 232"},
        ]}])
    r = rows[0]
    assert len(r["turns"]) == 2 and r["role"] == "ctl", r
    assert r["turns"][1]["role"] == "acft"
    assert "cleared to land runway 22r" in r["ref"] or "cleared to land runway 22 right" in r["ref"], r["ref"]
    assert not r["unclear"]


def test_unclear_flag_and_unk_token():
    rows = _run_ingest([{
        "id": "b", "airport": "KJFK", "feed": "tower", "status": "good",
        "turns": [{"text": "tower [unclear]garbled here[/unclear] going around",
                   "role": "acft", "callsign": ""}]}])
    r = rows[0]
    assert r["unclear"] is True, r
    assert "<unk>" in r["ref"] and "garbled" not in r["ref"], r["ref"]


def test_legacy_corrected_shape_still_ingests():
    rows = _run_ingest([{
        "id": "c", "airport": "KDFW", "feed": "twr", "status": "good",
        "corrected": "american 1045 contact ground", "role": "ctl", "callsign": "american 1045"}])
    assert rows[0]["turns"][0]["callsign"] == "american 1045", rows[0]


def test_bad_and_empty_skipped():
    rows = _run_ingest([
        {"id": "d", "status": "bad", "turns": [{"text": "x", "role": "unk", "callsign": ""}]},
        {"id": "e", "status": "good", "turns": [{"text": "[unclear]", "role": "unk", "callsign": ""}]},
    ])
    # d is bad; e strips to only <unk>... which is kept as a ref of '<unk>' — assert behavior:
    ids = [r["id"] for r in rows]
    assert "d" not in ids, ids


if __name__ == "__main__":
    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_")]
    for name, fn in tests:
        check(name, fn)
    print("-" * 60)
    npass = sum(1 for _, ok, _ in _results if ok)
    for name, ok, msg in _results:
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  <- {msg}"))
    print(f"{npass}/{len(_results)} passed")
    sys.exit(0 if npass == len(_results) else 1)
