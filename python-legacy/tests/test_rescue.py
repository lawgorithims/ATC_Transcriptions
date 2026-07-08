"""Unit tests for the rescue decision rule (dataset/rescue.py) — no API calls.

Run from python-legacy/:  python tests/test_rescue.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dataset.rescue import judge, prescreen, sanity_ok, _defaults

R = _defaults({})
_results = []


def check(name, fn):
    try:
        fn()
        _results.append((name, True, ""))
    except AssertionError as e:
        _results.append((name, False, str(e)))


def test_judge_rescues_when_c_agrees_with_a():
    v = judge("delta 232 cleared to land runway 17 right",
              "delta 332 cleared to land runway 17 right",
              "Delta 232, cleared to land runway 17R.", R)
    assert v.rescued and v.chosen_side == "a", v
    # the label is the WHISPER side's text, never C's
    assert v.label.startswith("delta 232"), v.label


def test_judge_label_is_never_c_text():
    v = judge("united 454 contact tower",
              "united 454 contact tower please",
              "United 454, contact tower.", R)
    assert v.rescued, v
    assert "please" in v.label or v.label == "united 454 contact tower", v.label
    assert v.label != "united 454 contact tower." , "must be normalized whisper text"


def test_judge_abstains_without_agreement():
    v = judge("delta 232 cleared to land",
              "united niner five heavy go around",
              "totally different words entirely spoken here", R)
    assert not v.rescued and v.reason == "no_agreement", v


def test_sanity_gate_empty_and_repetition():
    assert sanity_ok("", R) == "c_empty"
    assert sanity_ok("runway three left " * 5, R) == "c_repetition"
    assert sanity_ok("delta 232 cleared to land", R) is None


def test_judge_rejects_hallucinated_c():
    v = judge("delta 232 cleared", "delta 233 cleared",
              "cleared to land cleared to land cleared to land cleared to land", R)
    assert not v.rescued and v.reason == "c_repetition", v


def test_prescreen_applies_never_run_gates():
    assert prescreen({"no_speech_prob_a": 0.9}, R) == "pre_no_speech"
    assert prescreen({"language_a": "ja"}, R) == "pre_non_english"
    assert prescreen({"avg_logprob_a": -2.5}, R) == "pre_logprob_floor"
    assert prescreen({"no_speech_prob_a": 0.1, "language_a": "en",
                      "avg_logprob_a": -0.9}, R) is None


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
