import Foundation

/// The judgment layer for the off-field landability heatmap: a declarative ruleset compiled
/// against the pilot's aircraft into lookup tables the tile compositor can apply per pixel.
///
/// WHY THE RULES ARE DATA AND NOT CODE
///  * Reproducibility — any score is exactly recomputable from (facts, ruleset version). After an
///    incident, "why did it say that" has an answer.
///  * Tuning without a release — weights ride a small file, not a rebuild of 90 MB of tiles.
///  * Explainability — every veto and cap carries its own `card_text`, so the detail card can name
///    the rule that decided a cell. Silent scoring is the thing to avoid: a number a pilot cannot
///    interrogate is a number they cannot calibrate against.
///
/// THE MURPHY CONTRACT
/// The pack is aircraft-agnostic by construction. Aircraft dependence enters HERE, as a per-plane
/// curve plus a veto/cap mask — not as a scalar multiplier. Slope tolerance is a different SHAPE
/// for a Cub than for a jet, not the same shape scaled, so a single "murphy factor" number could
/// not express it. Compiling to 256-entry lookup tables makes the per-pixel cost identical
/// regardless of how complicated the curve is.
///
/// ORDER OF EVALUATION IS LOAD-BEARING
///     veto  -> score is zero, nothing else runs
///     cap   -> an upper bound on what follows
///     score -> weighted sum of per-plane utilities
/// A bonus can never lift a cell past a cap, and nothing can resurrect a veto.
enum LZRulesetError: Error { case malformed(String) }

/// One rule that fired on a cell, for the detail card.
struct LZFiredRule: Equatable {
    enum Kind: String { case veto, cap, flag }
    let kind: Kind
    let id: String
    let text: String
    let cap: Int?
}

/// A compiled, aircraft-specific ruleset. Immutable and `Sendable`: the compositor runs on the
/// tile server's concurrent queue and must not need a lock.
struct LZCompiledRuleset: Sendable {

    /// 256-entry lookup per plane, values 0...255 representing utility 0...1.
    let slopeLUT: [UInt8]
    let roughLUT: [UInt8]
    let hazardLUT: [UInt8]
    let surfaceLUT: [UInt8]

    /// Weights, pre-scaled to sum to 255 so the per-pixel maths is integer-only.
    let wSurface: Int
    let wSlope: Int
    let wRough: Int
    let wHazard: Int

    /// Veto lookups. Indexed by class byte / flag bit.
    let vetoClass: [Bool]
    let vetoOnSlopeNoData: Bool
    let slopeVetoAbove: UInt8          // raw slope byte above which the cell is vetoed

    /// Cap per raw extent byte, 0...100. 255 (saturated) always maps to 100 — "more room than any
    /// light aeroplane can use" must never cap anything. Empty when the ruleset has no extent model.
    let extentCap: [Int]
    /// Raw extent byte at or below which the cell is VETOED, or nil for no extent veto. Zero is
    /// excluded from this: a cell with no open ground at all is already handled by its class.
    let extentVetoAtOrBelow: UInt8?
    let extentVetoText: String
    let extentCapText: String
    /// What the aeroplane actually needs, in metres, for the card to explain the number.
    let requiredRunM: Double

    /// Caps, as 0...100 ceilings.
    let capCoarseTerrain: Int
    let capFlag: [UInt8: Int]
    let capLowConfidenceBelow: Int
    let capLowConfidenceValue: Int

    /// Rule text, for the card.
    let vetoText: [String: String]
    let capText: [String: String]
    let flagText: [(bit: UInt8, id: String, text: String)]
    let alwaysText: [(id: String, text: String)]

    let rulesetID: String
    let rulesetVersion: String

    /// Stable identity of (ruleset, aircraft, theme, pack). Lowercase hex ONLY — it becomes a URL
    /// path segment, and the tile server's path parser splits on "/" and ".", so a dotted version
    /// string here would silently truncate the address.
    let signature: String

    static let scoreMax = 100
}

/// Parses the ruleset document and compiles it against an aircraft profile.
enum LZRulesetCompiler {

    static let resourceName = "lz_ruleset_v1"
    static let resourceSubdirectory = "lz"

    // MARK: - Document model

