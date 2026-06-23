"""Cross-language parity check for the Swift port.

Runs the **Python reference** (`atc_corrector.py`, `difflib`) against the exact
cases asserted by the Swift unit tests, so we can confirm the Swift expectations
are faithful even though Swift can't be compiled on the Windows authoring box.

    python ios/Tools/parity_check.py

Exits non-zero if any reference value disagrees with a Swift test expectation.
Extend this as more modules are ported.
"""

from __future__ import annotations

import difflib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from atc_corrector import DeterministicCorrector  # noqa: E402
from atc_stream import VADSegmenter  # noqa: E402
import numpy as np  # noqa: E402
from server.engine import _word_error_rate  # noqa: E402


def det(vocab=()):
    return DeterministicCorrector(lambda: list(vocab))


checks: list[tuple[str, bool, object, object]] = []


def check(name, got, want):
    checks.append((name, got == want, got, want))


# --- SequenceMatcher.ratio() values asserted in ATCCorrectorTests ---
check("ratio maverik/maverick",
      round(difflib.SequenceMatcher(None, "maverik", "maverick").ratio(), 10),
      round(14 / 15, 10))
check("ratio golf/gulf", difflib.SequenceMatcher(None, "golf", "gulf").ratio(), 0.75)
check("ratio abc/xyz", difflib.SequenceMatcher(None, "abc", "xyz").ratio(), 0.0)

# --- DeterministicCorrector behaviors asserted in ATCCorrectorTests ---
check("icao numbers", det().correct("descend niner thousand").corrected, "descend 9 thousand")
check("grouped tens+unit", det().correct("climbing nine seventy five").corrected, "climbing 975")
check("no numbers -> unchanged", det().correct("contact tower").changed, False)
check("char near-miss", det(["Maverick"]).correct("inbound maverik").corrected, "inbound Maverick")

_phon = det(["Gulf"]).correct("over golf intersection")
check("phonetic corrected", _phon.corrected, "over Gulf intersection")
check("phonetic reason", (_phon.edits[0]["reason"] if _phon.edits else None), "phonetic match")

check("stopword protected", det(["Bright"]).correct("turn right").changed, False)
check("short token skipped", det(["six"]).correct("fix").changed, False)
check("known term as-is", det(["Maverick"]).correct("Maverick").changed, False)


# --- VADSegmenter (energy path) behaviors asserted in VADSegmenterTests ---
def _vad():
    s = VADSegmenter()
    s._use_webrtc = False  # force the energy path (the one the Swift port implements)
    return s


def _frames(n, amp):
    return np.full(n * 480, amp, dtype=np.float32)


_s1 = _vad().feed(np.concatenate([_frames(17, 0.5), _frames(23, 0.0)]))
check("vad: one segment", len(_s1), 1)
check("vad: seg start s", round(_s1[0].stream_start_s, 4), 0.0)
check("vad: seg end s", round(_s1[0].stream_end_s, 4), 1.2)
check("vad: seg samples", len(_s1[0].audio), 40 * 480)
check("vad: short speech dropped",
      len(_vad().feed(np.concatenate([_frames(5, 0.5), _frames(23, 0.0)]))), 0)
check("vad: max-segment cap", len(_vad().feed(_frames(400, 0.5))), 1)
check("vad: silence only -> nothing", len(_vad().feed(_frames(50, 0.0))), 0)


# --- WER (server/engine.py:_word_error_rate) asserted in EngineTests.testWERMatchesPython ---
check("wer rex->direct (1/11)",
      round(_word_error_rate("one six right cleared to land Rex Sixty One Thirty Four",
                             "one six right cleared to land direct sixty one thirty four"), 6), 0.090909)
check("wer article dropped", _word_error_rate("the tower cleared for takeoff", "tower cleared for takeoff"), 0.0)
check("wer case-insensitive", _word_error_rate("thank you QNH is one zero two three", "thank you qnh is one zero two three"), 0.0)
check("wer empty hyp", _word_error_rate("roger", ""), 1.0)
check("wer hyphen normalized", _word_error_rate("hotel echo xray", "hotel echo x-ray"), 0.0)

failed = [c for c in checks if not c[1]]
for name, ok, got, want in checks:
    print(f"[{'OK ' if ok else 'XX '}] {name}: got={got!r} want={want!r}")

if failed:
    print(f"\n{len(failed)} mismatch(es) — fix the Swift test expectations.")
    sys.exit(1)
print(f"\nAll {len(checks)} reference checks match the Swift test expectations.")
