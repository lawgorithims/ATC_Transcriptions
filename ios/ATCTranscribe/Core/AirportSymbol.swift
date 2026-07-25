import Foundation

/// What an FAA sectional airport symbol says, derived from the airport's attributes.
///
/// The FAA encodes a lot in one small mark, and a pilot reads it at a glance. This is the pure
/// classification — attributes in, a drawing spec out — so the rules are unit-testable and the
/// renderer stays dumb. Reference: FAA Aeronautical Chart Users' Guide, "Airports".
///
/// What we can and cannot know is deliberately explicit. `AirportAttributes` comes from the bundled
/// `airport_symbols.json` (FAA NASR via aviationweather.gov + OurAirports for type, plus the tower
/// frequency already in `airport_ctx.json`); runway geometry comes from `cifp.sqlite`. Anything the
/// data doesn't carry is left `nil` and simply isn't drawn — an unknown is never rendered as a
/// negative, because "no fuel tick" must not be read as "no fuel here".
enum AirportSymbol {

    /// The FAA's distinct airport classes. Order matters when classifying: a heliport is a heliport
    /// even if it also has a tower.
    enum Kind: String, Equatable {
        case airport        // the normal circle / runway-outline family
        case heliport       // circled H
        case seaplane       // anchor
        case ultralight     // circled F (flight park)
        case privateUse     // circled R — restricted / private, not open to the public
        case unverified     // circled U — information lacking or unusual limitations
        case abandoned      // circled X — landmark value only
        case military       // double-ring / military style (AFB, NAS, MCAS, AAF …)
    }

    /// How the airport proper is drawn (the FAA's runway-length / surface rules).
    enum Shape: String, Equatable {
        /// Filled circle with runway lines: public, hard-surfaced runway 1,500–8,069 ft.
        case filledCircleWithRunways
        /// Simple open circle: soft-surfaced only, or a hard runway under 1,500 ft.
        case openCircle
        /// Bare runway outline, no circle: a hard runway over 8,069 ft, or a multiple-runway layout.
        case runwaysOnly
    }

    /// Reported flight category, which tints the symbol the way every EFB does. This is CURRENT
    /// conditions — the trend is carried separately (see MetarTrend).
    enum Category: String, Equatable, CaseIterable {
        case vfr, mvfr, ifr, lifr
    }

    /// The airport facts a symbol is built from. Every optional means "not known", never "no".
    struct Attributes: Equatable {
        var hasTower: Bool?          // blue when true, magenta when false
        var hasFuel: Bool?           // tick marks around the symbol
        var hasBeacon: Bool?         // star beside the symbol
        var hardSurface: Bool?       // hard vs soft surfaced
        var owner: String?           // "P" public, "M" military, "R"/"PR" private …
        var typeCode: String?        // "ARP" | "HEL" | "SPB" | "ULT" | "CLS" …
        var name: String?            // used to spot military fields (AFB/NAS/MCAS/AAF)
        init(hasTower: Bool? = nil, hasFuel: Bool? = nil, hasBeacon: Bool? = nil,
             hardSurface: Bool? = nil, owner: String? = nil, typeCode: String? = nil,
             name: String? = nil) {
            self.hasTower = hasTower; self.hasFuel = hasFuel; self.hasBeacon = hasBeacon
            self.hardSurface = hardSurface; self.owner = owner; self.typeCode = typeCode
            self.name = name
        }
    }

    /// One runway, reduced to what the symbol draws: which way it points and how long it is.
    struct Runway: Equatable {
        let bearingDeg: Double       // magnetic, 0–360
        let lengthFt: Int
    }

    /// The finished drawing instruction.
    struct Spec: Equatable {
        var kind: Kind
        var shape: Shape
        var towered: Bool            // drives blue vs magenta
        var fuel: Bool
        var beacon: Bool
        /// Runway bearings to draw, de-duplicated to their 0–180° axis (a runway and its reciprocal
        /// are ONE line) and quantized to 5°, which is all that survives at symbol size — and it lets
        /// airports with the same layout share a rendered image.
        var runwayAxesDeg: [Int]
        var category: Category?      // nil when the field doesn't report / no observation

