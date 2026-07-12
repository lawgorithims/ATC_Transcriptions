// build_plate_georef.swift — OFFLINE georeferencing pipeline for FAA terminal-procedure plates.
//
// For each plate in the bundled d-TPP index (procedures.json), this: downloads/renders page 1,
// OCRs it with Vision, matches recognized tokens to the airport's coded fixes (cifp.sqlite) to form
// pixel↔lat/lon control points, and solves a robust 2D similarity (PlateSimilarity, shared with the
// app) → an overlay placement + residual + confidence. It ALSO harvests a rich per-plate OCR record
// (every text box + frequencies/courses/corner lat-lon/fixes) so future features don't need to
// re-OCR thousands of plates.
//
// Outputs:
//   plate_georef.json  — small, bundle-able: pdf → {airport,name,center,width,rotation,rms,confident}
//   plate_ocr.jsonl    — the FULL local corpus (one JSON object per plate). NOT bundled.
//
// Build:  swiftc -O build_plate_georef.swift ../ATCTranscribe/Core/PlateSimilarity.swift -o build_plate_georef
// Run:    ./build_plate_georef --procedures <procedures.json> --cifp <cifp.sqlite> \
//              --cache <plates_dir> --out plate_georef.json --ocr-out plate_ocr.jsonl [--limit N] [--airport KBOS] [--offline]
//
// macOS only (Vision/PDFKit). Idempotent: cached plate PDFs are reused; re-runnable per cycle.

import Foundation
import Vision
import PDFKit
import CoreGraphics
import simd
import SQLite3

let SQLITE_TRANSIENT_T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - args

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

guard let procPath = argValue("--procedures"), let cifpPath = argValue("--cifp") else {
    FileHandle.standardError.write("usage: build_plate_georef --procedures <json> --cifp <sqlite> --cache <dir> --out <json> --ocr-out <jsonl> [--limit N] [--airport ICAO] [--offline]\n".data(using: .utf8)!)
    exit(2)
}
let cacheDir = argValue("--cache") ?? "./plates_cache"
let outPath = argValue("--out") ?? "plate_georef.json"
let ocrOutPath = argValue("--ocr-out") ?? "plate_ocr.jsonl"
let limit = argValue("--limit").flatMap { Int($0) }
let onlyAirport = argValue("--airport")?.uppercased()
let offline = flag("--offline")
try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

// MARK: - d-TPP index

struct DTPP: Decodable { let cycle: String; let airports: [String: [Rec]]
    struct Rec: Decodable { let c: String; let n: String; let f: String } }
let dtpp = try JSONDecoder().decode(DTPP.self, from: Data(contentsOf: URL(fileURLWithPath: procPath)))
let cycle = dtpp.cycle
FileHandle.standardError.write("cycle \(cycle), \(dtpp.airports.count) airports\n".data(using: .utf8)!)

// MARK: - CIFP fix + airport-origin lookup

var cifp: OpaquePointer?
guard sqlite3_open_v2(cifpPath, &cifp, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    FileHandle.standardError.write("cannot open cifp\n".data(using: .utf8)!); exit(1)
}
/// Distinct fix idents + coords for an airport's coded procedures. `ORDER BY` makes the row order —
/// and therefore the coord chosen for a duplicate ident — DETERMINISTIC (run-to-run reproducible).
func airportFixes(_ icao: String) -> [(id: String, lat: Double, lon: Double)] {
    assert(!icao.isEmpty, "airportFixes: empty icao")
    var st: OpaquePointer?
    let q = "SELECT DISTINCT l.fix, l.lat, l.lon FROM leg l JOIN procedure p ON l.procedure_id=p.id WHERE p.airport=?1 AND l.lat IS NOT NULL AND l.fix<>'' ORDER BY l.fix, l.lat, l.lon"
    guard sqlite3_prepare_v2(cifp, q, -1, &st, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(st) }
    sqlite3_bind_text(st, 1, icao, -1, SQLITE_TRANSIENT_T)
    var out: [(String, Double, Double)] = []
    var guardN = 0
    while sqlite3_step(st) == SQLITE_ROW {
        guardN += 1; assert(guardN < 1_000_000, "airportFixes: runaway row count")
        guard let c = sqlite3_column_text(st, 0) else { continue }
        out.append((String(cString: c), sqlite3_column_double(st, 1), sqlite3_column_double(st, 2)))
    }
    return out
}

