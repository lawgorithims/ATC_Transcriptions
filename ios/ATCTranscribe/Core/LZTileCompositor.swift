import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One cell's decision, expanded for the detail card.
struct LZSampleInfo {
    let score: Int                     // 0...100, 0 when vetoed
    let vetoed: Bool
    let surfaceClass: UInt8
    let slopeDeg: Double?
    let roughM: Double?
    let hazard: Double                 // 0...1
    let confidence: Int?               // percent, nil when unknown
    let coarseTerrain: Bool
    let rules: [LZFiredRule]           // in evaluation order: vetoes, caps, then flags

    var surfaceName: String { LZPack.className(surfaceClass) }
}

/// Turns fact tiles into a rendered risk raster, applying the aircraft-compiled ruleset at
/// SERVE time rather than at build time.
///
/// WHY COMPOSITE HERE AND NOT IN A SHADER
/// The loopback tile server already composites tiles on the CPU (overzoom, seam blending, format
/// transcode), so slotting in here means the result is an ORDINARY raster layer. That buys two
/// things a custom style layer could not: correct z-order (the heatmap sits under the chart's
/// linework, above the basemap), and globe correctness — only the plain raster path is subdivided
/// for the sphere in our MapLibre fork, so a bespoke layer would inherit the flat-quad bug that
/// hillshade already has.
///
/// WHY IT IS SAFE ON THE SERVER'S CONCURRENT QUEUE
/// Every stored property is immutable, `MBTilesReader` opens SQLite with FULLMUTEX, and `NSCache`
/// is thread-safe. There is no lock because there is no mutable shared state.
///
/// THE PER-PIXEL PATH IS INTEGER-ONLY
/// 65,536 pixels x 4 plane lookups per tile, on the same queue that decodes chart tiles during a
/// pan. No allocation, no floating point, no per-pixel branching beyond the veto test.
final class LZTileCompositor {

    /// What the layer has to say about one cell. THREE states, never two.
    ///
    /// Collapsing `excluded` into `unknown` was a real bug in the first version of this file: a
    /// veto returned nil, the renderer skipped the pixel, and the Organ Mountains — 40-50 degree
    /// slopes under forest, the most lethal ground in the pilot cell — painted as NOTHING, exactly
    /// like terrain with no data at all. A pilot cannot tell "we know this will kill you" from "we
    /// know nothing here" when both are blank, and the honest rendering of a known-lethal slope is
    /// not silence.
    private enum Verdict {
        case unknown            // no claim — the only state that may render as nothing
        case excluded           // known unlandable — painted affirmatively
        case scored(Int)        // 0...100
    }

    private let store: LZPackStore
    private let rules: LZCompiledRuleset
    private let ramp: [UInt32]                 // 101 RGBA entries, premultiplied, indexed by score
    private let excludedColor: UInt32          // the affirmative "do not attempt" wash
    private let cache = NSCache<NSString, NSData>()

    /// Cache budget. A z13 tile renders to ~10-40 kB of PNG; 24 MB holds a generous pan's worth
    /// without competing with the chart tile cache for memory.
    private static let cacheBudgetBytes = 24 << 20

    let signature: String

    init(store: LZPackStore, rules: LZCompiledRuleset, night: Bool) {
        self.store = store
        self.rules = rules
        self.signature = rules.signature
        self.ramp = Self.buildRamp(night: night)
        self.excludedColor = Self.buildExcluded(night: night)
        cache.totalCostLimit = Self.cacheBudgetBytes
        assert(ramp.count == LZCompiledRuleset.scoreMax + 1, "ramp must cover every score")
        assert(!signature.isEmpty, "compositor needs a signature to key its cache")
    }

    // MARK: - Ramp

