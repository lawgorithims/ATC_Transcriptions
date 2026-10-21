import SwiftUI

/// "What is the app doing with my connection, and can I make it do the thing I need?"
///
/// Every other EFB answers this with a spinner. On a weak link that is the worst possible answer:
/// the pilot cannot tell whether waiting will help, what is competing for the pipe, or whether the
/// radar frame they need is even being fetched. This screen is the answer — the live queue in plain
/// words, a switch per category, and a way to pull one job to the front.
struct NetworkActivityView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var activity = NetworkActivity.shared

    var body: some View {
        let p = model.palette
        List {
            nowSection
            categoriesSection
            Section {
                EmptyView()
            } footer: {
                Text("The app only runs a few requests at once, so a weak signal is spent on a few "
                     + "that finish instead of many that stall. Anything you are waiting on goes "
                     + "first, and background work — loading charts ahead of you, checking for new "
                     + "cycles — stands aside until it is done.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(p.bg)
        .navigationTitle("Data activity")
        .navigationBarTitleDisplayMode(.inline)
        .tint(p.accent)
    }

    // MARK: Live queue

    @ViewBuilder
    private var nowSection: some View {
        let p = model.palette
        let active = activity.activeJobs
        Section {
            if active.isEmpty {
                Label("Nothing in the queue", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(p.textDim)
                    .accessibilityIdentifier("netq-idle")
            } else {
                // Re-renders once a second so the "waiting 40s" read is honest. Only while this
                // screen is on-> screen; TimelineView stops when it is not visible.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    ForEach(active) { job in
                        jobRow(job, now: ctx.date, p: p)
                    }
                }
            }
        } header: {
            HStack {
                Text("Right now")
                if let s = activity.summary {
                    Spacer()
                    Text(s).font(.caption2).foregroundStyle(p.textDim)
                        .accessibilityIdentifier("netq-summary")
                }
            }
        }
    }

    @ViewBuilder
    private func jobRow(_ job: NetworkActivity.Job, now: Date, p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                stateIcon(job.state, p: p)
                Text(job.label).font(.callout).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 6)
                if job.state == .queued || job.state == .paused {
                    Button("Get now") { Haptics.impact(.medium); activity.prioritise(job.id) }
                        .font(.dsLabelSBold).foregroundStyle(p.accent)
                        .buttonStyle(.plainHaptic)
                        .accessibilityIdentifier("netq-prioritise")
                }
            }
            Text(subtitle(job, now: now))
                .font(.caption2).foregroundStyle(p.textDim)
        }
        .padding(.vertical, 1)
    }

    private func subtitle(_ job: NetworkActivity.Job, now: Date) -> String {
        var parts = [job.category.title]
        switch job.state {
        case .running:  parts.append("downloading")
        case .queued:   parts.append("waiting")
        case .paused:   parts.append("paused by you")
        default:        break
        }
        if job.priority == .urgent { parts.append("needed now") }
        let secs = Int(job.age(now))
        if secs >= 2, job.state != .finished { parts.append("\(secs)s") }
        if job.bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(job.bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func stateIcon(_ state: NetworkActivity.State, p: Palette) -> some View {
        switch state {
        case .running: ProgressView().controlSize(.mini)
        case .queued:  Image(systemName: "clock").font(.caption).foregroundStyle(p.textDim)
        case .paused:  Image(systemName: "pause.circle").font(.caption).foregroundStyle(p.warn)
        default:       Image(systemName: "circle").font(.caption).foregroundStyle(p.textDim)
        }
    }

    // MARK: Category switches

    private var categoriesSection: some View {
        let p = model.palette
        return Section {
            ForEach(NetworkActivity.Category.allCases) { cat in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(
                        get: { !activity.isPaused(cat) },
                        set: { activity.setPaused(cat, !$0) }
                    )) {
                        HStack(spacing: 6) {
                            Text(cat.title).foregroundStyle(p.text)
                            if cat.isFlightCritical && activity.isPaused(cat) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(p.bad)
                            }
                        }
                    }
                    .tint(p.accent)
                    .accessibilityIdentifier("netq-toggle-\(cat.rawValue)")
                    Text(activity.isPaused(cat) && cat.isFlightCritical
                         ? "Paused — you will not get new \(cat.title.lowercased()) until you switch this back on."
                         : cat.blurb)
                        .font(.caption2)
                        .foregroundStyle(activity.isPaused(cat) && cat.isFlightCritical ? p.bad : p.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("What the app may use data for")
        } footer: {
            // Switching OFF weather or radar is allowed and NOT discouraged by disabling the control
            // — a pilot on a metered link over the ocean may genuinely want only the chart pack. It
            // is their aircraft. What the UI owes them is that the consequence is stated plainly and
            // that a paused request waits visibly rather than failing somewhere they cannot see.
            Text("Switching one off stops new requests of that kind. Anything already downloading "
                 + "finishes — stopping it halfway would waste what it has already pulled.")
        }
    }
}
