import Foundation

// The bench's scenario catalog. Grounded in real FAA CIFP data for KBOS/KJFK so the clearances
// resolve against actual fixes, procedures, and runways (the detector only proposes REAL targets).
// Phraseology is written the way the app would see it after ASR; `ATCNormalize` converts number
// words → digits and explodes digit runs, so "eight niner two five" and "8925" both land as
// "8 9 2 5" and match the ownship variants. Every scenario is validated in
// `ClearanceScenarioTests` against the live parser + grounding — a mis-authored line fails the suite.
//
// Ownship for the whole catalog is a GA tail (N8925T / "Piper Seneca"): ownship matching is fully
// robust for GA tails without a live knowledge base, which is what the bench runs with.

enum ClearanceScenarioCatalog {

    static let ownship = TestAircraft(callsign: "N8925T", type: "Piper Seneca", cruiseKts: 165, burnGPH: 16.5)

    /// All scenarios, positives first then fail-safes. Order is the bench display order.
    static let all: [ClearanceScenario] = [
        directToFix, directToAirport, arrivalStar, departureSid, approachClearance,
        failsafeOtherAircraft, failsafeMentionNotAddressed, failsafeRetraction, failsafeSimilarCallsign,
    ]

    static func scenario(id: String) -> ClearanceScenario? { all.first { $0.id == id } }

    // MARK: positives — one per supported clearance type

    /// Minor course correction: ATC sends you straight to a fix already on your route.
    static let directToFix = ClearanceScenario(
        id: "direct-fix",
        title: "Direct to a fix (course correction)",
        detail: "The everyday case — ATC clears you present-position direct to a downroute fix. Expect the plan to go direct to STOLI. Buried between instructions to two other aircraft.",
        category: .courseCorrection, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: ["STOLI", "SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("d1", "Delta four fifty two, contact Boston approach one two four point one."),
            ScriptedTransmission("d2", "American one eighty eight, climb and maintain flight level three three zero."),
            ScriptedTransmission("t",  "November eight niner two five Tango, proceed direct STOLI.", toOwnship: true),
            ScriptedTransmission("r",  "Direct STOLI, November eight niner two five Tango.", role: .pilot, toOwnship: true),
        ],
        targetIndex: 2,
        expected: .directTo("STOLI", destinationBecomes: "STOLI"))

    /// Diversion: cleared direct to the filed alternate by identifier (the direct-to-AIRPORT branch).
    static let directToAirport = ClearanceScenario(
        id: "direct-airport",
        title: "Direct to an airport (diversion)",
        detail: "Exercises the direct-to-airport branch — cleared direct to your filed alternate (KPVD). Realistic when ATC gives the identifier; the plan's destination becomes the airport.",
        category: .courseCorrection, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: ["STOLI", "SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("d1", "JetBlue five twenty two, turn right heading two seven zero, vectors for the visual."),
            ScriptedTransmission("t",  "November eight niner two five Tango, cleared direct KPVD.", toOwnship: true),
            ScriptedTransmission("d2", "United sixteen ten, descend and maintain six thousand."),
        ],
        targetIndex: 1,
        expected: .directTo("KPVD", destinationBecomes: "KPVD"))

