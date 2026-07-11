import Foundation

/// Large-scale speaker-separation study for the SHIPPED Swift MFCC fingerprint, run over the real
/// collected ATC corpus (`~/CommSight/atc-data/segments/<airport>/<feed>/<block>/<idx>.wav` + the
/// `us_pseudo/manifest.jsonl` labels). It measures the runtime `SpeakerModel` fingerprint's ability to
/// tell SAME-speaker apart from DIFFERENT-speaker on real band-limited audio — the deployability
/// evidence the 5-clip bundled set cannot give — and sweeps the decision threshold to an equal-error
/// operating point.
///
/// "Same speaker" proxy: two CONTROLLER-role clips from the same (airport, feed, block) — one ~10-min
/// block on one frequency is one controller. "Different speaker" proxy: two controller clips from
/// DIFFERENT airports. Comparing controller-vs-controller isolates the SPEAKER difference from the
/// role/content difference.
///
/// Opt-in from `main.swift` via `ATC_SPKR_STUDY=<segments-root>` (+ `ATC_SPKR_MANIFEST=<manifest.jsonl>`,
/// `ATC_SPKR_MAX=<clips>`). Coding standard: NASA/JPL "Power of Ten" — every loop has a fixed bound,
/// inputs are validated with recovery, invariants are asserted, functions stay small, no recursion.
enum SpeakerStudy {

    // Fixed bounds (Rule 2 / Rule 3: no unbounded work or growth).
    private static let maxClips = 1500        // clips loaded + fingerprinted
    private static let maxManifestLines = 200_000
    private static let maxPairs = 4000        // per population (within / cross)
    private static let minSamples = 300       // reject a clip shorter than this many samples
    // Covers both scales: MFCC cosine distances are tiny (~0.003–0.06); ECAPA's are large (~0.3–0.9).
    private static let thresholds: [Float] = [0.005, 0.02, 0.05, 0.1, 0.2, 0.3, 0.4, 0.45, 0.5,
                                              0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9]

    private struct Row: Decodable {
        let id: String
        let airport: String?
        let feed: String?
        let src_block: String?
        let role: String?
    }
    private struct Clip { let airport: String; let block: String; let role: String; let fp: [Float] }
    private enum Mode { case withinController, controllerVsPilot, crossController }

    /// Returns a process exit code (0 = study ran). `ecapaModelPath` (optional): a compiled ECAPA
    /// `.mlmodelc` — when it loads, the study measures the ECAPA embedding instead of the MFCC one.
    static func run(segmentsRoot: String, manifestPath: String, maxClips capIn: Int,
                    ecapaModelPath: String?) -> Int {
        let cap = min(max(capIn, 1), maxClips)
        assert(cap >= 1 && cap <= maxClips)
        var embedder: CoreMLSpeakerEmbedder?
        if let p = ecapaModelPath, !p.isEmpty {
            let e = CoreMLSpeakerEmbedder(modelURL: URL(fileURLWithPath: p))
            embedder = e.isAvailable ? e : nil
            FileHandle.standardError.write(Data("ECAPA model: \(e.isAvailable ? "loaded" : "FAILED to load") (\(p))\n".utf8))
        }
        FileHandle.standardError.write(Data("fingerprint backend: \(embedder != nil ? "ECAPA (192-d)" : "MFCC (13-d)")\n".utf8))
        let rows = parseManifest(manifestPath)
        guard !rows.isEmpty else { FileHandle.standardError.write(Data("no manifest rows\n".utf8)); return 1 }
        let clips = loadClips(rows, root: segmentsRoot, cap: cap, embedder: embedder)
        guard clips.count >= 2 else {
            FileHandle.standardError.write(Data("too few clips loaded (\(clips.count))\n".utf8)); return 1
        }
        let within = distances(clips, mode: .withinController)
        let ctrlPilot = distances(clips, mode: .controllerVsPilot)
        let cross = distances(clips, mode: .crossController)
        report(clips: clips, within: within, ctrlPilot: ctrlPilot, cross: cross)
        return 0
    }

    // MARK: - manifest

