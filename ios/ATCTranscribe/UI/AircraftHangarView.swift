import SwiftUI

/// The pilot's hangar: every saved aircraft, each one openable for editing.
///
/// ⚠️ WHY THIS VIEW EXISTS, BECAUSE THE EDITOR ALREADY DID. `AircraftSheet` has always handled add
/// and edit alike, and `AppModel.saveAircraft` has always updated by id. What was missing was any
/// way to REACH it. The one route was the flight-plan strip's callsign menu, whose "Edit …" entry
/// appears for `selectedAircraft` alone — so editing any other aeroplane in the hangar meant
/// selecting it first, and `selectAircraft` overwrites the filed plan's callsign and aircraft type.
/// The pilot had to change their flight plan to correct a landing distance. Reported from the air
/// as "there is no way to edit an aircraft once it is saved", which was true of every aeroplane
/// except the one being flown.
///
/// Presented TWO ways and has to work in both: pushed from Settings → Aircraft, and as a sheet from
/// the flight-plan strip's "Manage aircraft…". The caller owns the NavigationStack and the Done
/// button, as `SettingsSheet.categoryPage` already does for every other settings page.
///
/// ⚠️ FILING IS DELIBERATELY NOT OFFERED HERE. Which aeroplane is flying today is a flight-plan
/// decision and belongs to the strip; a settings page that could silently re-file the plan is how a
/// pilot ends up airborne under a callsign they did not choose. The FILED chip is shown even so,
/// because editing the filed aeroplane is the one case that does reach the plan — a corrected tail
/// number follows it (see `AppModel.updateAircraft`).
struct AircraftHangarView: View {
    @EnvironmentObject var model: AppModel

    /// The profile open in the editor. A fresh `AircraftProfile()` means "add"; `AircraftSheet`
    /// tells the two apart by whether the id is already in the hangar.
    @State private var editing: AircraftProfile?

    /// At the cap `AppModel.saveAircraft` rejects a new profile outright and says nothing. That was
    /// survivable while the hangar was invisible; on a screen that lists the aeroplanes, a button
    /// that silently does nothing is worse than one that is plainly unavailable.
    private var isFull: Bool { model.aircraftProfiles.count >= AircraftStore.maxProfiles }

