import SwiftUI

/// The minima block, answered.
///
/// A printed minima table asks the pilot to hold four things at once: which row the approach they are
/// flying is on, which column their aeroplane's approach category is, which of the plate's notes are in
/// force today, and what arithmetic each of those notes demands. All four are done under load, on the
/// approach, in the dark. This view does the reading and the arithmetic and shows ONE altitude and ONE
/// visibility — and then, in small type underneath, exactly where they came from, because a number that
/// cannot be checked against the chart in two seconds is a number a pilot should not fly to.
///
/// Categories the plate does not publish are shown BLACKED OUT rather than hidden. That a category has no
/// published minimum is information — usually that the line may not be flown at that speed — and hiding
/// it would read as though the question had not been asked.
struct MinimaPanel: View {
    let minima: PlateMinima
    let refusals: [String]
    /// Field temperature, °C, for the Baro-VNAV limit. nil when no observation is to hand.
    let temperatureC: Double?
    let palette: Palette

    @State private var request = MinimaSolver.Request()
    @State private var showDerivation = false

    private var p: Palette { palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                categorySelector
                lineSelector
                answer
                conditionsSection
                if !refusals.isEmpty { refusalNotice }
                provenance
            }
            .padding(16)
        }
        .background(p.bg.ignoresSafeArea())
        .onAppear { seed() }
        .accessibilityIdentifier("minima-panel")
    }

    // MARK: state

    private var solution: MinimaSolver.Solution? {
        var r = request
        r.temperatureC = temperatureC
        return MinimaSolver.solve(minima, request: r)
    }
    private var lines: [(kind: PlateMinima.Kind, index: Int)] { MinimaSolver.availableLines(minima) }

    /// Start on the plate's lowest published line and Category A — the commonest case, and one the pilot
    /// changes deliberately rather than one this guesses at from aircraft type it does not know.
    private func seed() {
        if let first = lines.first,
           !lines.contains(where: { $0.kind == request.kind && $0.index == request.lineIndex }) {
            request.kind = first.kind
            request.lineIndex = first.index
        }
        let published = minima.publishedCategories
        if !published.contains(request.category), let c = PlateMinima.Category.allCases.first(where: { published.contains($0) }) {
            request.category = c
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MINIMA").dsSectionHeader(p)
            Text(minima.approachName).font(.dsHeadline).foregroundStyle(p.text).lineLimit(2)
        }
    }

    // MARK: category (item 20)

    private var categorySelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Aircraft approach category").font(.dsLabelS).foregroundStyle(p.textDim)
            HStack(spacing: 6) {
                ForEach(PlateMinima.Category.allCases) { c in
                    let published = minima.publishedCategories.contains(c)
                    Button {
                        guard published else { return }
                        Haptics.impact(.light); request.category = c
                    } label: {
                        VStack(spacing: 1) {
                            Text(c.rawValue).font(.dsLabelBold)
                            Text(c.speedLabel).font(.system(size: 8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(cellFill(c, published: published), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4)
                            .stroke(request.category == c && published ? p.accent : p.border,
                                    lineWidth: request.category == c && published ? DS.Stroke.control : DS.Stroke.hairline))
                        .foregroundStyle(published ? (request.category == c ? p.accent : p.text) : p.textDim.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!published)
                    .accessibilityIdentifier("minima-cat-\(c.rawValue)")
                    .accessibilityLabel("Category \(c.rawValue), \(c.speedLabel)\(published ? "" : ", not published")")
                }
            }
        }
    }

    private func cellFill(_ c: PlateMinima.Category, published: Bool) -> Color {
        if !published { return Color.black.opacity(0.55) }        // blacked out, as on the chart
        return request.category == c ? p.accent.opacity(0.16) : p.surface
    }

    // MARK: line (item 21)

    private var lineSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Minima line").font(.dsLabelS).foregroundStyle(p.textDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let row = MinimaSolver.row(in: minima, kind: line.kind, lineIndex: line.index,
                                                   conditionals: [])
                        let selected = request.kind == line.kind && request.lineIndex == line.index
                        Button {
                            Haptics.impact(.light)
                            request.kind = line.kind
                            request.lineIndex = line.index
                        } label: {
                            // The asterisk is what distinguishes two rows of the same kind on the chart,
                            // so it has to survive into the chip or the two are indistinguishable here.
                            Text((row?.label ?? line.kind.shortLabel) + (row?.hasInopAsterisk == true ? " *" : ""))
                                .font(.dsLabelS)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(selected ? p.accent.opacity(0.16) : p.surface, in: Capsule())
                                .overlay(Capsule().stroke(selected ? p.accent : p.border,
                                                          lineWidth: DS.Stroke.hairline))
                                .foregroundStyle(selected ? p.accent : p.text)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("minima-line-\(line.kind.shortLabel)-\(line.index)")
                    }
                }
            }
        }
    }

    // MARK: the answer (item 26)

    @ViewBuilder private var answer: some View {
        if let s = solution {
            VStack(alignment: .leading, spacing: 8) {
                if let why = s.notAuthorised {
                    Label(why, systemImage: "xmark.octagon.fill")
                        .font(.dsLabel).foregroundStyle(p.bad)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.altitudeFtMSL.map { "\($0)" } ?? "—")
                                .font(.dsDisplayXL).foregroundStyle(p.text)
                                .accessibilityIdentifier("minima-altitude")
                            Text("\(s.altitudeKind) ft MSL").font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.visibility?.label ?? "—")
                                .font(.dsDisplayL).foregroundStyle(p.text)
                                .accessibilityIdentifier("minima-visibility")
                            Text("visibility").font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                        Spacer(minLength: 0)
                    }
                    if let hat = s.base.heightAboveFt {
                        Text("\(hat) ft above \(request.kind == .circling ? "airport" : "touchdown")")
                            .font(.dsLabelS).foregroundStyle(p.textDim)
                    }
                }

                // The check: what is printed on the plate, and what was done to it.
                Button { withAnimation(.easeInOut(duration: 0.15)) { showDerivation.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text("Read from the plate as “\(s.base.printedForm)”")
                        Image(systemName: showDerivation ? "chevron.up" : "chevron.down")
                    }
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("minima-derivation-toggle")

                if showDerivation {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(s.steps) { step in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "plus.circle").font(.system(size: 9)).foregroundStyle(p.accent)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(step.text).font(.dsLabelS).foregroundStyle(p.text)
                                    Text(step.source).font(.system(size: 9)).foregroundStyle(p.textDim)
                                }
                            }
                        }
                        if s.steps.isEmpty {
                            Text("No adjustments applied — this is the published value.")
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                    }
                    .padding(.leading, 2)
                }

                ForEach(s.advisories, id: \.self) { a in
                    Label(a, systemImage: "exclamationmark.triangle.fill")
                        .font(.dsLabelS).foregroundStyle(p.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(p.border, lineWidth: DS.Stroke.hairline))
        } else {
            Text("No published minima for this line and category.")
                .font(.dsLabel).foregroundStyle(p.textDim)
        }
    }

    // MARK: conditions (items 23, 25)

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Conditions today").dsSectionHeader(p)

            // The plate's own conditional blocks, as questions (item 25).
            ForEach(minima.conditionals) { c in
                toggleRow(title: c.question,
                          detail: "Published on this plate",
                          isOn: request.conditionals.contains(c.heading),
                          id: "minima-cond") {
                    if request.conditionals.contains(c.heading) { request.conditionals.remove(c.heading) }
                    else { request.conditionals.insert(c.heading) }
                }
            }

            // Inoperative components (item 23).
            ForEach(MinimaSolver.InopComponent.allCases) { comp in
                toggleRow(title: comp.rawValue,
                          detail: InopTable.source,
                          isOn: request.inoperative.contains(comp),
                          id: "minima-inop") {
                    if request.inoperative.contains(comp) { request.inoperative.remove(comp) }
                    else { request.inoperative.insert(comp) }
                }
            }

            // Remote altimeter (item 23) — only offered when the plate publishes the penalty.
            if let pen = MinimaSolver.altimeterPenalty(minima), let add = pen.addFt {
                toggleRow(title: "Not using the local altimeter setting",
                          detail: "+\(add) ft, \(pen.source.isEmpty ? "published on this plate" : pen.source + " setting")",
                          isOn: request.remoteAltimeter,
                          id: "minima-altimeter") { request.remoteAltimeter.toggle() }
            }

            // Temperature (item 24) — stated, not toggled: it is measured, not chosen.
            if let limit = MinimaSolver.temperatureLimit(minima) {
                temperatureRow(limit)
            }
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? p.accent : p.textDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.dsLabel).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(detail).font(.system(size: 9)).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    @ViewBuilder private func temperatureRow(_ limit: (minC: Int?, maxC: Int?)) -> some View {
        let verdict = MinimaSolver.temperatureVerdict(limit, temperatureC: temperatureC)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "thermometer.medium").font(.system(size: 14)).foregroundStyle(iconColour(verdict))
            VStack(alignment: .leading, spacing: 1) {
                Text(temperatureC.map { "Field temperature \(Int($0.rounded()))°C" } ?? "Field temperature unknown")
                    .font(.dsLabel).foregroundStyle(p.text)
                Text(limitText(limit)).font(.system(size: 9)).foregroundStyle(p.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("minima-temperature")
    }

    private func iconColour(_ v: MinimaSolver.TemperatureVerdict) -> Color {
        switch v {
        case .inside: return p.good
        case .outside: return p.bad
        case .unknown: return p.warn
        }
    }

    private func limitText(_ limit: (minC: Int?, maxC: Int?)) -> String {
        var parts: [String] = []
        if let lo = limit.minC { parts.append("below \(lo)°C") }
        if let hi = limit.maxC { parts.append("above \(hi)°C") }
        return "LNAV/VNAV NA " + (parts.isEmpty ? "outside the published window" : parts.joined(separator: " or "))
            + " for uncompensated Baro-VNAV"
    }

    // MARK: honesty

    private var refusalNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Part of this table could not be read", systemImage: "exclamationmark.triangle.fill")
                .font(.dsLabelSBold).foregroundStyle(p.warn)
            ForEach(refusals.prefix(4), id: \.self) { r in
                Text(r).font(.system(size: 9)).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Read the chart for anything missing.").font(.system(size: 9)).foregroundStyle(p.textDim)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("minima-refusals")
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text([minima.amendment, "cycle \(minima.cycle)"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 9)).foregroundStyle(p.textDim)
            Text("Read from this plate. The chart remains the authority — check the figure against it before you fly it.")
                .font(.system(size: 9)).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
