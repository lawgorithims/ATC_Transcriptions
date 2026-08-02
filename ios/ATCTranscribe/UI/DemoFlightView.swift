import SwiftUI

/// Park a hypothetical aeroplane over ground the landability layer knows about, then declare an
/// emergency on it — the whole feature, demonstrable at a desk in two taps.
///
/// =============================================================================================
/// THIS PUBLISHES A FAKE POSITION, AND THAT IS THE ONLY REASON IT IS HARD TO REACH
/// =============================================================================================
/// It arms through the same `DeviceLocation.holdSimulation` the flight simulator uses, so
/// `isSimulating` is published and the red SIMULATED GPS banner rides above every other chrome for
/// as long as it is on. It also inherits the same refusals: no arming while anything is moving, no
/// arming with a Stratux connected, no arming while a flight is being recorded.
///
/// ⚠️ THE REFUSALS CANNOT BE RE-CHECKED ONCE ARMED. While simulating, real fixes are dropped on the
/// floor (`DeviceLocation.publish` guards on `isSimulating`), so the app genuinely cannot tell that
/// an aeroplane has started moving underneath it. There is no auto-disarm to be written; the bar has
/// to be at the door. That is why this sits behind the same diagnostics unlock as the rest — not
/// because a demo is dangerous, but because a fake position that cannot notice it has become wrong
/// is.
///
/// The demonstration itself is deliberately the REAL path: a real random point, checked against the
/// real compositor, and then the real emergency button's own action. Nothing here is a mock-up, so
/// what an audience sees working is what works.
struct DemoFlightView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var deviceLocation: DeviceLocation
    @Environment(\.dismiss) private var dismiss

    @State private var drop: LZDemoFlight.Drop?
    @State private var notice: String?

    private var p: Palette { model.palette }
    private var armed: Bool { deviceLocation.isSimulating }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                if let refusal = refusal {
                    refusalCard(refusal)
                } else {
                    dropSection
                    if let drop { placard(drop) }
                    if armed { emergencySection }
                }
                if armed { disarm }
                caveat
            }
            .padding(16)
        }
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("Demo flight")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("demo-flight")
    }

    // MARK: - gating

    /// Reuses the flight simulator's bar, minus the parts that are about an APPROACH — there is no
    /// approach here, and requiring one would make the landability layer undemonstrable, which is
    /// exactly the reason `holdSimulation` exists separately from `startSimulation`.
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
            return "A flight is being recorded. Stop the recorder first — a fake position must "
                 + "never end up in a logbook."
        }
        let merged = GPSReadout.merge(stratux: model.freshStratuxGPS, device: model.deviceLocation.fix)
        if let gs = merged.groundSpeedKt, gs >= 5, !armed {
            return "Something is moving at \(Int(gs)) kt. Demo mode is for a desk, not for flight."
        }
        if model.lzPackStatus.contains("no .lzpack") {
            return "No landability pack is installed, so there is nowhere with data to demonstrate. "
                 + "Download a region in Settings › Downloads first."
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
        .accessibilityIdentifier("demo-refusal")
    }

    // MARK: - sections

    private var intro: some View {
        Text("Drops a hypothetical aeroplane over ground this device has landability data for, at a "
             + "height with something to glide to. Then you can press the emergency button and show "
             + "what it does.")
            .font(.dsLabelS).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.impact(.medium)
                rollAndArm()
            } label: {
                Label(drop == nil ? "Put me somewhere with data" : "Somewhere else",
                      systemImage: drop == nil ? "dice" : "arrow.triangle.2.circlepath")
                    .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(p.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("demo-roll")

            if let notice {
                Text(notice).font(.dsLabelS).foregroundStyle(p.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("demo-notice")
            }
        }
    }

    private func placard(_ d: LZDemoFlight.Drop) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PARKED HERE").dsSectionHeader(p)
            Text(String(format: "%.4f, %.4f", d.coord.lat, d.coord.lon))
                .font(.system(.body, design: .monospaced)).foregroundStyle(p.text)
            Text(String(format: "%.0f ft MSL · %.0f ft above ground · %@",
                        d.altitudeFtMSL, d.heightAGL, d.packName))
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("demo-placard")
    }

    private var emergencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.impact(.rigid)
                // THE REAL ACTION, not a demo copy of it. If the emergency button ever changes what
                // it does, this changes with it and the demonstration stays true.
                model.armEmergency(compact: model.isCompactWindow)
                // ⚠️ `dismiss()` ALONE ONLY POPS THIS SCREEN. It leaves the Settings sheet standing,
                // so pressing "show me" showed you Settings — with the emergency correctly armed and
                // completely invisible behind it. Close the sheet; that IS the reveal.
                dismiss()
                model.showSettings = false
                // Fly the camera to the aeroplane. Deliberately HERE and not inside `armEmergency`:
                // moving a pilot's map for them is a change to the emergency button's behaviour and
                // nobody asked for it. A demonstration that opens on a whole-globe view, though, is
                // just a picture of the Earth.
                model.sendMapCommand(.centerOwnship)
            } label: {
                Label("Declare the emergency and show me", systemImage: "exclamationmark.triangle.fill")
                    .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(p.bad.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                    .foregroundStyle(p.bad)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("demo-declare")

            Text("Same action as the button beside the logo: raises the map, turns on the "
                 + "landability shading and the glide bands, and opens nearest airports.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disarm: some View {
        Button {
            Haptics.impact(.medium)
            model.disarmSimulator()
            drop = nil
        } label: {
            Label("DISARM — return to the real receiver", systemImage: "stop.circle.fill")
                .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(p.bad.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                .foregroundStyle(p.bad)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("demo-disarm")
    }

    private var caveat: some View {
        Text("Everything shown is advisory and inferred from 10 m land cover and terrain. The "
             + "position is fabricated and the app says so on every screen while this is armed.")
            .font(.dsLabelS).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - the roll

    private func rollAndArm() {
        notice = nil
        // ⚠️ THE SAMPLER DOES NOT EXIST UNTIL SOMETHING COMPILES IT. `LZRiskController` builds its
        // compositor in the MAP's apply pass, so opening this screen without having visited the map
        // first left `sampler` returning nil for every point on earth — and the honest notice below
        // then reported "none of them scored", which reads as a data fault and is not one.
        //
        // Mounting here is idempotent and cheap: `refresh` re-keys on the mounted fingerprint and
        // returns immediately when nothing moved.
        LZRiskController.shared.packsChangedOnDisk(aircraft: model.selectedAircraft,
                                                   theme: model.theme)
        let store = LZPackStore()
        let sampler = LZRiskController.shared.sampler
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()
        let picked = LZDemoFlight.pick(
            mounted: store.mounted,
            sample: sampler,
            elevationFt: { TerrainElevation.shared.sampleElevationFt(at: $0) },
            rng: &rng)
        guard let picked else {
            // A REASON, never a silent no-op. "Nothing scored anywhere in the installed packs" is a
            // finding about the data, and on this layer it has been a real defect twice.
            notice = store.mounted.isEmpty
                ? "No landability pack is mounted."
                : "Tried \(LZDemoFlight.maxAttempts) points across \(store.mounted.count) pack(s) "
                  + "and none of them scored. Layer status: \(LZRiskController.shared.status). "
                  + "If a pack is mounted and a ruleset compiled, this means a pack was built "
                  + "without measuring anything — which is worth looking into."
            return
        }
        drop = picked
        model.deviceLocation.holdSimulation(at: picked.coord, altitudeFtMSL: picked.altitudeFtMSL)
        // The layers the demonstration is OF. Turned on here rather than left to the emergency
        // button so the map is already showing something when they get there.
        model.showLZRisk = true
        model.showLZEnergy = true
    }
}
