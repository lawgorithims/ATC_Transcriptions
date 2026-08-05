import Foundation

/// Typical performance figures for common types, as a STARTING POINT for a pilot's own profile.
///
/// =============================================================================================
/// ⚠️ THESE ARE NOMINAL FIGURES, NOT YOUR AEROPLANE'S NUMBERS, AND THE APP MUST NEVER SAY OTHERWISE
/// =============================================================================================
/// Two of these fields — `glideRatio` and `landingOver50Ft` — drive the engine-out glide footprint
/// and the off-field landability shading. A wrong glide ratio moves the ring of ground the app says
/// you can reach. A wrong landing distance changes which fields it will name.
///
/// The published figure for a type is not the figure for a tail number. It varies with weight, with
/// the propeller, with STCs and gap seals and wheel fairings, with a repaint, with rigging, and with
/// how the last owner treated it. Book landing distances are flown by test pilots on a dry paved
/// runway at sea level at max landing weight, and are routinely not reproducible in the field.
///
/// So selecting a type here FILLS THE FORM AND NOTHING MORE. Every value stays editable, the sheet
/// says where the number came from, and the pilot is asked for their POH figure. A catalogue that
/// silently became authoritative would be the most dangerous thing in this app.
///
/// ROTORCRAFT ARE NOT SLOW AEROPLANES — see `Entry.isRotorcraft`. Autorotation is a steep descent at
/// roughly 4:1, but the touchdown needs a fraction of the ground an aeroplane does, so the landing
/// distance model that governs the landability layer does not describe them. They carry no
/// `landingOver50Ft` and the UI says why rather than inventing one.
enum AircraftCatalog {

    struct Entry: Identifiable, Equatable {
        let manufacturer: String
        let model: String
        /// Best-glide L/D, still air, typical published figure at a representative weight.
        let glideRatio: Double
        /// Best-glide speed, KIAS.
        let bestGlideKts: Int
        /// Approach/threshold speed, KIAS.
        let vRefKts: Int
        /// Total landing distance over a 50 ft obstacle, feet. Nil for rotorcraft.
        let landingOver50Ft: Double?
        /// Max gross weight, pounds.
        let mtowLb: Int
        /// Wingspan, feet — rotor diameter for rotorcraft.
        let spanFt: Double
        /// Typical cruise TAS, knots.
        let cruiseKts: Int
        /// Typical fuel burn, US gallons per hour.
        let burnGPH: Double

        var id: String { "\(manufacturer) \(model)" }
        var displayName: String { "\(manufacturer) \(model)" }

        /// A helicopter or gyroplane. Autorotation makes the glide steep and the landing short, so
        /// the fixed-wing landing-distance model does not apply.
        var isRotorcraft: Bool { landingOver50Ft == nil }
    }

