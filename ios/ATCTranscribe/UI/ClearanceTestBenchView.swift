import SwiftUI

/// The buried Clearance Test Bench (Settings → tap the version 7×). It replays scripted ATC — a
/// clearance to a test aircraft, buried among decoys to other aircraft — through the REAL detector,
/// so the "ATC clears you → amended plan → ForeFlight" feature can be exercised on the ground.
///
/// SAFETY: entering snapshots the real flight state and leaving restores it verbatim; a crash
/// breadcrumb restores it at next launch even if the app is killed here. The banner makes the sandbox
/// state unmistakable, and nothing is sent to ForeFlight without an explicit tap.
struct ClearanceTestBenchView: View {
    @EnvironmentObject var model: AppModel
    @State private var results: [String: ScenarioRunResult] = [:]
    @State private var expanded: Set<String> = []

    private let scenarios = ClearanceScenarioCatalog.all

    var body: some View {
        let p = model.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                banner(p)
                runAllRow(p)
                ForEach(ClearanceCategory.allCases, id: \.self) { cat in
                    let group = scenarios.filter { $0.category == cat }
                    if !group.isEmpty { section(cat, group, p) }
                }
                Text("Transcript-injection mode replays each clearance as text through the live parser, ownship gate, and plan amendment — the same path a real transmission takes after speech-to-text. Audio-clip mode (real recordings through Whisper) drops in per the ClearanceClips README as clips are collected.")
                    .font(.caption2).foregroundStyle(p.textDim).padding(.top, 4)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Clearance test bench")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.diagnosticBeginBench() }
        .onDisappear { model.diagnosticEndBench() }   // deliberate exit → restore the real flight
    }

    // MARK: banner + run-all

    private func banner(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("TEST MODE", systemImage: "testtube.2")
                .font(.caption.weight(.bold)).foregroundStyle(p.warn)
            Text("Your real flight plan, aircraft, and airport are saved and restored automatically when you leave — even if the app closes. Nothing here changes your filed plan or sends anything to ATC.")
                .font(.caption2).foregroundStyle(p.text)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.warn.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.warn.opacity(0.5), lineWidth: 1))
        .accessibilityIdentifier("test-bench-banner")
    }

    private func runAllRow(_ p: Palette) -> some View {
        HStack {
            Button {
                Haptics.impact(.medium)
                for s in scenarios { results[s.id] = model.diagnosticRunScenario(s) }
            } label: {
                Label("Run all \(scenarios.count)", systemImage: "play.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(p.accent))
            }
            .buttonStyle(.plainHaptic).accessibilityIdentifier("test-bench-run-all")
            Spacer()
            if !results.isEmpty {
                let passed = results.values.filter(\.passed).count
                Text("\(passed)/\(results.count) passed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(passed == results.count ? p.good : p.warn)
            }
        }
    }

    // MARK: a category section

    private func section(_ cat: ClearanceCategory, _ group: [ClearanceScenario], _ p: Palette) -> some View {
        Card(title: cat.rawValue) {
            VStack(spacing: 0) {
                ForEach(group) { s in
                    scenarioRow(s, p)
                    if s.id != group.last?.id { Divider().overlay(p.border) }
                }
            }
        }
    }

    @ViewBuilder private func scenarioRow(_ s: ClearanceScenario, _ p: Palette) -> some View {
        let result = results[s.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusDot(result, p)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.caption.weight(.semibold)).foregroundStyle(p.text)
                    Text(s.detail).font(.system(size: 10)).foregroundStyle(p.textDim).lineLimit(2)
                }
                Spacer(minLength: 6)
                Button {
                    Haptics.impact(.light)
                    results[s.id] = model.diagnosticRunScenario(s)
                    expanded.insert(s.id)
                } label: {
                    Text("Run").font(.caption2.weight(.bold)).foregroundStyle(p.accent)
                }
                .buttonStyle(.plainHaptic).accessibilityIdentifier("run-\(s.id)")
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(s.id) }

            if expanded.contains(s.id), let r = result { resultDetail(s, r, p) }
        }
        .padding(.vertical, 8)
    }

    // MARK: result detail

    @ViewBuilder private func resultDetail(_ s: ClearanceScenario, _ r: ScenarioRunResult, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.summary)
                .font(.caption2.weight(.medium))
                .foregroundStyle(r.passed ? p.good : p.bad)
            ForEach(r.transmissions) { tx in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: tx.asExpected ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 9)).foregroundStyle(tx.asExpected ? p.good : p.bad)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tx.text).font(.system(size: 10)).foregroundStyle(p.text)
                        Text(txLabel(tx)).font(.system(size: 9)).foregroundStyle(p.textDim)
                    }
                }
            }
            if let plan = r.resultingPlanSummary {
                Text("Amended plan: \(plan)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.accent).padding(.top, 2)
            }
            if r.didAmendPlan {
                Button {
                    Haptics.impact(.medium)
                    _ = model.diagnosticRunScenario(s)   // re-stage this scenario's amended plan…
                    model.openInForeFlight()             // …then hand exactly that to ForeFlight
                } label: {
                    Label("Send this plan to ForeFlight", systemImage: "paperplane.fill")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plainHaptic).padding(.top, 2).accessibilityIdentifier("send-ff-\(s.id)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(p.surfaceAlt))
    }

    // MARK: bits

    private func statusDot(_ r: ScenarioRunResult?, _ p: Palette) -> some View {
        let color: Color = r == nil ? p.textDim.opacity(0.4) : (r!.passed ? p.good : p.bad)
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func txLabel(_ tx: TransmissionResult) -> String {
        let who = tx.toOwnship ? "to you" : "to another aircraft"
        guard tx.firedSuggestion else { return "\(who) — no change staged" }
        return "\(who) — staged \(tx.commandKind ?? "?") \(tx.commandTarget ?? "")"
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
