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
                                .font(.caption2).foregroundStyle(p.textDim)
                        }
                    }
                    if isExisting {
                        Button {
                            Haptics.impact(.light)
                            model.deleteAircraft(profile)
                            dismiss()
                        } label: {
                            Text("Remove from my aircraft").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(p.surfaceAlt).foregroundStyle(p.bad)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("aircraft-delete")
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
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .onAppear(perform: seed)
    }

    /// Seed the fields from the profile being edited (blank for a fresh add).
    private func seed() {
        callsign = profile.callsign
        type = profile.type
        cruiseText = profile.cruiseKts.map(String.init) ?? ""
        burnText = profile.burnGPH.map { String(format: "%g", $0) } ?? ""
    }

    /// Persist through the model (add-or-update by id) and fly the aircraft.
    private func save() {
        var updated = profile
        updated.callsign = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        updated.type = type.trimmingCharacters(in: .whitespaces)
        updated.cruiseKts = Int(cruiseText.filter(\.isNumber))
        updated.burnGPH = Double(burnText.replacingOccurrences(of: ",", with: "."))
        model.saveAircraft(updated)
        dismiss()
    }

    // MARK: building blocks (match the strip / settings styling)

    private func labeled(_ label: String, _ placeholder: String, _ text: Binding<String>,
                         autocap: TextInputAutocapitalization = .characters,
                         keyboard: UIKeyboardType = .default) -> some View {
        let p = model.palette
        return HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(p.textDim)
                .frame(width: 84, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .textInputAutocapitalization(autocap)
                .keyboardType(keyboard)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
                .frame(maxWidth: .infinity)
        }
    }
}
