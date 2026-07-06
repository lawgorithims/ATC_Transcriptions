"""Airport context providers for grounded correction stages (SlotSnap etc.).

A correction stage needs to know, for the airport(s) in play: runway
designators and published radio frequencies (fixes later). Real-life flights
touch arbitrary airports, so context comes from a PRIORITY CHAIN:

  1. Curated local configs (`airport_configs/*.json`) — richest, few airports.
  2. (iOS) flight plan + offline map database + live position — see the Swift
     mirror; not available in Python.
  3. INTERNET FALLBACK — OurAirports public-domain CSVs (airports, runways,
     airport-frequencies), cached locally, refreshable, no API key. This is
     the universal base layer and the ONLY layer available in LiveATC/demo
     mode (remote feeds have nothing to do with device sensors).

Sources compose via `CompositeSource` (first hit wins per field). The Swift
port mirrors this protocol; parity fixtures live with the tests.
"""

from __future__ import annotations

import csv
import json
import math
import os
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

OURAIRPORTS_URL = "https://davidmegginson.github.io/ourairports-data/{name}.csv"
DEFAULT_CACHE = Path(
    os.environ.get("ATC_AIRPORT_DATA", r"C:\Users\bsusl\atc_training_data\ourairports")
)

# frequency types that matter for ATC transcription context
ATC_FREQ_TYPES = {"TWR", "GND", "APP", "DEP", "ATIS", "CTAF", "UNIC", "CLD", "A/D", "CNTR"}


@dataclass
class AirportContext:
    ident: str
    name: str = ""
    lat: float = 0.0
    lon: float = 0.0
    runways: List[str] = field(default_factory=list)       # open designators, both ends
    frequencies: Dict[str, List[float]] = field(default_factory=dict)  # type -> MHz

    @property
    def frequency_values(self) -> List[float]:
        return sorted({f for v in self.frequencies.values() for f in v})


