import SwiftUI

/// Historical airport climatology from NASA POWER (MERRA-2 reanalysis): a 16-sector windrose with
/// month/time-of-day filters, prevailing-wind summary, density-altitude percentiles, and — when the
/// CIFP has pairable runways — favored-runway and crosswind-exceedance stats. This is CLIMATOLOGY,
/// not current weather (the footer says so). One ~2 MB download per airport, then cached forever
/// (`PowerClimateStore`); works fully offline afterwards.
struct AirportClimateView: View {
    // Palette is passed as a plain value (NOT via @EnvironmentObject) so this heavy sheet doesn't
    // re-run its body — full histogram scans + a CIFP.runways SQLite read — on every unrelated
    // AppModel publish during live capture. Same lesson as FloatingCanvas (ConsoleView.swift).
    let palette: Palette
    @Environment(\.dismiss) private var dismiss
    let ident: String
    let coord: Coord

    enum LoadState: Equatable {
        case loading(year: Int, of: Int)      // (0, 0) until the first request starts
        case loaded(PowerClimateStats)
        case unavailable                      // offline + uncached, or POWER had nothing
    }
    @State private var state: LoadState = .loading(year: 0, of: 0)
    @State private var monthFilter: Int?      // nil = all months (1–12)
    @State private var todFilter: Int?        // nil = all hours (0–3)

    private var months: Set<Int> { monthFilter.map { [$0] } ?? [] }
    private var tods: Set<Int> { todFilter.map { [$0] } ?? [] }

