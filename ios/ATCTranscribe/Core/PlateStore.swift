import Foundation

/// Offline cache for FAA terminal-procedure plate PDFs (the d-TPP charts referenced by
/// `AirportProcedure.plateURL`). Downloads a plate once from aeronav.faa.gov and keeps it in
/// Application Support so it opens instantly and works with no signal in the cockpit — the same
/// offline-first pattern as `ChartLibrary`/`ModelStore`. Cache is keyed by (pdf, cycle), so a new
/// 28-day chart cycle fetches fresh plates and the old ones can be cleared.
///
/// A plate PDF is small (tens–hundreds of KB), so a plate is fetched on first open rather than
/// bulk-downloaded; a route-ahead prefetch can be layered on later.
enum PlateStore {

    /// `Application Support/plates/` — persisted (not `.cachesDirectory`, which the OS may purge),
    /// created on first use. Falls back to a temp dir if Application Support is unavailable.
    static let dir: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("plates", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Local cache path for a plate — `<pdf-stem>-<cycle>.pdf`, so plates from different chart
    /// cycles never collide. Empty pdf/cycle → nil (nothing to cache).
    static func localURL(_ proc: AirportProcedure) -> URL? {
        let pdf = proc.pdf.trimmingCharacters(in: .whitespaces)
        guard !pdf.isEmpty, !Procedures.cycle.isEmpty else { return nil }
        let stem = (pdf as NSString).deletingPathExtension
        return dir.appendingPathComponent("\(stem)-\(Procedures.cycle).pdf")
    }

    /// Already on disk for the current cycle?
    static func isCached(_ proc: AirportProcedure) -> Bool {
        guard let url = localURL(proc) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Return the local plate URL, downloading it once if needed. nil on a bad reference or a
    /// failed download while offline (the caller shows an offline/failed state). A downloaded file
    /// is validated to be a real PDF (`%PDF` magic) before it's kept, so a captive-portal HTML
    /// error page is never cached as a "plate".
    static func ensureOnDisk(_ proc: AirportProcedure) async -> URL? {
        guard let dst = localURL(proc) else { return nil }
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        guard let remote = proc.plateURL else { return nil }
        do {
            var req = URLRequest(url: remote, timeoutInterval: 30)
            req.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, isPDF(tmp) else { return nil }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// True when the file begins with the `%PDF` signature (rejects an HTML error page / truncation).
    private static func isPDF(_ url: URL) -> Bool {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4)) ?? Data()
        return head.elementsEqual([0x25, 0x50, 0x44, 0x46])   // "%PDF"
    }

    /// Drop cached plates from OLD chart cycles (keep the current cycle's). Called opportunistically;
    /// bounded scan of the cache dir. Returns the number removed.
    @discardableResult
    static func pruneStaleCycles() -> Int {
        let cycle = Procedures.cycle
        guard !cycle.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for f in files.prefix(4096) where f.pathExtension.lowercased() == "pdf" && !f.lastPathComponent.contains("-\(cycle).pdf") {
            if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }
}
