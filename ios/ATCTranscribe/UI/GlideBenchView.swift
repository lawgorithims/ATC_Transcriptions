import SwiftUI
import MapKit

/// Put the aeroplane anywhere, at any height, on any heading — and watch the glide answer change.
///
/// WHY THIS EXISTS. The glide footprint, the landability shading and the approach planner are all
/// functions of three inputs: where you are, how high, and which way you point. Until now the only
/// ways to move those were to fly, or to relaunch the app with `--hold-ownship`. Neither lets you
/// ask "what happens if I am 2,000 ft lower", which is the question the whole layer exists to
/// answer. This is a bench: drag the aeroplane, turn the dials, read the result.
///
/// ⚠️ IT PUBLISHES A FAKE POSITION, so it lives behind the same door as the flight simulator and the
/// demo flight, and inherits the same refusals — nothing moving, no Stratux, not recording. Those
/// refusals cannot be re-checked once armed (while simulating, real fixes are dropped), so the bar
/// is at the door and the red SIMULATED GPS banner rides above everything while it is on.
struct GlideBenchView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var deviceLocation: DeviceLocation
    @Environment(\.dismiss) private var dismiss

    /// Where the aeroplane is parked. Seeded from the present fix so the bench opens somewhere
    /// meaningful rather than at Null Island.
    @State private var coord: Coord?
    @State private var altitudeFt: Double = 9500
    @State private var headingDeg: Double = 0
    @State private var region = MKCoordinateRegion()
    @State private var notice: String?

    private var p: Palette { model.palette }
    private var armed: Bool { deviceLocation.isSimulating }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                if let refusal { refusalCard(refusal) } else {
                    dragMap
                    readout
                    dials
                    actions
                }
                if armed { disarm }
                caveat
            }
            .padding(16)
        }
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("Glide bench")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("glide-bench")
        .onAppear(perform: seed)
    }

    // MARK: - gating

    /// Same bar as the demo flight, for the same reason.
    private var refusal: String? {
        if !model.diagnosticsEnabled {
            return "Developer diagnostics are off. Unlock them by tapping the version seven times "
                 + "in Settings — this publishes a fake position, so it is not an ordinary control."
        }
        if model.trustedStratuxOwnship != nil {
            return "A Stratux is connected and reporting a real aircraft. This will not fake a "
                 + "position over the top of one."
        }
        if model.flightRecorder.isRecording {
            return "A flight is being recorded. Stop the recorder first."
        }
        let merged = GPSReadout.merge(stratux: model.freshStratuxGPS, device: model.deviceLocation.fix)
        if let gs = merged.groundSpeedKt, gs >= 5, !armed {
            return "Something is moving at \(Int(gs)) kt. This is a desk tool, not a flight one."
        }
        return nil
    }

    private func refusalCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not available", systemImage: "exclamationmark.triangle.fill")
                .font(.dsHeadline).foregroundStyle(p.warn)
            Text(text).font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("bench-refusal")
    }

    // MARK: - sections

    private var intro: some View {
        Text("Drag the aeroplane anywhere, set a height and a heading, and the glide footprint, "
             + "landability shading and rehearsal all recompute from there.")
            .font(.dsLabelS).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A plain MapKit map used ONLY as a positioning surface.
    ///
    /// Deliberately not the app's chart engine: this needs a drag target and a centre readout, not
    /// overlays, and reusing the real map here would mean a second live chart instance competing
    /// with the one the pilot is about to go look at.
    private var dragMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Map(coordinateRegion: $region)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r4))
                // The aeroplane stays pinned to the CENTRE and the map moves under it — the same
                // idiom as a chart's centre crosshair. Dragging a marker instead would fight the
                // map's own pan gesture and lose on a small view.
                Image(systemName: "airplane")
                    .font(.system(size: 26, weight: .semibold))
                    .rotationEffect(.degrees(headingDeg - 90))
                    .foregroundStyle(p.accent)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
            }
            Text("Pan the map — the aeroplane sits at the centre.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
        .accessibilityIdentifier("bench-map")
    }

    private var readout: some View {
        let c = region.center
        return VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.4f, %.4f", c.latitude, c.longitude))
                .font(.system(.body, design: .monospaced)).foregroundStyle(p.text)
            Text(String(format: "%.0f ft MSL · heading %03.0f°", altitudeFt, headingDeg))
                .font(.dsLabelS).foregroundStyle(p.textDim)
            if let ground = TerrainElevation.shared.sampleElevationFt(
                at: Coord(lat: c.latitude, lon: c.longitude)) {
                Text(String(format: "ground %.0f ft · %.0f ft AGL", ground, altitudeFt - ground))
                    .font(.dsLabelS)
                    .foregroundStyle(altitudeFt - ground < 500 ? p.warn : p.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("bench-readout")
    }

    private var dials: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Altitude").font(.dsLabel).foregroundStyle(p.text)
                    Spacer()
                    Text("\(Int(altitudeFt)) ft").font(.system(.body, design: .monospaced))
                        .foregroundStyle(p.text)
                }
                Slider(value: $altitudeFt, in: 500...25_000, step: 100)
                    .accessibilityIdentifier("bench-altitude")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Heading").font(.dsLabel).foregroundStyle(p.text)
                    Spacer()
                    Text(String(format: "%03.0f°", headingDeg))
                        .font(.system(.body, design: .monospaced)).foregroundStyle(p.text)
                }
                Slider(value: $headingDeg, in: 0...359, step: 1)
                    .accessibilityIdentifier("bench-heading")
                Text("Heading matters: the footprint is stretched by wind, and the rehearsal picks "
                     + "its landing direction relative to where you are pointed.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.impact(.medium)
                place()
            } label: {
                Label(armed ? "Move me here" : "Put me here", systemImage: "location.circle.fill")
                    .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(p.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bench-place")

            if armed {
                Button {
                    Haptics.impact(.rigid)
                    place()
                    model.showLZRisk = true
                    model.showLZEnergy = true
                    model.sendMapCommand(.centerOwnship)
                    dismiss()
                    model.showSettings = false
                } label: {
                    Label("Show me on the map", systemImage: "map.fill")
                        .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(p.accentMuted, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                        .foregroundStyle(p.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bench-show")
            }
            if let notice {
                Text(notice).font(.dsLabelS).foregroundStyle(p.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var disarm: some View {
        Button {
            Haptics.impact(.medium)
            model.disarmSimulator()
        } label: {
            Label("DISARM — return to the real receiver", systemImage: "stop.circle.fill")
                .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(p.bad.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                .foregroundStyle(p.bad)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bench-disarm")
    }

    private var caveat: some View {
        Text("The position is fabricated and the app says so on every screen while this is armed. "
             + "Everything the layer shows remains advisory and inferred from 10 m land cover.")
            .font(.dsLabelS).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - behaviour

    private func seed() {
        let start = model.presentPosition
            ?? Coord(lat: 32.2894, lon: -106.9219)          // Las Cruces, where coverage exists
        coord = start
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
        let readout = GPSReadout.merge(stratux: model.freshStratuxGPS,
                                       device: model.deviceLocation.fix)
        if let a = readout.altitudeFtMSL, a.isFinite { altitudeFt = min(max(a, 500), 25_000) }
        if let t = readout.trackDeg { headingDeg = t }
    }

    private func place() {
        let c = region.center
        let where_ = Coord(lat: c.latitude, lon: c.longitude)
        coord = where_
        model.deviceLocation.holdSimulation(at: where_, altitudeFtMSL: altitudeFt,
                                            headingDeg: headingDeg)
        // Mount the layer explicitly: LZRiskController compiles its compositor in the MAP's apply
        // pass, so a bench opened before the map has drawn would otherwise score nothing.
        LZRiskController.shared.packsChangedOnDisk(aircraft: model.selectedAircraft,
                                                   theme: model.theme)
        notice = LZRiskController.shared.packAvailable
            ? nil
            : "No landability pack covers this spot — the glide bands still work, but there is no "
              + "surface shading to see here."
    }
}