    /// Standard arrival: "descend via the OOSHN five arrival" into Boston.
    static let arrivalStar = ClearanceScenario(
        id: "star",
        title: "Standard arrival (STAR)",
        detail: "Cleared to descend via a published arrival into KBOS. Expect the OOSHN FIVE arrival to load into the plan. The coded name (OOSHN) is what the parser matches.",
        category: .arrival, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KJFK", destination: "KBOS", route: ["SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 11000),
        script: [
            ScriptedTransmission("d1", "Southwest twenty two hundred, New York center, radar contact."),
            ScriptedTransmission("t",  "November eight niner two five Tango, descend via the OOSHN five arrival.", toOwnship: true),
            ScriptedTransmission("d2", "Envoy forty one twenty, cross SEETS at and maintain one zero thousand."),
        ],
        targetIndex: 1,
        expected: .procedure(kind: "loadStar", ident: "OOSHN5", slot: "STAR"))

    /// Standard departure: "climb via the BLZZR six departure" out of Boston.
    static let departureSid = ClearanceScenario(
        id: "sid",
        title: "Standard departure (SID)",
        detail: "Cleared to climb via a published departure off KBOS. Expect the BLZZR SIX departure to load. Tests that the app never confuses your SID with the clearance ATC gives the aircraft behind you.",
        category: .departure, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: [],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("d1", "Cape Air twelve, Boston tower, runway two two right, cleared for takeoff."),
            ScriptedTransmission("t",  "November eight niner two five Tango, climb via the BLZZR six departure.", toOwnship: true),
            ScriptedTransmission("d2", "Delta seven fifteen, climb via the CELTK seven departure.", toOwnship: false),
        ],
        targetIndex: 1,
        expected: .procedure(kind: "loadSID", ident: "BLZZR6", slot: "SID"))

    /// Approach clearance: "cleared ILS runway four right" into Boston.
    static let approachClearance = ClearanceScenario(
        id: "approach",
        title: "Approach clearance",
        detail: "Cleared for an instrument approach into KBOS. Expect the ILS runway 4 right approach to load. Load approaches in ForeFlight's procedure advisor — CommSight only stages the clearance.",
        category: .approach, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KJFK", destination: "KBOS", route: [],
                       alternate: "KPVD", cruiseAltitudeFt: 4000),
        script: [
            ScriptedTransmission("d1", "American twenty one hundred, reduce speed one seven zero, follow the traffic on the river."),
            ScriptedTransmission("t",  "November eight niner two five Tango, cleared ILS runway four right approach.", toOwnship: true),
        ],
        targetIndex: 1,
        expected: .approach())

    // MARK: fail-safes — the app must NOT act

    /// The single most important test: an actionable clearance addressed to ANOTHER aircraft.
    static let failsafeOtherAircraft = ClearanceScenario(
        id: "fs-other",
        title: "Clearance to another aircraft",
        detail: "The critical safety case. American 188 — NOT you — is sent direct STOLI. The app must NOT amend your plan. If a suggestion fires here, ownship gating is broken.",
        category: .failsafe, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: ["STOLI", "SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("d1", "November eight niner two five Tango, Boston approach, radar contact.", toOwnship: true),
            ScriptedTransmission("t",  "American one eighty eight, proceed direct STOLI.", toOwnship: false),
            ScriptedTransmission("d2", "American one eighty eight, roger, direct STOLI.", role: .pilot, toOwnship: false),
        ],
        targetIndex: 1,
        expected: .none)

    /// Ownship is MENTIONED as traffic to another aircraft, not addressed a clearance.
    static let failsafeMentionNotAddressed = ClearanceScenario(
        id: "fs-mention",
        title: "Mentioned as traffic, not addressed",
        detail: "Your tail number is spoken — but as traffic for another aircraft to follow, not as a clearance to you. The 'addressed to me' gate must reject it.",
        category: .failsafe, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: ["STOLI", "SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("t",  "Cessna three four X-ray, traffic to follow is the November eight niner two five Tango, a Seneca on a two mile final.", toOwnship: false),
        ],
        targetIndex: 0,
        expected: .none)

    /// A clearance to us that the controller immediately takes back.
    static let failsafeRetraction = ClearanceScenario(
        id: "fs-retract",
        title: "Clearance retracted (disregard)",
        detail: "ATC clears you direct STOLI, then says 'disregard'. A self-corrected clearance must not be staged — the app should abstain when a retraction word is present.",
        category: .failsafe, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: ["STOLI", "SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("t",  "November eight niner two five Tango, proceed direct STOLI, disregard, maintain present heading.", toOwnship: true),
        ],
        targetIndex: 0,
        expected: .none)

    /// A near-identical tail number (same digits, different phonetic suffix) gets the clearance.
    static let failsafeSimilarCallsign = ClearanceScenario(
        id: "fs-similar",
        title: "Similar callsign (not yours)",
        detail: "A look-alike tail — November 8925 X-ray, not your 8925 Tango — is cleared direct STOLI. The suffix must disambiguate; the app must not act on the wrong aircraft.",
        category: .failsafe, aircraft: ownship, airport: "KBOS",
        seed: PlanSeed(departure: "KBOS", destination: "KJFK", route: ["STOLI", "SEETS"],
                       alternate: "KPVD", cruiseAltitudeFt: 8000),
        script: [
            ScriptedTransmission("d1", "November eight niner two five Tango, Boston approach, altimeter two niner niner two.", toOwnship: true),
            ScriptedTransmission("t",  "November eight niner two five X-ray, proceed direct STOLI.", toOwnship: false),
        ],
        targetIndex: 1,
        expected: .none)
}
