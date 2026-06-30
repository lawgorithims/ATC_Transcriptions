import Foundation

/// Streams raw 16 kHz mono signed-16-bit little-endian PCM from the Stratux cockpit-audio sidecar
/// (`http://<host>:<port>/audio.raw`) and yields the `[Float]` chunks the live pipeline expects.
///
/// The sidecar already emits the pipeline's native format, so unlike the LiveATC path there is **no
/// decode** — just accumulate the byte stream, fold each little-endian `Int16` pair to a `Float` in
/// [-1, 1), and emit fixed-size chunks. Uses a delegate-backed `URLSessionDataTask` (bulk `Data`
/// blocks, not per-byte `AsyncBytes`) so a 256 kbps stream costs almost nothing, and reconnects on a
/// dropped stream the way `StreamAudioSource` does for LiveATC.
final class StratuxAudioSource: NSObject, AudioSource, URLSessionDataDelegate {
    private let url: URL
    private let chunkSamples: Int
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var carry: UInt8?            // a leftover odd byte spanning two `Data` blocks
    private var samples: [Float] = []
    private var stopped = false
    private var reconnect: Task<Void, Never>?

    /// `nil` if the host/port don't form a valid URL. Default chunk = 0.5 s at 16 kHz.
    init?(host: String, audioPort: Int, path: String = "/audio.raw", chunkSamples: Int = 8000) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, let url = URL(string: "http://\(h):\(audioPort)\(path)") else { return nil }
        self.url = url
        self.chunkSamples = chunkSamples
        super.init()
    }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            self.samples.reserveCapacity(chunkSamples)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
            connect()
        }
    }

    private func connect() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15           // no data for 15 s → treat the stream as dead
        cfg.timeoutIntervalForResource = .infinity   // the stream itself is indefinite
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: url)
        self.session = session
        self.dataTask = task
        carry = nil
        task.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation, !stopped else { return }
        let (new, newCarry) = Self.decodePCM16(data, carry: carry)
        carry = newCarry
        for s in new {
            samples.append(s)
            if samples.count >= chunkSamples {
                continuation.yield(samples)
                samples.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Fold a run of little-endian Int16 PCM bytes to Floats in [-1, 1), carrying a leftover odd byte
    /// across `Data` block boundaries. Pure (no I/O) so the boundary handling is unit-tested. An empty
    /// block preserves the carry rather than dropping it.
    static func decodePCM16(_ data: Data, carry: UInt8?) -> (samples: [Float], carry: UInt8?) {
        guard !data.isEmpty else { return ([], carry) }
        var out: [Float] = []
        out.reserveCapacity(data.count / 2 + 1)
        var c = carry
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            if let lo = c { out.append(Self.sample(lo, bytes[0])); c = nil; i = 1 }   // finish a split pair
            while i + 1 < bytes.count { out.append(Self.sample(bytes[i], bytes[i + 1])); i += 2 }
            c = i < bytes.count ? bytes[i] : nil    // odd trailing byte → carry to the next block
        }
        return (out, c)
    }

    private static func sample(_ lo: UInt8, _ hi: UInt8) -> Float {
        Float(Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))) / 32768.0
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let shouldReconnect = !stopped
        self.session?.finishTasksAndInvalidate(); self.session = nil; self.dataTask = nil
        lock.unlock()
        guard shouldReconnect else { return }
        reconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // brief backoff, then retry
            self?.connect()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        reconnect?.cancel(); reconnect = nil
        dataTask?.cancel(); dataTask = nil
        session?.invalidateAndCancel(); session = nil
        continuation?.finish(); continuation = nil
        lock.unlock()
    }
}
