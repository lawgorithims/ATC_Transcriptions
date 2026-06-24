"""Generate Butterworth SOS coefficients + a filtfilt parity fixture for the Swift
AudioPreprocessor port (Audio/Biquad.swift, Audio/AudioPreprocessor.swift).

    python ios/Tools/gen_filter_fixtures.py

Prints Swift-ready SOS coefficient arrays and the expected `sosfiltfilt` output at
interior sample indices for a deterministic test signal, so the Swift biquad filter
can be parity-checked against SciPy (the same filters audio_preprocessing.py uses).
"""

import numpy as np
from scipy import signal

SR = 16000
NYQ = SR / 2.0


def emit_sos(name, *args, **kwargs):
    sos = signal.butter(*args, **kwargs, output="sos")
    print(f"    /// {name}: scipy.signal.butter{args} (16 kHz)")
    print(f"    static let {name}: [[Double]] = [")
    for row in sos:
        print("        [" + ", ".join(f"{v:.17g}" for v in row) + "],")
    print("    ]")
    return sos


print("=== SOS coefficients (paste into Biquad.swift) ===")
hp5 = emit_sos("hp5_350", 5, 350 / NYQ, btype="high")          # aggressive high-pass
hp4 = emit_sos("hp4_300", 4, 300 / NYQ, btype="high")          # default high-pass
bp4 = emit_sos("bp4_250_3800", 4, [250 / NYQ, 3800 / NYQ], btype="band")  # speech band-pass

# Deterministic test signal (no RNG) so the Swift test reproduces the exact input:
# 100 Hz (below HP), 1000 Hz (passband), 5000 Hz (above BP) tones.
N = 4000
n = np.arange(N)
x = (np.sin(2 * np.pi * 100 * n / SR)
     + np.sin(2 * np.pi * 1000 * n / SR)
     + 0.5 * np.sin(2 * np.pi * 5000 * n / SR)).astype(np.float64)

idx = [500, 1000, 2000, 3000, 3500]
print("\n=== parity fixture (paste into AudioPreprocessorTests.swift) ===")
print(f"    // test signal: sin(2pi*100*n/16000)+sin(2pi*1000*n/16000)+0.5*sin(2pi*5000*n/16000), n=0..{N-1}")
print(f"    static let parityIndices = {idx}")
for fname, sos in [("hp5_350", hp5), ("bp4_250_3800", bp4)]:
    y = signal.sosfiltfilt(sos, x)
    vals = ", ".join(f"{y[i]:.10f}" for i in idx)
    print(f"    static let expected_{fname}: [Double] = [{vals}]")