    private struct Doc: Decodable {
        struct Rule: Decodable {
            let id: String
            let when: String
            let cap: Int?
            let card_text: String
        }
        struct Utility: Decodable {
            let breakpoints: [[Double]]?
            let table: [String: Double]?
        }
        struct Defaults: Decodable {
            let vref_kt: Double
            let glide_ratio: Double
            let surface_tolerance_ref_kt: Double
            let slope_tolerance_scale: Double
            /// Optional so a ruleset published before the distance model still decodes.
            let landing_over_50ft: Double?
        }
        /// How far the aeroplane needs, and what unprepared ground costs it. See the model's own
        /// `note` in the JSON for why this can scale marginal ground but cannot answer "will it fit".
        struct DistanceModel: Decodable {
            let reference_over_50ft: Double
            let applies_to: [String]
            let multiplier_min: Double
            let multiplier_max: Double
            let surface_distance_factor: [String: Double]
        }
        /// Turns the aircraft-agnostic extent plane into a verdict for THIS aeroplane.
        struct ExtentModel: Decodable {
            let unprepared_factor: Double
            let cap_by_ratio: [[Double]]
            let veto_below_ratio: Double
            let veto_card_text: String
            let cap_card_text: String
        }
        struct Energy: Decodable {
            let applies_to: [String]
            let multiplier_min: Double
            let multiplier_max: Double
            let reference_kt: Double
        }
        let id: String
        let version: String
        let requires_facts_schema: Int
        let vetoes: [Rule]
        let caps: [Rule]
        let weights: [String: Double]
        let utilities: [String: Utility]
        let flags: [Rule]
        let aircraft_defaults: Defaults
        let energy_model: Energy
        /// Optional: a ruleset without it behaves exactly as before the distance model existed.
        let distance_model: DistanceModel?
        /// Optional for the same reason, and additionally inert on a schema-1 pack that has no
        /// extent plane to read.
        let extent_model: ExtentModel?
    }

    // MARK: - Loading

    static func loadDocument(bundle: Bundle = .main) -> Data? {
        if let u = bundle.url(forResource: resourceName, withExtension: "json",
                              subdirectory: resourceSubdirectory) ?? bundle
            .url(forResource: resourceName, withExtension: "json") {
            return try? Data(contentsOf: u)
        }
        return nil
    }

