import Foundation

/// Append-only JSONL transcript log — the on-device dataset an opted-in pilot accumulates for the next
/// fine-tuning round / QA. One JSON object per line in `Documents/atc-transcripts.jsonl` (offline, never
/// iCloud; exportable via the Files app + a ShareLink). An `actor` so writes happen OFF the `@MainActor`
/// session. NASA/JPL Power-of-10: a BOUNDED buffer (forced flush at the cap → no unbounded growth), every
/// `FileHandle` write is checked (a throw sets `broken` and stops — never crashes), and a size cap rotates
/// the file so disk use stays bounded.
actor TranscriptLogStore {

    struct Config {
        var maxBufferLines = 64
        var maxFileBytes: Int64 = 32 * 1024 * 1024   // 32 MB, then rotate to `.1`
    }

    private let fileURL: URL
    private let rotatedURL: URL
    private let sessionId: String
    private var source: String
    private var gps: GPSLogStamp?
    private let modelId: String
    private let config: Config
    private let encoder: JSONEncoder

    private var handle: FileHandle?
    private var buffer: [Data] = []
    private var fileBytes: Int64 = 0
    private var broken = false

    /// Open the log at `directory/atc-transcripts.jsonl`, creating it if absent. Returns nil if the file
    /// can't be created/opened (the caller then simply logs nothing).
    init?(directory: URL, sessionId: String, source: String, modelId: String, config: Config = .init()) {
        let url = directory.appendingPathComponent("atc-transcripts.jsonl")
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil) {
            return nil
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.fileURL = url
        self.rotatedURL = directory.appendingPathComponent("atc-transcripts.jsonl.1")
        self.sessionId = sessionId
        self.source = source
        self.modelId = modelId
        self.config = config
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
        self.handle = h
        self.fileBytes = Int64((try? h.seekToEnd()) ?? 0)
    }

    /// Update the input source tag (set when a run starts).
    func setSource(_ s: String) { source = s }

    /// Update the ownship/GPS integrity stamp applied to subsequent lines. Pushed by `AppModel` when the
    /// monitor's verdict changes — the store never reads location itself (one GPS owner, build-62 rule).
    func setGPS(_ stamp: GPSLogStamp?) { gps = stamp }

    /// Buffer one entry (stamping session context). Flushes when the buffer reaches the line cap.
    func log(_ entry: TranscriptLogEntry) {
        guard !broken else { return }
        var e = entry
        e.loggedAtMs = Date().timeIntervalSince1970 * 1000.0
        e.sessionId = sessionId
        e.source = source
        e.modelId = modelId
        e.gps = gps
        guard let data = try? encoder.encode(e) else { return }
        assert(!data.contains(0x0A), "a JSONL entry must not contain an interior newline")
        buffer.append(data)
        assert(buffer.count <= config.maxBufferLines, "log buffer exceeded its cap")
        if buffer.count >= config.maxBufferLines { flush() }
    }

    /// Write the buffered lines to disk (checked). A write failure disables further logging without crashing.
    func flush() {
        guard !broken, let handle, !buffer.isEmpty else { return }
        var blob = Data()
        blob.reserveCapacity(buffer.reduce(0) { $0 + $1.count + 1 })
        for line in buffer {                                        // bounded by maxBufferLines
            blob.append(line)
            blob.append(0x0A)
        }
        do {
            try handle.write(contentsOf: blob)
            fileBytes += Int64(blob.count)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            broken = true
            buffer.removeAll(keepingCapacity: true)
            NSLog("CommSight: transcript log write failed: %@", String(describing: error))
            return
        }
        assert(fileBytes >= 0, "file byte counter must stay non-negative")
        if fileBytes >= config.maxFileBytes { rotate() }
    }

    /// Flush and return the file URL for a ShareLink export.
    func exportFileURL() -> URL {
        flush()
        return fileURL
    }

    /// Flush and close (on stop / teardown).
    func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    /// Roll the live file to `.1` (keeping one rotation) and reopen a fresh empty file. Bounds disk use.
    private func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let h = try? FileHandle(forWritingTo: fileURL) else {
            broken = true
            return
        }
        handle = h
        fileBytes = 0
    }
}