    var body: some View {
        let p = model.palette
        ScrollView {
            VStack(spacing: 16) {
                if model.aircraftProfiles.isEmpty {
                    emptyCard(p)
                } else {
                    Card(title: "My aircraft (\(model.aircraftProfiles.count))") {
                        VStack(spacing: 0) {
                            ForEach(model.aircraftProfiles) { a in
                                if a.id != model.aircraftProfiles.first?.id {
                                    Divider().overlay(p.hairline)
                                }
                                row(a, p)
                            }
                        }
                    }
                }
                addButton(p)
                Card(title: "What these numbers do") {
                    Text("Cruise speed and fuel burn drive the flight-plan strip's ETE, ETA and fuel. "
                         + "Glide ratio ranks the nearest airports after an engine failure. Approach "
                         + "speed and landing distance decide how much rough ground the off-field "
                         + "layer will offer you. Every one of them falls back to a deliberately "
                         + "conservative default when it is blank — safe, but not your aeroplane.")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Aircraft")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("aircraft-hangar")
        // ⚠️ `filesOnSave: false` is the whole reason this screen is safe to open mid-flight: a
        // correction made here must not re-file the plan for whichever aeroplane the pilot tapped.
        .sheet(item: $editing) { a in
            AircraftSheet(profile: a, filesOnSave: false).environmentObject(model)
        }
    }

    // MARK: rows

    /// One aeroplane. The whole row is the button — a pencil affordance on a list whose only action
    /// is "open this one" is a second thing to aim at for no added meaning.
    private func row(_ a: AircraftProfile, _ p: Palette) -> some View {
        let filed = model.selectedAircraft?.id == a.id
        let gaps = Self.gaps(a)
        return Button {
            Haptics.impact(.light)
            editing = a
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(a.callsign.isEmpty ? "No callsign" : a.callsign)
                            .font(.callout.weight(.semibold).monospaced())
                            .foregroundStyle(a.callsign.isEmpty ? p.textDim : p.text)
                        if filed {
                            Text("FILED").font(.dsLabelS.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(p.accentMuted)
                                .foregroundStyle(p.accent)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
                        }
                    }
                    Text(Self.detailLine(a)).font(.dsLabelS).foregroundStyle(p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if !gaps.isEmpty {
                        // Named in terms of what is affected, not which field is nil: "glide ratio"
                        // is a thing the pilot knows about their aeroplane, `glideRatio` is not.
                        Text("Using defaults for \(gaps.joined(separator: ", "))")
                            .font(.dsLabelS).foregroundStyle(p.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.dsLabel).foregroundStyle(p.textDim)
                    .padding(.top, 2)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("aircraft-hangar-row")
    }

    private func addButton(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.impact(.light)
                editing = AircraftProfile()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.dsLabelS)
                    Text("Add aircraft…").font(.dsHeadline)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isFull ? p.textDim : p.accent)
                .padding(.vertical, 11).padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(p.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r4))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(p.border, lineWidth: 1))
            }
            .buttonStyle(.plainHaptic)
            .disabled(isFull)
            .accessibilityIdentifier("aircraft-hangar-add")
            if isFull {
                Text("Hangar full at \(AircraftStore.maxProfiles) aircraft. Remove one to add another.")
                    .font(.dsLabelS).foregroundStyle(p.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func emptyCard(_ p: Palette) -> some View {
        Card(title: "My aircraft") {
            Text("No aircraft saved yet. Add the one you fly and its performance numbers feed the "
                 + "trip stats, the engine-out airport ranking and the off-field landing layer. You "
                 + "can start from a type and correct the numbers from your own POH.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("aircraft-hangar-empty")
        }
    }

    // MARK: summaries

    /// The numbers this profile actually carries, in the order the pilot meets them elsewhere in the
    /// app. Shows what is SET; `gaps` says what is not.
    static func detailLine(_ a: AircraftProfile) -> String {
        var bits: [String] = []
        if !a.type.isEmpty { bits.append(a.type) }
        if let k = a.cruiseKts { bits.append("\(k) kt") }
        if let g = a.burnGPH { bits.append(String(format: "%g gph", g)) }
        if let r = a.glideRatio { bits.append(String(format: "%g:1 glide", r)) }
        if a.isRotorcraft == true { bits.append("rotorcraft") }
        if let w = a.waterOps { bits.append(w == .amphibian ? "amphibian" : "floats") }
        return bits.isEmpty ? "No details yet" : bits.joined(separator: " · ")
    }

    /// What this profile still leaves to a default, named by what it affects.
    ///
    /// A blank field here is not neutral. Each one silently substitutes a conservative value, and a
    /// conservative value in an engine-out ranking is still a number the pilot did not choose — the
    /// hangar is the one place that can say so before the number matters.
    ///
    /// ⚠️ RESPECTS THE ROTORCRAFT RULES, or it would nag a helicopter pilot for two figures the app
    /// deliberately refuses to use: there is no fixed-wing landing distance for an autorotation
    /// (`AircraftSheet.save` nils it) and no impossible turn to brief.
    static func gaps(_ a: AircraftProfile) -> [String] {
        var out: [String] = []
        if a.cruiseKts == nil || a.burnGPH == nil { out.append("trip stats") }
        if a.glideRatio == nil { out.append("glide ratio") }
        let rotor = a.isRotorcraft == true
        if !rotor, a.landingOver50Ft == nil { out.append("landing distance") }
        if !rotor, a.turnbackMinimumFtAGL == nil { out.append("turn-back height") }
        return out
    }
}