    /// Compile a ruleset for one aircraft and theme. Returns nil on ANY malformation — a layer
    /// that cannot be explained must not render, because an unexplainable score is worse than
    /// no score.
    static func compile(document: Data,
                        aircraft: AircraftProfile?,
                        themeKey: String,
                        packStamp: String) -> LZCompiledRuleset? {
        guard let doc = try? JSONDecoder().decode(Doc.self, from: document) else { return nil }
        // The ruleset states the OLDEST schema it needs, and this build may read newer packs than
        // that. Requiring equality meant bumping the pack schema silently invalidated the shipped
        // ruleset and the compiler returned nil — every tile blank, no error anywhere.
        guard LZPack.readableSchemas.contains(doc.requires_facts_schema) else { return nil }

        // Weights must be a partition of unity, or the score is not on the scale the caps assume.
        let names = ["surface", "slope", "rough", "hazard"]
        var w = [Double]()
        for n in names {
            guard let v = doc.weights[n], v >= 0 else { return nil }
            w.append(v)
        }
        let total = w.reduce(0, +)
        guard abs(total - 1.0) < 0.001 else { return nil }

        // Aircraft. Every value the profile genuinely carries is honoured; the rest comes from the
        // conservative default table (see the ruleset's note).
        let d = doc.aircraft_defaults
        // ⚠️ vRefKts, NOT bestGlideKts. This used to read the best-glide speed as though it were
        // the approach speed, and they are different numbers — best glide is flown well above Vref,
        // and the gap widens with the aeroplane. The error was in the safe direction (a faster
        // assumed touchdown tolerates less surface and slope), which is exactly why it survived:
        // nothing looked wrong. A pilot who enters their real numbers now gets their real numbers.
        let vref = max(30.0, min(200.0, Double(aircraft?.vRefKts ?? Int(d.vref_kt))))
        let glide = max(3.0, min(60.0, aircraft?.glideRatio ?? d.glide_ratio))
        // Book landing distance over a 50 ft obstacle. Bounded so a data-entry slip (a ground roll
        // typed in metres, say) cannot invent an aeroplane that lands anywhere — and routed through
        // the site finder's helper so the shading's extent cap and the ranked list decide the
        // ROTORCRAFT case identically. They read the same nil and drew opposite conclusions before.
        let bookDistanceFt = LZSiteFinder.bookLandingDistanceFt(
            for: aircraft,
            fixedWingDefault: d.landing_over_50ft ?? doc.distance_model?.reference_over_50ft ?? 1600.0)

        guard let slopeU = doc.utilities["slope_deg"]?.breakpoints,
              let roughU = doc.utilities["rough_m"]?.breakpoints,
              let hazardU = doc.utilities["hazard"]?.breakpoints,
              let surfaceT = doc.utilities["surface_class"]?.table else { return nil }

        // Slope tolerance is where aircraft capability enters the CURVE rather than a multiplier:
        // a slower aeroplane tolerates more slope for the same outcome, so the whole breakpoint
        // set stretches. Bounded so a data-entry slip cannot invent a bush plane.
        //
        // ⚠️ AND A ROTORCRAFT MUST NOT COME OUT MORE SLOPE-TOLERANT THAN THE REFERENCE. The stretch
        // is a fixed-wing argument: a slower touchdown leaves more margin on sloping ground. Skid
        // gear does not work that way — slope is a rollover limit, not an energy one — so a
        // helicopter's low Vref was quietly widening the very curve it should tighten. Rather than
        // invent a rotorcraft slope limit this model has no source for, it refuses to widen it at
        // all and leaves the conservative fixed-wing curve standing.
        let rawSlopeScale = (d.vref_kt / vref) * d.slope_tolerance_scale
        let slopeScale = aircraft?.isRotorcraft == true
            ? max(0.6, min(1.0, rawSlopeScale))
            : max(0.6, min(1.6, rawSlopeScale))
        let slopeLUT = buildLUT(count: 256) { raw in
            guard let deg = LZPack.slopeDegrees(UInt8(raw)) else { return 0.0 }
            return interpolate(slopeU, at: deg / slopeScale)
        }
        let roughLUT = buildLUT(count: 256) { raw in
            guard let m = LZPack.roughMetres(UInt8(raw)) else { return 0.0 }
            return interpolate(roughU, at: m)
        }
        let hazardLUT = buildLUT(count: 256) { raw in
            interpolate(hazardU, at: Double(raw) / LZPack.hazardMax)
        }

        // Surface utility, with two bounded aircraft modifiers on MARGINAL surfaces only.
        //
        //  1. TOUCHDOWN ENERGY (vref) — how hard the arrival is.
        //  2. LANDING DISTANCE — how much unprepared ground the aeroplane can actually use.
        //
        // Both scale the same marginal surfaces and NEITHER touches the hazard term, because a
        // tower is equally lethal to a Cub and to a Malibu. The distance model can say this much and
        // no more: a 10 m cell does not know how LONG the field is, so "will it fit" is not
        // answerable at pixel level and belongs to the site finder, which searches for runs.
        let e = doc.energy_model
        let energyMul = max(e.multiplier_min, min(e.multiplier_max, 1.3 - vref / e.reference_kt))
        let marginal = Set(e.applies_to)

        let dm = doc.distance_model
        let distanceApplies = Set(dm?.applies_to ?? [])
        var surfaceLUT = [UInt8](repeating: 0, count: 256)
        var requiredFt = [String: Double]()
        for code in 0...255 {
            let name = className(UInt8(code))
            var u = surfaceT[name] ?? 0.0
            if marginal.contains(name) { u = min(1.0, u * energyMul) }
            if let dm, distanceApplies.contains(name) {
                // Required distance on THIS surface = the book number times what the surface costs.
                let factor = dm.surface_distance_factor[name] ?? 1.0
                let need = bookDistanceFt * factor
                requiredFt[name] = need
                // Ratio against the reference aeroplane: needing more than the reference shrinks the
                // usable value of marginal ground, needing less lifts it, both bounded. An aeroplane
                // at the reference distance is unchanged, so the default table stays the default.
                let ratio = dm.reference_over_50ft / max(1.0, need / factor)
                u = min(1.0, u * max(dm.multiplier_min, min(dm.multiplier_max, ratio)))
            }
            surfaceLUT[code] = quantise(u)
        }

        // EXTENT: room to use the ground, compiled against this aeroplane's landing distance.
        //
        // A cap and a veto rather than a weighted term, because "how good is this ground" and "can
        // you use it at all" are different questions. A beautiful 80 m field must not average out
        // to mediocre — it must be excluded, and say why.
        let requiredRunM = bookDistanceFt * 0.3048 * (doc.extent_model?.unprepared_factor ?? 1.5)
        var extentCap = [Int]()
        var extentVetoAtOrBelow: UInt8?
        if let em = doc.extent_model, requiredRunM > 1 {
            extentCap = (0...255).map { raw -> Int in
                // SATURATION IS NOT A LENGTH. 255 means "at least 2550 m", which is more room than
                // any light aeroplane can use, so it can never cap — reading it as exactly 2550 m
                // would penalise an aeroplane needing more than that on ground that is effectively
                // unbounded.
                if UInt8(raw) == LZPack.extentSaturated { return LZCompiledRuleset.scoreMax }
                let ratio = LZPack.extentMetres(UInt8(raw)) / requiredRunM
                // `cap_by_ratio` is already in CAP units (0...100), matching every other cap in the
                // ruleset — `{"id": "coarse_terrain", "cap": 55}`. Scaling it by scoreMax as though
                // it were a 0...1 utility produced caps of 131, 350, 437... which never bind against
                // a score that tops out at 100, so the graded ceiling silently did NOTHING and only
                // the veto worked. Clamped as well as unscaled, so a bad ruleset cannot resurrect it.
                let cap = interpolate(em.cap_by_ratio, at: ratio)
                return max(0, min(LZCompiledRuleset.scoreMax, Int(cap.rounded())))
            }
            // Everything strictly below the veto ratio, EXCEPT zero. Zero means the cell carries no
            // open ground at all, which its surface class already excludes; vetoing on it here would
            // double-report the same fact and hide the real reason on the card.
            let vetoM = requiredRunM * em.veto_below_ratio
            let steps = Int((vetoM / LZPack.extentStepM).rounded(.down))
            if steps >= 1 { extentVetoAtOrBelow = UInt8(min(254, max(1, steps))) }
        }

        // Vetoes.
        var vetoClass = [Bool](repeating: false, count: 256)
        var vetoNoData = false
        var slopeVetoAbove: UInt8 = 254
        var vetoText = [String: String]()
        for r in doc.vetoes {
            vetoText[r.id] = r.card_text
            if let cls = parseClassCondition(r.when) { vetoClass[Int(cls)] = true }
            if r.when == "slope == nodata" { vetoNoData = true }
            if let deg = parseSlopeGreaterThan(r.when) {
                slopeVetoAbove = UInt8(max(0, min(254, Int((deg / LZPack.slopeStepDeg).rounded()))))
            }
        }
        guard !vetoText.isEmpty else { return nil }

        // Caps.
        var capCoarse = LZCompiledRuleset.scoreMax
        var capFlag = [UInt8: Int]()
        var capLowConfBelow = 0
        var capLowConfValue = LZCompiledRuleset.scoreMax
        var capText = [String: String]()
        for r in doc.caps {
            guard let cap = r.cap, cap >= 0, cap <= LZCompiledRuleset.scoreMax else { return nil }
            capText[r.id] = r.card_text
            if r.when == "terrain_source != fine" { capCoarse = cap }
            if let bit = parseFlagCondition(r.when) { capFlag[bit] = cap }
            if let below = parseConfLessThan(r.when) {
                capLowConfBelow = below
                capLowConfValue = cap
            }
        }

        // Flags (annotation only — never touch the score).
        var flagText = [(bit: UInt8, id: String, text: String)]()
        var alwaysText = [(id: String, text: String)]()
        for r in doc.flags {
            if let bit = parseFlagCondition(r.when) {
                flagText.append((bit, r.id, r.card_text))
            } else if r.when == "always" {
                alwaysText.append((r.id, r.card_text))
            }
        }

        // Every veto and cap MUST carry text, or a cell could be decided by a rule that cannot
        // name itself. That is the invariant the whole explainability story rests on.
        for r in doc.vetoes where r.card_text.isEmpty { return nil }
        for r in doc.caps where r.card_text.isEmpty { return nil }

        assert(extentCap.isEmpty || extentCap.count == 256, "extent cap table must be full or absent")
        let sig = signature(rulesetID: doc.id, version: doc.version, vref: vref, glide: glide,
                            slopeScale: slopeScale, energyMul: energyMul,
                            bookDistanceFt: bookDistanceFt,
                            themeKey: themeKey, packStamp: packStamp)

        return LZCompiledRuleset(
            slopeLUT: slopeLUT, roughLUT: roughLUT, hazardLUT: hazardLUT, surfaceLUT: surfaceLUT,
            wSurface: Int((w[0] * 255).rounded()), wSlope: Int((w[1] * 255).rounded()),
            wRough: Int((w[2] * 255).rounded()), wHazard: Int((w[3] * 255).rounded()),
            vetoClass: vetoClass, vetoOnSlopeNoData: vetoNoData, slopeVetoAbove: slopeVetoAbove,
            extentCap: extentCap, extentVetoAtOrBelow: extentVetoAtOrBelow,
            extentVetoText: doc.extent_model?.veto_card_text ?? "",
            extentCapText: doc.extent_model?.cap_card_text ?? "",
            requiredRunM: requiredRunM,
            capCoarseTerrain: capCoarse, capFlag: capFlag,
            capLowConfidenceBelow: capLowConfBelow, capLowConfidenceValue: capLowConfValue,
            vetoText: vetoText, capText: capText, flagText: flagText, alwaysText: alwaysText,
            rulesetID: doc.id, rulesetVersion: doc.version, signature: sig)
    }

