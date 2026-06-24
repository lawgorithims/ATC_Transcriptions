"""
Airline ICAO-code -> ATC telephony name lookup (spec section 5, step 5).

The mapping lives in ``data/airlines.json`` so it can be edited without code
changes. A tiny embedded fallback keeps callsign formatting working if that file
is ever missing.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Dict, Optional

_DATA_FILE = Path(__file__).resolve().parent / "data" / "airlines.json"

_FALLBACK = {
    "AAL": "American", "ASA": "Alaska", "DAL": "Delta", "FDX": "FedEx",
    "FFT": "Frontier", "JBU": "JetBlue", "NKS": "Spirit", "SKW": "SkyWest",
    "SWA": "Southwest", "UAL": "United", "UPS": "UPS",
}


@lru_cache(maxsize=1)
def telephony_map() -> Dict[str, str]:
    """Load and cache the ICAO->telephony dictionary (keys are upper-cased)."""
    try:
        raw = json.loads(_DATA_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dict(_FALLBACK)
    return {
        str(k).upper(): str(v)
        for k, v in raw.items()
        if not str(k).startswith("_")
    }


def telephony_for(icao_prefix: str) -> Optional[str]:
    """Return the telephony name for a 3-letter ICAO airline code, or None."""
    if not icao_prefix:
        return None
    return telephony_map().get(icao_prefix.upper())
