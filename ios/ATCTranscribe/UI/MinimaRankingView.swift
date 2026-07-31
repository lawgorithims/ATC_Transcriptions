import SwiftUI

/// Every approach at an airport, ordered by the minima it actually delivers.
///
/// The question this answers is the one a pilot asks when the weather is marginal and there is more than
/// one way in: *which of these gets me lowest?* On paper it is answered by opening each plate in turn,
/// finding the right row and the right column on each, and holding four numbers in your head to compare
/// them. Here the comparison is the view.
///
/// It ranks on the LOWEST line each approach publishes for the selected category, and names that line,
/// because "the ILS gets you to 218" is only true if you can fly the ILS — an approach whose best figure
/// comes from its LPV line is a different proposition from one whose best comes from its localizer.
///
/// Approaches whose plates have not been parsed yet, or whose tables could not be read, are listed
/// SEPARATELY rather than omitted. An approach missing from a ranked list reads as "this one is worse",
/// and the one thing this view must not do is quietly shorten the pilot's list of options.
struct MinimaRankingView: View {
    let airport: String
    let procedures: [AirportProcedure]
    @ObservedObject var store: MinimaStore
    let palette: Palette
    var onOpen: (AirportProcedure) -> Void

    @State private var category: PlateMinima.Category = .a
    @State private var sort: Sort = .altitude

    enum Sort: String, CaseIterable, Identifiable {
        case altitude = "Lowest altitude"
        case visibility = "Lowest visibility"
        var id: String { rawValue }
    }

    /// Cap on plates ranked in one view (rule 2) — a large airport publishes a few dozen approaches.
    static let maxRanked = 60

    private var p: Palette { palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                if ranked.isEmpty && unavailable.isEmpty {
                    Text("Reading the plates…").font(.dsLabel).foregroundStyle(p.textDim)
                } else {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { i, entry in
                        row(entry, rank: i + 1)
                    }
                }
                if !unavailable.isEmpty { unavailableSection }
                footnote
            }
            .padding(16)
        }
        .background(p.bg.ignoresSafeArea())
        .onAppear { for proc in procedures.prefix(Self.maxRanked) { store.ensure(proc, airport: airport) } }
        .accessibilityIdentifier("minima-ranking")
    }

    // MARK: model

    struct Entry: Identifiable {
        let procedure: AirportProcedure
        let solution: MinimaSolver.Solution
        var id: String { procedure.pdf }
    }

    /// The best line each approach publishes for the selected category, ranked.
    private var ranked: [Entry] {
        var out: [Entry] = []
        for proc in procedures.prefix(Self.maxRanked) {           // bounded (rule 2)
            guard let m = store.result(for: proc)?.minima else { continue }
            var best: MinimaSolver.Solution?
            for line in MinimaSolver.availableLines(m).prefix(16) {   // bounded (rule 2)
                var r = MinimaSolver.Request(category: category, kind: line.kind, lineIndex: line.index)
                r.temperatureC = nil
                guard let s = MinimaSolver.solve(m, request: r), s.isUsable else { continue }
                // Circling is not a straight-in option and must not win a ranking against one.
                if line.kind == .circling, best != nil { continue }
                if let b = best, (b.altitudeFtMSL ?? .max) <= (s.altitudeFtMSL ?? .max) { continue }
                best = s
            }
            if let b = best { out.append(Entry(procedure: proc, solution: b)) }
        }
        // Ties break on the other figure, because they are not really ties: of two approaches that both
        // get you to 216 ft, the one that needs RVR 1800 rather than RVR 4000 is plainly the better
        // option, and listing them in arbitrary order would hide that.
        func alt(_ e: Entry) -> Int { e.solution.altitudeFtMSL ?? .max }
        func vis(_ e: Entry) -> Int { e.solution.visibility?.rvrEquivalentFt ?? .max }
        switch sort {
        case .altitude:
            return out.sorted { alt($0) == alt($1) ? vis($0) < vis($1) : alt($0) < alt($1) }
        case .visibility:
            return out.sorted { vis($0) == vis($1) ? alt($0) < alt($1) : vis($0) < vis($1) }
        }
    }

    /// Approaches with no usable figure — still parsing, unreadable, or nothing published for this category.
    private var unavailable: [(proc: AirportProcedure, why: String)] {
        var out: [(AirportProcedure, String)] = []
        let rankedIDs = Set(ranked.map(\.procedure.pdf))
        for proc in procedures.prefix(Self.maxRanked) where !rankedIDs.contains(proc.pdf) {
            if store.isLoading(proc) { out.append((proc, "reading…")); continue }
            guard let result = store.result(for: proc) else { out.append((proc, "not downloaded")); continue }
            if result.minima == nil { out.append((proc, "minima could not be read")); continue }
            out.append((proc, "nothing published for Category \(category.rawValue)"))
        }
        return out
    }

    // MARK: chrome

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(PlateMinima.Category.allCases) { c in
                    Button {
                        Haptics.impact(.light); category = c
                    } label: {
                        Text(c.rawValue)
                            .font(.dsLabelBold)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(category == c ? p.accent.opacity(0.16) : p.surface,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4)
                                .stroke(category == c ? p.accent : p.border, lineWidth: DS.Stroke.hairline))
                            .foregroundStyle(category == c ? p.accent : p.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ranking-cat-\(c.rawValue)")
                }
            }
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ranking-sort")
        }
    }

    private func row(_ e: Entry, rank: Int) -> some View {
        Button { Haptics.impact(.light); onOpen(e.procedure) } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("\(rank)").font(.dsLabelSBold).foregroundStyle(p.textDim).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.procedure.name).font(.dsLabel).foregroundStyle(p.text).lineLimit(1)
                    Text(e.solution.label).font(.dsLabelS).foregroundStyle(p.textDim)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(e.solution.altitudeFtMSL.map { "\($0)" } ?? "—")
                        .font(.dsDisplayM).foregroundStyle(p.text)
                    Text("\(e.solution.altitudeKind) · \(e.solution.visibility?.label ?? "—")")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(p.border, lineWidth: DS.Stroke.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ranking-row-\(rank)")
    }

    private var unavailableSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not ranked").dsSectionHeader(p)
            ForEach(unavailable.prefix(20), id: \.proc.pdf) { item in
                HStack {
                    Text(item.proc.name).font(.dsLabelS).foregroundStyle(p.text).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.why).font(.dsLabelS).foregroundStyle(p.textDim)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var footnote: some View {
        Text("Ranked on the lowest line each approach publishes for the selected category, as printed — before any inoperative-component or altimeter adjustment. Open an approach to apply today's conditions.")
            .font(.system(size: 9)).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
