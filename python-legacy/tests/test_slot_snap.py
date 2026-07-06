"""Unit tests for SlotSnap (slot_snap.py) + the airport data provider chain.

Run from python-legacy/:  python tests/test_slot_snap.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from airport_data import AirportContext
from slot_snap import snap_slots

CTX = AirportContext(
    ident="KTST",
    runways=["15", "17R", "17C", "35L", "22"],
    frequencies={"TWR": [126.55], "GND": [121.8], "APP": [119.3],
                 "OPS": [32.29]},  # OPS is outside the airband -> never a candidate
)

_results = []


def check(name, fn):
    try:
        fn()
        _results.append((name, True, ""))
    except AssertionError as e:
        _results.append((name, False, str(e)))


def test_runway_exact_verified():
    text, edits = snap_slots("cleared to land runway one seven right", CTX)
    assert edits and edits[0].verdict == "verified" and not edits[0].applied, edits
    assert "1 7 right" in text


def test_runway_digit_snap_same_suffix():
    text, edits = snap_slots("cleared to land runway one eight right", CTX)
    assert edits[0].verdict == "snapped" and edits[0].applied, edits
    assert "runway 1 7 right" in text and "1 8" not in text, text


def test_runway_suffix_never_changed():
    # heard 35 right; airport only has 35L -> abstain, text untouched
    text, edits = snap_slots("hold short runway three five right", CTX)
    assert edits[0].verdict == "unverified" and not edits[0].applied, edits
    assert "3 5 right" in text


def test_runway_family_ambiguous_abstains():
    # heard 16 (no suffix): families {15, 17, 35, 22} -> 15 and 17 both edit-1
    text, edits = snap_slots("taxi to runway one six", CTX)
    assert edits[0].verdict == "unverified" and not edits[0].applied, edits


def test_runway_bare_family_verified():
    text, edits = snap_slots("cleared to land runway two two", CTX)
    assert edits[0].verdict == "verified", edits


def test_freq_exact_verified():
    text, edits = snap_slots("contact tower one two six point five five", CTX)
    assert edits and edits[0].verdict == "verified", edits


def test_freq_digit_snap():
    text, edits = snap_slots("contact tower one two seven point five five", CTX)
    assert edits[0].verdict == "snapped" and edits[0].applied, edits
    assert "1 2 6 point 5 5" in text, text


def test_freq_needs_anchor():
    # no ATC anchor word before the number -> untouched, no edit recorded
    text, edits = snap_slots("that was one two seven point five five earlier", CTX)
    assert not edits, edits
    assert "1 2 7 point 5 5" in text


def test_freq_off_airband_invalid():
    text, edits = snap_slots("contact ground one four one point two", CTX)
    assert edits[0].verdict == "invalid" and not edits[0].applied, edits
    assert "1 4 1 point 2" in text


def test_freq_outside_airband_candidate_never_used():
    # OPS 32.29 must never be considered a snap target
    text, edits = snap_slots("contact ground one two one point eight", CTX)
    assert edits[0].verdict == "verified", edits


def test_freq_without_point_word():
    # "tower one two six five five" — radio speech omitting "point"
    text, edits = snap_slots("contact tower one two six five five", CTX)
    assert edits and edits[0].verdict == "verified", edits


def test_freq_without_point_snap():
    text, edits = snap_slots("contact tower one two seven five five", CTX)
    assert edits[0].verdict == "snapped" and "1 2 6 point 5 5" in text, (edits, text)


def test_suffix_from_next_phrase_not_captured():
    # "runway 22, right traffic" — 'right' belongs to the pattern, not the runway
    text, edits = snap_slots("runway two two right traffic approved", CTX)
    assert edits[0].verdict == "verified" and edits[0].original == "22", edits
    assert "2 2 right traffic" in text, text


def test_ga_tail_never_read_as_frequency():
    text, edits = snap_slots("tower cessna twelve sixty five ready for departure", CTX)
    assert not any(e.slot == "frequency" for e in edits), edits


def test_integer_mhz_no_digit_collapse():
    # 120.0 must not collapse to '12' and license a 2-digit snap onto 132.0-style
    # candidates; with no near candidate it stays unverified (on-raster, in-band)
    from airport_data import AirportContext
    ctx = AirportContext(ident="KTS2", runways=[], frequencies={"TWR": [132.0]})
    text, edits = snap_slots("contact tower one two zero point zero", ctx)
    assert edits and edits[0].verdict == "unverified", edits
    assert "1 2 0 point 0" in text, text


def test_helipad_designators_never_enter_pool():
    from airport_data import AirportContext
    # airport with ONLY unparseable designators -> no candidates -> abstain
    # (the critical bug snapped heard runways onto the EMPTY designator, deleting
    # the number from the transcript)
    ctx = AirportContext(ident="KTS3", runways=["H1"], frequencies={})
    text, edits = snap_slots("cleared to land runway three", ctx)
    assert edits[0].verdict == "unverified" and not edits[0].applied, edits
    assert "runway 3" in text, text
    # mixed airport: H1 must not perturb the pool — '3' -> '36' is the legitimate
    # unique edit-1 (dropped digit) snap, never a snap-to-nothing
    ctx2 = AirportContext(ident="KTS4", runways=["H1", "18", "36"], frequencies={})
    text2, edits2 = snap_slots("cleared to land runway three", ctx2)
    assert edits2[0].verdict == "snapped" and edits2[0].snapped == "36", edits2
    assert "runway 3 6" in text2, text2


def test_callsign_flight_number_never_read_as_frequency():
    # "center american 1786" is a callsign, not frequency 178.6 (measured
    # false-positive class on the collected corpus)
    text, edits = snap_slots("center american 1786 with you at 320", CTX)
    assert not any(e.slot == "frequency" for e in edits), edits
    assert "american 1 7 8 6" in text, text


def test_real_frequency_after_callsign_still_checked():
    # callsign guard must not shadow a genuine frequency later in the text
    text, edits = snap_slots("american 1786 contact tower one two six point five five", CTX)
    freq = [e for e in edits if e.slot == "frequency"]
    assert len(freq) == 1 and freq[0].verdict == "verified", edits


def test_no_context_passthrough():
    src = "cleared to land runway one eight right"
    text, edits = snap_slots(src, None)
    assert not edits and "1 8 right" in text


def test_multiple_slots_one_transmission():
    text, edits = snap_slots(
        "runway one eight right cleared to land then contact tower one two seven point five five",
        CTX)
    kinds = sorted((e.slot, e.verdict) for e in edits)
    assert kinds == [("frequency", "snapped"), ("runway", "snapped")], kinds
    assert "1 7 right" in text and "1 2 6 point 5 5" in text, text


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
