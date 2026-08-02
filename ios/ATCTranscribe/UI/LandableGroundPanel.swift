import SwiftUI

/// Ranked ground you could reach, as a LIST.
///
/// =============================================================================================
/// WHY THIS IS A LIST AND NOT SYMBOLS ON THE CHART
/// =============================================================================================
/// The landability layer is a RISK FIELD: it shades ground high-to-low so a pilot can read the
/// gradient and turn toward the better side of it. That is advisory the way a terrain colour band
/// is advisory. The moment it places a mark on the chart saying "here", it stops describing terrain
/// and starts recommending a specific patch of dirt it has never seen — a different product with a
/// far higher burden of proof, and one this data cannot carry.
///
/// A list makes the same information available without borrowing the chart's visual authority. A
/// pilot reads a row, decides for themselves, and the shading underneath is what actually guides
/// the turn. Nothing here is drawn on the map.
///
/// Every row carries what is NOT known, because a bearing and a run length read as survey data
/// unless something says otherwise. That text comes from the candidate itself rather than being
/// composed here, so no future caller can present the number without the caveat.
struct LandableGroundPanelView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: LZRiskController

    @State private var candidates: [LZSiteFinder.Candidate] = []
    @State private var searching = false
    @State private var notice: String?
    @State private var rehearsal: Rehearsal?

    /// A plan and which row it came from — one `Identifiable` so the sheet cannot be presented for
    /// a candidate the list has since re-ranked out from under it.
    private struct Rehearsal: Identifiable {
        let plan: LZGlidePlan
        let rank: Int
        var id: Int { rank }
    }

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            Divider().overlay(p.hairline)
            if searching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching reachable ground…").font(.dsLabel).foregroundStyle(p.textDim)
                }
                .padding(12)
            } else if let notice {
                // A REASON, never an empty list. "Nothing found" and "I could not look" are
                // completely different answers and a blank panel says neither.
                Text(notice)
                    .font(.dsLabel).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .accessibilityIdentifier("landable-notice")
            } else if candidates.isEmpty {
                Text("No ground within glide scores well enough to list. The shading still shows "
                     + "where the better ground is — this only names the strongest of it.")
                    .font(.dsLabel).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .accessibilityIdentifier("landable-empty")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { i, c in
                            row(c, rank: i + 1, p)
                            Divider().overlay(p.hairline)
                        }
                        footer(p)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task(id: readiness) { await search() }
        .sheet(item: $rehearsal) { r in
            LZGlidePlanSheet(plan: r.plan, rank: r.rank).environmentObject(model)
        }
    }

    /// Build the plan for one candidate and present it.
    ///
    /// The OTHER candidates go in as alternatives, which is what makes the commit point mean
    /// anything: "the last place you could still change your mind" is a statement about this list,
    /// not about the world.
    private func rehearse(_ c: LZSiteFinder.Candidate, rank: Int) {
        guard let here = model.presentPosition else { return }
        let readout = GPSReadout.merge(stratux: model.freshStratuxGPS, device: model.deviceLocation.fix)
        guard let alt = readout.altitudeFtMSL, alt.isFinite else { return }
        let wind = model.windAloft.wind(at: here.lat, lon: here.lon,
                                        level: WindLevel.at(index: model.windLevelIndex))
        let others = candidates.filter { $0 != c }
        let plan = LZGlidePlanner.plan(
            from: here, altitudeFtMSL: alt,
            groundElevationFt: controller.energyFieldSnapshot != nil
                ? TerrainElevation.shared.sampleElevationFt(at: c.centre) : nil,
            candidate: c, alternatives: others,
            glideRatio: model.selectedAircraft?.glideRatio ?? NearestAirports.defaultGlideRatio,
            bestGlideKts: Double(model.selectedAircraft?.bestGlideKts ?? 65),
            windFromDeg: wind.map { Double($0.fromDeg) },
            windKts: wind.map { Double($0.kt) })
        guard let plan else { return }
        rehearsal = Rehearsal(plan: plan, rank: rank)
    }

    /// The three things the search needs, as a small discrete token.
    ///
    /// ⚠️ A PLAIN `.task` LATCHES THE STARTUP RACE. Opened from the emergency button — or simply
    /// restored at launch, which is how this was caught — the panel can run its search before the
    /// first fix arrives, print "no trusted position", and then sit on that notice for as long as it
    /// is open while the aircraft symbol is plainly on the map behind it. The pilot's only recovery
    /// is a refresh button they have no reason to think is needed.
    ///
    /// Keyed on readiness instead, the search re-runs the moment the missing piece appears. Eight
    /// possible values, so this cannot churn. `energyBands` stands in for the field snapshot because
    /// it is the published half of the same assignment.
    private var readiness: String {
        let position = model.presentPosition != nil
        let field = !controller.energyBands.isEmpty
        return "\(position)|\(field)|\(controller.packAvailable)"
    }

    // MARK: - header

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            Text("Reachable ground, best first").font(.dsLabelSBold).foregroundStyle(p.textDim)
            Spacer(minLength: 4)
            Button {
                Haptics.impact(.light)
                Task { await search() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.dsLabel).foregroundStyle(p.accent)
            }
            .buttonStyle(.plainHaptic)
            .disabled(searching)
            .accessibilityIdentifier("landable-refresh")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - a row

    private func row(_ c: LZSiteFinder.Candidate, rank: Int, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(rank)").font(.dsLabelSBold).foregroundStyle(p.textDim).frame(width: 14)
                // Bearing and distance — how a pilot would actually fly to it. Deliberately the
                // most prominent thing in the row, because it is the part the data supports best.
                Text(String(format: "%03.0f°", c.bearingDeg))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(p.text)
                Text(String(format: "%.1f NM", c.distanceNm))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(p.text)
                Spacer(minLength: 4)
                arrivalChip(c.arrival, p)
            }
            // The run, phrased as the measurement it is — never "runway", never a length with a
            // heading formatted like a runway designator.
            Text("about \(Int(c.runMetres.rounded())) m of open ground, lying "
                 + String(format: "%03.0f°", c.runHeadingDeg))
                .font(.dsLabelS).foregroundStyle(p.textDim)
            if c.coarseTerrain {
                Text("10 m elevation here — the ditch and berm checks could not run")
                    .font(.dsLabelS).foregroundStyle(p.warn)
            }
            // The same named rules the tap card shows, so the list and the map agree about why.
            ForEach(Array(c.rules.prefix(3).enumerated()), id: \.offset) { _, r in
                Text("• \(r.text)").font(.dsLabelS).foregroundStyle(p.textDim)
            }
            Button {
                Haptics.impact(.light)
                rehearse(c, rank: rank)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle").font(.dsLabelS)
                    Text("Rehearse the glide").font(.dsLabelS)
                }
                .foregroundStyle(p.accent)
            }
            .buttonStyle(.plainHaptic)
            .accessibilityIdentifier("landable-rehearse-\(rank)")
            .padding(.top, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // One element per row, not five loose labels. A pilot on VoiceOver should hear "070 degrees,
        // 3.8 nautical miles, high, about 1230 m of open ground" as ONE thing they can act on —
        // and a bare identifier on a plain stack is not exposed at all, so the row was invisible to
        // the UI tests as well.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("landable-row-\(rank)")
    }

    private func arrivalChip(_ a: LZEnergyClass, _ p: Palette) -> some View {
        let (label, colour): (String, Color) = {
            switch a {
            case .comfortable: return ("comfortable", p.good)
            case .excess:      return ("high", p.warn)
            case .marginal:    return ("marginal", p.warn)
            case .blocked:     return ("blocked", p.bad)
            }
        }()
        return Text(label)
            .font(.dsLabelSBold).foregroundStyle(colour)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.r2))
    }

    /// The unknowns, once, at the bottom — and taken from a candidate rather than written here, so
    /// this panel cannot drift from what the engine says it does not know.
    private func footer(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidates.first?.unknowns ?? "")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("This names the strongest of what the shading already shows. It is not a "
                 + "recommendation to land, and nothing here is drawn on the chart.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("landable-unknowns")
    }

    // MARK: - the search

    /// ON DEMAND. The answer is about ground, which changes slowly; a timer would spend battery
    /// re-deriving the same list. It runs when the panel opens and when the pilot asks.
    @MainActor
    private func search() async {
        guard !searching else { return }
        searching = true
        notice = nil
        defer { searching = false }

        guard model.showLZRisk || controller.packAvailable else {
            notice = "The off-field landability layer has no data loaded. Download a region in "
                   + "Settings › Downloads."
            candidates = []
            return
        }
        guard let here = model.presentPosition else {
            notice = "No trusted position — this needs to know where you are before it can say "
                   + "what you can reach."
            candidates = []
            return
        }
        let readout = GPSReadout.merge(stratux: model.freshStratuxGPS, device: model.deviceLocation.fix)
        guard let alt = readout.altitudeFtMSL, alt.isFinite else {
            notice = "Position is good but there is no altitude. A glide has nothing to spend "
                   + "without one."
            candidates = []
            return
        }
        guard let field = controller.energyFieldSnapshot else {
            notice = "The glide footprint is not available yet. Turn on Glide energy bands, or "
                   + "wait a moment for the first sweep."
            candidates = []
            return
        }

        let wind = model.windAloft.wind(at: here.lat, lon: here.lon,
                                        level: WindLevel.at(index: model.windLevelIndex))
        let required = LZSiteFinder.requiredRunMetres(for: model.selectedAircraft)
        let input = LZSiteFinder.Input(coord: here, altitudeFtMSL: alt,
                                       headingDeg: readout.trackDeg,
                                       windFromDeg: wind.map { Double($0.fromDeg) },
                                       windKts: wind.map { Double($0.kt) },
                                       requiredRunMetres: required)
        // Off the main actor: a few thousand scored samples plus a directional walk per candidate
        // is not render-loop work.
        let sampler = controller.sampler
        let found = await Task.detached(priority: .userInitiated) {
            LZSiteFinder.find(input, field: field, sample: sampler)
        }.value
        candidates = found
    }
}
