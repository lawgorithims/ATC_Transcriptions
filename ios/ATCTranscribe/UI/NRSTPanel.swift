import SwiftUI

/// The engine-out NRST panel — the ranked "where can I glide" list behind the map's NRST button.
///
/// Hosted as the `.nrst` floating widget / side pane on regular width and as `NRSTSheet` on compact.
/// The panel OWNS the refresh cadence (a `.task` loop that dies with the view), so there is no
/// AppModel timer to reconcile across state transitions: closed panel = zero background work. Rows
/// come fully ranked from `NearestAirports` — this view formats, it never re-derives.
struct NRSTPanelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var metars: MetarStore
    /// Compact-sheet hosting passes a dismiss so DIRECT can drop the sheet and reveal the map.
    var onEngaged: (() -> Void)? = nil
    /// Why the last DIRECT tap did nothing. Shown in the panel rather than swallowed — the emergency
    /// control is the last place a failure should look like a success.
    @State private var engageNotice: String?

    /// Refresh cadence while the panel is open. Position moves ~1.5 NM/min at GA speeds; 10 s keeps
    /// the list honest without burning the battery on terrain sweeps.
    static let refreshSeconds: UInt64 = 10
    /// How many candidates get a METAR request per cycle (one batched HTTP GET).
    static let wxSeedLimit = 30
    /// Loop-iteration ceiling (rule 2 — no unbounded loops). At 10 s a tick this is ~48 hours, far
    /// past any flight, so it is a runaway backstop and never a functional limit.
    static let maxRefreshTicks = 17_280

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            Rectangle().fill(p.border).frame(height: 1)
            if let notice = engageNotice { noticeBar(p, notice) }
            content(p)
        }
        .task { await refreshLoop() }
        .onReceive(metars.$metars) { _ in Task { await refreshOnce() } }   // re-rank when METARs land
        // Going out of sight drops the ranking; coming back recomputes it at once rather than waiting out
        // the loop's sleep. Without this pair the panel showed a ranking as old as the excursion, with
        // live DIRECT buttons on it — see `AppModel.clearNRSTAssessment`.
        .onChange(of: model.selectedTab) { _, tab in
            if tab == .map { Task { await refreshOnce() } } else { model.clearNRSTAssessment() }
        }
        .onChange(of: model.standby) { _, standby in
            if standby { model.clearNRSTAssessment() } else { Task { await refreshOnce() } }
        }
        .accessibilityIdentifier("nrst-panel")
    }

    /// The list, or the specific reason there isn't one. Ordered by which truth matters most: a
    /// position we don't trust, then a database we can't read, then an honestly empty search.
    ///
    /// The position check is re-evaluated HERE rather than relied on from the last refresh: a trusted
    /// fix can lapse purely by time (a cached Stratux fix ageing past its freshness limit) with no
    /// publisher firing, so rows computed up to a refresh-cycle ago could otherwise still be sitting
    /// on screen with live DIRECT buttons behind a guard that would silently do nothing.
    @ViewBuilder private func content(_ p: Palette) -> some View {
        if model.presentPosition == nil {
            message(p, "No trusted GPS position — the glide ranking will not run on a fix the map itself would suppress. It resumes automatically.")
        } else if model.nrstBlocked == .noAltitude {
            message(p, "No GPS altitude — a glide range cannot be computed without one. Ranking resumes as soon as the receiver reports altitude (a 2D-only fix never will).")
        } else if !model.nrstDatabaseAvailable {
            message(p, "Airport database unavailable — this is a data fault, NOT a statement that nothing is reachable. Check Downloads for the navigation data cycle.")
        } else if let assessment = model.nrstAssessment {
            if assessment.candidates.isEmpty {
                message(p, "No landable airports found within \(Int(NearestAirports.searchRadiusNm(for: assessment.situation))) NM.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(assessment.candidates) { c in
                            row(c, palette: p)
                            Rectangle().fill(p.border.opacity(0.5)).frame(height: 0.5)
                        }
                    }
                }
            }
        } else {
            message(p, "Computing glide ranking…")
        }
    }

    private func noticeBar(_ p: Palette, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.dsLabelS).foregroundStyle(p.bad)
            Text(text).font(.dsLabelS).foregroundStyle(p.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(p.bad.opacity(0.14))
        .accessibilityIdentifier("nrst-notice")
    }

    // MARK: refresh

    private func refreshLoop() async {
        var ticks = 0
        while !Task.isCancelled, ticks < Self.maxRefreshTicks {   // bounded (rule 2)
            assert(ticks >= 0, "tick counter never negative")
            ticks += 1
            // Terrain sweeps are not free, and this panel stays MOUNTED behind another tab and under
            // the standby screen (the floating canvas is never torn down). Keep ticking so the list is
            // current the instant the pilot comes back, but skip the work while nobody can see it.
            await refreshOnce()                 // gated inside, so both entry points obey one rule
            try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
        }
    }

    /// One ranking pass. The visibility gate lives HERE, not only in the loop, because METARs arrive on
    /// their own schedule and `.onReceive(metars.$metars)` fired regardless — so a store update while the
    /// pilot was on another tab, or in standby, ran a full terrain sweep over every candidate for a list
    /// nobody could see. The loop's own gate was doing the right thing and this path walked around it.
    private func refreshOnce() async {
        guard model.selectedTab == .map, !model.standby else { return }
        await model.refreshNRST(weather: model.nrstWeather(from: metars))
        // Warm live weather for the fields we just ranked; the NEXT pass ranks with it. Offline this
        // fails soft — the store keeps its terminal failed state and rows show no category.
        if let a = model.nrstAssessment {
            let idents = a.candidates.prefix(Self.wxSeedLimit).compactMap { NearestAirports.wxIdent(for: $0.airport) }
            if !idents.isEmpty { metars.ensure(idents) }
        }
    }

    // MARK: header

    private func header(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let a = model.nrstAssessment {
                let s = a.situation
                let ratio = String(format: "%g:1", s.glideRatio)
                // AGL rides beside MSL because they answer different questions: MSL over each field's
                // elevation is what sets the ranges below, AGL is what tells the pilot how much time
                // they have. A glide can be thousands of feet above a valley floor and still be below
                // the ridge in the way — which is what the per-row terrain verdict is for.
                let agl = a.ownshipAglFt.map { " · \(Int(max(0, $0)).formatted()) ft AGL" } ?? ""
                Text("From \(Int(s.altitudeFtMSL).formatted()) ft MSL\(agl) · glide \(ratio)\(s.isDefaultGlideRatio ? " (default)" : "") · still air")
                    .font(.dsLabelBold).foregroundStyle(p.text)
                Text(caption(a))
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                if s.isAltitudeCarried {
                    Text("GPS altitude lost \(Int(s.altitudeAgeS)) s ago — altitude carried forward at best-glide sink, so these ranges are estimates and read SHORT.")
                        .font(.dsLabelS).foregroundStyle(p.warn)
                        .accessibilityIdentifier("nrst-carried-altitude")
                }
            } else {
                Text("Engine-out glide ranking").font(.dsLabelBold).foregroundStyle(p.text)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ a: NRSTAssessment) -> String {
        var parts = [String(format: "best-case range %.0f NM", a.stillAirRangeNm)]
        parts.append(a.terrainAvailable ? "terrain swept" : "TERRAIN DATA UNAVAILABLE")
        if a.situation.isDefaultGlideRatio { parts.append("set your glide ratio in the aircraft profile") }
        return parts.joined(separator: " · ")
    }

    private func message(_ p: Palette, _ text: String) -> some View {
        Text(text).font(.dsLabel).foregroundStyle(p.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    // MARK: rows

    private func row(_ c: NRSTCandidate, palette p: Palette) -> some View {
        let engaged = model.nrstEngagement?.ident == c.airport.ident
        return HStack(alignment: .center, spacing: 10) {
            badge(c.reachability, palette: p)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.airport.icao.isEmpty ? c.airport.ident : c.airport.icao)
                        .font(.dsHeadline).foregroundStyle(p.text)
                    categoryChip(c, palette: p)
                    facilityGlyphs(c.airport, palette: p)
                }
                Text(c.airport.name.capitalized).font(.dsLabelS).foregroundStyle(p.textDim).lineLimit(1)
                Text(detailLine(c)).font(.dsLabelS).foregroundStyle(p.textDim).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f NM", c.distanceNm)).font(.dsDataMono).foregroundStyle(p.text)
                Text(String(format: "%03.0f°T", c.bearingTrueDeg)).font(.dsLabelS).foregroundStyle(p.textDim)
                if let margin = c.arrivalMarginFt {
                    Text("+\(Int(margin).formatted()) ft")
                        .font(.dsLabelS)
                        .foregroundStyle(margin < NearestAirports.thinArrivalMarginFt ? p.warn : p.good)
                }
            }
            directButton(c, engaged: engaged, palette: p)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(engaged ? p.bad.opacity(0.12) : .clear)
        .opacity(c.reachability.isReachable ? 1 : 0.55)
        .accessibilityIdentifier("nrst-row-\(c.airport.ident)")
    }

    private func directButton(_ c: NRSTCandidate, engaged: Bool, palette p: Palette) -> some View {
        Button {
            // Every success cue — the haptic, the map recenter, dismissing the compact sheet — fires
            // ONLY on an actual engage. Firing them around a guard that can silently return left the
            // pilot believing a course was active with no banner and no magenta line to contradict it.
            switch model.engageNRST(c) {
            case .engaged:
                Haptics.impact(.medium)
                engageNotice = nil
                model.sendMapCommand(.centerOwnship)
                onEngaged?()
            case .noTrustedPosition:
                Haptics.impact(.rigid)
                engageNotice = "Not engaged — no trusted GPS position to fly the course FROM. Nothing was changed."
            }
        } label: {
            Text(engaged ? "ACTIVE" : "DIRECT").font(.dsLabelBold)
                .foregroundStyle(engaged ? p.bad : .white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(engaged ? p.bad.opacity(0.18) : p.bad))
        }
        .buttonStyle(.plainHaptic)
        .disabled(engaged)
        .accessibilityIdentifier("nrst-direct-\(c.airport.ident)")
    }

    /// Reachability tag — the tier-1 verdict, always the loudest thing on the row.
    private func badge(_ r: NRSTReachability, palette p: Palette) -> some View {
        let (text, color): (String, Color) = {
            switch r {
            case .clear:                    return ("GLIDE", p.good)
            case .caution(.thinMargin):     return ("TIGHT", p.warn)
            case .caution(.terrainUnknown): return ("TER ?", p.warn)
            case .blocked(let nm):          return (String(format: "TER %.0f", nm), p.bad)
            case .outOfGlide:               return ("OUT", p.textDim)
            }
        }()
        return Text(text).font(.dsLabelSBold).foregroundStyle(color)
            .frame(width: 46, alignment: .leading)
    }

    private func categoryChip(_ c: NRSTCandidate, palette p: Palette) -> some View {
        let color: Color = {
            switch c.category {
            case .vfr: return p.good
            case .mvfr: return p.accent
            case .ifr: return p.warn
            case .lifr: return p.bad
            case .unknown: return p.textDim
            }
        }()
        return Group {
            if c.category != .unknown {
                Text(c.category.rawValue).font(.dsLabelSBold).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: DS.Stroke.hairline))
            }
        }
    }

    /// Tower / fuel / Part-139 rescue, only when known-true (absence of a glyph is not a claim).
    private func facilityGlyphs(_ a: AirportData.Airport, palette p: Palette) -> some View {
        HStack(spacing: 4) {
            if a.isTowered { Image(systemName: "antenna.radiowaves.left.and.right") }
            if a.hasFuel { Image(systemName: "fuelpump") }
            if a.isCertificated { Image(systemName: "cross.circle.fill") }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(p.textDim)
    }

    private func detailLine(_ c: NRSTCandidate) -> String {
        var parts: [String] = []
        if let len = c.longestRunwayFt {
            var rwy = "\(Int(len).formatted())′ \(c.longestRunwayPaved ? "paved" : "unpaved")"
            if c.longestRunwayLit { rwy += " · lit" }
            parts.append(rwy)
        } else {
            parts.append("runway data unavailable")
        }
        if let rise = c.terrainRiseFt, rise > NearestAirports.terrainRiseEasyFt {
            // The enroute sweep deliberately exempts the field's own ~1 NM cell (it holds the high
            // ground AROUND the field, and blocking on it would reject every mountain airport), so the
            // terminal terrain is advisory — which makes the wording matter. When the surrounding rise
            // exceeds the height the glide ARRIVES at, "terrain nearby" undersells it: the pilot would
            // be arriving below the ridge line, i.e. committed to already being inside that valley.
            let arrivalAboveField = NearestAirports.arrivalReserveFt + (c.arrivalMarginFt ?? 0)
            if c.reachability.isReachable, rise > arrivalAboveField {
                parts.append("ARRIVES BELOW surrounding terrain (+\(Int(rise).formatted())′ over field)")
            } else {
                parts.append("terrain +\(Int(rise).formatted())′ nearby")
            }
        }
        if let age = c.wxAgeMinutes, c.category != .unknown { parts.append("wx \(age)m ago") }
        if !c.airport.isPublicUse { parts.append("private") }
        return parts.joined(separator: " · ")
    }
}

/// Compact-width (iPhone) hosting: the same panel on a sheet, mirroring `MapSearchSheet`.
struct NRSTSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NRSTPanelView(onEngaged: { dismiss() })
                .background(model.palette.bg)
                .navigationTitle("Nearest airports")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme.colorScheme)
    }
}