    /// Everything the picker offers, grouped by manufacturer in `byManufacturer`.
    ///
    /// Deliberately a curated set of types commonly flown in US general aviation rather than an
    /// exhaustive register. A short list of numbers worth trusting beats a long list of numbers
    /// nobody checked, and anything absent is one form away from being entered by hand.
    static let all: [Entry] = [
        // ---- Cessna -------------------------------------------------------------------------
        .init(manufacturer: "Cessna", model: "152", glideRatio: 9.0, bestGlideKts: 60,
              vRefKts: 54, landingOver50Ft: 1200, mtowLb: 1670, spanFt: 33.4,
              cruiseKts: 95, burnGPH: 6.0),
        .init(manufacturer: "Cessna", model: "172 Skyhawk", glideRatio: 9.0, bestGlideKts: 68,
              vRefKts: 62, landingOver50Ft: 1250, mtowLb: 2450, spanFt: 36.1,
              cruiseKts: 120, burnGPH: 8.5),
        .init(manufacturer: "Cessna", model: "182 Skylane", glideRatio: 9.0, bestGlideKts: 76,
              vRefKts: 65, landingOver50Ft: 1350, mtowLb: 3110, spanFt: 36.0,
              cruiseKts: 145, burnGPH: 13.0),
        .init(manufacturer: "Cessna", model: "206 Stationair", glideRatio: 9.0, bestGlideKts: 80,
              vRefKts: 70, landingOver50Ft: 1400, mtowLb: 3600, spanFt: 36.0,
              cruiseKts: 145, burnGPH: 15.5),
        .init(manufacturer: "Cessna", model: "210 Centurion", glideRatio: 10.0, bestGlideKts: 85,
              vRefKts: 75, landingOver50Ft: 1500, mtowLb: 3800, spanFt: 36.9,
              cruiseKts: 170, burnGPH: 16.0),
        .init(manufacturer: "Cessna", model: "310", glideRatio: 9.0, bestGlideKts: 105,
              vRefKts: 92, landingOver50Ft: 1700, mtowLb: 5500, spanFt: 36.9,
              cruiseKts: 180, burnGPH: 28.0),

        // ---- Piper --------------------------------------------------------------------------
        .init(manufacturer: "Piper", model: "J-3 Cub", glideRatio: 8.0, bestGlideKts: 50,
              vRefKts: 45, landingOver50Ft: 900, mtowLb: 1220, spanFt: 35.3,
              cruiseKts: 65, burnGPH: 4.5),
        .init(manufacturer: "Piper", model: "PA-28 Cherokee 180", glideRatio: 10.0,
              bestGlideKts: 76, vRefKts: 66, landingOver50Ft: 1150, mtowLb: 2450, spanFt: 30.0,
              cruiseKts: 125, burnGPH: 9.5),
        .init(manufacturer: "Piper", model: "PA-28R Arrow", glideRatio: 10.0, bestGlideKts: 79,
              vRefKts: 70, landingOver50Ft: 1600, mtowLb: 2750, spanFt: 35.4,
              cruiseKts: 137, burnGPH: 10.5),
        .init(manufacturer: "Piper", model: "PA-32 Saratoga", glideRatio: 9.0, bestGlideKts: 85,
              vRefKts: 75, landingOver50Ft: 1700, mtowLb: 3600, spanFt: 36.2,
              cruiseKts: 155, burnGPH: 16.0),
        .init(manufacturer: "Piper", model: "PA-34 Seneca", glideRatio: 9.0, bestGlideKts: 92,
              vRefKts: 80, landingOver50Ft: 2000, mtowLb: 4750, spanFt: 38.9,
              cruiseKts: 175, burnGPH: 26.0),
        .init(manufacturer: "Piper", model: "PA-18 Super Cub", glideRatio: 8.0, bestGlideKts: 55,
              vRefKts: 48, landingOver50Ft: 800, mtowLb: 1750, spanFt: 35.5,
              cruiseKts: 85, burnGPH: 6.0),

        // ---- Beechcraft ---------------------------------------------------------------------
        .init(manufacturer: "Beechcraft", model: "A36 Bonanza", glideRatio: 10.0,
              bestGlideKts: 105, vRefKts: 75, landingOver50Ft: 1500, mtowLb: 3650, spanFt: 33.5,
              cruiseKts: 175, burnGPH: 17.0),
        .init(manufacturer: "Beechcraft", model: "V35 Bonanza", glideRatio: 10.0,
              bestGlideKts: 105, vRefKts: 72, landingOver50Ft: 1400, mtowLb: 3400, spanFt: 33.5,
              cruiseKts: 170, burnGPH: 15.0),
        .init(manufacturer: "Beechcraft", model: "Baron 58", glideRatio: 9.0, bestGlideKts: 115,
              vRefKts: 95, landingOver50Ft: 2100, mtowLb: 5500, spanFt: 37.8,
              cruiseKts: 200, burnGPH: 32.0),
        .init(manufacturer: "Beechcraft", model: "King Air C90", glideRatio: 11.0,
              bestGlideKts: 125, vRefKts: 100, landingOver50Ft: 2500, mtowLb: 9650, spanFt: 50.3,
              cruiseKts: 240, burnGPH: 60.0),

        // ---- Cirrus -------------------------------------------------------------------------
        // ⚠️ CAPS changes the engine-out decision entirely — the glide figures below describe an
        // unpowered glide, not the manufacturer's guidance, which is to pull the parachute.
        .init(manufacturer: "Cirrus", model: "SR20", glideRatio: 10.0, bestGlideKts: 90,
              vRefKts: 75, landingOver50Ft: 1700, mtowLb: 3150, spanFt: 38.3,
              cruiseKts: 155, burnGPH: 11.0),
        .init(manufacturer: "Cirrus", model: "SR22", glideRatio: 9.0, bestGlideKts: 92,
              vRefKts: 80, landingOver50Ft: 2000, mtowLb: 3600, spanFt: 38.3,
              cruiseKts: 180, burnGPH: 17.0),

        // ---- Mooney / Diamond / Grumman -----------------------------------------------------
        .init(manufacturer: "Mooney", model: "M20J", glideRatio: 12.0, bestGlideKts: 90,
              vRefKts: 70, landingOver50Ft: 1600, mtowLb: 2740, spanFt: 36.1,
              cruiseKts: 165, burnGPH: 10.0),
        .init(manufacturer: "Diamond", model: "DA40", glideRatio: 11.0, bestGlideKts: 73,
              vRefKts: 65, landingOver50Ft: 1200, mtowLb: 2646, spanFt: 39.2,
              cruiseKts: 140, burnGPH: 8.0),
        .init(manufacturer: "Diamond", model: "DA42 Twin Star", glideRatio: 11.0,
              bestGlideKts: 85, vRefKts: 76, landingOver50Ft: 1700, mtowLb: 3935, spanFt: 44.0,
              cruiseKts: 160, burnGPH: 11.0),
        .init(manufacturer: "Grumman", model: "AA-5 Tiger", glideRatio: 10.0, bestGlideKts: 75,
              vRefKts: 65, landingOver50Ft: 1200, mtowLb: 2400, spanFt: 31.5,
              cruiseKts: 140, burnGPH: 10.0),

        // ---- Experimental / LSA -------------------------------------------------------------
        .init(manufacturer: "Van's", model: "RV-7", glideRatio: 10.0, bestGlideKts: 80,
              vRefKts: 65, landingOver50Ft: 1100, mtowLb: 1800, spanFt: 25.0,
              cruiseKts: 175, burnGPH: 8.5),
        .init(manufacturer: "Van's", model: "RV-10", glideRatio: 10.0, bestGlideKts: 85,
              vRefKts: 70, landingOver50Ft: 1300, mtowLb: 2700, spanFt: 31.7,
              cruiseKts: 175, burnGPH: 12.0),
        .init(manufacturer: "Aviat", model: "A-1 Husky", glideRatio: 8.0, bestGlideKts: 60,
              vRefKts: 52, landingOver50Ft: 900, mtowLb: 2200, spanFt: 35.5,
              cruiseKts: 115, burnGPH: 9.0),
        .init(manufacturer: "American Champion", model: "8KCAB Decathlon", glideRatio: 8.0,
              bestGlideKts: 65, vRefKts: 58, landingOver50Ft: 1000, mtowLb: 1800, spanFt: 32.0,
              cruiseKts: 120, burnGPH: 9.0),
        .init(manufacturer: "Icon", model: "A5", glideRatio: 8.0, bestGlideKts: 55,
              vRefKts: 50, landingOver50Ft: 1000, mtowLb: 1510, spanFt: 34.8,
              cruiseKts: 85, burnGPH: 5.0),

        // ---- Rotorcraft ---------------------------------------------------------------------
        // No landingOver50Ft BY DESIGN. In autorotation these descend at roughly 4:1 — far steeper
        // than any aeroplane — but touch down in a fraction of the ground, so a fixed-wing landing
        // distance would be both wrong and misleading. `isRotorcraft` is derived from its absence.
        .init(manufacturer: "Robinson", model: "R22", glideRatio: 4.0, bestGlideKts: 65,
              vRefKts: 55, landingOver50Ft: nil, mtowLb: 1370, spanFt: 25.2,
              cruiseKts: 95, burnGPH: 9.0),
        .init(manufacturer: "Robinson", model: "R44", glideRatio: 4.0, bestGlideKts: 70,
              vRefKts: 60, landingOver50Ft: nil, mtowLb: 2500, spanFt: 33.0,
              cruiseKts: 110, burnGPH: 15.0),
        .init(manufacturer: "Robinson", model: "R66", glideRatio: 4.5, bestGlideKts: 75,
              vRefKts: 60, landingOver50Ft: nil, mtowLb: 2700, spanFt: 33.0,
              cruiseKts: 110, burnGPH: 22.0),
        .init(manufacturer: "Bell", model: "206 JetRanger", glideRatio: 4.0, bestGlideKts: 69,
              vRefKts: 60, landingOver50Ft: nil, mtowLb: 3200, spanFt: 33.3,
              cruiseKts: 110, burnGPH: 28.0),
        .init(manufacturer: "Bell", model: "407", glideRatio: 4.5, bestGlideKts: 80,
              vRefKts: 65, landingOver50Ft: nil, mtowLb: 5250, spanFt: 35.0,
              cruiseKts: 125, burnGPH: 42.0),
        .init(manufacturer: "Airbus Helicopters", model: "H125 (AS350)", glideRatio: 4.5,
              bestGlideKts: 75, vRefKts: 65, landingOver50Ft: nil, mtowLb: 4960, spanFt: 35.1,
              cruiseKts: 125, burnGPH: 45.0),
        .init(manufacturer: "Airbus Helicopters", model: "H130", glideRatio: 4.5,
              bestGlideKts: 75, vRefKts: 65, landingOver50Ft: nil, mtowLb: 5512, spanFt: 35.1,
              cruiseKts: 125, burnGPH: 48.0),
        .init(manufacturer: "MD Helicopters", model: "MD 500E", glideRatio: 4.0, bestGlideKts: 70,
              vRefKts: 60, landingOver50Ft: nil, mtowLb: 3000, spanFt: 26.4,
              cruiseKts: 125, burnGPH: 26.0),
        .init(manufacturer: "Guimbal", model: "Cabri G2", glideRatio: 4.0, bestGlideKts: 60,
              vRefKts: 50, landingOver50Ft: nil, mtowLb: 1543, spanFt: 23.6,
              cruiseKts: 90, burnGPH: 9.0),
    ]

