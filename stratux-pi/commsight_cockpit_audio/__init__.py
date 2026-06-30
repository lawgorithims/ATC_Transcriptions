"""CommSight cockpit-audio gateway — a Stratux sidecar.

Captures cockpit audio from a USB audio adapter on the Stratux Raspberry Pi and serves it as a raw
16 kHz mono PCM stream that the CommSight iPad app ("Stratux receiver" input) transcribes. Runs
BESIDE Stratux and never touches its ADS-B / GPS / ForeFlight services. Pure Python standard library
plus ALSA `arecord` — no pip dependencies.
"""

__version__ = "1.0.0"
