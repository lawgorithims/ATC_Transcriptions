import SwiftUI

/// The rehearsal: fly the plan, look at where it ends up, and only then decide.
///
/// WHY A REHEARSAL AND NOT A LIVE "GO THERE" BUTTON. Selecting a patch of unsurveyed ground and
/// having the aeroplane's guidance immediately point at it is one tap away from a commitment nobody
/// examined. Flying it first answers the question that actually matters — does this close from where
/// I am, with this wind, at this height — and it answers it before anything on the map changes.
///
/// The numbers here are deliberately plain. A profile drawn to a tenth of a mile is the most
/// survey-like thing this feature produces, so the unknowns travel with it and the wording never
/// borrows a published procedure's vocabulary: a key position, not a final approach fix.
struct LZGlidePlanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let plan: LZGlidePlan
    let rank: Int

    var body: some View {
        let p = model.palette
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headline(p)
                    if !plan.warnings.isEmpty { warnings(p) }
                    profile(p)
                    if let commit = plan.commit { commitCard(commit, p) } else { noAlternatives(p) }
                    unknowns(p)
                    armRow(p)
                }
                .padding(16)
            }
            .background(p.bg)
            .navigationTitle("Rehearsal — area \(rank)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("glideplan-close")
                }
            }
        }
    }

    // MARK: - headline

    private func headline(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "Land %03.0f°", plan.finalHeadingDeg))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(p.text)
                Spacer(minLength: 4)
                marginChip(p)
            }
            Text(windLine).font(.dsLabelS).foregroundStyle(p.textDim)
            Text(String(format: "%.1f NM to fly, from %.0f ft",
                        plan.totalDistanceNm, plan.startAltitudeFtMSL))
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
        .padding(12)
        .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("glideplan-headline")
    }

    private var windLine: String {
        if plan.headwindKts > 1 {
            return String(format: "About %.0f kt on the nose down the run.", plan.headwindKts)
        }
        if plan.headwindKts < -1 {
            return String(format: "About %.0f kt on the tail — this run lies no better way.",
                          -plan.headwindKts)
        }
        return "No useful headwind either way down this run."
    }

    /// The one number that says whether the plan closes. Colour-coded, because "arrives 300 ft
    /// short" and "arrives 300 ft high" are opposite problems and read identically as text.
    private func marginChip(_ p: Palette) -> some View {
        let closes = plan.arrivalMarginFt >= 0
        let text = closes
            ? "\(Int(plan.arrivalMarginFt.rounded())) ft in hand"
            : "\(Int((-plan.arrivalMarginFt).rounded())) ft short"
        return Text(text)
            .font(.dsLabelSBold).foregroundStyle(closes ? p.good : p.bad)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((closes ? p.good : p.bad).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: DS.Radius.r2))
            .accessibilityIdentifier("glideplan-margin")
    }

    // MARK: - warnings

    private func warnings(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.dsLabelS).foregroundStyle(p.warn)
                    Text(w).font(.dsLabelS).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("glideplan-warnings")
    }

    // MARK: - the profile

    private func profile(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THE PLAN").font(.dsLabelSBold).foregroundStyle(p.textDim)
                .padding(.bottom, 6)
            ForEach(Array(plan.legs.enumerated()), id: \.offset) { i, leg in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(leg.kind.title).font(.dsLabel).foregroundStyle(p.text)
                        .frame(width: 92, alignment: .leading)
                    Text(leg.kind == .energyDump
                         ? "overhead"
                         : String(format: "%03.0f°  %.1f NM", leg.headingDeg, leg.distanceNm))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(p.textDim)
                    Spacer(minLength: 4)
                    Text(String(format: "%.0f → %.0f ft", leg.entryAltFtMSL, leg.exitAltFtMSL))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(p.text)
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("glideplan-leg-\(i + 1)")
                if i < plan.legs.count - 1 { Divider().overlay(p.hairline) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
    }

    // MARK: - the commit point

    private func commitCard(_ c: LZGlidePlan.CommitPoint, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LAST CHANCE TO CHANGE YOUR MIND")
                .font(.dsLabelSBold).foregroundStyle(p.textDim)
            Text(String(format: "%.1f NM along the run-in, at about %.0f ft.",
                        c.alongTrackNm, c.altitudeFtMSL))
                .font(.dsLabel).foregroundStyle(p.text)
            Text(String(format: "Past that point the next-best area (%03.0f° at %.1f NM from there) "
                        + "is out of glide, and this ground is the only one left.",
                        c.alternativeBearingDeg, c.alternativeDistanceNm))
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("glideplan-commit")
    }

    private func noAlternatives(_ p: Palette) -> some View {
        Text("No other listed area stays within glide along this track — taking it commits you to "
             + "this ground from the start.")
            .font(.dsLabelS).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            .accessibilityIdentifier("glideplan-commit-none")
    }

    // MARK: - unknowns and arming

    private func unknowns(_ p: Palette) -> some View {
        Text(plan.unknowns)
            .font(.dsLabelS).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("glideplan-unknowns")
    }

    private var isArmed: Bool { model.armedGlidePlan == plan }

    private func armRow(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.impact(.medium)
                model.armedGlidePlan = isArmed ? nil : plan
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isArmed ? "xmark.circle" : "location.north.line")
                    Text(isArmed ? "Disarm" : "Arm this as my plan")
                    Spacer(minLength: 0)
                }
                .font(.dsLabelSBold)
                .foregroundStyle(isArmed ? p.bad : p.accent)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background((isArmed ? p.bad : p.accent).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: DS.Radius.r4))
            }
            .buttonStyle(.plainHaptic)
            .accessibilityIdentifier("glideplan-arm")

            Text(isArmed
                 ? "Armed. The track is drawn on the map. This does not fly the aeroplane and it "
                   + "does not make the ground any more known than it was."
                 : "Arming draws the track on the map so you can fly it. Nothing changes until you "
                   + "press it.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