/// Build ident→coord map DETERMINISTICALLY (first row wins; `airportFixes` ORDER BY makes "first"
/// reproducible run-to-run — the actual M2 bug). We deliberately do NOT drop an ident that appears at
/// two coordinates: RANSAC's 450 m inlier gate already rejects a wrong/duplicate coord as an outlier,
/// so keeping the deterministic first coord costs no correctness but preserves recall (dropping it
/// silently lost otherwise-clean fits). Only a pathological >0.5° collision — the same ident naming two
/// far-apart places, which even RANSAC could coincidentally consense — is dropped.
func fixCoordMap(_ fixes: [(id: String, lat: Double, lon: Double)]) -> [String: (Double, Double)] {
    var map: [String: (Double, Double)] = [:]
    var pathological = Set<String>()
    for f in fixes {
        guard f.lat.isFinite, f.lon.isFinite, abs(f.lat) <= 90, abs(f.lon) <= 180 else { continue }
        if let existing = map[f.id] {
            if abs(existing.0 - f.lat) > 0.5 || abs(existing.1 - f.lon) > 0.5 { pathological.insert(f.id) }
        } else {
            map[f.id] = (f.lat, f.lon)
        }
    }
    for id in pathological { map.removeValue(forKey: id) }
    return map
}
/// Airport ENU origin = mean of its runway thresholds (always present, precise).
func airportOrigin(_ icao: String) -> (lat: Double, lon: Double)? {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(cifp, "SELECT avg(lat), avg(lon) FROM runway WHERE airport=?1 AND lat IS NOT NULL", -1, &st, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(st) }
    sqlite3_bind_text(st, 1, icao, -1, SQLITE_TRANSIENT_T)
    guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
    return (sqlite3_column_double(st, 0), sqlite3_column_double(st, 1))
}

// MARK: - ENU helpers (local tangent plane in metres about an origin)

func enu(lat: Double, lon: Double, lat0: Double, lon0: Double) -> SIMD2<Double> {
    SIMD2((lon - lon0) * 111_320.0 * cos(lat0 * .pi / 180), (lat - lat0) * 111_320.0)
}
func fromENU(_ e: Double, _ n: Double, lat0: Double, lon0: Double) -> (lat: Double, lon: Double) {
    (lat0 + n / 111_320.0, lon0 + e / (111_320.0 * cos(lat0 * .pi / 180)))
}

// MARK: - plate PDF → CGImage

func plateImage(pdf: String) -> (cg: CGImage, w: Int, h: Int)? {
    let local = "\(cacheDir)/\(pdf)"
    if !FileManager.default.fileExists(atPath: local) {
        guard !offline else { return nil }
        guard let url = URL(string: "https://aeronav.faa.gov/d-tpp/\(cycle)/\(pdf)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 40); req.setValue("CommSight/1.0", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0); var data: Data?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if (r as? HTTPURLResponse)?.statusCode == 200, let d, d.starts(with: [0x25,0x50,0x44,0x46]) { data = d }
            sem.signal()
        }.resume()
        sem.wait()
        guard let data else { return nil }
        try? data.write(to: URL(fileURLWithPath: local))
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: local)), let page = doc.page(at: 0) else { return nil }
    let box = page.bounds(for: .mediaBox)
    let longEdge: CGFloat = 3400
    let scale = longEdge / max(box.width, box.height)
    let W = Int(box.width * scale), H = Int(box.height * scale)
    guard W > 1, H > 1, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.scaleBy(x: scale, y: scale)
    withExtendedLifetime(doc) { page.draw(with: .mediaBox, to: ctx) }   // keep the document alive through the draw
    guard let cg = ctx.makeImage() else { return nil }
    return (cg, W, H)
}

