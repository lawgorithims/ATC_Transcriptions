import SwiftUI

/// Electronic Flight Bag editor — file or edit a ForeFlight-style flight plan. The pilot can paste
/// a ForeFlight route string (parsed into departure / destination / route) or fill the fields
/// manually. Saving commits the plan to `AppModel.flightPlan`, which persists it and packs its
/// context block into the on-device correction layer (both LLM backends). A plan over a week old is
/// flagged stale here and on the briefcase so it gets refiled before the next flight.
struct FlightBagSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    // Working copy edited in the sheet; committed to `model.flightPlan` on Save.
    @State private var aircraftType = ""
    @State private var callsign = ""
    @State private var departure = ""
    @State private var destination = ""
    @State private var alternate = ""
    @State private var routeText = ""
    @State private var paste = ""
    // Garmin .fpl of the SAVED plan for the ShareLink; regenerated whenever the saved plan changes
    // (the share reflects the last-saved plan, not unsaved edits in the fields above).
    @State private var fplURL: URL?

    private var hasInput: Bool {
        ![aircraftType, callsign, departure, destination, alternate, routeText]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let fp = model.flightPlan, fp.isStale { staleBanner(p, days: fp.ageDays) }

                    Card(title: "Paste ForeFlight route") {
                        VStack(alignment: .leading, spacing: 10) {
                            field("e.g. KDFW DCT BLECO Q105 LFK KAUS", text: $paste, multiline: true)
                            Button { applyPaste() } label: {
                                Text("Parse route").font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(canParse ? p.accent : p.surfaceAlt)
                                    .foregroundStyle(canParse ? p.bg : p.textDim)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain).disabled(!canParse)
                            .accessibilityIdentifier("flight-bag-parse")
                            Text("Paste a route copied from ForeFlight (or type one). The first and last airports become departure and destination; the tokens between become the route. You can fix anything below.")
                                .font(.caption2).foregroundStyle(p.textDim)
                        }
                    }

                    Card(title: "Flight plan") {
                        VStack(spacing: 10) {
                            labeled("Aircraft type", "e.g. Cessna 172", $aircraftType, autocap: .words)
                            labeled("Callsign", "e.g. N345AB", $callsign)
                            labeled("Departure", "e.g. KDFW", $departure)
                            labeled("Destination", "e.g. KAUS", $destination)
                            labeled("Alternate", "e.g. KSAT", $alternate)
                            labeled("Route", "waypoints & airways", $routeText)
                        }
                    }

                    if model.foreflightEnabled { foreflightCard(p) }

                    Card(title: "Used by") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Saved plans are packed into the on-device AI context fixer so it can lock onto your own callsign, airports, and route. The plan stays on this device.")
                                .font(.caption2).foregroundStyle(p.textDim)
                            if let fp = model.flightPlan {
                                Rectangle().fill(p.border).frame(height: 1)
                                KV("Filed", fp.isStale ? "\(fp.ageDays) days ago — update recommended" : "\(fp.ageDays) day(s) ago")
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button { clearPlan() } label: {
                            Text("Clear").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(p.surfaceAlt).foregroundStyle(p.bad)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain).disabled(model.flightPlan == nil)
                        .opacity(model.flightPlan == nil ? 0.5 : 1)

                        Button { savePlan() } label: {
                            Text("Save flight plan").font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(hasInput ? p.accent : p.surfaceAlt)
                                .foregroundStyle(hasInput ? p.bg : p.textDim)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).disabled(!hasInput)
                        .accessibilityIdentifier("flight-bag-save")
                    }
                }
                .padding(16)
            }
            .background(p.bg)
            .navigationTitle("Flight bag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { model.showRouteMap = true; dismiss() } label: {
                        Label("Map", systemImage: "map")
                    }
                    .accessibilityIdentifier("flight-bag-map")
                    .accessibilityLabel("View route on map")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .onAppear(perform: loadFromModel)
        .task(id: model.flightPlan) { fplURL = await model.writeFPLFile() }   // keep the .fpl share fresh
    }

    /// ForeFlight hand-off card: one-tap send of the SAVED plan via the offline URL scheme, plus a
    /// Garmin .fpl share ("Copy to ForeFlight") as the file-based fallback. The send button needs
    /// ForeFlight installed; the .fpl share works with any app that accepts flight-plan files.
    private func foreflightCard(_ p: Palette) -> some View {
        Card(title: "ForeFlight") {
            VStack(alignment: .leading, spacing: 10) {
                Button { model.openInForeFlight() } label: {
                    Label("Send to ForeFlight", systemImage: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(canSendToForeFlight ? p.accent : p.surfaceAlt)
                        .foregroundStyle(canSendToForeFlight ? p.bg : p.textDim)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(!canSendToForeFlight)
                .accessibilityIdentifier("flight-bag-foreflight")
                if let fplURL {
                    ShareLink(item: fplURL) {
                        Label("Share .fpl file", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(p.surfaceAlt).foregroundStyle(p.text)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flight-bag-share-fpl")
                }
                Text("Loads the saved route onto ForeFlight's map — works offline (no cell or internet needed). Loaded departures and arrivals are sent as their individual fixes; approaches are not sent (load those in ForeFlight's own procedure advisor). The .fpl file can be shared to ForeFlight or any EFB that imports Garmin flight plans.")
                    .font(.caption2).foregroundStyle(p.textDim)
            }
        }
    }

    /// The saved plan must exist and ForeFlight must be installed for the one-tap send.
    private var canSendToForeFlight: Bool { model.flightPlan != nil && model.foreflightInstalled }

    private var canParse: Bool { !paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: actions

    /// Seed the editor fields from the saved plan (if any) when the sheet opens.
    private func loadFromModel() {
        guard let fp = model.flightPlan else { return }
        aircraftType = fp.aircraftType
        callsign = fp.callsign
        departure = fp.departure
        destination = fp.destination
        alternate = fp.alternate
        routeText = fp.routeText
    }

    /// Parse the pasted ForeFlight route into the departure / destination / route fields.
    private func applyPaste() {
        let parsed = FlightPlan.parseRoute(paste)
        if let dep = parsed.departure { departure = dep }
        if let dest = parsed.destination { destination = dest }
        routeText = parsed.route.joined(separator: " ")
        paste = ""
    }

    /// Commit the editor fields to the model (trimmed/uppercased where it helps the LLM), which
    /// persists and pushes the context block into the live session. Stamps `savedAt = now`.
    private func savePlan() {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let route = routeText.uppercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var plan = FlightPlan()
        plan.aircraftType = clean(aircraftType)
        plan.callsign = clean(callsign).uppercased()
        plan.departure = clean(departure).uppercased()
        plan.destination = clean(destination).uppercased()
        plan.alternate = clean(alternate).uppercased()
        plan.route = route
        plan.savedAt = Date()
        model.flightPlan = plan.isEmpty ? nil : plan
        // Convenience: prefill the live-feed airport context from the departure when it's blank.
        if model.airport.isEmpty, !plan.departure.isEmpty { model.airport = plan.departure }
        dismiss()
    }

    private func clearPlan() {
        model.flightPlan = nil
        aircraftType = ""; callsign = ""; departure = ""; destination = ""; alternate = ""; routeText = ""
    }

    // MARK: building blocks (match SettingsSheet styling)

    private func staleBanner(_ p: Palette, days: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.warn)
            Text("This flight plan was filed \(days) days ago. Update it before your next flight.")
                .font(.caption).foregroundStyle(p.text)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(p.warn.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.warn.opacity(0.5), lineWidth: 1))
    }

    private func labeled(_ label: String, _ placeholder: String, _ text: Binding<String>,
                         autocap: TextInputAutocapitalization = .characters) -> some View {
        let p = model.palette
        return HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(p.textDim)
                .frame(width: 96, alignment: .leading)
            field(placeholder, text: text, autocap: autocap)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>,
                       multiline: Bool = false, autocap: TextInputAutocapitalization = .characters) -> some View {
        let p = model.palette
        return TextField(placeholder, text: text, axis: multiline ? .vertical : .horizontal)
            .textFieldStyle(.plain).autocorrectionDisabled()
            .textInputAutocapitalization(autocap)
            .font(.caption)
            .lineLimit(multiline ? 2...4 : 1...1)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
            .frame(maxWidth: .infinity)
    }
}
