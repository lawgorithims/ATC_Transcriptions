#!/usr/bin/env python3
"""Generate Swift<->Python parity fixtures for the Rung-2 speaker-label fusion.

Runs synthetic voice-clusters through the reference fusion in
`python-legacy/dataset/atc_speaker_cluster.py` (`cluster_affinity` + `fuse_line`) and records the
per-member `role_fused` / `speaker_label` / `fused_from`. `SpeakerFusionParityTests` replays the same
clusters through the Swift `SpeakerFusion` port and asserts it matches.

The module pulls in numpy at import, so run under a venv that has it, e.g.:

    ~/CommSight/zipformer-atc/venv/bin/python ios/Tools/gen_fusion_fixtures.py
    # writes ../ATCTranscribeTests/fusion_fixtures.json
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python-legacy"))

from dataset.atc_speaker_cluster import cluster_affinity, fuse_line  # noqa: E402

# Each case is one acoustic cluster: a time-ordered list of members {role, callsign}. The generator
# derives the expected output from the reference, so the Python is the single source of truth.
CASES = [
    # majority controller, one unknown to fill acoustically
    [{"role": "controller"}, {"role": "controller"}, {"role": "unknown"}],
    # count tie (1 controller, 1 pilot) → first confident seen (controller) wins
    [{"role": "controller"}, {"role": "pilot", "callsign": "delta 232"}],
    # a controller line inside a pilot-majority cluster is NEVER overridden; the unknown fills to pilot
    [{"role": "pilot", "callsign": "american 1"}, {"role": "pilot", "callsign": "delta 2"},
     {"role": "controller"}, {"role": "unknown"}],
    # unknown filled toward pilot WITH its own callsign → the callsign surfaces as the label
    [{"role": "pilot", "callsign": "united 5"}, {"role": "pilot", "callsign": "united 5"},
     {"role": "unknown", "callsign": "november 3 4 5"}],
    # singleton unknown, no callsign → UNKNOWN / none (no cluster to fill from)
    [{"role": "unknown"}],
    # singleton unknown WITH a callsign → still UNKNOWN (offline asymmetry: role_fused==unknown wins)
    [{"role": "unknown", "callsign": "delta 5"}],
    # all controller
    [{"role": "controller"}, {"role": "controller"}, {"role": "controller"}],
    # pilot readback with a callsign, plus a bare pilot
    [{"role": "pilot", "callsign": "southwest 2914"}, {"role": "pilot"}],
]


def main() -> None:
    out = []
    for members in CASES:
        affinity = cluster_affinity([m["role"] for m in members])
        expected = []
        for m in members:
            role_fused, speaker_label, fused_from = fuse_line(m["role"], affinity, m.get("callsign"))
            expected.append({"role_fused": role_fused, "speaker_label": speaker_label,
                             "fused_from": fused_from})
        out.append({"members": members, "affinity": affinity, "expected": expected})
    dst = Path(__file__).resolve().parents[1] / "ATCTranscribeTests" / "fusion_fixtures.json"
    dst.write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"wrote {dst} ({len(out)} clusters)")


if __name__ == "__main__":
    main()
