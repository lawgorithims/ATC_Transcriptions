import SwiftUI

/// Picks the coded approach (when a plate maps to more than one) and the ENTRY — which published
/// transition to join at, or VECTORS — then activates it.
///
/// Two steps rather than one long list because they are different questions: *which* approach, then
/// *how you're getting on it*. ~68% of approaches publish two or more transitions, so the entry choice
/// is the common case; the approach choice only appears when the plate is genuinely ambiguous (an
/// "ILS OR LOC RWY 04R" plate covers both `I04R` and `L04R`).
struct ActivateApproachSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The coded approaches this sheet may activate, best match first.
    let candidates: [CIFPProcedure]
    /// Shown at the top for context (the plate title, or the airport).
    let contextLabel: String

    @State private var chosen: CIFPProcedure?

    private var approach: CIFPProcedure? { chosen ?? (candidates.count == 1 ? candidates.first : nil) }

    var body: some View {
        let p = model.palette
        NavigationStack {
            List {
                if candidates.count > 1 {
                    Section("Approach") {
                        ForEach(candidates) { c in
                            Button { chosen = c } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name.isEmpty ? c.ident : c.name)
                                            .font(.callout).foregroundStyle(p.text)
                                        Text(c.ident).font(.caption2.monospaced()).foregroundStyle(p.textDim)
                                    }
                                    Spacer(minLength: 4)
                                    if approach?.id == c.id {
                                        Image(systemName: "checkmark").foregroundStyle(p.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plainHaptic)
                            .accessibilityIdentifier("activate-approach-\(c.ident)")
                        }
                    }
                }
                if let a = approach {
                    Section {
                        ForEach(entries(for: a)) { entry in
                            Button {
                                model.activateApproach(a, entry: entry)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry == .vectors
                                          ? "arrow.triangle.turn.up.right.diamond" : "point.topleft.down.to.point.bottomright.curvepath")
                                        .foregroundStyle(p.accent).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry == .vectors ? "Vectors to final" : "Direct \(entry.label)")
                                            .font(.callout).foregroundStyle(p.text)
                                        Text(entry == .vectors
                                             ? "ATC will vector you onto the final approach course — the route is left as filed."
                                             : "Join the approach at \(entry.label), then fly the published legs.")
                                            .font(.dsLabelS).foregroundStyle(p.textDim)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plainHaptic)
                            .accessibilityIdentifier("activate-entry-\(entry.label)")
                        }
                    } header: {
                        Text("Join at")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Activating loads \(a.name.isEmpty ? a.ident : a.name) into the flight plan and arms the missed approach.")
                                .font(.dsLabelS)
                            // Provenance where it matters most: this sheet is about to change what the
                            // aircraft flies, so the cycle behind those legs is shown at the decision.
                            HStack(spacing: 5) {
                                DataCurrencyBadge(sources: [CIFP.provenance], compact: false)
                                    .environmentObject(model)
                                Text(CIFP.provenance.summary).font(.dsLabelS).foregroundStyle(p.textDim)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activate approach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(contextLabel).font(.dsLabel).foregroundStyle(p.textDim).lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("activate-cancel")
                }
            }
        }
        .accessibilityIdentifier("activate-approach-sheet")
    }

    /// The published transitions for this approach plus the synthesized VECTORS entry.
    private func entries(for a: CIFPProcedure) -> [ApproachActivation.Entry] {
        assert(!a.ident.isEmpty, "an approach must have an ident to enumerate entries for")
        let t = CIFP.transitions(airport: a.airport, ident: a.ident)
        assert(t.count <= 64, "unexpectedly many transitions for one approach")
        return ApproachActivation.entries(transitions: t)
    }
}
