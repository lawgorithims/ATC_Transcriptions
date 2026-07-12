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