    /// Manufacturers in display order, each with its models.
    static var byManufacturer: [(name: String, entries: [Entry])] {
        Dictionary(grouping: all, by: \.manufacturer)
            .map { (name: $0.key, entries: $0.value.sorted { $0.model < $1.model }) }
            .sorted { $0.name < $1.name }
    }

    static func matching(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.displayName.lowercased().contains(q) }
    }

    /// The sentence that must accompany any number taken from here.
    static let provenanceNote =
        "Typical published figures for the type — a starting point, not your aeroplane. Weight, "
        + "propeller, STCs and rigging all move them, and book landing distances are flown by test "
        + "pilots on dry pavement at sea level. Check every value against your POH and edit it."
}

extension AircraftProfile {
    /// Fill this profile from a catalogue entry, keeping the pilot's own callsign.
    ///
    /// The callsign is never touched: it identifies the airframe, and the whole point of the
    /// catalogue is to populate the numbers around an aeroplane the pilot has already named.
    mutating func apply(_ e: AircraftCatalog.Entry) {
        type = e.displayName
        glideRatio = e.glideRatio
        bestGlideKts = e.bestGlideKts
        vRefKts = e.vRefKts
        landingOver50Ft = e.landingOver50Ft
        cruiseKts = e.cruiseKts
        burnGPH = e.burnGPH
        mtowLb = e.mtowLb
        spanFt = e.spanFt
        isRotorcraft = e.isRotorcraft
    }
}
