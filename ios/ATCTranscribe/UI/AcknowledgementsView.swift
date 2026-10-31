import SwiftUI

/// Settings → General → About → Acknowledgements.
///
/// # Why this page exists
///
/// The app already attributes each source where it is *displayed* — `ADSBService.attribution` under
/// the traffic toggle, `WindAloftService.attribution` on the winds layer, and so on. That is the
/// right place for "where did this number come from" in flight, but it leaves two things with
/// nowhere to live:
///
/// 1. **NASA's non-endorsement statement.** The app uses NASA EONET (hazard events) and NASA POWER
///    (climate) in a product that is sold. NASA's media guidelines are explicit that its data must
///    not be used in a way that implies NASA endorses a commercial product, and the remedy is to
///    say so plainly. A per-layer caption is not the place for it; this is.
/// 2. **The open-source notices** for what is linked into the binary. Nobody reads them in the
///    cockpit, and they still have to be somewhere findable.
///
/// Kept deliberately plain: this is a reference page, not a feature.
struct AcknowledgementsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL

    private struct Source: Identifiable {
        let id = UUID()
        let what: String
        let who: String
        let terms: String
    }

    /// Runtime data sources — what the app actually fetches or ships, not what the build pipeline
    /// touches on a Mac.
    private let data: [Source] = [
        .init(what: "Charts, procedures, plates, airports",
              who: "FAA Aeronautical Information Services — CIFP, NASR, d-TPP",
              terms: "US Government work, public domain"),
        .init(what: "Temporary Flight Restrictions",
              who: "FAA (tfr.faa.gov)",
              terms: "Public domain — not an official briefing"),
        .init(what: "METAR, TAF, forecasts, winds aloft",
              who: "NOAA / National Weather Service, NCEP GFS",
              terms: "Public domain — model data, not an official briefing"),
        .init(what: "Natural-hazard events",
              who: "NASA EONET",
              terms: "Open data"),
        .init(what: "Airport climate and density altitude",
              who: "NASA POWER (MERRA-2)",
              terms: "Open data"),
        .init(what: "Live aircraft traffic",
              who: "airplanes.live",
              terms: "Community ADS-B network"),
        .init(what: "Precipitation radar",
              who: "RainViewer",
              terms: "Used under their API terms"),
    ]

    private let software: [Source] = [
        .init(what: "MapLibre Native", who: "MapLibre contributors", terms: "BSD-2-Clause"),
        .init(what: "llama.cpp", who: "Georgi Gerganov and contributors", terms: "MIT"),
        .init(what: "WhisperKit", who: "Argmax, Inc.", terms: "MIT"),
        .init(what: "D-DIN type family", who: "Datto, Inc.", terms: "SIL Open Font License 1.1"),
    ]

    var body: some View {
        let p = model.palette
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Data sources") {
                    ForEach(data) { row(p, $0) }
                }

                // The statement itself. Set apart rather than buried in the list, because its whole
                // job is to be unambiguous.
                Card(title: "NASA") {
                    Text("Obelisk incorporates publicly available NASA data, including the EONET "
                         + "natural-event and POWER climate datasets. NASA does not endorse Obelisk "
                         + "or any commercial product or service.")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card(title: "Open source") {
                    ForEach(software) { row(p, $0) }
                }

                Card(title: "Legal") {
                    Button("Privacy Policy") {
                        openURL(URL(string: "https://obeliskaerospace.com/legal/privacy")!)
                    }
                    Button("Terms of Service") {
                        openURL(URL(string: "https://obeliskaerospace.com/legal/terms")!)
                    }
                }
                .font(.dsLabel)
                .foregroundStyle(p.accent)
                .buttonStyle(.plain)

                Text("Obelisk is an aid to situational awareness. It is not certified for "
                     + "navigation and does not replace official charts, an official weather "
                     + "briefing, or the judgement of the pilot in command.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)

                Text("© 2026 Obelisk Aerospace LLC")
                    .font(.dsLabelS).foregroundStyle(p.textDim.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ p: Palette, _ s: Source) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.what).font(.dsLabel).foregroundStyle(p.text)
            Text(s.who).font(.dsLabelS).foregroundStyle(p.textDim)
            Text(s.terms).font(.dsLabelS).foregroundStyle(p.textDim.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
