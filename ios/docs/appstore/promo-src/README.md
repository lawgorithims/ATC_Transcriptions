# Promotional artwork sources

The two landscape frames here are the **sources** for App Store featuring artwork. They are
committed; the artwork built from them is not — `ios/Tools/make_promo_art.py` rebuilds both sets
into `../promo/` and `../promo-approach/` in seconds, and 64 MB of regenerable PNGs do not belong
in a git history. These frames do, because reproducing them needs a simulator and a network.

| Frame | Shows |
| --- | --- |
| `promo-chart-landscape.png` | Enroute at FL390: the filed route, radar cells, ADS-B traffic, the flown track, and the glide footprint. |
| `promo-approach-landscape.png` | KATL ILS 08L: the plate georeferenced on the map, LARII/JAAJJ/BAZAR/SCHEL as the active route, ownship on final. |

Re-shoot both with `SIM="<your iPad sim>" bash ios/Tools/promo_capture.sh`, which stages everything
offline so the frames are identical every run. What each argument is for, and the four things that
cost a run each to learn, are in `ios/ATCTranscribeUITests/PromoArtCaptureTests.swift`.

⚠️ **One 5244x2950 file, not two.** App Store Connect takes that size for both the header and the
search placement and the generator gives them identical anchors, so it is emitted once as
`promo-5244x2950.png`. Upload the same file to either.