class OurAirportsSource:
    """Internet-fallback provider backed by cached OurAirports CSVs."""

    def __init__(self, cache_dir: Path = DEFAULT_CACHE, download: bool = True):
        self.cache_dir = Path(cache_dir)
        self._airports: Dict[str, dict] = {}
        self._runways: Dict[str, List[str]] = {}
        self._freqs: Dict[str, Dict[str, List[float]]] = {}
        self._loaded = False
        self._download_ok = download

    def _fetch(self, name: str) -> Path:
        p = self.cache_dir / f"{name}.csv"
        if not p.exists():
            if not self._download_ok:
                raise FileNotFoundError(p)
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(OURAIRPORTS_URL.format(name=name), p)
        return p

    def _load(self) -> None:
        if self._loaded:
            return
        with open(self._fetch("airports"), encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                self._airports[row["ident"]] = {
                    "name": row["name"],
                    "type": row["type"],
                    "lat": float(row["latitude_deg"] or 0),
                    "lon": float(row["longitude_deg"] or 0),
                }
        with open(self._fetch("runways"), encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                if row["closed"] == "1":
                    continue
                ends = [row["le_ident"].strip(), row["he_ident"].strip()]
                lst = self._runways.setdefault(row["airport_ident"], [])
                lst.extend(e for e in ends if e and e not in lst)
        with open(self._fetch("airport-frequencies"), encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                try:
                    mhz = float(row["frequency_mhz"])
                except ValueError:
                    continue
                t = row["type"].strip().upper()[:4]
                self._freqs.setdefault(row["airport_ident"], {}).setdefault(t, []).append(mhz)
        self._loaded = True

    def airport(self, ident: str) -> Optional[AirportContext]:
        self._load()
        a = self._airports.get(ident.upper())
        if a is None:
            return None
        return AirportContext(
            ident=ident.upper(), name=a["name"], lat=a["lat"], lon=a["lon"],
            runways=sorted(self._runways.get(ident.upper(), [])),
            frequencies=self._freqs.get(ident.upper(), {}),
        )

    NEARBY_TYPES = ("large_airport", "medium_airport", "small_airport")

    def nearby(self, lat: float, lon: float, radius_nm: float = 30.0,
               types: tuple = NEARBY_TYPES) -> List[AirportContext]:
        """Airports within radius — the 'what is around here' query (map/GPS path).

        Heliports/closed/seaplane bases are excluded by default; a runway-less
        result is still useful for its frequencies.
        """
        self._load()
        out = []
        for ident, a in self._airports.items():
            if a["type"] not in types:
                continue
            d = _haversine_nm(lat, lon, a["lat"], a["lon"])
            if d <= radius_nm:
                ctx = self.airport(ident)
                if ctx:
                    out.append((d, ctx))
        return [c for _, c in sorted(out, key=lambda t: t[0])]


class LocalConfigSource:
    """Curated per-feed configs (`airport_configs/*.json`) — gold/collector airports."""

    def __init__(self, config_dir: Optional[Path] = None):
        self.config_dir = Path(config_dir or Path(__file__).parent / "airport_configs")

    def airport(self, ident: str) -> Optional[AirportContext]:
        p = self.config_dir / f"{ident.lower()}.json"
        if not p.exists():
            return None
        cfg = json.loads(p.read_text(encoding="utf-8"))
        # schema: {"runways": [...], "frequencies": {feed_key: "127.075", ...}}
        freqs: Dict[str, List[float]] = {}
        for _feed_key, mhz in (cfg.get("frequencies") or {}).items():
            try:
                freqs.setdefault("ATC", []).append(float(mhz))
            except (TypeError, ValueError):
                continue
        return AirportContext(
            ident=cfg.get("airport_code", ident.upper()),
            name=cfg.get("airport_name", ""),
            runways=[str(r) for r in cfg.get("runways", [])],
            frequencies=freqs,
        )

    def nearby(self, lat, lon, radius_nm=30.0, **_):
        return []  # curated configs carry no coordinates


class CompositeSource:
    """First source that answers wins per field; later sources fill gaps."""

    def __init__(self, sources: List):
        self.sources = sources

    def airport(self, ident: str) -> Optional[AirportContext]:
        result: Optional[AirportContext] = None
        for s in self.sources:
            ctx = s.airport(ident)
            if ctx is None:
                continue
            if result is None:
                result = ctx
            else:
                if not result.runways:
                    result.runways = ctx.runways
                if not result.frequencies:
                    result.frequencies = ctx.frequencies
                if not result.name:
                    result.name = ctx.name
        return result

    def nearby(self, lat, lon, radius_nm=30.0, **kw):
        for s in self.sources:
            got = s.nearby(lat, lon, radius_nm, **kw)
            if got:
                return got
        return []


@dataclass
class FlightContext:
    """Candidate airports for a whole flight: plan airports + around a position.

    Mirrors the iOS composition: EFB flight plan (departure/destination/
    alternates), map/offline DB or internet fallback for airport data, and
    live position (Stratux GPS / device) for the nearby query.
    """

    plan_airports: List[str] = field(default_factory=list)
    position: Optional[tuple] = None      # (lat, lon)
    radius_nm: float = 30.0

    def candidate_airports(self, source) -> List[AirportContext]:
        out, seen = [], set()
        for ident in self.plan_airports:
            ctx = source.airport(ident)
            if ctx and ctx.ident not in seen:
                out.append(ctx)
                seen.add(ctx.ident)
        if self.position:
            for ctx in source.nearby(*self.position, self.radius_nm):
                if ctx.ident not in seen:
                    out.append(ctx)
                    seen.add(ctx.ident)
        return out


def _haversine_nm(lat1, lon1, lat2, lon2) -> float:
    r_nm = 3440.065
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r_nm * math.asin(math.sqrt(a))


def default_source(download: bool = True) -> CompositeSource:
    """Curated configs first, OurAirports internet fallback underneath."""
    return CompositeSource([LocalConfigSource(), OurAirportsSource(download=download)])