// MARK: - OCR

struct TextBox { let t: String; let c: Double; let x: Int; let y: Int; let w: Int; let h: Int }
func ocr(_ cg: CGImage, W: Int, H: Int) -> [TextBox] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.minimumTextHeight = 0.004
    do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { return [] }
    var out: [TextBox] = []
    for obs in req.results ?? [] {
        guard let top = obs.topCandidates(1).first else { continue }
        let bb = obs.boundingBox
        out.append(TextBox(t: top.string, c: Double(top.confidence),
                           x: Int(bb.midX * CGFloat(W)), y: Int((1 - bb.midY) * CGFloat(H)),
                           w: Int(bb.width * CGFloat(W)), h: Int(bb.height * CGFloat(H))))
    }
    return out
}

// MARK: - structured extraction (harvest everything useful — future features)

let cornerRx = try! NSRegularExpression(pattern: #"(\d{1,3})°(\d{1,2})['′]([NS])\D+(\d{1,3})°(\d{1,2})['′]([EW])"#)
func cornerLatLon(_ boxes: [TextBox]) -> (lat: Double, lon: Double)? {
    for b in boxes {
        let s = b.t
        let r = NSRange(s.startIndex..., in: s)
        guard let m = cornerRx.firstMatch(in: s, range: r) else { continue }
        func g(_ i: Int) -> String { let rr = m.range(at: i); return rr.location == NSNotFound ? "" : String(s[Range(rr, in: s)!]) }
        let latDeg = Double(g(1)) ?? 0, latMin = Double(g(2)) ?? 0
        let lonDeg = Double(g(4)) ?? 0, lonMin = Double(g(5)) ?? 0
        var lat = latDeg + latMin / 60, lon = lonDeg + lonMin / 60
        if g(3) == "S" { lat = -lat }
        if g(6) == "W" { lon = -lon }
        return (lat, lon)
    }
    return nil
}
let freqRx = try! NSRegularExpression(pattern: #"\b1[0-3][0-9]\.\d{1,3}\b"#)
func frequencies(_ boxes: [TextBox]) -> [String] {
    var set = Set<String>()
    for b in boxes {
        let r = NSRange(b.t.startIndex..., in: b.t)
        for m in freqRx.matches(in: b.t, range: r) {
            let f = String(b.t[Range(m.range, in: b.t)!])
            if let v = Double(f), v >= 108, v <= 137.99 { set.insert(f) }
        }
    }
    return set.sorted()
}
func courses(_ boxes: [TextBox]) -> [Int] {
    var set = Set<Int>()
    for b in boxes where b.t.contains("°") {
        let digits = b.t.prefix(while: { !( $0 == "°") }).filter(\.isNumber)
        if digits.count >= 2, digits.count <= 3, let v = Int(digits.suffix(3)), v <= 360 { set.insert(v) }
    }
    return set.sorted()
}
func isFixIdent(_ s: String) -> Bool { s.count >= 3 && s.count <= 5 && s.allSatisfy { $0.isLetter && $0.isUppercase } }

/// 2D spread (minor/major PCA std ratio) of a point cloud: 0 = collinear, 1 = isotropic. Guards the
/// collinear-approach-fix failure mode — 3 fixes strung along the final approach course fit a
/// similarity with low residual but leave the perpendicular scale UNCONSTRAINED, so the plate could
/// be stretched sideways undetected. We require a minimum spread before trusting a fit.
func spread2D(_ pts: [SIMD2<Double>]) -> Double {
    guard pts.count >= 2 else { return 0 }
    var mean = SIMD2<Double>(0, 0); for p in pts { mean += p }; mean /= Double(pts.count)
    var cxx = 0.0, cyy = 0.0, cxy = 0.0
    for p in pts { let d = p - mean; cxx += d.x * d.x; cyy += d.y * d.y; cxy += d.x * d.y }
    let tr = cxx + cyy, det = cxx * cyy - cxy * cxy
    let disc = max(0, tr * tr - 4 * det)
    let l1 = (tr + disc.squareRoot()) / 2, l2 = (tr - disc.squareRoot()) / 2
    guard l1 > 1e-9 else { return 0 }
    return (max(0, l2) / l1).squareRoot()
}

// MARK: - robust similarity fit with outlier rejection

struct GeorefResult { let center: (lat: Double, lon: Double); let widthMeters: Double; let rotationDeg: Double
                      let rms: Double; let inliers: Int; let spread: Double; let confident: Bool }

/// RANSAC over fix→pixel candidates. A fix ident can appear at several pixels on a plate (the plan
/// symbol, the missed-approach track, the profile view, the minimums table). We must select the
/// consistent PLAN-VIEW cluster, not crop by hand. Each hypothesis is a 2-fix minimal fit; a fix is
/// an inlier if ANY of its pixel candidates lands within threshold; the best consensus wins, then a
/// least-squares fit over the inlier pixels gives the final placement. Bounded loops throughout.
func ransacGeoref(byFix: [String: [(px: SIMD2<Double>, world: SIMD2<Double>)]], W: Int, H: Int,
                  lat0: Double, lon0: Double, hasAirportOrigin: Bool) -> GeorefResult? {
    assert(W > 1 && H > 1, "ransacGeoref: implausible image size")
    assert(lat0.isFinite && lon0.isFinite, "ransacGeoref: non-finite origin")
    // Bound the candidate explosion: a plate that OCRs many fix idents × many pixel occurrences makes
    // the #fixes² × candidates² nest costly. Cap the idents considered and the pixels per ident.
    let MAX_FIXES = 40, MAX_PX_PER_FIX = 12
    let ids = Array(byFix.keys.sorted().prefix(MAX_FIXES))         // sorted → deterministic hypothesis order
    guard ids.count >= 2 else { return nil }
    let capped = Dictionary(uniqueKeysWithValues: ids.map { ($0, Array(byFix[$0]!.prefix(MAX_PX_PER_FIX))) })
    let byFix = capped
    let wD = Double(W), hD = Double(H)
    let inlierThreshM = 450.0
    var best: (inliers: Int, rms: Double, pts: [(px: SIMD2<Double>, world: SIMD2<Double>)])?

    func inlierSet(_ pl: PlateSimilarity.Placement) -> [(px: SIMD2<Double>, world: SIMD2<Double>)] {
        var pts: [(SIMD2<Double>, SIMD2<Double>)] = []
        for id in ids {                                             // one best pixel per fix (rule 2 bound: #fixes)
            var bd = Double.infinity, bp: (SIMD2<Double>, SIMD2<Double>)?
            for cp in byFix[id]! {
                let pred = PlateSimilarity.forwardModel(pl, imageW: wD, imageH: hD, px: cp.px.x, py: cp.px.y)
                let d = simd_distance(pred, cp.world); if d < bd { bd = d; bp = cp }
            }
            if bd <= inlierThreshM, let bp { pts.append(bp) }
        }
        return pts
    }

    for i in 0..<ids.count {                                        // bounded: #fixes² × candidates²
        for j in (i + 1)..<ids.count {
            for pa in byFix[ids[i]]! {
                for pb in byFix[ids[j]]! {
                    guard let r0 = PlateSimilarity.georeference(pixels: [pa.px, pb.px], world: [pa.world, pb.world],
                                                               imageW: wD, imageH: hD),
                          r0.placement.widthMeters > 8_000, r0.placement.widthMeters < 250_000 else { continue }
                    let inliers = inlierSet(r0.placement)
                    guard inliers.count >= 2,
                          let rf = PlateSimilarity.georeference(pixels: inliers.map(\.px), world: inliers.map(\.world),
                                                               imageW: wD, imageH: hD) else { continue }
                    if best == nil || inliers.count > best!.inliers || (inliers.count == best!.inliers && rf.rmsMeters < best!.rms) {
                        best = (inliers.count, rf.rmsMeters, inliers)
                    }
                }
            }
        }
    }
    guard let b = best,
          let rf = PlateSimilarity.georeference(pixels: b.pts.map(\.px), world: b.pts.map(\.world), imageW: wD, imageH: hD)
    else { return nil }
    let pl = rf.placement
    let center = fromENU(pl.centerEast, pl.centerNorth, lat0: lat0, lon0: lon0)
    let spread = spread2D(b.pts.map(\.px))
    // Where does the AIRPORT (ENU origin) land on the page under this fit? A correct fit puts it in
    // the plan view (upper-centre); a low-residual fit over the WRONG fixes (a coincidental cluster)
    // puts it outside the page or in the profile/margins. This is the discriminator that low rms +
    // few inliers alone miss.
    // CRITICAL: this discriminator is only valid when the ENU origin IS the true airport (mean runway
    // threshold). For no-runway airports (heliport/seaplane/missing CIFP runway rows) the origin falls
    // back to an OCR'd corner tick, and testing "does the corner land in the plan view" is vacuously
    // true — it would silently disable the primary false-positive guard (H1). Fail CLOSED: without a
    // real airport origin, the plate cannot be confidently auto-aligned (still harvested for the corpus).
    let apPix = PlateSimilarity.worldToPixel(pl, imageW: wD, imageH: hD, east: 0, north: 0)
    let airportInPlanView = hasAirportOrigin
        && apPix.x > 0.03 * wD && apPix.x < 0.97 * wD && apPix.y > 0.02 * hD && apPix.y < 0.68 * hD
    // North-up prior: EVERY FAA d-TPP plan view is drawn true-north-up, so a correct fit's rotation
    // must be ≈0 (a few degrees of OCR/label-offset noise). A large rotation means RANSAC locked onto
    // a coincidental cluster (e.g. a vertical column of fix names in a route table) — reject it. This
    // is the discriminator a low residual alone misses (a wrong subset can fit tightly but rotated).
    let northUp = abs(PlateSimilarity.normalizeDeg(pl.rotationDeg)) < 12
    // Confident: ≥3 mutually-consistent fixes (2 always fit exactly → no validation; 3+ with a tight
    // residual proves the matches are real), the airport lands in the plan view, north-up, plausible
    // scale. NOTE no 2D-spread requirement: a SIMILARITY has uniform scale, so collinear approach
    // fixes still fully determine it — spread is a diagnostic only.
    let confident = b.inliers >= 3 && rf.rmsMeters < 250 && airportInPlanView && northUp
        && pl.widthMeters > 8_000 && pl.widthMeters < 250_000
    return GeorefResult(center: center, widthMeters: pl.widthMeters, rotationDeg: pl.rotationDeg,
                        rms: rf.rmsMeters, inliers: b.inliers, spread: spread, confident: confident)
}

/// Shared georef derivation used by BOTH the OCR run and `--regeoref` (so re-deriving from the corpus
/// applies the exact same gates as a fresh run). From an airport's fix map + (runway) origin + the
/// plate's OCR text boxes, build pixel↔world control points and solve. Returns the result + the matched
/// fix hits (for the corpus). Skips near-antimeridian origins (L3: linear ENU + avg(lon) break there).
func computeGeoref(fixMap: [String: (Double, Double)], origin: (lat: Double, lon: Double)?,
                   corner: (lat: Double, lon: Double)?, boxes: [TextBox], W: Int, H: Int)
    -> (geo: GeorefResult?, fixHits: [(id: String, x: Int, y: Int, lat: Double, lon: Double)]) {
    assert(W > 1 && H > 1, "computeGeoref: implausible image size")
    let lat0 = origin?.lat ?? corner?.lat
    let lon0 = origin?.lon ?? corner?.lon
    guard let lat0, let lon0, lat0.isFinite, lon0.isFinite, abs(lat0) <= 90, abs(lon0) <= 179.5 else {
        return (nil, [])
    }
    var byFix: [String: [(px: SIMD2<Double>, world: SIMD2<Double>)]] = [:]
    var fixHits: [(id: String, x: Int, y: Int, lat: Double, lon: Double)] = []
    var guardN = 0
    for b in boxes {
        guardN += 1; assert(guardN < 1_000_000, "computeGeoref: runaway box count")
        let tok = b.t.trimmingCharacters(in: .whitespaces).uppercased()
        guard isFixIdent(tok), let c = fixMap[tok] else { continue }
        byFix[tok, default: []].append((SIMD2(Double(b.x), Double(b.y)), enu(lat: c.0, lon: c.1, lat0: lat0, lon0: lon0)))
        fixHits.append((tok, b.x, b.y, c.0, c.1))
    }
    // hasAirportOrigin = a TRUE runway-derived origin (not a corner-tick fallback) → H1 gate.
    let geo = ransacGeoref(byFix: byFix, W: W, H: H, lat0: lat0, lon0: lon0, hasAirportOrigin: origin != nil)
    return (geo, fixHits)
}

// MARK: - JSON helpers (hand-rolled so numbers stay compact)

// NaN/±Inf render as `nan`/`inf` under %f — INVALID JSON that would make the whole file unparseable
// (and silently drop EVERY overlay). Emit 0 instead; upstream guards keep non-finite values out of
// confident entries, so a 0 here only appears on already-rejected/diagnostic fields (M4).
func jnum(_ d: Double, _ p: Int = 6) -> String { d.isFinite ? String(format: "%.\(p)f", d) : "0" }
func jstr(_ s: String) -> String {
    var o = "\""
    for ch in s.unicodeScalars {
        switch ch { case "\"": o += "\\\""; case "\\": o += "\\\\"; case "\n": o += "\\n"; case "\t": o += "\\t"
        default: o += ch.value < 0x20 ? String(format: "\\u%04x", ch.value) : String(ch) }
    }
    return o + "\""
}

// MARK: - run (RESUMABLE: ocr.jsonl is append-only + the source of truth; georef.json is derived
// from it and re-flushed periodically, so a killed run resumes without reprocessing.)

// georef entries keyed by PDF filename → dedup by construction (a shared/regional doc referenced by
// many airports can only produce ONE key, so the JSON is never `{"X":{…},"X":{…}}`) (M1).
var georefByPdf: [String: String] = [:]
var done = Set<String>()

/// The distilled bundle-able entry BODY for a plate (no `"pdf":` prefix — the caller keys by pdf).
func entryBody(airport: String, name: String, centerLat: Double, centerLon: Double,
               widthMeters: Double, rotationDeg: Double, rmsMeters: Double, inliers: Int) -> String {
    "{\"airport\":\(jstr(airport)),\"name\":\(jstr(name)),\"centerLat\":\(jnum(centerLat)),\"centerLon\":\(jnum(centerLon)),\"widthMeters\":\(jnum(widthMeters,1)),\"rotationDeg\":\(jnum(rotationDeg,2)),\"rmsMeters\":\(jnum(rmsMeters,1)),\"inliers\":\(inliers)}"
}
func flushGeoref() {
    let body = georefByPdf.keys.sorted().map { "\(jstr($0)):\(georefByPdf[$0]!)" }.joined(separator: ",")
    let json = "{\"cycle\":\(jstr(cycle)),\"plates\":{\(body)}}"
    try? json.write(toFile: outPath, atomically: true, encoding: .utf8)
}

// Per-airport CIFP lookups are cached so `--regeoref` (and the airport-major run) query each airport once.
var fixMapCache: [String: [String: (Double, Double)]] = [:]
var originCache: [String: (lat: Double, lon: Double)?] = [:]
func airportData(_ icao: String) -> (fixMap: [String: (Double, Double)], origin: (lat: Double, lon: Double)?) {
    if let fm = fixMapCache[icao], let og = originCache[icao] { return (fm, og) }
    let fm = fixCoordMap(airportFixes(icao)); let og = airportOrigin(icao)
    fixMapCache[icao] = fm; originCache[icao] = og
    return (fm, og)
}

// ---- --regeoref: re-derive plate_georef.json from the EXISTING OCR corpus under the CURRENT gates,
//      WITHOUT re-rendering/re-OCR'ing (fast; reuses the expensive OCR). Then exit. ----
if flag("--regeoref") {
    guard let corpus = try? String(contentsOfFile: ocrOutPath, encoding: .utf8) else {
        FileHandle.standardError.write("--regeoref: cannot read corpus \(ocrOutPath)\n".data(using: .utf8)!); exit(1)
    }
    var n = 0, conf = 0
    for line in corpus.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pdf = o["pdf"] as? String, let icao = o["airport"] as? String,
              let W = o["imageW"] as? Int, let H = o["imageH"] as? Int, W > 1, H > 1,
              let rawBoxes = o["ocr"] as? [[String: Any]] else { continue }
        if let only = onlyAirport, icao != only { continue }
        n += 1
        let boxes = rawBoxes.compactMap { b -> TextBox? in
            guard let t = b["t"] as? String, let x = b["x"] as? Int, let y = b["y"] as? Int else { return nil }
            return TextBox(t: t, c: (b["c"] as? Double) ?? 1, x: x, y: y, w: (b["w"] as? Int) ?? 0, h: (b["h"] as? Int) ?? 0)
        }
        var corner: (lat: Double, lon: Double)?
        if let cc = o["corner"] as? [String: Any], let la = cc["lat"] as? Double, let lo = cc["lon"] as? Double { corner = (la, lo) }
        let ad = airportData(icao)
        let (geo, _) = computeGeoref(fixMap: ad.fixMap, origin: ad.origin, corner: corner, boxes: boxes, W: W, H: H)
        if let g = geo, g.confident {
            georefByPdf[pdf] = entryBody(airport: icao, name: (o["name"] as? String) ?? "",
                                         centerLat: g.center.lat, centerLon: g.center.lon, widthMeters: g.widthMeters,
                                         rotationDeg: g.rotationDeg, rmsMeters: g.rms, inliers: g.inliers)
            conf += 1
        }
        if n % 500 == 0 { FileHandle.standardError.write("  regeoref \(n), \(conf) confident\n".data(using: .utf8)!) }
    }
    flushGeoref()
    FileHandle.standardError.write("REGEOREF DONE: \(n) plates re-derived, \(conf) confident -> \(outPath)\n".data(using: .utf8)!)
    exit(0)
}

// Load prior progress from an existing corpus (resume).
if let existing = try? String(contentsOfFile: ocrOutPath, encoding: .utf8) {
    for line in existing.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pdf = o["pdf"] as? String else { continue }
        done.insert(pdf)
        if let g = o["georef"] as? [String: Any], (g["confident"] as? Bool) == true {
            func n(_ k: String) -> Double { (g[k] as? Double) ?? 0 }
            georefByPdf[pdf] = entryBody(airport: (o["airport"] as? String) ?? "", name: (o["name"] as? String) ?? "",
                                         centerLat: n("centerLat"), centerLon: n("centerLon"), widthMeters: n("widthMeters"),
                                         rotationDeg: n("rotationDeg"), rmsMeters: n("rmsMeters"), inliers: Int(n("inliers")))
        }
    }
    FileHandle.standardError.write("resume: \(done.count) plates already done, \(georefByPdf.count) confident\n".data(using: .utf8)!)
}
// L1: a crash mid-write can leave a trailing partial line (no newline); appending would concatenate
// the next record onto it. Truncate the corpus to the last COMPLETE line before we append.
if let handle = FileHandle(forUpdatingAtPath: ocrOutPath), let all = try? Data(contentsOf: URL(fileURLWithPath: ocrOutPath)) {
    // Cut back to just after the last newline. No newline anywhere ⇒ cut = 0 (the whole file is one
    // partial line from a crash during the very first record) — truncate it entirely.
    let cut = all.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
    if cut < all.count { try? handle.truncate(atOffset: UInt64(cut)) }
    try? handle.close()
}
if !FileManager.default.fileExists(atPath: ocrOutPath) { FileManager.default.createFile(atPath: ocrOutPath, contents: nil) }
let ocrOut = FileHandle(forWritingAtPath: ocrOutPath)!
ocrOut.seekToEndOfFile()                                       // append
var nDone = 0, nConfident = 0, nControlOK = 0

