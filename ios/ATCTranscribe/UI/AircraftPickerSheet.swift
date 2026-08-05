import SwiftUI

/// Pick a type to fill the form with, grouped by manufacturer.
///
/// ⚠️ THIS FILLS A FORM. IT DOES NOT SET YOUR AEROPLANE'S PERFORMANCE. Two of the values it writes —
/// glide ratio and landing distance — move the ring of ground the app says you can reach and decide
/// which fields it will name. The published figure for a TYPE is not the figure for a TAIL NUMBER:
/// weight, propeller, STCs, fairings and rigging all move it, and book landing distances are flown
/// by test pilots on dry pavement at sea level.
///
/// So the provenance note rides at the top where it cannot be scrolled past before choosing, every
/// value lands in an editable field, and nothing here is written anywhere except into the sheet the
/// pilot is already looking at.
struct AircraftPickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (AircraftCatalog.Entry) -> Void

    @State private var query = ""

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(AircraftCatalog.provenanceNote)
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.top, 12)
                        .accessibilityIdentifier("aircraft-picker-provenance")

                    if query.isEmpty {
                        ForEach(AircraftCatalog.byManufacturer, id: \.name) { group in
                            section(group.name, group.entries, p)
                        }
                    } else {
                        let hits = AircraftCatalog.matching(query)
                        if hits.isEmpty {
                            Text("No match. Close this and type your aeroplane's numbers in "
                                 + "directly — the list is a convenience, not a requirement.")
                                .font(.dsLabelS).foregroundStyle(p.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16)
                        } else {
                            section("Matches", hits, p)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .background(p.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Manufacturer or model")
            .navigationTitle("Pick a type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("aircraft-picker")
    }

    private func section(_ title: String, _ entries: [AircraftCatalog.Entry],
                         _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.dsLabelSBold).foregroundStyle(p.textDim)
                .padding(.horizontal, 16).padding(.bottom, 4)
            ForEach(entries) { e in
                Button {
                    Haptics.impact(.light)
                    onPick(e)
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.model).font(.dsLabel).foregroundStyle(p.text)
                            Text(summary(e)).font(.dsLabelS).foregroundStyle(p.textDim)
                        }
                        Spacer(minLength: 4)
                        if e.isRotorcraft {
                            Text("rotor").font(.dsLabelS).foregroundStyle(p.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(p.accent.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: DS.Radius.r2))
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("aircraft-pick-\(e.id)")
                Divider().overlay(p.hairline).padding(.leading, 16)
            }
        }
        .padding(.bottom, 8)
    }

    /// One line of what selecting this will write. Rotorcraft say what does NOT apply rather than
    /// quietly leaving a field blank the pilot might read as "unknown".
    private func summary(_ e: AircraftCatalog.Entry) -> String {
        var bits = [String(format: "%g:1 glide", e.glideRatio),
                    "\(e.bestGlideKts) kt best glide",
                    "\(e.mtowLb) lb"]
        if let ld = e.landingOver50Ft {
            bits.append("\(Int(ld)) ft over 50")
        } else {
            bits.append("autorotation — no fixed-wing landing distance")
        }
        return bits.joined(separator: " · ")
    }
}
