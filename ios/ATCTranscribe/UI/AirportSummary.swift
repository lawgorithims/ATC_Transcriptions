import SwiftUI

/// The pilot-relevant snapshot of an airport for the Airports tab / Plates binders captions: name,
/// elevation + estimated pattern altitude, the key comm frequencies, and which approach types it has.
/// Live weather is layered on separately (async, from `MetarStore`). All from bundled data — pure, cheap.
struct AirportSummary: Equatable {
    let ident: String
    let name: String?
    let elevationFt: Int?
    let keyFreqs: [Freq]          // ordered, already capped for a one-line caption
    let procedureTypes: [String]  // e.g. ["ILS", "RNAV (GPS)", "VOR"]
    let hasPlates: Bool

    struct Freq: Equatable { let label: String; let value: String }

    /// Pattern altitude estimate: field elevation + 1000′ (the light-aircraft default; charted TPA can
    /// differ, so it's marked "est." wherever shown).
    var patternAltFt: Int? { elevationFt.map { $0 + 1000 } }

    static func make(_ ident: String) -> AirportSummary {
        let id = ident.trimmingCharacters(in: .whitespaces).uppercased()
        let meta = NavMeta.airport(id)
        let ctx = BundledAirportContextSource.lookup(id)
        let plates = Procedures.forAirport(id)
        return AirportSummary(ident: id, name: meta?.name, elevationFt: meta?.elevationFt,
                              keyFreqs: Self.keyFreqs(ctx?.frequencies ?? [:]),
                              procedureTypes: Self.procedureTypes(plates),
                              hasPlates: !plates.isEmpty)
    }

    /// The most useful comms for a quick glance, in a fixed priority, capped to 4 so the caption stays one
    /// line. CTAF/UNICOM first (the non-towered field's key freq), then Tower/Ground/ATIS/Approach.
    private static func keyFreqs(_ freqs: [String: [Double]]) -> [Freq] {
        let priority = ["CTAF", "UNIC", "TWR", "GND", "ATIS", "ASOS", "AWOS", "CLD", "APP", "DEP", "CTR"]
        let names = ["CTAF": "CTAF", "UNIC": "UNICOM", "TWR": "TWR", "GND": "GND", "ATIS": "ATIS",
                     "ASOS": "ASOS", "AWOS": "AWOS", "CLD": "CLNC", "APP": "APP", "DEP": "DEP", "CTR": "CTR"]
        var out: [Freq] = []
        for key in priority where out.count < 4 {
            guard let vals = freqs[key], let first = vals.sorted().first else { continue }
            out.append(Freq(label: names[key] ?? key, value: String(format: "%.3f", first)))
        }
        return out
    }

    /// Distinct approach types published at the field, in a conventional order.
    private static func procedureTypes(_ plates: [AirportProcedure]) -> [String] {
        let names = plates.filter { $0.category == .approach }.map { $0.name.uppercased() }
        var found: [String] = []
        func add(_ token: String, if present: Bool) { if present, !found.contains(token) { found.append(token) } }
        add("ILS", if: names.contains { $0.contains("ILS") })
        add("RNAV (GPS)", if: names.contains { $0.contains("RNAV") || $0.contains("GPS") })
        add("VOR", if: names.contains { $0.contains("VOR") })
        add("LOC", if: names.contains { $0.contains("LOC") && !$0.contains("ILS") })
        add("LDA", if: names.contains { $0.contains("LDA") })
        add("NDB", if: names.contains { $0.contains("NDB") })
        add("TACAN", if: names.contains { $0.contains("TACAN") })
        return found
    }
}

// MARK: - Flight-category chip

/// The VFR / MVFR / IFR / LIFR pill (ForeFlight-style colour coding). `nil` metar → a muted "— WX".
struct FlightCategoryChip: View {
    let metar: Metar?
    var body: some View {
        let cat = metar?.category ?? .unknown
        return Text(cat == .mvfr ? "MVFR" : cat.rawValue)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Self.color(cat)))
            .foregroundStyle(.white)
            .accessibilityIdentifier("flight-category")
            .accessibilityLabel("Flight category \(cat.rawValue)")
    }

    static func color(_ cat: Metar.Category) -> Color {
        switch cat {
        case .vfr:     return .hex(0x18A957)   // green
        case .mvfr:    return .hex(0x2F6FED)   // blue
        case .ifr:     return .hex(0xE0304B)   // red
        case .lifr:    return .hex(0xB02FE0)   // magenta
        case .unknown: return .hex(0x8A94A6)   // grey
        }
    }
}

// MARK: - Reusable airport-diagram image

/// The airport-diagram (APD) plate rendered as an image, with a graceful placeholder while it downloads /
/// when the field has none. Used as the row thumbnail in the Airports tab and the binder header. Renders
/// off the main actor and cancels on ident change (a fast scroll never piles up renders).
struct AirportDiagramImage: View {
    @EnvironmentObject var model: AppModel
    let ident: String
    var height: CGFloat = 132
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?
    @State private var phase: Phase = .loading
    private enum Phase { case loading, ready, none }

    private var apd: AirportProcedure? { Procedures.forAirport(ident).first { $0.code == "APD" } }

    var body: some View {
        let p = model.palette
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)   // whole diagram, north-up
            } else if phase == .loading {
                ProgressView()
            } else {
                Rectangle().fill(p.surfaceAlt)
                    .overlay { Image(systemName: "airplane").font(.title3).foregroundStyle(p.textDim) }
            }
        }
        .frame(width: height * 1.3, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(p.border, lineWidth: 0.5))
        .task(id: ident) { await load() }
    }

    private func load() async {
        image = nil; phase = .loading
        guard let apd, let url = await PlateStore.ensureOnDisk(apd) else { phase = .none; return }
        let pdf = apd.pdf
        let rendered = await Task.detached(priority: .utility) {
            PlateImageRenderer.northUpFirstPage(pdfURL: url, pdf: pdf, maxDimension: 600)
        }.value
        guard !Task.isCancelled else { return }
        if let rendered { image = rendered; phase = .ready } else { phase = .none }
    }
}
