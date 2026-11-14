import SwiftUI

/// The cold-temperature advisory over an approach plate.
///
/// Informational only: it never blocks the plate, never hides a control, and never says the approach
/// is unusable. It exists so a snowflake printed in the corner of the notes box is not missed. It is
/// shown when the temperature is at or below the published figure, and — quietly — when the temperature
/// cannot be found at all. Above the limit it shows nothing, so a restriction that does not apply today
/// does not train the pilot to ignore the banner.
///
/// The host observes the store and the METARs itself, so `PlateViewer` stays untouched by both.
struct ColdTemperatureBannerHost: View {
    let procedure: AirportProcedure
    let airport: String
    let palette: Palette
    /// The plate is on disk — the store only reads cached plates, so it is asked again once it is.
    var plateReady = true
    @ObservedObject var store: ColdTemperatureStore
    @EnvironmentObject var metars: MetarStore

    var body: some View {
        let advisory = store.advisory(for: procedure, airport: airport, metars: metars)
        Group {
            // A temperature that is still being fetched is not "unknown" — say nothing until it lands.
            if let advisory, advisory.status == .atOrBelow
                || (advisory.status == .unknown
                    && store.weatherSettled(for: procedure, airport: airport, metars: metars)) {
                ColdTemperatureBanner(advisory: advisory, palette: palette)
            }
        }
        .task(id: "\(procedure.id)-\(plateReady)") { store.ensure(procedure) }
        // Re-ask as each answer lands: the plate read first, then the field's METAR, then (only if the
        // field has no temperature) the stand-in stations.
        .onChange(of: store.info(for: procedure)) { _, _ in fetch() }
        .onChange(of: metars.checked) { _, _ in fetch() }
        .onAppear { fetch() }
    }

    private func fetch() {
        let ids = store.weatherIdents(for: procedure, airport: airport, metars: metars)
        if !ids.isEmpty { metars.ensure(ids) }
    }
}

struct ColdTemperatureBanner: View {
    let advisory: ColdTemperatureAdvisor.Advisory
    let palette: Palette
    @State private var expanded = true

    private var tint: Color { advisory.status == .atOrBelow ? palette.warn : palette.textDim }

    var body: some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "thermometer.snowflake")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(advisory.headline).font(.dsHeadline).foregroundStyle(palette.text)
                        Text("\(advisory.restrictionC)°C").font(.dsLabel.monospacedDigit()).foregroundStyle(tint)
                        if let o = advisory.observation {
                            Text("· \(o.ident) \(Int(o.tempC.rounded()))°C")
                                .font(.dsLabel.monospacedDigit()).foregroundStyle(palette.textDim)
                        }
                    }
                    if expanded {
                        Text(advisory.detail)
                            .font(.dsLabel).foregroundStyle(palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.dsLabelS).foregroundStyle(palette.textDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(palette.overlay)
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
            .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plate-cold-temperature")
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Collapse" : "Expand")
    }
}

/// The snowflake badge on a plate thumbnail: present whenever the plate carries a CTA figure, coloured
/// when the temperature is at or below it.
struct ColdTemperatureBadge: View {
    let procedure: AirportProcedure
    let airport: String
    let palette: Palette
    @ObservedObject var store: ColdTemperatureStore
    @EnvironmentObject var metars: MetarStore

    var body: some View {
        Group {
            if let a = store.advisory(for: procedure, airport: airport, metars: metars) {
                Image(systemName: "thermometer.snowflake")
                    .foregroundStyle(a.status == .atOrBelow ? palette.warn : palette.textDim)
                    .accessibilityLabel(a.status == .atOrBelow
                                        ? "Cold temperature restriction in effect"
                                        : "Cold temperature restricted airport, \(a.restrictionC) degrees")
            }
        }
        .onChange(of: store.info(for: procedure)) { _, _ in
            let ids = store.weatherIdents(for: procedure, airport: airport, metars: metars)
            if !ids.isEmpty { metars.ensure(ids) }
        }
    }
}
