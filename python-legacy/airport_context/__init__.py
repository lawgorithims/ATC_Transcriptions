"""
Airport-mode ATC context-injection pipeline.

Takes an airport code (e.g. ``KMSP``) plus optional frequency type, prior
transcript, and candidate callsigns; gathers local aviation context from a
SQLite database built offline from OurAirports data; ranks and compresses it;
and renders a compact, frequency-specific prompt for a speech-to-text call.

The structured ``context_snapshot`` is the primary product; the prompt string is
its final rendering. See ``airport_context/README.md`` and the original spec.

Public API::

    from airport_context import build_context, AirportContextService

Both are imported lazily so that importing submodules (e.g. ``spoken``) does not
pull in the database layer.
"""

from __future__ import annotations

__version__ = "0.1.0"

__all__ = ["build_context", "AirportContextService", "__version__"]


def build_context(request: dict, db_path=None, conn=None) -> dict:
    """Build an airport-mode context snapshot + prompt for a request dict.

    Thin wrapper around :class:`airport_context.builder.AirportContextService`.
    """
    from .builder import AirportContextService

    return AirportContextService(db_path=db_path, conn=conn).build(request)


def __getattr__(name):  # PEP 562 lazy attribute access
    if name == "AirportContextService":
        from .builder import AirportContextService

        return AirportContextService
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
