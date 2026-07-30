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
                        VStack(spacing: 10) {
                            labeled("Callsign", "e.g. N8925T", $callsign)
                            labeled("Type", "e.g. Piper Seneca", $type, autocap: .words)
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
    }

    /// Seed the fields from the profile being edited (blank for a fresh add).
    private func seed() {
        callsign = profile.callsign
        type = profile.type
        cruiseText = profile.cruiseKts.map(String.init) ?? ""
        burnText = profile.burnGPH.map { String(format: "%g", $0) } ?? ""
        glideRatioText = profile.glideRatio.map { String(format: "%g", $0) } ?? ""
        bestGlideText = profile.bestGlideKts.map(String.init) ?? ""
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
        model.saveAircraft(updated)
        dismiss()
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
