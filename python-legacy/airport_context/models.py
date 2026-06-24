"""
Dataclasses and constants for the airport-mode context pipeline.

These types model the *structured context snapshot* described in the spec: the
important internal product is the snapshot, and the rendered prompt string is
only its final rendering. Every entity carries both a raw identifier and a
``spoken`` form so the ranker/renderer can prefer pronounceable terms while the
snapshot keeps canonical values for later evaluation.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

# Supported frequency types (spec section 5). "unknown" is the default.
FREQUENCY_TYPES = (
    "clearance",
    "ground",
    "tower",
    "approach",
    "departure",
    "center",
    "ctaf",
    "unknown",
)

# Per-frequency-type search radius (NM) for nearby fixes/navaids (spec section 8 step 3).
RADIUS_NM_BY_FREQUENCY = {
    "clearance": 25,
    "ground": 25,
    "tower": 25,
    "approach": 100,
    "departure": 100,
    "center": 250,
    "ctaf": 25,
    "unknown": 50,
}

# Per-category caps for prompt terms (spec section 6 step 6).
DEFAULT_CAPS = {
    "candidate_callsigns": 15,
    "facility_names": 8,
    "runways": 12,
    "procedures": 20,
    "fixes": 25,
    "weather_terms": 8,
    "phrase_templates": 20,
    "spelling_hints": 20,
}


def normalize_frequency_type(value: Optional[str]) -> str:
    """Coerce arbitrary input to a supported frequency type, defaulting to unknown."""
    if not value:
        return "unknown"
    v = str(value).strip().lower()
    return v if v in FREQUENCY_TYPES else "unknown"


@dataclass
class Airport:
    """Resolved canonical airport identity (spec section 6)."""

    icao: Optional[str] = None
    faa_lid: Optional[str] = None
    iata: Optional[str] = None
    ident: Optional[str] = None
    name: str = ""
    city: Optional[str] = None
    region: Optional[str] = None
    country: Optional[str] = None
    lat: Optional[float] = None
    lon: Optional[float] = None
    elevation_ft: Optional[float] = None
    type: Optional[str] = None
    spoken_names: List[str] = field(default_factory=list)
    source: str = "ourairports"
    source_cycle: Optional[str] = None
    db_id: Optional[int] = None

    @property
    def display_code(self) -> str:
        """Best single code to print: ICAO, then FAA LID, then IATA."""
        return self.icao or self.faa_lid or self.iata or self.ident or ""

    def identity_dict(self) -> dict:
        """The ``airport`` block used in the context snapshot (spec section 4)."""
        return {
            "icao": self.icao,
            "faa_lid": self.faa_lid,
            "iata": self.iata,
            "name": self.name,
            "city": self.city,
            "region": self.region,
            "country": self.country,
            "lat": self.lat,
            "lon": self.lon,
            "spoken_names": list(self.spoken_names),
            "source": self.source,
            "source_cycle": self.source_cycle,
        }

    def candidate_dict(self) -> dict:
        """Compact form used in an ambiguity error's candidate list."""
        return {
            "icao": self.icao,
            "faa_lid": self.faa_lid,
            "iata": self.iata,
            "name": self.name,
            "city": self.city,
            "region": self.region,
        }


@dataclass
class Runway:
    ident: str
    spoken: str
    length_ft: Optional[int] = None
    width_ft: Optional[int] = None
    surface: Optional[str] = None
    closed: bool = False

    def snapshot_dict(self) -> dict:
        return {"ident": self.ident, "spoken": self.spoken}


@dataclass
class Frequency:
    frequency_mhz: str
    facility_type: str
    facility_name: Optional[str] = None
    spoken_facility_name: Optional[str] = None
    spoken_frequency: Optional[str] = None
    description: Optional[str] = None


@dataclass
class Navaid:
    ident: str
    name: str
    type: str
    spoken: str
    lat: Optional[float] = None
    lon: Optional[float] = None
    distance_nm: Optional[float] = None
    bearing_deg: Optional[float] = None

    def snapshot_dict(self) -> dict:
        return {
            "ident": self.ident,
            "name": self.name,
            "type": self.type,
            "spoken": self.spoken,
            "distance_nm": round(self.distance_nm, 1) if self.distance_nm is not None else None,
        }


@dataclass
class Procedure:
    """A terminal procedure (FAA d-TPP) linked to an airport."""

    procedure_type: str  # IAP | DP | STAR | CVFP | APD | TAKEOFF_MINIMA | ALTERNATE_MINIMA
    name: str  # raw d-TPP chart_name
    spoken: str
    runway_ident: Optional[str] = None
    chart_code: Optional[str] = None

    def snapshot_dict(self) -> dict:
        return {
            "type": self.procedure_type,
            "name": self.name,
            "spoken": self.spoken,
            "runway": self.runway_ident,
        }


@dataclass
class Callsign:
    """A candidate callsign and its spoken variants (spec section 12)."""

    canonical: str
    spoken: List[str] = field(default_factory=list)
    kind: str = "unknown"  # airline | tail | unknown
    confidence: str = "given"  # given | low

    def snapshot_dict(self) -> dict:
        return {"canonical": self.canonical, "spoken": list(self.spoken), "kind": self.kind}
