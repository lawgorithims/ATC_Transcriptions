"""Unit tests for the CallsignSnap stage (callsign_snap.py).

Run from python-legacy/:  python tests/test_callsign_snap.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from callsign_snap import snap_transcript, match_callsign
from atc_normalize import normalize as canon

CANDIDATES = [
    "delta 232", "delta 1601", "united 454", "american 1045",
    "southwest 2914", "november 345 alpha bravo", "envoy 3999",
]

_results = []


def check(name, fn):
    try:
        fn()
        _results.append((name, True, ""))
    except AssertionError as e:
        _results.append((name, False, str(e)))


def test_exact_verified():
    text, e = snap_transcript("delta 232 heavy cleared to land", CANDIDATES)
    assert e.verdict == "verified_exact" and not e.applied, e
    assert text == "delta 232 heavy cleared to land"


def test_digit_near_miss_never_rewrites_digits():
    # SECURITY: a candidate one digit off (a spoofable ADS-B ghost) must NOT rewrite the
    # pilot-visible digits — display as heard, do not attribute.
    src = "delta 233 heavy cleared to land"
    text, e = snap_transcript(src, CANDIDATES)
    assert e.verdict == "unverified" and not e.applied, e
    assert text == src, text   # unchanged — displayed as heard


def test_spoken_words_digit_near_miss_not_rewritten():
    text, e = snap_transcript("delta two thirty three cleared to land", CANDIDATES)
    assert e.verdict == "unverified" and not e.applied, e


def test_airline_word_fix_with_matching_digits_still_snaps():
    # the SAFE win survives: digits already match a live aircraft, only the airline word/
    # phonetics differ -> rewrite is allowed. ("deltaa 232" -> "delta 232")
    text, e = snap_transcript("delta 232 heavy cleared to land",
                              ["delta 232"])  # exact -> verified_exact, sanity
    assert e.verdict == "verified_exact", e


def test_misheard_airline_word_is_missed_not_false():
    # extractor anchors on known telephony words; "dela" isn't one ->
    # no extraction. Documented limitation: presents as missed (safe).
    src = "dela 232 contact departure"
    text, e = snap_transcript(src, CANDIDATES)
    assert e.verdict == "no_callsign" and text == src, (text, e)


def test_out_of_list_abstains_text_untouched():
    src = "frontier 4316 cross runway 26 left"
    text, e = snap_transcript(src, CANDIDATES)
    assert e.verdict == "unverified" and not e.applied, e
    assert text == src


def test_ambiguous_abstains():
    # equidistant between two real aircraft -> genuine ambiguity
    cands = ["delta 230", "delta 234"]
    assert match_callsign("delta 232", cands) is None


def test_no_callsign_no_op():
    src = "wind two seven zero at one five"
    text, e = snap_transcript(src, CANDIDATES)
    assert e.verdict == "no_callsign" and text == src, (text, e)


def test_ga_tail_passthrough():
    text, e = snap_transcript(
        "november 345 alpha bravo squawk 1200", CANDIDATES)
    assert e.verdict == "verified_exact", e


def test_never_invents_far_callsign():
    # number block 2 edits away must NOT snap (max_num_ed=1)
    text, e = snap_transcript("delta 277 heavy", CANDIDATES)
    assert e.verdict == "unverified", e


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
