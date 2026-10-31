import SwiftUI

/// Add or edit one saved aircraft (opened from the flight-plan strip's aircraft box). Callsign +
/// type name the plane; cruise speed + fuel burn feed the strip's ETE / ETA / FUEL trip stats.
/// Saving also selects the aircraft — its callsign/type land on the filed plan, which is what the
/// EFB ownship gate and corrector grounding read.
struct AircraftSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: AircraftProfile

    @State private var callsign = ""
    @State private var type = ""
    @State private var cruiseText = ""
    @State private var burnText = ""
    @State private var glideRatioText = ""
    @State private var bestGlideText = ""
    @State private var vRefText = ""
    @State private var landingOver50Text = ""
    @State private var mtowText = ""
    @State private var spanText = ""
    @State private var isRotorcraft = false
    @State private var waterOps: AircraftProfile.WaterOps?
    @State private var turnbackText = ""
    @State private var turnbackDAText = ""
    @State private var turnbackPractised = false
    @State private var turnbackDate = Date()
    @State private var showPicker = false
    /// Which catalogue entry filled the form, so the sheet can say where the numbers came from.
    ///
    /// DELIBERATELY NOT CLEARED ON EDIT. Editing one field does not change the provenance of the
    /// others — a pilot who corrects the landing distance still has a catalogue glide ratio — and a
    /// warning that disappears after the first keystroke would be least visible exactly when the
    /// form is most mixed. It stays until the sheet is closed.
    @State private var filledFrom: String?

    private var hasInput: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty
            || !type.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var isExisting: Bool { model.aircraftProfiles.contains { $0.id == profile.id } }

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card(title: "Aircraft") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled("Callsign", "e.g. N8925T", $callsign)
                            labeled("Type", "e.g. Piper Seneca", $type, autocap: .words)
                            Button {
                                Haptics.impact(.light); showPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "list.bullet").font(.dsLabelS)
                                    Text("Fill from a type…").font(.dsLabel)
                                    Spacer(minLength: 0)
                                }.foregroundStyle(p.accent)
                            }
                            .buttonStyle(.plainHaptic)
                            .accessibilityIdentifier("aircraft-fill-from-type")
                            if let filledFrom {
                                Text("Filled from \(filledFrom). "
                                     + AircraftCatalog.provenanceNote)
                                    .font(.dsLabelS).foregroundStyle(p.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("aircraft-filled-note")
                            }
                        }
                    }
                    Card(title: "Airframe") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled("Max gross weight", "lb — e.g. 2450", $mtowText,
                                    keyboard: .numberPad)
                            labeled(isRotorcraft ? "Rotor diameter" : "Wingspan",
                                    "ft — e.g. 36", $spanText, keyboard: .decimalPad)
                            Toggle(isOn: $isRotorcraft) {
                                Text("Helicopter or gyroplane").font(.dsLabel)
                                    .foregroundStyle(p.text)
                            }
                            .accessibilityIdentifier("aircraft-is-rotorcraft")
                            Text(isRotorcraft
                                 ? "Autorotation descends far more steeply than any aeroplane but "
                                   + "touches down in a fraction of the ground, so the landing "
                                   + "distance below is replaced with a rotorcraft minimum of about "
                                   + "\(Int(LZSiteFinder.rotorcraftBookFt)) ft — not by your POH "
                                   + "numbers, which this app has no rotorcraft table for. You "
                                   + "judge the space; the layer shows surface, slope and room."
                                 : "Recorded for reference. Weight and span do not feed the "
                                   + "landability scoring today.")
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)

                            // Water operations. THREE states, because the nearest-airport list has
                            // to give three different answers: a landplane must not be sent to a
                            // lake, a straight floatplane must not be sent to asphalt, and only an
                            // amphibian may be offered both.
                            Picker(selection: $waterOps) {
                                Text("Landplane").tag(AircraftProfile.WaterOps?.none)
                                ForEach(AircraftProfile.WaterOps.allCases) { w in
                                    Text(w.title).tag(AircraftProfile.WaterOps?.some(w))
                                }
                            } label: {
                                Text("Lands on").font(.dsLabel).foregroundStyle(p.text)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("aircraft-water-ops")
                            Text(waterOpsNote)
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Card(title: "Performance") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled("Cruise", "kts — e.g. 165", $cruiseText, keyboard: .numberPad)
                            labeled("Fuel burn", "gph — e.g. 16.5", $burnText, keyboard: .decimalPad)
                            Text("Planning numbers for the flight-plan strip's ETE, ETA, and fuel. Leave blank to show “–”.")
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                    }
                    Card(title: "Glide") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled("Glide ratio", "L/D — e.g. 9 (C172)", $glideRatioText, keyboard: .decimalPad)
                            labeled("Best glide", "kts — e.g. 68", $bestGlideText, keyboard: .numberPad)
                            Text("POH best-glide numbers for the NRST engine-out ranking. Blank uses a conservative \(String(format: "%g", NearestAirports.defaultGlideRatio)):1 default.")
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                    }
                    turnbackCard(p)
                    Card(title: isRotorcraft ? "Landing (rotorcraft minimum used instead)" : "Landing") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled("Approach speed", "kts Vref — e.g. 62", $vRefText, keyboard: .numberPad)
                            labeled("Landing distance", "ft over 50 ft — e.g. 1250", $landingOver50Text,
                                    keyboard: .numberPad)
                            // Says WHY it wants the over-50 number rather than ground roll: an
                            // unprepared field has a fence or trees at the approach end far more
                            // often than a clear threshold, and ground roll omits exactly the part
                            // the obstruction governs.
                            Text("Used by the off-field landability layer to judge how much rough or "
                                 + "soft ground you can actually use. Give the POH total over a 50 ft "
                                 + "obstacle, not the ground roll — an unprepared field usually has "
                                 + "something at the approach end. Blank uses a conservative default.")
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                    }
                    if isExisting {
                        Button {
                            Haptics.impact(.light)
                            model.deleteAircraft(profile)
                            dismiss()
                        } label: {
                            Text("Remove from my aircraft").font(.dsHeadline)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(p.surfaceAlt).foregroundStyle(p.bad)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r4))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(p.border, lineWidth: 1))
                        }
                        .buttonStyle(.plainHaptic).accessibilityIdentifier("aircraft-delete")
                    }
                }
                .padding(16)
            }
            .background(p.bg)
            .navigationTitle(isExisting ? "Edit aircraft" : "Add aircraft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!hasInput)
                        .accessibilityIdentifier("aircraft-save")
                }
            }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme.colorScheme)
        .onAppear(perform: seed)
        .sheet(isPresented: $showPicker) {
            AircraftPickerSheet { e in fill(from: e) }.environmentObject(model)
        }
    }

    /// Copy a catalogue entry into the FORM. Nothing is saved until the pilot taps Save, and every
    /// value stays editable — see AircraftCatalog for why that separation is load-bearing.
    private func fill(from e: AircraftCatalog.Entry) {
        if type.trimmingCharacters(in: .whitespaces).isEmpty { type = e.displayName }
        glideRatioText = String(format: "%g", e.glideRatio)
        bestGlideText = String(e.bestGlideKts)
        vRefText = String(e.vRefKts)
        landingOver50Text = e.landingOver50Ft.map { String(format: "%g", $0) } ?? ""
        cruiseText = String(e.cruiseKts)
        burnText = String(format: "%g", e.burnGPH)
        mtowText = String(e.mtowLb)
        spanText = String(format: "%g", e.spanFt)
        isRotorcraft = e.isRotorcraft
        filledFrom = e.displayName
    }

    /// Seed the fields from the profile being edited (blank for a fresh add).
    private func seed() {
        callsign = profile.callsign
        type = profile.type
        cruiseText = profile.cruiseKts.map(String.init) ?? ""
        burnText = profile.burnGPH.map { String(format: "%g", $0) } ?? ""
        glideRatioText = profile.glideRatio.map { String(format: "%g", $0) } ?? ""
        bestGlideText = profile.bestGlideKts.map(String.init) ?? ""
        vRefText = profile.vRefKts.map(String.init) ?? ""
        landingOver50Text = profile.landingOver50Ft.map { String(format: "%g", $0) } ?? ""
        mtowText = profile.mtowLb.map(String.init) ?? ""
        spanText = profile.spanFt.map { String(format: "%g", $0) } ?? ""
        isRotorcraft = profile.isRotorcraft ?? false
        waterOps = profile.waterOps
        turnbackText = profile.turnbackMinimumFtAGL.map(String.init) ?? ""
        turnbackDAText = profile.turnbackSetAtDensityAltitudeFt.map(String.init) ?? ""
        turnbackPractised = profile.turnbackSetOn != nil
        turnbackDate = profile.turnbackSetOn ?? Date()
    }

    /// Persist through the model (add-or-update by id) and fly the aircraft.
    private func save() {
        var updated = profile
        updated.callsign = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        updated.type = type.trimmingCharacters(in: .whitespaces)
        updated.cruiseKts = Int(cruiseText.filter(\.isNumber))
        updated.burnGPH = Double(burnText.replacingOccurrences(of: ",", with: "."))
        // Clamp to the plausible band rather than trusting a typo: a fat-fingered 90:1 would inflate
        // the NRST glide ring far past the airplane; 0/garbage falls back to nil (= the safe default).
        let ratio = Double(glideRatioText.replacingOccurrences(of: ",", with: "."))
        updated.glideRatio = ratio.flatMap { $0 >= 3 && $0 <= 60 ? $0 : nil }
        updated.bestGlideKts = Int(bestGlideText.filter(\.isNumber)).flatMap { $0 >= 40 && $0 <= 250 ? $0 : nil }
        // Same clamp-or-nil rule as the glide fields: an implausible entry falls back to the
        // conservative default rather than being believed. A landing distance typed in metres is
        // the likely slip, and it would make marginal ground look more usable than it is.
        updated.vRefKts = Int(vRefText.filter(\.isNumber)).flatMap { $0 >= 30 && $0 <= 200 ? $0 : nil }
        let over50 = Double(landingOver50Text.replacingOccurrences(of: ",", with: "."))
        updated.landingOver50Ft = over50.flatMap { $0 >= 300 && $0 <= 12_000 ? $0 : nil }
        updated.mtowLb = Int(mtowText.filter(\.isNumber)).flatMap { $0 >= 200 && $0 <= 1_500_000 ? $0 : nil }
        updated.spanFt = Double(spanText.replacingOccurrences(of: ",", with: "."))
            .flatMap { $0 >= 5 && $0 <= 300 ? $0 : nil }
        updated.isRotorcraft = isRotorcraft ? true : nil
        updated.waterOps = waterOps
        // The pilot's own turn-back number. Out of band → nil (= "land ahead"), never a guess: below
        // 300 ft no light aeroplane turns back; above 3,000 ft it is no longer a takeoff decision.
        updated.turnbackMinimumFtAGL = isRotorcraft ? nil
            : Int(turnbackText.filter(\.isNumber)).flatMap { $0 >= 300 && $0 <= 3_000 ? $0 : nil }
        let da = Int(turnbackDAText.filter { $0.isNumber || $0 == "-" })
        updated.turnbackSetAtDensityAltitudeFt = updated.turnbackMinimumFtAGL == nil ? nil
            : da.flatMap { $0 >= -2_000 && $0 <= 15_000 ? $0 : nil }
        updated.turnbackSetOn = (updated.turnbackMinimumFtAGL != nil && turnbackPractised) ? turnbackDate : nil
        // ⚠️ A ROTORCRAFT CARRIES NO FIXED-WING LANDING DISTANCE. Autorotation touches down in a
        // fraction of the ground an aeroplane needs, so keeping a book over-50-ft figure here would
        // make the landability layer demand a runway's worth of open ground from a helicopter.
        if isRotorcraft { updated.landingOver50Ft = nil }
        model.saveAircraft(updated)
        dismiss()
    }

    /// "Engine failure after takeoff": the pilot's own turn-back number, never one of ours.
    @ViewBuilder private func turnbackCard(_ p: Palette) -> some View {
        if isRotorcraft {
            Card(title: "Engine failure after takeoff") {
                Text("Autorotation, not a turn-back: there is no impossible turn to brief. The flight "
                     + "briefing shows the departure field and its density altitude instead.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Card(title: "Engine failure after takeoff") {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("Turn back above", "ft above the runway — yours", $turnbackText, keyboard: .numberPad)
                        .accessibilityIdentifier("aircraft-turnback")
                    labeled("Set at DA", "density altitude, ft — e.g. 3000", $turnbackDAText,
                            keyboard: .numbersAndPunctuation)
                        .accessibilityIdentifier("aircraft-turnback-da")
                    Toggle(isOn: $turnbackPractised) {
                        Text("Practised with an instructor").font(.dsLabel).foregroundStyle(p.textDim)
                    }
                    .tint(p.accent)
                    .accessibilityIdentifier("aircraft-turnback-practised")
                    if turnbackPractised {
                        DatePicker("Last practised", selection: $turnbackDate, in: ...Date(), displayedComponents: .date)
                            .font(.dsLabel).foregroundStyle(p.textDim)
                    }
                    Text("The lowest height at which YOU will turn back to the runway, found by practising "
                         + "it at a safe altitude with an instructor in this aircraft. Obelisk never "
                         + "calculates or suggests it. Below it — and whenever it is blank — the briefing "
                         + "says land ahead. A number set at one density altitude is not valid at a higher one.")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What changes when the pilot picks a water configuration. Says what the app will DO, not
    /// what the aircraft is — the nearest-airport list is the only thing that behaves differently.
    private var waterOpsNote: String {
        switch waterOps {
        case .none:
            return "Nearest airports will offer runways only. Seaplane bases stay hidden."
        case .amphibian:
            return "Nearest airports will offer both runways and water landing areas — 561 seaplane "
                 + "bases ship with the app, and 77 ordinary airports have a water lane beside the "
                 + "asphalt."
        case .floatOnly:
            return "Nearest airports will offer water only. Paved and turf runways are excluded, "
                 + "including at fields that have both."
        }
    }

    // MARK: building blocks (match the strip / settings styling)

    private func labeled(_ label: String, _ placeholder: String, _ text: Binding<String>,
                         autocap: TextInputAutocapitalization = .characters,
                         keyboard: UIKeyboardType = .default) -> some View {
        let p = model.palette
        return HStack(spacing: 10) {
            Text(label).font(.dsLabel).foregroundStyle(p.textDim)
                .frame(width: 84, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .textInputAutocapitalization(autocap)
                .keyboardType(keyboard)
                .font(.dsLabel)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r2).stroke(p.border, lineWidth: 1))
                .frame(maxWidth: .infinity)
        }
    }
}
