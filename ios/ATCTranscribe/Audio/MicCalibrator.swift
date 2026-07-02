import Foundation
import AVFoundation

/// Records a short window from the device microphone and reports its mean RMS level (mono 16 kHz —
/// the same signal the VAD gates on), the raw measurement behind mic squelch calibration.
///
/// Self-contained (its own `AVAudioEngine`) so it can run a one-off measurement without touching the
/// live pipeline. Requires an already-active `.playAndRecord` session + record permission (the caller
/// arranges both). **Device-only:** there's no audio input on the headless build box, so this can't
/// be exercised in CI — the pure gate math it feeds lives in `SquelchCalibration` and IS unit-tested.
enum MicCalibrator {
    enum Failure: Error {
        case noInput      // no usable mic route/format (permission, no device)
        case noAudio      // route opened but no buffers arrived (muted / used by another app)
    }

    /// Capture ≈ `seconds` of mic audio and return its RMS. Throws on an unavailable/silent mic.
    static func measureRMS(seconds: Double) async throws -> Float {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw Failure.noInput
        }

        let acc = Accumulator()
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData
                return buffer
            }
            guard let channel = out.floatChannelData, out.frameLength > 0 else { return }
            var sumSq: Double = 0
            for i in 0..<Int(out.frameLength) { let v = Double(channel[0][i]); sumSq += v * v }
            acc.add(sumSq: sumSq, count: Int(out.frameLength))
        }

        engine.prepare()
        do { try engine.start() } catch { throw Failure.noInput }
        defer {
            input.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }

        // Gather until we have `seconds` of samples, or bail after a grace period if the mic is dead.
        let target = Int(seconds * outFormat.sampleRate)
        var waited = 0.0
        let grace = seconds + 3.0
        while acc.count < target, waited < grace {
            try? await Task.sleep(nanoseconds: 100_000_000)   // 0.1 s
            waited += 0.1
        }

        let (sumSq, n) = acc.snapshot()
        guard n > 0 else { throw Failure.noAudio }
        return Float((sumSq / Double(n)).squareRoot())
    }

    /// Thread-safe running sum-of-squares (the tap fires on the audio thread; the async loop reads it).
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var sumSq: Double = 0
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func add(sumSq: Double, count: Int) {
            lock.lock(); self.sumSq += sumSq; self.n += count; lock.unlock()
        }
        func snapshot() -> (Double, Int) { lock.lock(); defer { lock.unlock() }; return (sumSq, n) }
    }
}
