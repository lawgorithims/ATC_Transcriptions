"""
Eval corpus for the deterministic ATC corrector (atc_corrector.DeterministicCorrector).

Each case is (vocab, raw_transcript, expected_corrected). `expected_corrected`
is "" when the corrector should make NO change (raw is left untouched). This is
the measurable backbone for iterating the algorithm — add the real errors you
hit in live tests here with their expected output, and re-run.

Run standalone:   python tests/test_corrector.py
Or via pytest:    pytest tests/test_corrector.py
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from atc_corrector import DeterministicCorrector  # noqa: E402


def _corrector(vocab, **kw):
    return DeterministicCorrector(lambda: list(vocab), **kw)


# (vocab, raw, expected_corrected)  — "" expected means "no change".
CASES = [
    # --- number / phraseology normalization (vocab-independent) ---
    ([], "delta nine seventy five contact ground", "delta 975 contact ground"),
    ([], "turn heading two seven zero", "turn heading 270"),
    ([], "niner tree fife", "935"),
    ([], "runway one seven center", "runway 17 center"),
    ([], "climb one zero thousand", "climb 10 thousand"),    # scale ends the run (v1)
    ([], "say again", ""),                                    # nothing to do

    # --- phonetic matching (sounds alike, spelled differently) ---
    (["Gulf"], "hold short of golf", "hold short of Gulf"),   # vowel confusion
    (["Maverick"], "proceed direct maverik", "proceed direct Maverick"),  # char near-miss

    # --- conservatism: no false corrections ---
    (["Bonham"], "contact tower", ""),                        # stopwords, no vocab hit
    (["Lift"], "cleared to land runway two seven left",       # 'left' protected; numbers still run
     "cleared to land runway 27 left"),

    # --- combined: numbers + vocab in one transmission ---
    (["Bonham"], "bonnham nine seventy five", "Bonham 975"),
]


def run_corpus():
    passed, failed = 0, 0
    print(f"{'STATUS':7} {'RAW':45} -> CORRECTED")
    print("-" * 92)
    for vocab, raw, expected in CASES:
        res = _corrector(vocab).correct(raw)
        got = res.corrected if res.changed else ""
        ok = got == expected
        passed += ok
        failed += (not ok)
        print(f"{'ok' if ok else 'FAIL':7} {raw[:45]:45} -> {got or '(unchanged)'}")
        if not ok:
            print(f"        expected: {expected or '(unchanged)'}")
        elif res.changed:
            for e in res.edits:
                print(f"          edit: {e['from']!r} -> {e['to']!r}  [{e['reason']}]")
    print("-" * 92)
    print(f"{passed}/{passed + failed} passed")
    return failed == 0


# ----- pytest entry points (also runnable standalone) -----------------------

def test_corpus():
    assert run_corpus(), "correction eval corpus has failures"


def test_raw_is_always_preserved():
    res = _corrector(["Maverick"]).correct("direct maverik")
    assert res.raw == "direct maverik"          # original never lost
    assert res.changed and res.edits             # change is recorded


def test_edits_carry_from_to_and_reason():
    res = _corrector([]).correct("nine seventy five")
    assert res.edits and res.edits[0]["from"] == "nine seventy five"
    assert res.edits[0]["to"] == "975" and res.edits[0]["reason"] == "number"


def test_toggles_are_honored():
    # numbers off -> spoken numbers left alone
    assert not _corrector([], numbers=False).correct("two seven zero").changed
    # phonetic off -> vowel-confusion no longer corrected
    assert not _corrector(["Gulf"], phonetic=False).correct("hold short of golf").changed


if __name__ == "__main__":
    ok = run_corpus()
    print()
    for fn in (test_raw_is_always_preserved, test_edits_carry_from_to_and_reason, test_toggles_are_honored):
        try:
            fn()
            print(f"ok    {fn.__name__}")
        except AssertionError as exc:
            ok = False
            print(f"FAIL  {fn.__name__}: {exc}")
    sys.exit(0 if ok else 1)