    var body: some View {
        let p = palette
        NavigationStack {
            Group {
                switch state {
                case .loading(let year, let of): loadingView(year: year, of: of)
                case .unavailable:               unavailableView
                case .loaded(let stats):         statsList(stats)
                }
            }
            .navigationTitle("\(ident) · Airport Climate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .background(p.bg)
        }
        .tint(p.accent)
        .presentationDetents([.large])
        .task { await load() }
    }

    private func load() async {
        let elev = NavMeta.airport(ident)?.elevationFt
        let stats = await PowerClimateStore.shared.stats(ident: ident, coord: coord, fieldElevFt: elev) { year, of in
            Task { @MainActor in
                // Only step the progress while still loading (a cached hit resolves immediately).
                if case .loading = state { state = .loading(year: year, of: of) }
            }
        }
        await MainActor.run { state = stats.map { .loaded($0) } ?? .unavailable }
    }

    // MARK: Load / empty states

    private func loadingView(year: Int, of: Int) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(year > 0 ? "Downloading year \(year) of \(of)…" : "Checking cached climate…")
                .font(.caption).foregroundStyle(palette.textDim)
            Text("One-time ~2 MB download, then saved for offline use.")
                .font(.caption2).foregroundStyle(palette.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.title2).foregroundStyle(palette.textDim)
            Text("Climate data needs one connection").font(.callout).foregroundStyle(palette.text)
            Text("A one-time ~2 MB download from NASA POWER is saved for offline use. Try again when online.")
                .font(.caption).foregroundStyle(palette.textDim)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaded content

    private func statsList(_ stats: PowerClimateStats) -> some View {
        let p = palette
        let rose = ClimateMath.rose(stats: stats, months: months, tods: tods)
        return List {
            Section {
                filterRow
                WindroseCanvas(rose: rose, palette: p)
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Windrose")
                if let prev = ClimateMath.prevailing(rose) {
                    KV("Prevailing", String(format: "%@ (%03.0f°T) · %.0f kt avg · calm %.0f%%",
                                            ClimateMath.sectorNames[prev.sector], Double(prev.sector) * 22.5,
                                            prev.meanKt, rose.calmPct))
                } else {
                    KV("Prevailing", "calm / no data")
                }
            } header: {
                Text(headerLine(stats))
            }
            daSection(stats)
            runwaySection(stats)
            Section {
            } footer: {
                Text("Historical climatology from NASA POWER (MERRA-2 reanalysis, ~50 km grid), \(yearsLabel(stats)). This is not current weather — winds are 10 m grid-cell averages and can differ from field observations, especially near coasts and terrain. For planning awareness only; check current METAR/TAF.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
        .scrollContentBackground(.hidden)
        .foregroundStyle(p.text)
    }

    private func headerLine(_ stats: PowerClimateStats) -> String {
        var line = "Historical averages \(yearsLabel(stats))"
        if let e = stats.fieldElevationFt { line += " · field elev \(e) ft" }
        return line
    }

    private func yearsLabel(_ stats: PowerClimateStats) -> String {
        guard let first = stats.years.first, let last = stats.years.last else { return "—" }
        return first == last ? "\(first)" : "\(first)–\(last)"
    }

    /// Month menu + time-of-day segmented control (both feed every stat on the card).
    private var filterRow: some View {
        let p = palette
        return VStack(spacing: 8) {
            Picker("Time of day", selection: $todFilter) {
                Text("All").tag(Int?.none)
                ForEach(0..<4, id: \.self) { Text(ClimateMath.todNames[$0]).tag(Int?.some($0)) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Month").font(.caption).foregroundStyle(p.textDim)
                Spacer()
                Picker("Month", selection: $monthFilter) {
                    Text("All months").tag(Int?.none)
                    ForEach(1...12, id: \.self) { Text(Self.monthNames[$0 - 1]).tag(Int?.some($0)) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private static let monthNames = Calendar(identifier: .gregorian).monthSymbols

    // MARK: Density altitude

    @ViewBuilder private func daSection(_ stats: PowerClimateStats) -> some View {
        if stats.fieldElevationFt != nil {
            Section("Density altitude (typical / hot days)") {
                if let all = ClimateMath.daPercentiles(stats: stats, months: months, tods: tods) {
                    KV("Selected filter", daText(all))
                }
                ForEach(1...12, id: \.self) { month in
                    if let da = ClimateMath.daPercentiles(stats: stats, months: [month], tods: tods) {
                        daRow(month: month, da: da, stats: stats)
                    }
                }
            }
        }
    }

    private func daRow(month: Int, da: (p50: Double, p90: Double), stats: PowerClimateStats) -> some View {
        let p = palette
        // Bar scale: field elevation → +10,000 ft DA maps to the row width.
        let base = Double(stats.fieldElevationFt ?? 0)
        let frac = min(max((da.p50 - base) / 10_000, 0), 1)
        return HStack(spacing: 8) {
            Text(Self.monthNames[month - 1].prefix(3))
                .font(.caption.monospaced()).foregroundStyle(p.textDim)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.border.opacity(0.5)).frame(height: 6)
                    Capsule().fill(p.accent).frame(width: max(6, geo.size.width * frac), height: 6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Text(daText(da))
                .font(.caption2.monospaced()).foregroundStyle(p.text)
                .frame(width: 132, alignment: .trailing)
        }
    }

    private func daText(_ da: (p50: Double, p90: Double)) -> String {
        String(format: "%@ / %@ ft", Self.thousands(da.p50), Self.thousands(da.p90))
    }

    private static func thousands(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))"
    }

    // MARK: Runways (Feature D)

    @ViewBuilder private func runwaySection(_ stats: PowerClimateStats) -> some View {
        let pairs = RunwayGeometry.pairs(from: CIFP.runways(airport: ident))
        if !pairs.isEmpty {
            let ends = pairs.flatMap { [($0.a.designator, $0.a.trueHeadingDeg),
                                        ($0.b.designator, $0.b.trueHeadingDeg)] }
            let favored = ClimateMath.favoredPct(ends: ends, stats: stats, months: months, tods: tods)
            Section("Runways (headwind-favored share of windy hours)") {
                ForEach(pairs) { pair in runwayRow(pair, favored: favored, stats: stats) }
            }
        }
    }

    private func runwayRow(_ pair: RunwayPair, favored: [String: Double],
                           stats: PowerClimateStats) -> some View {
        let p = palette
        let x10 = ClimateMath.crosswindExceedancePct(runwayTrueHeadingDeg: pair.a.trueHeadingDeg,
                                                     thresholdKt: 10, stats: stats, months: months, tods: tods)
        let x15 = ClimateMath.crosswindExceedancePct(runwayTrueHeadingDeg: pair.a.trueHeadingDeg,
                                                     thresholdKt: 15, stats: stats, months: months, tods: tods)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(pair.id).font(.callout.monospaced().weight(.semibold)).foregroundStyle(p.text)
                Spacer()
                if let len = pair.lengthFt { Text("\(len) ft").font(.caption2).foregroundStyle(p.textDim) }
            }
            HStack(spacing: 12) {
                favoredLabel(pair.a, favored: favored)
                favoredLabel(pair.b, favored: favored)
            }
            if let x10, let x15 {
                Text(String(format: "Crosswind >10 kt: %.0f%% · >15 kt: %.0f%% of windy hours", x10, x15))
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
        .padding(.vertical, 2)
    }

    private func favoredLabel(_ end: RunwayPair.End, favored: [String: Double]) -> some View {
        let p = palette
        let pct = favored[end.designator] ?? 0
        return Text(String(format: "Rwy %@ favored %.0f%%", end.designator, pct))
            .font(.caption)
            .foregroundStyle(pct >= 50 ? p.accent : p.textDim)
    }
}

// MARK: - Windrose (SwiftUI Canvas — no charting framework)

/// A 16-petal windrose: petal length = share of hours the wind blows FROM that direction, rings at
/// thirds of the max petal, calm share printed at the center.
struct WindroseCanvas: View {
    let rose: WindRose
    let palette: Palette

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 16
            guard radius > 20 else { return }
            let maxPct = max(rose.petalPct.max() ?? 0, 4)          // floor so tiny roses stay legible

            for ring in 1...3 {                                    // reference rings (rule 2: fixed)
                let r = radius * CGFloat(ring) / 3
                let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                ctx.stroke(circle, with: .color(palette.border), lineWidth: 0.7)
            }
            for (i, name) in ["N", "E", "S", "W"].enumerated() {   // cardinal labels
                let angle = Double(i) * 90.0 * .pi / 180 - .pi / 2
                let pt = CGPoint(x: center.x + (radius + 9) * CGFloat(cos(angle)),
                                 y: center.y + (radius + 9) * CGFloat(sin(angle)))
                ctx.draw(Text(name).font(.caption2).foregroundStyle(palette.textDim), at: pt)
            }
            for sector in 0..<16 {                                 // petals (fixed 16)
                let pct = rose.petalPct[sector]
                guard pct > 0 else { continue }
                let r = radius * CGFloat(pct / maxPct)
                let centerAngle = Double(sector) * 22.5 * .pi / 180 - .pi / 2
                let halfWidth = 9.0 * .pi / 180
                var petal = Path()
                petal.move(to: center)
                petal.addArc(center: center, radius: r,
                             startAngle: .radians(centerAngle - halfWidth),
                             endAngle: .radians(centerAngle + halfWidth), clockwise: false)
                petal.closeSubpath()
                ctx.fill(petal, with: .color(palette.accent.opacity(0.55)))
                ctx.stroke(petal, with: .color(palette.accent), lineWidth: 1)
            }
            let calmText = Text(String(format: "calm\n%.0f%%", rose.calmPct))
                .font(.system(size: 9)).foregroundStyle(palette.textDim)
            ctx.draw(calmText, at: center)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