        /// A stable identity for image caching + the MapLibre image name. Airports that look
        /// identical share one rendered glyph.
        var signature: String {
            let axes = runwayAxesDeg.map(String.init).joined(separator: ".")
            return [kind.rawValue, shape.rawValue, towered ? "t" : "n", fuel ? "f" : "-",
                    beacon ? "b" : "-", axes, category?.rawValue ?? "x"].joined(separator: "_")
        }
    }

    // MARK: classification

    /// The FAA's runway-length thresholds, in feet.
    static let shortRunwayFt = 1_500
    static let longRunwayFt = 8_069

    /// Build the drawing spec for one airport.
    static func spec(attributes a: Attributes, runways: [Runway], category: Category?) -> Spec {
        let kind = classifyKind(a)
        let axes = runwayAxes(runways)
        return Spec(kind: kind,
                    shape: classifyShape(a, runways: runways, kind: kind),
                    towered: a.hasTower ?? false,
                    fuel: a.hasFuel ?? false,
                    beacon: a.hasBeacon ?? false,
                    runwayAxesDeg: axes,
                    category: category)
    }

    /// Which FAA glyph family this airport belongs to.
    static func classifyKind(_ a: Attributes) -> Kind {
        switch (a.typeCode ?? "").uppercased() {
        case "HEL": return .heliport
        case "SPB": return .seaplane
        case "ULT": return .ultralight
        case "CLS": return .abandoned
        default: break
        }
        // Military is owner-coded, but the name is the reliable tell for joint-use fields.
        let owner = (a.owner ?? "").uppercased()
        if owner == "M" { return .military }
        let name = (a.name ?? "").uppercased()
        for tag in [" AFB", " NAS ", " NAS", " MCAS", " AAF", "AIR FORCE BASE", "NAVAL AIR"]
        where name.contains(tag) { return .military }
        // Private / restricted use.
        if owner == "R" || owner == "PR" || owner == "PVT" { return .privateUse }
        // No usable record at all → the FAA's "unverified" case: information is lacking.
        if a.hasTower == nil && a.hardSurface == nil && a.typeCode == nil { return .unverified }
        return .airport
    }

    /// Filled circle vs open circle vs bare runway outline.
    static func classifyShape(_ a: Attributes, runways: [Runway], kind: Kind) -> Shape {
        // Only the ordinary airport family uses these; the rest have their own glyph.
        guard kind == .airport || kind == .military else { return .openCircle }
        let longest = runways.map(\.lengthFt).max() ?? 0
        let hard = a.hardSurface ?? (longest >= shortRunwayFt)   // length is the fallback signal
        if !hard || longest < shortRunwayFt { return .openCircle }
        if longest > longRunwayFt { return .runwaysOnly }
        if runways.count >= 3 { return .runwaysOnly }            // multiple-runway configuration
        return .filledCircleWithRunways
    }

    /// Runway bearings reduced to distinct 0–180° axes, quantized to 5°.
    ///
    /// A runway is one strip of pavement with two numbers; drawing both ends would double every line.
    /// Folding to a 0–180 axis collapses 04/22 into one, and the 5° quantization is both all that is
    /// legible at symbol size and what lets identical layouts share a cached image.
    static func runwayAxes(_ runways: [Runway]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for r in runways.prefix(32) {                            // bounded (rule 2)
            guard r.bearingDeg.isFinite else { continue }
            var deg = r.bearingDeg.truncatingRemainder(dividingBy: 180)
            if deg < 0 { deg += 180 }
            let q = Int((deg / 5).rounded()) * 5 % 180
            if seen.insert(q).inserted { out.append(q) }
        }
        out.sort()
        assert(out.count <= 32, "runwayAxes: unexpectedly many axes")
        assert(out.allSatisfy { $0 >= 0 && $0 < 180 }, "runwayAxes: axis out of range")
        return out
    }
}
