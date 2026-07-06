#!/usr/bin/env python3
"""Generate Swift<->Python parity fixtures for CallsignSnap + SlotSnap.

The Python implementations (python-legacy/callsign_snap.py, slot_snap.py) are
the reference; this script runs a fixed case list through them and records the
outputs. `SnapParityTests.swift` replays the same inputs through the Swift
ports and asserts byte-identical text + verdicts (the ATCNormalize parity
pattern). Regenerate after any reference change:

    python gen_snap_fixtures.py   # writes ../ATCTranscribeTests/snap_fixtures.json
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python-legacy"))

from callsign_snap import snap_transcript          # noqa: E402
from slot_snap import snap_slots                   # noqa: E402
from airport_data import AirportContext            # noqa: E402

CS_CANDIDATES = ["delta 232", "delta 1601", "united 454", "american 1045",
                 "southwest 2914", "november 345 alpha bravo", "envoy 3999"]

CS_TEXTS = [
    "delta 232 heavy cleared to land",
    "delta 233 heavy cleared to land",
    "delta two thirty three cleared to land",
    "dela 232 contact departure",
    "frontier 4316 cross runway 26 left",
    "wind two seven zero at one five",
    "november 345 alpha bravo squawk 1200",
    "delta 277 heavy",
    "united four fifty four flight two eight zero heading two eight zero united four fifty four",
    "american ten forty five contact kennedy tower one one niner point one",
]

SLOT_CTX = {
    "ident": "KTST",
    "runways": ["15", "17R", "17C", "35L", "22"],
    "frequencies": {"TWR": [126.55], "GND": [121.8], "APP": [119.3], "OPS": [32.29]},
}

SLOT_TEXTS = [
    "cleared to land runway one seven right",
    "cleared to land runway one eight right",
    "hold short runway three five right",
    "taxi to runway one six",
    "cleared to land runway two two",
    "contact tower one two six point five five",
    "contact tower one two seven point five five",
    "that was one two seven point five five earlier",
    "contact ground one four one point two",
    "contact ground one two one point eight",
    "contact tower one two six five five",
    "runway one eight right cleared to land then contact tower one two seven five five",
    "center american 1786 with you at 320",
    "american 1786 contact tower one two six point five five",
    "runway two two right traffic approved",
    "tower cessna twelve sixty five ready for departure",
]


def main() -> None:
    ctx = AirportContext(ident=SLOT_CTX["ident"], runways=SLOT_CTX["runways"],
                         frequencies=SLOT_CTX["frequencies"])
    fixtures = {"callsign": [], "slots": [], "cs_candidates": CS_CANDIDATES,
                "slot_ctx": SLOT_CTX}
    for t in CS_TEXTS:
        text, e = snap_transcript(t, CS_CANDIDATES)
        fixtures["callsign"].append({
            "in": t, "out": text, "verdict": e.verdict,
            "original": e.original, "snapped": e.snapped, "applied": e.applied,
        })
    for t in SLOT_TEXTS:
        text, edits = snap_slots(t, ctx)
        fixtures["slots"].append({
            "in": t, "out": text,
            "edits": [{"slot": e.slot, "verdict": e.verdict, "original": e.original,
                       "snapped": e.snapped, "applied": e.applied} for e in edits],
        })
    out = Path(__file__).resolve().parents[1] / "ATCTranscribeTests" / "snap_fixtures.json"
    out.write_text(json.dumps(fixtures, indent=1), encoding="utf-8")
    print(f"wrote {out} ({len(CS_TEXTS)} callsign + {len(SLOT_TEXTS)} slot cases)")


if __name__ == "__main__":
    main()