    /// The affirmative "do not attempt" wash: water, forest, built-up, and slope past the veto.
    /// Deliberately the MOST opaque thing this layer draws — "paint hazards, whisper opportunities"
    /// means the known-lethal ground is what reads first, not the pleasant fields.
    private static func buildExcluded(night: Bool) -> UInt32 {
        // Deep red. Kept translucent enough that the sectional's linework still reads through it:
        // the pilot must be able to see WHAT the terrain is, not just that we rejected it.
        return night ? premultiplied(r: 0.78, g: 0.10, b: 0.12, a: 0.42)
                     : premultiplied(r: 0.80, g: 0.08, b: 0.10, a: 0.50)
    }

    /// Score -> colour across the FULL range, with a deliberately U-SHAPED opacity curve.
    ///
    /// The naive choice — opacity rising or falling monotonically with score — fails on real
    /// ground. This pilot cell is 84% Chihuahuan desert scrub, which scores "poor" almost
    /// everywhere, so a heavy low end washes the entire sectional in amber and tells the pilot
    /// nothing they could act on. The baseline is not the message.
    ///
    /// The two things worth calling out are the extremes: ground we EXCLUDE (handled above, the
    /// strongest wash this layer draws) and ground actually worth aiming at. The unremarkable
    /// middle is kept quiet so the chart reads through it and the good ground pops out of it.
    ///
    /// Only `unknown` renders as nothing. Absence of paint is a claim of NOTHING — never a claim of
    /// safety, and never a claim of danger either — which is why the legend has to say so.
    private static func buildRamp(night: Bool) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: LZCompiledRuleset.scoreMax + 1)
        let dim: Double = night ? 0.80 : 1.0
        for s in 0...LZCompiledRuleset.scoreMax {
            let t = Double(s) / Double(LZCompiledRuleset.scoreMax)
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0
            if t >= 0.62 {                                   // favourable: green, and MEANT to be seen
                let k = (t - 0.62) / 0.38
                r = 0.24 * (1 - k); g = 0.64 + 0.22 * k; b = 0.30 * (1 - k)
                a = 0.26 + 0.16 * k
            } else if t >= 0.34 {                            // marginal: amber, quiet
                let k = (t - 0.34) / 0.28
                r = 0.92 - 0.26 * k; g = 0.58 + 0.20 * k; b = 0.12
                a = 0.18 + 0.06 * k
            } else {                                         // poor: the desert baseline — quietest
                let k = t / 0.34
                r = 0.84; g = 0.22 + 0.36 * k; b = 0.12
                a = 0.24 - 0.06 * k
            }
            out[s] = Self.premultiplied(r: r, g: g, b: b, a: a * dim)
        }
        return out
    }

    /// Pack a premultiplied colour for `CGImageAlphaInfo.premultipliedFirst | byteOrder32Little`.
    ///
    /// That combination means the 32-bit word is read little-endian as ARGB, so the byte layout in
    /// memory is B,G,R,A and the word must be `A<<24 | R<<16 | G<<8 | B`. The first version of this
    /// put R and B in each other's slots — GREEN sits in the same place either way, so a green-only
    /// ramp looked perfect while the red exclusion wash rendered as blue-purple. Getting this
    /// backwards is invisible until something non-green paints.
    private static func premultiplied(r: Double, g: Double, b: Double, a: Double) -> UInt32 {
        let A = UInt32(max(0, min(255, Int((a * 255).rounded()))))
        let R = UInt32(max(0, min(255, Int((r * a * 255).rounded()))))
        let G = UInt32(max(0, min(255, Int((g * a * 255).rounded()))))
        let B = UInt32(max(0, min(255, Int((b * a * 255).rounded()))))
        return (A << 24) | (R << 16) | (G << 8) | B
    }

    // MARK: - Scoring

    /// The per-pixel decision. Kept `@inline(__always)` and integer-only — 65,536 calls per tile.
    ///
    /// The ORDER of the three early exits matters. "No elevation data" is an absence of knowledge
    /// and must come back `unknown`; a vetoed CLASS or a slope past the limit is knowledge, and
    /// must come back `excluded` so it gets painted. Treating them alike is what made the Organ
    /// Mountains invisible.
    @inline(__always)
    /// `extent` is OPTIONAL: nil on a schema-1 pack, which predates the plane.
    ///
    /// ⚠️ NIL IS NOT ZERO. Nil means the run was never measured, and the cell must then score
    /// exactly as it did before the plane existed. Zero means the cell carries no open ground at
    /// all, which is a measurement. Collapsing those would turn every pack published so far into a
    /// map of unusable terrain the moment this build shipped.
    private func verdict(cls: UInt8, conf: UInt8, slope: UInt8, rough: UInt8,
                         hazard: UInt8, flags: UInt8, coarse: Bool,
                         extent: UInt8?) -> Verdict {
        if cls == LZPack.classUnknown { return .unknown }
        if rules.vetoOnSlopeNoData && slope == LZPack.slopeNoData { return .unknown }
        if rules.vetoClass[Int(cls)] { return .excluded }
        if slope != LZPack.slopeNoData && slope > rules.slopeVetoAbove { return .excluded }
        // Not enough room is an EXCLUSION, not a low score. A field that is beautiful and far too
        // short is not mediocre ground — it is ground you cannot use, and saying so plainly beats a
        // number the pilot has to interpret under load.
        if let e = extent, e > 0, let vetoAt = rules.extentVetoAtOrBelow, e <= vetoAt {
            return .excluded
        }

        let sum = rules.wSurface * Int(rules.surfaceLUT[Int(cls)])
                + rules.wSlope * Int(rules.slopeLUT[Int(slope)])
                + rules.wRough * Int(rules.roughLUT[Int(rough)])
                + rules.wHazard * Int(rules.hazardLUT[Int(hazard)])
        var s = (sum / 255) * LZCompiledRuleset.scoreMax / 255

        // Caps. Most-conservative-wins: the lowest applicable ceiling holds.
        if coarse { s = min(s, rules.capCoarseTerrain) }
        if flags != 0 {
            for (bit, cap) in rules.capFlag where (flags & bit) != 0 { s = min(s, cap) }
        }
        if conf != LZPack.confUnknown && Int(conf) < rules.capLowConfidenceBelow {
            s = min(s, rules.capLowConfidenceValue)
        }
        // Room, as a ceiling. Only when the plane exists AND the ruleset compiled a table for it —
        // an absent measurement leaves the score untouched.
        if let e = extent, e > 0, !rules.extentCap.isEmpty {
            s = min(s, rules.extentCap[Int(e)])
        }
        return .scored(max(0, min(LZCompiledRuleset.scoreMax, s)))
    }

    /// Numeric score for the card. `nil` means the layer makes no claim; `0` means it actively
    /// excludes the cell — the card must distinguish those, so this cannot collapse them either.
    private func scoreValue(_ v: Verdict) -> Int? {
        switch v {
        case .unknown: return nil
        case .excluded: return 0
        case .scored(let s): return s
        }
    }

    // MARK: - Tile rendering

    /// Render one tile as PNG. Returns nil when the signature is stale (the aircraft or theme
    /// changed while the request was in flight) or when no pack covers the address — both become
    /// a 404, which MapLibre draws as nothing.
    func tilePNG(signature requested: String, z: Int, x: Int, y: Int) -> Data? {
        guard requested == signature else { return nil }
        assert(z >= 0 && z <= 24, "tilePNG: zoom out of range")
        let key = "\(signature)/\(z)/\(x)/\(y)" as NSString
        if let hit = cache.object(forKey: key) { return hit as Data }
        guard let tile = store.planes(z: z, x: x, y: y) else { return nil }
        guard let png = render(tile) else { return nil }
        cache.setObject(png as NSData, forKey: key, cost: png.count)
        return png
    }

    private func render(_ tile: LZTilePlanes) -> Data? {
        let n = LZPack.planeBytes
        let cls = tile.planes[LZPack.planeClass]
        let conf = tile.planes[LZPack.planeConf]
        let slope = tile.planes[LZPack.planeSlope]
        let rough = tile.planes[LZPack.planeRough]
        let hazard = tile.planes[LZPack.planeHazard]
        let flags = tile.planes[LZPack.planeFlags]
        let coarse = tile.isCoarseTerrain
        // nil for a schema-1 tile. Resolved once per tile rather than per pixel: the branch is the
        // same for all 65,536 of them.
        let extent: [UInt8]? = tile.planes.count > LZPack.planeExtent
            ? tile.planes[LZPack.planeExtent] : nil

        var pixels = [UInt32](repeating: 0, count: n)
        var painted = 0
        for i in 0..<n {
            let c: UInt32
            switch verdict(cls: cls[i], conf: conf[i], slope: slope[i], rough: rough[i],
                           hazard: hazard[i], flags: flags[i], coarse: coarse,
                           extent: extent?[i]) {
            case .unknown:  continue                  // the ONLY state that renders as nothing
            case .excluded: c = excludedColor         // known unlandable — say so
            case .scored(let s): c = ramp[s]
            }
            if c != 0 { pixels[i] = c; painted += 1 }
        }
        // A tile with nothing to say is not worth the bytes — let it 404 and draw as nothing,
        // which is also the honest rendering of "no claim here".
        guard painted > 0 else { return nil }
        return encodePNG(pixels)
    }

    private func encodePNG(_ pixels: [UInt32]) -> Data? {
        let side = LZPack.side
        var buf = pixels
        let bytes = buf.withUnsafeMutableBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: side, height: side, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString,
                                                          1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Point sampling (the detail card)

    /// Decode the cell under a coordinate and list every rule that fired, in evaluation order.
    /// This is the explainability path: a score a pilot cannot interrogate is a score they cannot
    /// calibrate against, so every veto and cap names itself here.
    func sample(lon: Double, lat: Double, z: Int = LZPack.side) -> LZSampleInfo? {
        let zoom = min(store.maxZoom, max(store.minZoom, z == LZPack.side ? store.maxZoom : z))
        guard let (tx, ty, px, py) = Self.tilePixel(lon: lon, lat: lat, z: zoom) else { return nil }
        guard let tile = store.planes(z: zoom, x: tx, y: ty) else { return nil }
        guard let cls = tile.value(plane: LZPack.planeClass, x: px, y: py),
              let confRaw = tile.value(plane: LZPack.planeConf, x: px, y: py),
              let slopeRaw = tile.value(plane: LZPack.planeSlope, x: px, y: py),
              let roughRaw = tile.value(plane: LZPack.planeRough, x: px, y: py),
              let hazardRaw = tile.value(plane: LZPack.planeHazard, x: px, y: py),
              let flagsRaw = tile.value(plane: LZPack.planeFlags, x: px, y: py) else { return nil }

        // Deliberately NOT in the guard above: a schema-1 tile has no extent plane, and treating
        // its absence as a decode failure would make every older pack un-tappable.
        let extentRaw = tile.extentRaw(x: px, y: py)
        let v = verdict(cls: cls, conf: confRaw, slope: slopeRaw, rough: roughRaw,
                        hazard: hazardRaw, flags: flagsRaw, coarse: tile.isCoarseTerrain,
                        extent: extentRaw)
        let s = scoreValue(v)
        let excluded: Bool = { if case .excluded = v { return true }; return false }()
        let fired = firedRules(cls: cls, conf: confRaw, slope: slopeRaw, flags: flagsRaw,
                               coarse: tile.isCoarseTerrain, extent: extentRaw)
        return LZSampleInfo(score: s ?? 0, vetoed: excluded, surfaceClass: cls,
                            slopeDeg: LZPack.slopeDegrees(slopeRaw),
                            roughM: LZPack.roughMetres(roughRaw),
                            hazard: Double(hazardRaw) / LZPack.hazardMax,
                            confidence: confRaw == LZPack.confUnknown ? nil : Int(confRaw),
                            coarseTerrain: tile.isCoarseTerrain, rules: fired)
    }

    private func firedRules(cls: UInt8, conf: UInt8, slope: UInt8,
                            flags: UInt8, coarse: Bool, extent: UInt8?) -> [LZFiredRule] {
        var out = [LZFiredRule]()
        // Named FIRST among the vetoes when it fires, because "not enough room" is the reason a
        // pilot most needs to see at the top of a card — the surface may be perfect, and without
        // this the exclusion looks unexplained.
        if let e = extent, e > 0, let vetoAt = rules.extentVetoAtOrBelow, e <= vetoAt {
            out.append(.init(kind: .veto, id: "extent_too_short",
                             text: rules.extentVetoText.isEmpty
                                 ? "Not enough room for your landing distance"
                                 : rules.extentVetoText,
                             cap: nil))
        }
        if rules.vetoClass[Int(cls)] {
            let id = vetoIDForClass(cls)
            out.append(.init(kind: .veto, id: id, text: rules.vetoText[id] ?? id, cap: nil))
        }
        if slope == LZPack.slopeNoData, rules.vetoOnSlopeNoData {
            out.append(.init(kind: .veto, id: "no_terrain_data",
                             text: rules.vetoText["no_terrain_data"] ?? "", cap: nil))
        } else if slope > rules.slopeVetoAbove {
            out.append(.init(kind: .veto, id: "slope_extreme",
                             text: rules.vetoText["slope_extreme"] ?? "", cap: nil))
        }
        if coarse, let t = rules.capText["coarse_terrain"] {
            out.append(.init(kind: .cap, id: "coarse_terrain", text: t, cap: rules.capCoarseTerrain))
        }
        for (bit, cap) in rules.capFlag.sorted(by: { $0.value < $1.value }) where (flags & bit) != 0 {
            let id = capIDForFlag(bit)
            out.append(.init(kind: .cap, id: id, text: rules.capText[id] ?? id, cap: cap))
        }
        if conf != LZPack.confUnknown, Int(conf) < rules.capLowConfidenceBelow {
            out.append(.init(kind: .cap, id: "low_confidence",
                             text: rules.capText["low_confidence"] ?? "",
                             cap: rules.capLowConfidenceValue))
        }
        for f in rules.flagText where (flags & f.bit) != 0 {
            out.append(.init(kind: .flag, id: f.id, text: f.text, cap: nil))
        }
        for a in rules.alwaysText {
            out.append(.init(kind: .flag, id: a.id, text: a.text, cap: nil))
        }
        return out
    }

    private func vetoIDForClass(_ c: UInt8) -> String {
        switch c {
        case LZPack.classWater: return "water"
        case LZPack.classDevelopedDense: return "built_up"
        case LZPack.classForest: return "forest"
        default: return "veto"
        }
    }

    private func capIDForFlag(_ b: UInt8) -> String {
        switch b {
        case LZPack.flagTXCorridor: return "wire_corridor"
        case LZPack.flagRoadBuffer: return "assumed_road_wires"
        case LZPack.flagWetland: return "deceptive_wet"
        default: return "cap"
        }
    }

    /// Web-Mercator: coordinate -> (tile x, tile y, pixel x, pixel y).
    static func tilePixel(lon: Double, lat: Double, z: Int) -> (Int, Int, Int, Int)? {
        guard z >= 0, z <= 24, lat > -85.06, lat < 85.06 else { return nil }
        let n = Double(1 << z)
        let xf = (lon + 180.0) / 360.0 * n
        let yf = (1.0 - asinh(tan(lat * .pi / 180.0)) / .pi) / 2.0 * n
        guard xf.isFinite, yf.isFinite, xf >= 0, yf >= 0, xf < n, yf < n else { return nil }
        let tx = Int(xf), ty = Int(yf)
        let px = min(LZPack.side - 1, Int((xf - Double(tx)) * Double(LZPack.side)))
        let py = min(LZPack.side - 1, Int((yf - Double(ty)) * Double(LZPack.side)))
        return (tx, ty, px, py)
    }
}
