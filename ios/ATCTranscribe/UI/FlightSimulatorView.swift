import SwiftUI

/// Fly the active approach on the ground, so the vertical guidance can be watched working.
///
/// A developer diagnostic, reached only through the unlocked Settings section — the same buried route as
/// the clearance test bench. It publishes a FAKE position, which is why arming is refused outright
/// whenever a real aeroplane could be involved, and why a red banner rides above every other chrome for
/// as long as it is armed.
///
/// The controls exist to make the guidance MISBEHAVE on purpose: dial in a vertical offset and the
/// deviation readout and its colour must follow it by that amount and in that direction; push the
/// cross-track past four miles and the profile must stop drawing an aircraft that is not on this
/// approach; drop the ground speed under thirty knots and the required-rate advisory must go quiet.
/// A control that only ever demonstrates the happy path is decoration.
struct FlightSimulatorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var deviceLocation: DeviceLocation

    private var p: Palette { model.palette }
    private var armed: Bool { deviceLocation.isSimulating }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let profile = model.approachProfile {
                    context(profile)
                    armSection
                    if armed {
                        transport
                        readout
                        offsets(profile)
                    }
                } else {
                    noApproach
                }
                caveat
            }
            .padding(16)
        }
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("Flight simulator")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("flight-simulator")
    }

    // MARK: sections

    private func context(_ profile: ApproachProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ACTIVE APPROACH").dsSectionHeader(p)
            Text(profile.approachName).font(.dsHeadline).foregroundStyle(p.text)
            Text(profile.hasVerticalGuidance
                 ? String(format: "%@ · glidepath %.2f°", profile.airport, profile.descentAngleDeg ?? 0)
                 : "\(profile.airport) · no published glidepath — stepdown floors only")
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
    }

    private var noApproach: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No approach is active", systemImage: "exclamationmark.triangle.fill")
                .font(.dsHeadline).foregroundStyle(p.warn)
            Text("Activate an approach first. This screen deliberately will not activate one for you — that is a change to the flight plan, not a diagnostic.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var armSection: some View {
        if armed {
            Button {
                Haptics.impact(.medium); model.disarmSimulator()
            } label: {
                Label("DISARM — return to the real receiver", systemImage: "stop.circle.fill")
                    .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(p.bad.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                    .foregroundStyle(p.bad)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sim-disarm")
        } else if let refusal = model.simulatorRefusal() {
            VStack(alignment: .leading, spacing: 4) {
                Label("Will not arm", systemImage: "hand.raised.fill")
                    .font(.dsLabelSBold).foregroundStyle(p.warn)
                Text(refusal.rawValue).font(.dsLabelS).foregroundStyle(p.textDim)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(p.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            .accessibilityIdentifier("sim-refusal")
        } else {
            Button {
                Haptics.impact(.medium); model.armSimulator()
            } label: {
                Label("ARM — publish a simulated position", systemImage: "play.circle.fill")
                    .font(.dsLabelBold).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(p.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sim-arm")
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRANSPORT").dsSectionHeader(p)
            HStack(spacing: 8) {
                Button {
                    Haptics.impact(.light); model.setSimulatorPaused(!model.simPaused)
                } label: {
                    Label(model.simPaused ? "Resume" : "Pause",
                          systemImage: model.simPaused ? "play.fill" : "pause.fill")
                        .font(.dsLabelS).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.border, lineWidth: DS.Stroke.hairline))
                        .foregroundStyle(p.text)
                }
                .buttonStyle(.plain).accessibilityIdentifier("sim-pause")
                Spacer(minLength: 0)
                ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { m in
                    Button {
                        Haptics.impact(.light); model.setSimulatorSpeed(m)
                    } label: {
                        Text("×\(Int(m))").font(.dsLabelS)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(model.simSpeedMultiplier == m ? p.accent.opacity(0.16) : p.surface,
                                        in: Capsule())
                            .overlay(Capsule().stroke(model.simSpeedMultiplier == m ? p.accent : p.border,
                                                      lineWidth: DS.Stroke.hairline))
                            .foregroundStyle(model.simSpeedMultiplier == m ? p.accent : p.text)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("sim-speed-\(Int(m))")
                }
            }
            Text("The multiplier scales FLIGHT time, never ground speed — the advisory must keep describing the aeroplane, not the clock.")
                .font(.system(size: 9)).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var readout: some View {
        if let s = deviceLocation.simulationSample {
            let pos = model.approachProfile?.position(of: s.coord, altitudeFtMSL: s.altitudeFtMSL,
                                                      threshold: thresholdCoord)
            VStack(alignment: .leading, spacing: 3) {
                Text("LIVE").dsSectionHeader(p)
                row("phase", s.phase.rawValue)
                row("distance to threshold", String(format: "%.2f NM", s.distanceToThresholdNm))
                row("altitude", "\(Int(s.altitudeFtMSL)) ft MSL")
                row("flown rate", "\(Int(s.verticalSpeedFpm)) fpm")
                if let dev = pos?.deviationFt {
                    row("deviation", String(format: "%+.0f ft %@", dev, dev >= 0 ? "high" : "low"))
                } else if pos == nil {
                    row("deviation", "not on this approach — profile refuses to place it")
                } else {
                    row("deviation", "none published — no glidepath to be off")
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            .accessibilityIdentifier("sim-readout")
        }
    }

    private func offsets(_ profile: ApproachProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FLY IT WRONG ON PURPOSE").dsSectionHeader(p)
            slider("Vertical offset", value: $model.simConfig.verticalOffsetFt, range: -600...600, step: 25,
                   format: { String(format: "%+.0f ft", $0) }, id: "sim-vertical-offset")
            slider("Cross-track offset", value: $model.simConfig.crossTrackNm, range: 0...6, step: 0.25,
                   format: { String(format: "%.2f NM%@", $0,
                                    $0 > ApproachProfile.maxCrossTrackNm ? "  (past the limit)" : "") },
                   id: "sim-cross-track")
            slider("Ground speed", value: $model.simConfig.groundSpeedKt, range: 20...250, step: 5,
                   format: { String(format: "%.0f kt%@", $0, $0 < 30 ? "  (under the advisory gate)" : "") },
                   id: "sim-ground-speed")
            HStack(spacing: 8) {
                Button {
                    Haptics.impact(.light)
                    model.deviceLocation.placeSimulation(atNm: ApproachSimulator.defaultStartNm(profile: profile))
                } label: { chip("Restart outside the FAF") }
                    .buttonStyle(.plain).accessibilityIdentifier("sim-restart")
                Button {
                    Haptics.impact(.light); model.deviceLocation.flySimulatedMissed()
                } label: { chip("Fly the missed") }
                    .buttonStyle(.plain).accessibilityIdentifier("sim-missed")
            }
        }
        .onChange(of: model.simConfig) { _, _ in model.applySimulatorConfig() }
    }

    private var caveat: some View {
        Text("Nothing here is persisted. Backgrounding the app, or anything that stops the GPS session, disarms the simulation — a fake position must never come back on its own.")
            .font(.system(size: 9)).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: bits

    private var thresholdCoord: Coord? {
        model.activeApproach.flatMap {
            AppModel.landingThreshold(airport: $0.airport, runway: $0.runway)?.coord
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.dsLabelS).foregroundStyle(p.textDim)
            Spacer(minLength: 8)
            Text(value).font(.dsDataMono).foregroundStyle(p.text)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.dsLabelS)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().stroke(p.border, lineWidth: DS.Stroke.hairline))
            .foregroundStyle(p.text)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, format: @escaping (Double) -> String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.dsLabelS).foregroundStyle(p.textDim)
                Spacer(minLength: 8)
                Text(format(value.wrappedValue)).font(.dsDataMono).foregroundStyle(p.text)
            }
            Slider(value: value, in: range, step: step).tint(p.accent)
                .accessibilityIdentifier(id)
        }
    }
}

/// The banner that makes a simulated position impossible to mistake for a real one.
///
/// Non-dismissible and in the alarm colour, because the failure mode it guards against is a pilot
/// glancing at an ownship symbol that is not where the aeroplane is. It carries its own disarm so the
/// way out is always one tap from wherever the position is being displayed.
struct SimulatedGPSBanner: View {
    @ObservedObject var deviceLocation: DeviceLocation
    let palette: Palette
    var onDisarm: () -> Void

    var body: some View {
        if deviceLocation.isSimulating {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 12, weight: .bold))
                Text("SIMULATED GPS — this position is not real")
                    .font(.dsLabelSBold).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Button { Haptics.impact(.medium); onDisarm() } label: {
                    Text("DISARM").font(.dsLabelSBold)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(palette.bad.opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sim-banner-disarm")
            }
            .foregroundStyle(palette.bad)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.bad.opacity(0.16))
            .overlay(alignment: .bottom) { Rectangle().fill(palette.bad).frame(height: 1) }
            .accessibilityIdentifier("sim-gps-banner")
        }
    }
}
