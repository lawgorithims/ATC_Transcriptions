#!/usr/bin/env python3
"""Generate Swift<->Python parity fixtures for TurnRoleTagger.

Runs a fixed transmission list through `python-legacy/atc_diarize.classify_turn`
(the reference) and records role + confidence. `TurnRoleParityTests` replays the
same inputs through the Swift port. Regenerate after any reference change:

    python gen_role_fixtures.py   # writes ../ATCTranscribeTests/role_fixtures.json
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python-legacy"))

from atc_diarize import classify_turn  # noqa: E402

CASES = [
    "delta 232 heavy cleared to land runway 22 right",
    "cleared to land delta 232 heavy",                       # trailing callsign, but controller cue
    "united 415 roger descending to 3000",
    "with you at 5000 american 88",                          # pilot readback tag
    "november 345 alpha bravo request taxi",
    "turn left heading 270 southwest 2914",
    "southwest 2914 left heading 270",                       # readback, trailing callsign
    "wind 270 at 15 runway 22 cleared to land",
    "unable delta 232",
    "good morning kennedy tower jetblue 604 with you",
    "squawk 1200 ident",
    "we would like higher when able frontier 4316",
    "traffic in sight",
    "and that is all the traffic i have for you",            # ambiguous chatter -> unknown
    "climbing to one zero thousand",
    "delta two thirty two heavy cleared to land runway two two",  # front + heavy -> controller
    "cleared to land runway two two delta two thirty two heavy",  # readback + heavy -> pilot
    "southwest eight eighty eight",                              # bare callsign ident -> pilot
    "",
]


def main() -> None:
    out = []
    for t in CASES:
        lbl = classify_turn(t)
        out.append({"in": t, "role": lbl.role, "confidence": round(lbl.confidence, 4)})
    dst = Path(__file__).resolve().parents[1] / "ATCTranscribeTests" / "role_fixtures.json"
    dst.write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"wrote {dst} ({len(out)} cases)")


if __name__ == "__main__":
    main()
