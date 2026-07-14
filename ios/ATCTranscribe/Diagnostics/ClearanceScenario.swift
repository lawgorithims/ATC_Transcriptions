import Foundation

// Clearance Test Bench — the DATA layer (Phase 1 of the buried diagnostic).
//
// A scenario is a scripted radio exchange: a handful of decoy transmissions to OTHER aircraft with,
// somewhere in the middle, one clearance addressed to OUR (test) aircraft. Replaying it through the
// real detection pipeline lets us verify — on the bench, with no airplane and no live ATC — that the
// app recognizes a route change addressed to us, ignores everything that isn't, and produces the
// amended plan we can hand to ForeFlight. Everything here is a pure Foundation value type so the whole
// catalog is validated in unit tests against the real `ATCCommandParser` + CIFP grounding.
//
// NASA/JPL "Power of 10" (Swift): no recursion, statically-bounded loops, small funcs, ≥2 assertions
// on the non-trivial ones, validated inputs.

/// What a scenario is exercising — also the grouping in the bench UI.
enum ClearanceCategory: String, CaseIterable, Sendable {
    case courseCorrection = "Course correction"
    case arrival          = "Arrival"
    case departure        = "Departure"
    case approach         = "Approach"
    case failsafe         = "Fail-safe (must NOT fire)"

    /// Fail-safe scenarios assert the app does NOT act; every other category asserts it DOES.
    var expectsSuggestion: Bool { self != .failsafe }
}

/// The aircraft a scenario flies. Drives ownship identity (callsign + type cues) and the trip stats.
/// Deliberately separate from `AircraftProfile` so the catalog stays a pure immutable value.
struct TestAircraft: Equatable, Sendable {
    let callsign: String      // e.g. "N8925T"
    let type: String          // e.g. "Piper Seneca" — the ≥3-letter words become ownship type cues
    let cruiseKts: Int
    let burnGPH: Double
}

/// The plan the sandbox starts from, before any clearance is applied.
struct PlanSeed: Equatable, Sendable {
    let departure: String
    let destination: String
    let route: [String]
    let alternate: String
    let cruiseAltitudeFt: Int?
}

/// One scripted transmission. `toOwnship` documents intent (is this meant for us?) and is what the
/// fail-safe assertions check against; `role` is the content role the detector gates on (a clearance's
/// text is `.controller`); `clip` optionally names a bundled audio file for the audio-injection mode.
struct ScriptedTransmission: Equatable, Identifiable, Sendable {
    let id: String
    let text: String            // phraseology as the app would see it after ASR (pre-normalization)
    let role: TurnRole          // .controller for clearances/instructions, .pilot for readbacks
    let toOwnship: Bool         // is this transmission addressed to OUR aircraft?
    let clip: String?           // optional bundled clip filename in Resources/ClearanceClips/

    init(_ id: String, _ text: String, role: TurnRole = .controller,
         toOwnship: Bool = false, clip: String? = nil) {
        self.id = id; self.text = text; self.role = role; self.toOwnship = toOwnship; self.clip = clip
    }
}

/// What the detector SHOULD produce for the scenario's target transmission. `commandKind == nil`
/// means "no suggestion at all" (the fail-safe expectation). The `expect*` fields are optional
/// post-accept assertions on the resulting plan.
struct ExpectedOutcome: Equatable, Sendable {
    let commandKind: String?     // ATCCommandKind rawValue, or nil for "must not fire"
    let target: String?          // expected command target (fix / airport / runway / procedure ident)
    let expectDestination: String?   // plan.destination after accept (direct-to)
    let expectRouteCleared: Bool     // plan.route == [] after accept (direct-to)
    let expectProcedureKind: String? // "SID" | "STAR" | "IAP" — a loaded-procedure slot should be set

    static let none = ExpectedOutcome(commandKind: nil, target: nil, expectDestination: nil,
                                      expectRouteCleared: false, expectProcedureKind: nil)

    static func directTo(_ target: String, destinationBecomes: String) -> ExpectedOutcome {
        ExpectedOutcome(commandKind: "directTo", target: target, expectDestination: destinationBecomes,
                        expectRouteCleared: true, expectProcedureKind: nil)
    }
    static func procedure(kind rawKind: String, ident: String, slot: String) -> ExpectedOutcome {
        ExpectedOutcome(commandKind: rawKind, target: ident, expectDestination: nil,
                        expectRouteCleared: false, expectProcedureKind: slot)
    }
    /// Approach: the exact runway-designator string the parser emits ("4R" vs "4 right") isn't
    /// pinned — assert the kind and that a real approach loads, not a spelling.
    static func approach() -> ExpectedOutcome {
        ExpectedOutcome(commandKind: "clearedApproach", target: nil, expectDestination: nil,
                        expectRouteCleared: false, expectProcedureKind: "IAP")
    }
}

/// One end-to-end bench scenario.
struct ClearanceScenario: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String            // plain-English: what it exercises + real-world framing
    let category: ClearanceCategory
    let aircraft: TestAircraft
    let airport: String           // context airport ident used to build grounding (CIFP)
    let seed: PlanSeed
    let script: [ScriptedTransmission]
    let targetIndex: Int          // index in `script` of the clearance `expected` describes
    let expected: ExpectedOutcome

    /// The transmission `expected` refers to (the ownship clearance, or the tempting decoy in a
    /// fail-safe). Bounds-checked so a mis-authored catalog can't crash the bench.
    var target: ScriptedTransmission? {
        guard targetIndex >= 0, targetIndex < script.count else { return nil }
        return script[targetIndex]
    }

    /// A seed `FlightPlan` for the sandbox — callsign/type drive ownship; endpoints + route feed
    /// grounding. Pure (no persistence side effects here — the runner owns those).
    func seedPlan() -> FlightPlan {
        var p = FlightPlan()
        p.callsign = aircraft.callsign
        p.aircraftType = aircraft.type
        p.departure = seed.departure
        p.destination = seed.destination
        p.route = seed.route
        p.alternate = seed.alternate
        p.cruiseAltitudeFt = seed.cruiseAltitudeFt
        return p
    }
}
