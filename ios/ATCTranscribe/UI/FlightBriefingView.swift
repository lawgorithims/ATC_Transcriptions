import SwiftUI

/// The pre-flight briefing behind the strip's BRIEF button: the engine failure after takeoff first,
/// because it is decided on the ground or not at all, then the route's glide exposure.
struct FlightBriefingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var metars: MetarStore
    let onEditAircraft: (AircraftProfile) -> Void

    private var p: Palette { model.palette }
    private var depIdent: String? {
        let d = model.flightPlan?.departure.trimmingCharacters(in: .whitespaces) ?? ""
        return d.isEmpty ? nil : d.uppercased()
    }

    private var briefing: FlightBriefing {
        let ident = depIdent
        return FlightBriefing.build(
            departureIdent: ident, airport: ident.flatMap { AirportData.airport($0) },
            ends: ident.map { AirportData.runwayEnds(airport: $0) } ?? [],
            metar: ident.flatMap { metars.metar($0) }, aircraft: model.selectedAircraft,
            callsign: model.flightPlan?.callsign, exposure: model.routeGlideExposure,
            suggestion: model.routeGlideSuggestion)
    }

    var body: some View {
        let b = briefing
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Flight briefing").font(.dsHeadline).foregroundStyle(p.text)
                if let d = b.departure { departureSection(d) } else {
                    Text("File a departure airport to brief the takeoff.").font(.dsLabelS).foregroundStyle(p.textDim)
                }
                turnbackSection(b.turnback)
                if let e = b.enroute { enrouteSection(e) }
            }
            .padding(16)
        }
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 460, minHeight: 300)
        .task(id: depIdent) { if let d = depIdent { metars.ensure([d]) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flight-briefing")
    }

    private func departureSection(_ d: FlightBriefing.Departure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DEPARTURE · \(d.ident)").font(.dsLabelSBold).foregroundStyle(p.textDim)
            if let e = d.fieldElevationFt { line("Field elevation \(e.formatted()) ft") }
            if let w = d.windText { line("Wind \(w)" + (d.weatherAgeMin.map { " · \($0) min ago" } ?? "")) }
            if let da = d.densityAltitudeFt {
                line("Density altitude \(da.formatted()) ft").accessibilityIdentifier("briefing-da")
            } else {
                line("Density altitude unknown — no current weather", dim: true).accessibilityIdentifier("briefing-da")
            }
            ForEach(d.runways.prefix(4), id: \.end) { r in
                let head = r.headwindKt >= 0 ? "\(r.headwindKt) kt headwind" : "\(-r.headwindKt) kt TAILWIND"
                let cross = r.crosswindKt == 0 ? "" : " · \(abs(r.crosswindKt)) kt from the \(r.crosswindKt > 0 ? "right" : "left")"
                line("RWY \(r.end): \(head)\(cross)", dim: true)
            }
        }
    }

    @ViewBuilder private func turnbackSection(_ t: FlightBriefing.Turnback) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ENGINE FAILURE AFTER TAKEOFF").font(.dsLabelSBold).foregroundStyle(p.textDim)
            switch t {
            case .noAircraft:
                line("Add or select your aircraft to brief a turn-back altitude. Until then: land ahead.")
            case .rotorcraft:
                line("Autorotate. There is no impossible turn to brief for a rotorcraft.")
            case .notSet(let callsign):
                Text("No turn-back altitude set for \(callsign.isEmpty ? "this aircraft" : callsign). Land ahead, within about 30° of the nose.")
                    .font(.dsLabelBold).foregroundStyle(p.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("briefing-turnback-unset")
                if let a = model.selectedAircraft {
                    Button("Set your turn-back altitude") { onEditAircraft(a) }
                        .font(.dsLabelBold).foregroundStyle(p.accent)
                        .accessibilityIdentifier("briefing-turnback-set")
                }
            case .set(let plan):
                turnbackPlan(plan)
            }
            Text("Your number, from practice at a safe height with an instructor. CommSight never calculates it.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func turnbackPlan(_ plan: FlightBriefing.TurnbackPlan) -> some View {
        let alt = plan.altimeterFt.map { " — \($0.formatted()) ft on the altimeter" } ?? ""
        Text("Below \(plan.aglFt.formatted()) ft above the field\(alt): land ahead.")
            .font(.dsLabelBold).foregroundStyle(p.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("briefing-turnback")
        let set = plan.setAtDensityAltitudeFt.map { "Set at density altitude \($0.formatted()) ft" } ?? "Conditions it was set in: not recorded"
        let today = plan.todayDensityAltitudeFt.map { " · today \($0.formatted()) ft" } ?? ""
        line(set + today, dim: true)
        if plan.densityAltitudeCaution {
            Text("Today's density altitude is higher than your number was set in: the turn loses more height "
                 + "and the climb is slower. At high density altitude a turn-back can be impossible. Plan to land ahead.")
                .font(.dsLabelS).foregroundStyle(p.warn)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("briefing-turnback-da-caution")
        }
        if plan.practiceStale {
            line(plan.practisedOn == nil ? "Practice date not recorded — practise it again with an instructor."
                                         : "Practised over a year ago — practise it again with an instructor.", dim: true)
        }
    }

    private func enrouteSection(_ e: FlightBriefing.Enroute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ENROUTE").font(.dsLabelSBold).foregroundStyle(p.textDim)
            line("At \(e.cruiseFt.formatted()) ft, \(e.exposedPercent)% of the route is out of glide of every runway; "
                 + "the longest stretch is \(e.longestGapNm) NM.")
            if let b = e.betterAltitudeFt {
                line("At \(b.formatted()) ft the longest stretch shortens — see OUT OF GLIDE.", dim: true)
            }
        }
    }

    private func line(_ s: String, dim: Bool = false) -> some View {
        Text(s).font(.dsLabelS).foregroundStyle(dim ? p.textDim : p.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The prompt that asks for a missing turn-back number once a flight is planned — quiet otherwise,
/// dismissed for the session, the `DataCurrencyBanner` pattern.
struct TurnbackPromptBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let p = model.palette
        if let a = model.turnbackPromptAircraft, !model.turnbackPromptDismissed {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(p.warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text("No turn-back altitude for \(a.callsign.isEmpty ? a.type : a.callsign)")
                        .font(.dsLabelBold).foregroundStyle(p.text)
                    Text("Until you set your own number, the briefing says land ahead.")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                }
                Spacer(minLength: 4)
                Button("Set it") {
                    model.showFlightPlanBar = true          // the strip owns the aircraft editor
                    model.requestTurnbackEdit = true
                }
                    .font(.dsLabelBold).foregroundStyle(p.accent)
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("turnback-prompt-set")
                Button { model.turnbackPromptDismissed = true } label: {
                    Image(systemName: "xmark").font(.dsLabelSBold).foregroundStyle(p.textDim)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("turnback-prompt-dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 0.5) }
            // ⚠️ `.contain` FIRST, or this identifier is pushed down onto both buttons and
            // `turnback-prompt-set` / `-dismiss` stop existing (the flight-plan strip's lesson).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("turnback-prompt")
        }
    }
}
