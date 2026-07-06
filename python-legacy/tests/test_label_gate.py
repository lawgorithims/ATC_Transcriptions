"""Unit tests for the pm-as-labeler-gate (dataset/label_gate.py).

Run from python-legacy/:  python tests/test_label_gate.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from airport_data import AirportContext
from dataset.label_gate import assess_label

CTX = AirportContext(ident="KTST", runways=["17R", "17C", "35L", "22"],
                     frequencies={"TWR": [126.55], "GND": [121.8]})

_results = []


def check(name, fn):
    try:
        fn()
        _results.append((name, True, ""))
    except AssertionError as e:
        _results.append((name, False, str(e)))


def test_clean_label_passes():
    r = assess_label("delta 232 cleared to land runway 17 right", CTX)
    assert r.ok and not r.fixed, r


def test_runway_not_at_airport_rejects():
    r = assess_label("cleared to land runway 27 left", CTX)
    assert not r.ok, r
    assert any(x.startswith("runway_not_at_airport") for x in r.reasons), r.reasons


def test_snappable_runway_typo_is_fixed_not_rejected():
    # 18R doesn't exist but 17R does (unique digit-edit-1, same suffix) -> fixed label
    r = assess_label("cleared to land runway 18 right", CTX)
    assert r.ok and r.fixed, r
    assert "1 7 right" in r.label, r.label


def test_impossible_squawk_rejects():
    r = assess_label("squawk 4 5 8 9 and ident", CTX)
    assert not r.ok, r
    assert any(x.startswith("invalid_squawk") for x in r.reasons), r.reasons


def test_impossible_frequency_rejects():
    r = assess_label("contact ground 1 4 1 point 2", CTX)
    assert not r.ok, r


def test_no_context_runs_ontology_only():
    good = assess_label("cleared to land runway 27 left", None)
    assert good.ok, "runway grounding needs context; without it the label passes"
    bad = assess_label("squawk 4 5 8 9", None)
    assert not bad.ok, "static ontology applies even without an airport"


def test_center_style_no_slots_passes():
    r = assess_label("descend and maintain flight level 3 5 0", None)
    assert r.ok and not r.reasons, r


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
