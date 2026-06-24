"""
Airport code resolver (spec section 6).

Accepts ICAO / FAA-LID / IATA / loose input (spaces, lowercase) and returns a
single canonical airport. Resolution is tiered by priority; ambiguous matches
within a tier raise rather than silently guessing.
"""

from __future__ import annotations

import re
import sqlite3
from typing import List

from . import db
from .models import Airport


class AirportNotFound(Exception):
    def __init__(self, code: str):
        super().__init__(f"No airport found for input code: {code!r}")
        self.code = code


class AmbiguousAirport(Exception):
    def __init__(self, code: str, candidates: List[Airport]):
        super().__init__(f"Ambiguous airport code: {code!r} ({len(candidates)} matches)")
        self.code = code
        self.candidates = candidates


def normalize_code(value: str) -> str:
    """Uppercase and strip all whitespace: 'kms p' -> 'KMSP'."""
    return re.sub(r"\s+", "", str(value or "")).upper()


class AirportResolver:
    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn

    def _query(self, where: str, params) -> List[Airport]:
        rows = self.conn.execute(
            f"SELECT * FROM airports WHERE {where}", params
        ).fetchall()
        # De-duplicate by id (a single airport can match several columns).
        seen = {}
        for r in rows:
            seen.setdefault(r["id"], db.row_to_airport(r))
        return list(seen.values())

    def resolve(self, code: str) -> Airport:
        q = normalize_code(code)
        if not q:
            raise AirportNotFound(code)

        # Tiered by priority (spec section 6). First non-empty tier decides.
        # Exact identifier tiers must be unambiguous; only the fuzzy alias tier
        # falls back to prominence ranking to break ties.
        tiers = [
            ("icao", "icao=? OR ident=?", (q, q), True),
            ("faa_lid", "faa_lid=?", (q,), True),
            ("iata", "iata=?", (q,), True),
            ("alias", "upper(keywords) LIKE ? OR upper(name) LIKE ?", (f"%{q}%", f"{q} %"), False),
        ]
        for _tier, where, params, exact in tiers:
            matches = self._query(where, params)
            if not matches:
                continue
            if len(matches) == 1:
                return matches[0]
            if not exact:
                # Fuzzy tier: accept only if one airport is strictly more
                # prominent (e.g. the large airport over nearby small fields).
                matches.sort(key=lambda a: _TYPE_RANK.get(a.type or "", 9))
                rank0 = _TYPE_RANK.get(matches[0].type or "", 9)
                rank1 = _TYPE_RANK.get(matches[1].type or "", 9)
                if rank0 < rank1:
                    return matches[0]
            raise AmbiguousAirport(q, matches[:8])

        raise AirportNotFound(code)


_TYPE_RANK = {
    "large_airport": 0,
    "medium_airport": 1,
    "small_airport": 2,
    "seaplane_base": 3,
    "heliport": 4,
    "balloonport": 5,
}
