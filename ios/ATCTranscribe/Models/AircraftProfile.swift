import Foundation

/// A saved aircraft the pilot flies — selectable from the flight-plan bar's callsign box (the
/// ForeFlight-style "pick another aircraft you have on file"). Carries the planning performance
/// numbers the trip-stats row needs (cruise speed → ETE/ETA, burn → fuel). Selecting a profile
/// copies `callsign`/`type` into the filed `FlightPlan`, which is what the EFB ownship gate and
/// corrector grounding read — the profile list itself is just the pilot's hangar.
struct AircraftProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var callsign = ""        // tail / callsign, e.g. "N8925T"
    var type = ""            // e.g. "Piper Seneca"
    var cruiseKts: Int?      // planned cruise TAS — nil until the pilot fills it in
    var burnGPH: Double?     // planned fuel burn — nil until filled in
    // Engine-out numbers for the NRST glide engine. Optional so profiles saved before these fields
    // existed still decode (the established back-compat pattern for this UserDefaults JSON blob);
    // nil falls back to `NearestAirports.defaultGlideRatio` — deliberately conservative.
    var glideRatio: Double?  // best-glide L/D, e.g. 9.0 for a C172 (POH figure, still air)
    var bestGlideKts: Int?   // best-glide speed — display only, the ratio does the math

    // Landing performance, for the off-field landability layer. Optional on the same back-compat
    // rule as the glide fields above: a profile saved before these existed must still decode.
    //
    // WHY THESE AND NOT bestGlideKts. The landability compiler was reading `bestGlideKts` AS Vref,
    // and they are different numbers — best glide is flown well above approach speed, and the gap
    // widens with the aeroplane. It errs safe (a faster assumed touchdown is less tolerant of
    // surface and slope), but "less wrong in the safe direction" is not the same as right, and it
    // meant a pilot who entered their real numbers still got a borrowed one.
    /// Approach/threshold speed, knots — what the aeroplane actually crosses the fence at.
    var vRefKts: Int?
    /// Total landing distance over a 50 ft obstacle, feet, at max landing weight on a dry paved
    /// runway at sea level (the POH's book number).
    ///
    /// OVER-50-FT, NOT GROUND ROLL, on purpose. An unprepared field has a fence, a berm or trees at
    /// the approach end far more often than it has a clear threshold, and ground roll silently omits
    /// the part of the landing that the obstruction governs.
    var landingOver50Ft: Double?

    // Airframe facts. Optional on the same back-compat rule: a profile saved before these existed
    // must still decode, so every one is `nil` for older entries rather than a fabricated default.
    /// Max gross weight, pounds.
    var mtowLb: Int?
    /// Wingspan in feet — ROTOR DIAMETER for a rotorcraft.
    var spanFt: Double?

    /// Whether this is a helicopter or gyroplane.
    ///
    /// ⚠️ NOT COSMETIC. Autorotation descends at roughly 4:1 — far steeper than any aeroplane — but
    /// touches down in a fraction of the ground. The landability layer's required-run model is
    /// built on fixed-wing landing distance and does not describe that, so this flag exists to let
    /// the UI say which numbers do not apply rather than quietly scoring a helicopter as a very bad
    /// glider that needs a runway.
    var isRotorcraft: Bool?

    /// What this aircraft can put down on.
    ///
    /// ⚠️ THREE STATES, NOT A BOOLEAN, AND THAT IS THE WHOLE POINT. The nearest-airport list exists
    /// to answer "where can I put it down", and the three answers genuinely differ: a landplane must
    /// not be offered water, a STRAIGHT FLOATPLANE MUST NOT BE OFFERED ASPHALT, and only an
    /// amphibian may be offered both. Collapsing the last two into one `isSeaplane` flag would hand
    /// a float-only pilot a paved runway during an engine-out — a confident wrong answer on the one
    /// screen that exists for the worst minute of a flight.
    ///
    /// `nil` means land only, so every profile written before water operations existed keeps exactly
    /// the behaviour it has today rather than silently acquiring 561 seaplane bases.
    var waterOps: WaterOps?

    enum WaterOps: String, Codable, CaseIterable, Identifiable {
        case amphibian      // wheels plus floats or a hull — both surfaces
        case floatOnly      // straight floats or a flying boat — water only
        var id: String { rawValue }
        var title: String { self == .amphibian ? "Amphibian" : "Floats (water only)" }
    }

    /// Can this aircraft alight on water at all?
    var canLandOnWater: Bool { waterOps != nil }
    /// Can it use a conventional runway? Everything except a straight floatplane.
    var canLandOnLand: Bool { waterOps != .floatOnly }

    /// True when there's nothing worth keeping (drives add-sheet validation).
    var isEmpty: Bool { callsign.isEmpty && type.isEmpty }

    /// One-line label for the picker chip, e.g. "N8925T · Piper Seneca".
    var displayLine: String {
        let parts = [callsign, type].filter { !$0.isEmpty }
        return parts.isEmpty ? "Aircraft" : parts.joined(separator: " · ")
    }
}

/// UserDefaults-JSON persistence for the pilot's saved aircraft, mirroring `FlightPlan.load/save`.
/// Bounded (a hangar of 32 is plenty) so the stored blob can't grow without limit (rule 2).
enum AircraftStore {
    static let storageKey = "atc.aircraftProfiles"
    static let maxProfiles = 32

    /// The saved profiles (empty when nothing stored / undecodable).
    static func load() -> [AircraftProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profiles = try? JSONDecoder().decode([AircraftProfile].self, from: data) else { return [] }
        return Array(profiles.prefix(maxProfiles))
    }

    /// Persist `profiles` (empty list clears storage). Drops entries beyond the cap.
    static func save(_ profiles: [AircraftProfile]) {
        let kept = profiles.filter { !$0.isEmpty }.prefix(maxProfiles)
        guard !kept.isEmpty else { UserDefaults.standard.removeObject(forKey: storageKey); return }
        if let data = try? JSONEncoder().encode(Array(kept)) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }
}
