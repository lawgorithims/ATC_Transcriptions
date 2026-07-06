"""Recording-time ADS-B traffic snapshots — the world-model input the labeler
was missing.

ADS-B is live-only (no free historical API), so the aircraft actually on
frequency must be captured WHILE a block records: a background thread polls
airplanes.live around the feed airport (coordinates via the provider chain)
and unions the callsigns seen. The snapshot is written next to the block as
``<block>.traffic.json`` and later grounds CallsignSnap over the pseudo-label
(`label_gate.fix_callsign`) — same freshness philosophy as the app's ADS-B
channel, applied to teacher data.

Fail-soft by design: no coordinates, no network, 429s → an empty snapshot,
and the labeler simply skips callsign grounding for that block.
"""

from __future__ import annotations

import json
import sys
import threading
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Set

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

API = "https://api.airplanes.live/v2/point/{lat:.4f}/{lon:.4f}/{radius}"
UA = "CommSight-Collector/1.0 (on-device ATC transcription; label grounding)"

_PHONETIC = {
    "A": "alpha", "B": "bravo", "C": "charlie", "D": "delta", "E": "echo",
    "F": "foxtrot", "G": "golf", "H": "hotel", "I": "india", "J": "juliet",
    "K": "kilo", "L": "lima", "M": "mike", "N": "november", "O": "oscar",
    "P": "papa", "Q": "quebec", "R": "romeo", "S": "sierra", "T": "tango",
    "U": "uniform", "V": "victor", "W": "whiskey", "X": "xray", "Y": "yankee",
    "Z": "zulu",
}


def _telephony_map() -> Dict[str, str]:
    try:
        from airport_context.airlines import telephony_map

        return {k.upper(): str(v).lower() for k, v in telephony_map().items()}
    except Exception:
        return {"DAL": "delta", "UAL": "united", "AAL": "american",
                "SWA": "southwest", "JBU": "jetblue", "ASA": "alaska",
                "NKS": "spirit", "FFT": "frontier", "SKW": "skywest",
                "FDX": "fedex", "UPS": "ups", "ENY": "envoy"}


def spoken_candidates(codes: List[str]) -> List[str]:
    """ADS-B flight codes / registrations → natural spoken candidates.

    "DAL232" → "delta 232"; "N345AB" → "november 3 4 5 alpha bravo".
    Unknown airline prefixes are skipped (a wrong telephony guess would
    poison the snap list).
    """
    tel = _telephony_map()
    out: List[str] = []
    for raw in codes:
        code = "".join(ch for ch in raw.upper() if ch.isalnum())
        if len(code) < 3:
            continue
        if code.startswith("N") and any(ch.isdigit() for ch in code):
            body = code[1:]
            spoken = ["november"] + [
                (ch if ch.isdigit() else _PHONETIC.get(ch, "")) for ch in body
            ]
            if all(spoken):
                out.append(" ".join(spoken))
            continue
        prefix, rest = code[:3], code[3:]
        if prefix in tel and rest.isdigit() and rest:
            out.append(f"{tel[prefix]} {rest}")
    return sorted(set(out))


class TrafficSnapshotter:
    """Polls airplanes.live around ``airport_ident`` while recording runs."""

    def __init__(self, airport_ident: str, radius_nm: int = 30, poll_s: float = 90.0):
        self.airport_ident = airport_ident
        self.radius_nm = radius_nm
        self.poll_s = poll_s
        self.codes: Set[str] = set()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._coords = self._resolve_coords(airport_ident)

    @staticmethod
    def _resolve_coords(ident: str):
        try:
            from airport_data import default_source

            ctx = default_source(download=False).airport(ident)
            if ctx and (ctx.lat or ctx.lon):
                return (ctx.lat, ctx.lon)
        except Exception:
            pass
        return None

    def _poll_once(self) -> None:
        lat, lon = self._coords
        req = urllib.request.Request(
            API.format(lat=lat, lon=lon, radius=self.radius_nm),
            headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        for ac in data.get("ac") or []:
            for key in ("flight", "r"):
                v = (ac.get(key) or "").strip()
                if v:
                    self.codes.add(v)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._poll_once()
            except Exception:
                pass  # fail-soft: transient network/429 must never hurt recording
            self._stop.wait(self.poll_s)

    def __enter__(self) -> "TrafficSnapshotter":
        if self._coords is not None:
            self._thread = threading.Thread(target=self._run, daemon=True,
                                            name=f"traffic-{self.airport_ident}")
            self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)

    def write_snapshot(self, block_path: Path) -> Optional[Path]:
        """Persist the union next to the block; None when nothing was seen."""
        if not self.codes:
            return None
        out = Path(block_path).with_suffix(".traffic.json")
        out.write_text(json.dumps({
            "airport": self.airport_ident,
            "codes": sorted(self.codes),
            "spoken": spoken_candidates(sorted(self.codes)),
        }, indent=0), encoding="utf-8")
        return out


def load_snapshot(block_path: Path) -> List[str]:
    """Spoken candidates for a block, [] when no snapshot exists."""
    p = Path(block_path).with_suffix(".traffic.json")
    if not p.exists():
        return []
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("spoken") or []
    except Exception:
        return []