let airportsSorted = dtpp.airports.keys.sorted()
outer: for icao in airportsSorted {
    if let only = onlyAirport, icao != only { continue }
    let ad = airportData(icao)

    for rec in dtpp.airports[icao] ?? [] {
        if let lim = limit, nDone >= lim { break outer }
        if done.contains(rec.f) { continue }                  // resume: skip already-processed
        guard let (cg, W, H) = plateImage(pdf: rec.f) else { continue }
        nDone += 1
        done.insert(rec.f)                                    // M1: don't reprocess a shared PDF under other airports
        let boxes = ocr(cg, W: W, H: H)
        let corner = cornerLatLon(boxes)
        let (geo, fixHits) = computeGeoref(fixMap: ad.fixMap, origin: ad.origin, corner: corner, boxes: boxes, W: W, H: H)
        if geo != nil { nControlOK += 1 }
        if geo?.confident == true { nConfident += 1 }

        // ---- rich per-plate OCR record (local corpus) ----
        var line = "{\"pdf\":\(jstr(rec.f)),\"airport\":\(jstr(icao)),\"name\":\(jstr(rec.n)),\"cat\":\(jstr(rec.c)),\"cycle\":\(jstr(cycle)),\"imageW\":\(W),\"imageH\":\(H)"
        if let corner { line += ",\"corner\":{\"lat\":\(jnum(corner.lat)),\"lon\":\(jnum(corner.lon))}" }
        line += ",\"frequencies\":[\(frequencies(boxes).map(jstr).joined(separator: ","))]"
        line += ",\"courses\":[\(courses(boxes).map(String.init).joined(separator: ","))]"
        line += ",\"fixes\":[" + fixHits.map { "{\"id\":\(jstr($0.id)),\"x\":\($0.x),\"y\":\($0.y),\"lat\":\(jnum($0.lat)),\"lon\":\(jnum($0.lon))}" }.joined(separator: ",") + "]"
        if let g = geo {
            line += ",\"georef\":{\"centerLat\":\(jnum(g.center.lat)),\"centerLon\":\(jnum(g.center.lon)),\"widthMeters\":\(jnum(g.widthMeters,1)),\"rotationDeg\":\(jnum(g.rotationDeg,2)),\"rmsMeters\":\(jnum(g.rms,1)),\"inliers\":\(g.inliers),\"spread\":\(jnum(g.spread,3)),\"confident\":\(g.confident)}"
        }
        line += ",\"ocr\":[" + boxes.map { "{\"t\":\(jstr($0.t)),\"c\":\(jnum($0.c,2)),\"x\":\($0.x),\"y\":\($0.y),\"w\":\($0.w),\"h\":\($0.h)}" }.joined(separator: ",") + "]}"
        ocrOut.write((line + "\n").data(using: .utf8)!)

        // ---- distilled georef entry (bundle-able, deduped by pdf) ----
        if let g = geo, g.confident {
            georefByPdf[rec.f] = entryBody(airport: icao, name: rec.n, centerLat: g.center.lat, centerLon: g.center.lon,
                                           widthMeters: g.widthMeters, rotationDeg: g.rotationDeg, rmsMeters: g.rms, inliers: g.inliers)
        }
        if nDone % 25 == 0 { FileHandle.standardError.write("  +\(nDone) this run, \(georefByPdf.count) confident total\n".data(using: .utf8)!) }
        if nDone % 200 == 0 { try? ocrOut.synchronize(); flushGeoref() }   // crash-safe checkpoint
    }
}
try? ocrOut.synchronize(); ocrOut.closeFile()
flushGeoref()
FileHandle.standardError.write("DONE: +\(nDone) this run, \(nControlOK) fitted, \(nConfident) newly confident, \(georefByPdf.count) confident total -> \(outPath), corpus -> \(ocrOutPath)\n".data(using: .utf8)!)