    // MARK: - helpers

    private static func buildLUT(count: Int, _ f: (Int) -> Double) -> [UInt8] {
        assert(count == 256, "LUTs are indexed by a byte")
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = quantise(f(i)) }
        return out
    }

    private static func quantise(_ u: Double) -> UInt8 {
        UInt8(max(0, min(255, Int((max(0.0, min(1.0, u)) * 255).rounded()))))
    }

    /// Piecewise-linear interpolation over `[[x, y], ...]`, clamped at both ends.
    static func interpolate(_ pts: [[Double]], at x: Double) -> Double {
        guard let first = pts.first, first.count >= 2 else { return 0 }
        if x <= first[0] { return first[1] }
        var prev = first
        for p in pts.dropFirst() where p.count >= 2 {
            if x <= p[0] {
                let span = p[0] - prev[0]
                guard span > 0 else { return p[1] }
                let t = (x - prev[0]) / span
                return prev[1] + t * (p[1] - prev[1])
            }
            prev = p
        }
        return prev[1]
    }

    static func className(_ code: UInt8) -> String {
        switch code {
        case LZPack.classOpenFirm: return "open_firm"
        case LZPack.classOpenSoft: return "open_soft"
        case LZPack.classCrop: return "crop"
        case LZPack.classBrush: return "brush"
        case LZPack.classForest: return "forest"
        case LZPack.classDevelopedOpen: return "developed_open"
        case LZPack.classDevelopedDense: return "developed_dense"
        case LZPack.classBarrenRough: return "barren_rough"
        case LZPack.classWater: return "water"
        case LZPack.classWetland: return "wetland"
        case LZPack.classSnowIce: return "snow_ice"
        default: return "unknown"
        }
    }

    private static func classCode(_ name: String) -> UInt8? {
        for c in UInt8(0)...UInt8(11) where className(c) == name { return c }
        return nil
    }

    private static func parseClassCondition(_ s: String) -> UInt8? {
        guard s.hasPrefix("class == ") else { return nil }
        return classCode(String(s.dropFirst("class == ".count)))
    }

    private static func parseFlagCondition(_ s: String) -> UInt8? {
        guard s.hasPrefix("flag ") else { return nil }
        switch String(s.dropFirst(5)) {
        case "dof_tower": return LZPack.flagDOFTower
        case "tx_corridor": return LZPack.flagTXCorridor
        case "road_buffer": return LZPack.flagRoadBuffer
        case "water_veto": return LZPack.flagWaterVeto
        case "wetland": return LZPack.flagWetland
        case "coarse_terrain": return LZPack.flagCoarseTerrain
        default: return nil
        }
    }

    private static func parseSlopeGreaterThan(_ s: String) -> Double? {
        guard s.hasPrefix("slope_deg > ") else { return nil }
        return Double(s.dropFirst("slope_deg > ".count))
    }

    private static func parseConfLessThan(_ s: String) -> Int? {
        guard s.hasPrefix("conf < ") else { return nil }
        return Int(s.dropFirst("conf < ".count))
    }

    /// FNV-1a over the inputs that change what a pixel renders. Lowercase hex only.
    /// Every input that changes a pixel must be in here. `bookDistanceFt` joined it with the
    /// distance model: without it, entering a different landing distance recompiles a different LUT
    /// and then serves the PREVIOUS aeroplane's cached tiles under the same URL.
    static func signature(rulesetID: String, version: String, vref: Double, glide: Double,
                          slopeScale: Double, energyMul: Double, bookDistanceFt: Double,
                          themeKey: String, packStamp: String) -> String {
        let parts = [rulesetID, version, themeKey, packStamp,
                     String(format: "%.2f|%.2f|%.4f|%.4f|%.1f",
                            vref, glide, slopeScale, energyMul, bookDistanceFt)]
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