    private static func parseManifest(_ path: String) -> [Row] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [Row] = []
        rows.reserveCapacity(maxClips)
        let decoder = JSONDecoder()
        var scanned = 0
        for line in text.split(separator: "\n") {
            if scanned >= maxManifestLines { break }        // Rule 2: bounded scan
            scanned += 1
            guard let lineData = line.data(using: .utf8),
                  let row = try? decoder.decode(Row.self, from: lineData) else { continue }
            rows.append(row)
        }
        assert(rows.count <= maxManifestLines)
        return rows
    }

    private static func clipPath(root: String, _ r: Row) -> String? {
        guard let airport = r.airport, let feed = r.feed, let block = r.src_block else { return nil }
        guard let idx = r.id.split(separator: "_").last, !idx.isEmpty else { return nil }
        let ns = root as NSString
        return ns.appendingPathComponent("\(airport)/\(feed)/\(block)/\(idx).wav")
    }

    // MARK: - loading + fingerprints

    private static func loadClips(_ rows: [Row], root: String, cap: Int,
                                  embedder: CoreMLSpeakerEmbedder?) -> [Clip] {
        let model = SpeakerModel()
        var clips: [Clip] = []
        clips.reserveCapacity(cap)
        var i = 0
        var controllers = 0, pilots = 0
        while i < rows.count && clips.count < cap {           // Rule 2: bounded by rows.count AND cap
            let r = rows[i]; i += 1
            let role = r.role ?? ""
            guard role == "controller" || role == "pilot" else { continue }
            guard let path = clipPath(root: root, r),
                  let audio = try? AudioFile.load16kMono(path: path), audio.count >= minSamples else { continue }
            // ECAPA when available (with an MFCC fallback for a clip the model rejects), else MFCC.
            let fp = embedder?.embed(audio) ?? model.fingerprint(audio)
            guard fp.count >= 2 else { continue }   // need c1… for the cosine compare
            let block = "\(r.airport ?? "?")/\(r.feed ?? "?")/\(r.src_block ?? "?")"
            clips.append(Clip(airport: r.airport ?? "?", block: block, role: role, fp: fp))
            if role == "controller" { controllers += 1 } else { pilots += 1 }
        }
        assert(clips.count <= cap)
        FileHandle.standardError.write(Data("loaded \(clips.count) clips (\(controllers) ctrl / \(pilots) pilot, scanned \(i) rows)\n".utf8))
        return clips
    }

    // MARK: - distance populations

    /// Whether a clip pair belongs to the requested population.
    private static func matches(_ x: Clip, _ y: Clip, _ mode: Mode) -> Bool {
        let bothCtrl = x.role == "controller" && y.role == "controller"
        switch mode {
        case .withinController:  return x.block == y.block && bothCtrl
        case .crossController:   return x.airport != y.airport && bothCtrl
        case .controllerVsPilot:
            let mixed = (x.role == "controller" && y.role == "pilot")
                     || (x.role == "pilot" && y.role == "controller")
            return x.block == y.block && mixed
        }
    }

    /// Cosine distances for one population, capped at `maxPairs`. Bounded double loop.
    private static func distances(_ clips: [Clip], mode: Mode) -> [Float] {
        let model = SpeakerModel()
        var out: [Float] = []
        out.reserveCapacity(maxPairs)
        let n = clips.count
        var a = 0
        while a < n {                                          // Rule 2: bounded by n
            if out.count >= maxPairs { break }
            var b = a + 1
            while b < n {                                      // Rule 2: bounded by n
                if out.count >= maxPairs { break }
                if matches(clips[a], clips[b], mode) {
                    let d = model.dist(clips[a].fp, clips[b].fp)
                    assert(d.isFinite && d >= -0.001)
                    out.append(d)
                }
                b += 1
            }
            a += 1
        }
        return out
    }

    // MARK: - stats + report

    private static func stat(_ v: [Float], _ q: Float) -> Float {
        guard !v.isEmpty else { return 0 }
        assert(q >= 0 && q <= 1)
        let s = v.sorted()
        var idx = Int(q * Float(s.count - 1))
        if idx < 0 { idx = 0 }
        if idx > s.count - 1 { idx = s.count - 1 }
        return s[idx]
    }

    private static func mean(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        var sum: Float = 0
        for x in v { sum += x }
        return sum / Float(v.count)
    }

    /// Fraction of `v` on the wrong side of `t` (below when counting false-merges, at/above for splits).
    private static func fraction(_ v: [Float], below: Bool, _ t: Float) -> Float {
        guard !v.isEmpty else { return 0 }
        var hits = 0
        for x in v { if below ? (x < t) : (x >= t) { hits += 1 } }
        return Float(hits) / Float(v.count)
    }

    private static func report(clips: [Clip], within: [Float], ctrlPilot: [Float], cross: [Float]) {
        print("===== MFCC SPEAKER-SEPARATION STUDY (real corpus, shipped Swift fingerprint) =====")
        print("clips=\(clips.count)  within-ctrl pairs=\(within.count)  "
            + "ctrl-vs-pilot pairs=\(ctrlPilot.count)  cross-airport-ctrl pairs=\(cross.count)")
        printPop("WITHIN-CTRL  (same block, same controller — should be SMALL)", within)
        printPop("CTRL-vs-PILOT(same block, controller vs pilot — should be LARGE)", ctrlPilot)
        printPop("CROSS-AIRPORT(different controllers — global reference only)", cross)
        guard !within.isEmpty, !ctrlPilot.isEmpty else { print("  insufficient pairs — widen the sample"); return }
        // The LIVE operating point is single-feed: keep the controller's own turns together
        // (false-split = within-ctrl >= t) while keeping pilots OUT of the controller cluster
        // (false-merge = ctrl-vs-pilot < t). This is the number that governs fusion-fill safety.
        print("  threshold  ctrl-split(within>=t)  pilot-merge(ctrlPilot<t)  max-err")
        var bestT: Float = 0, bestErr: Float = 2
        for t in thresholds {
            let split = fraction(within, below: false, t)
            let merge = fraction(ctrlPilot, below: true, t)
            let err = max(split, merge)
            if err < bestErr { bestErr = err; bestT = t }
            print(String(format: "  %.3f       %5.1f%%                %5.1f%%              %5.1f%%%@",
                         t, split * 100, merge * 100, err * 100,
                         t == 0.05 ? "  <- current" : ""))
        }
        print(String(format: "SUGGESTED newSpeakerDist ~ %.3f (equal-error %.1f%% on the live-relevant split)",
                     bestT, bestErr * 100))
        print("===== end =====")
    }

    private static func printPop(_ label: String, _ v: [Float]) {
        guard !v.isEmpty else { print("  \(label): (no pairs)"); return }
        print(String(format: "  %@: mean %.4f  median %.4f  p10 %.4f  p90 %.4f",
                     label, mean(v), stat(v, 0.5), stat(v, 0.1), stat(v, 0.9)))
    }
}
