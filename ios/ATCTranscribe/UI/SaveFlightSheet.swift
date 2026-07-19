import SwiftUI

/// Presented (via `.sheet(item: $model.pendingLoggedFlight)`) the moment a recording stops: review the trip,
/// tag the aircraft, add notes, then save it to the logbook — or discard it.
struct SaveFlightSheet: View {
    @EnvironmentObject var model: AppModel
    let flight: LoggedFlight
    @State private var callsign: String
    @State private var type: String
    @State private var notes: String

    init(flight: LoggedFlight) {
        self.flight = flight
        _callsign = State(initialValue: flight.aircraftCallsign ?? "")
        _type = State(initialValue: flight.aircraftType ?? "")
        _notes = State(initialValue: flight.notes)
    }

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Trip") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(flight.routeSummary).font(.headline).foregroundStyle(p.text)
                            KV("Duration", flight.durationText)
                            KV("Distance", flight.distanceText)
                            KV("Max speed", flight.maxSpeedText)
                            KV("Avg speed", flight.avgSpeedText)
                            KV("Max altitude", flight.maxAltText)
                            KV("Stops", "\(flight.stops.count)")
                        }
                    }
                    Card(title: "Aircraft") {
                        Menu {
                            Button("Not recorded") { callsign = ""; type = "" }
                            ForEach(model.aircraftProfiles) { a in
                                Button(a.displayLine) { callsign = a.callsign; type = a.type }
                            }
                        } label: {
                            HStack {
                                Text(aircraftLabel).foregroundStyle(p.text)
                                Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(p.textDim)
                            }
                        }
                        .accessibilityIdentifier("save-flight-aircraft")
                    }
                    Card(title: "Notes") {
                        TextEditor(text: $notes).frame(minHeight: 90).scrollContentBackground(.hidden)
                            .foregroundStyle(p.text)
                    }
                }
                .padding(16)
            }
            .background(p.bg)
            .navigationTitle("Save flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { discard() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.accessibilityIdentifier("logbook-save")
                }
            }
        }
    }

    private var aircraftLabel: String {
        let parts = [callsign, type].filter { !$0.isEmpty }
        return parts.isEmpty ? "Not recorded" : parts.joined(separator: " · ")
    }

    private func save() {
        var f = flight
        f.aircraftCallsign = callsign.isEmpty ? nil : callsign
        f.aircraftType = type.isEmpty ? nil : type
        f.notes = notes
        model.logbook.add(f)
        model.flightRecorder.clearPendingSave()
        model.pendingLoggedFlight = nil
        Haptics.impact(.light)
    }
    private func discard() {
        model.flightRecorder.clearPendingSave()
        model.pendingLoggedFlight = nil
    }
}
