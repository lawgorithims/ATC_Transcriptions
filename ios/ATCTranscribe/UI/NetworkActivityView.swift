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

// MARK: - Top-bar entry point

/// The one-tap way in, parked in the map's top bar beside Settings.
///
/// WHY IT IS IN THE BAR AT ALL. This panel is opened at the moment the app APPEARS to have frozen —
/// which is the worst possible moment to make someone walk Settings → Data activity. It has to be
/// one tap, on the surface they are already looking at.
///
/// WHY IT IS ITS OWN VIEW AND NOT A `TopBar` HELPER. `NetworkActivity` is a nested ObservableObject;
/// reading `NetworkActivity.shared.activeJobs` from inside `TopBar` compiles and then never
/// re-renders, because a nested observable does not republish its parent — the trap `TopBar`'s own
/// header comment documents for `WidgetStore`. Subscribing the WHOLE bar to the queue would be worse
/// than useless in the other direction: the queue mutates on every byte reported, which would drag
/// the clock's TimelineView and three Menus through a re-render on every network tick. A separate
/// small view subscribes exactly the 30 points that need to change.
struct DataActivityButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var activity = NetworkActivity.shared
    var iconSize: CGFloat = 19
    @State private var show = false

    /// What the icon is saying. PAUSED OUTRANKS ACTIVE, and that ordering is the whole point.
    ///
    /// A category the pilot switched off an hour ago, with nothing queued behind it, leaves
    /// `activeJobs` empty and `summary` nil. Drive the icon off "is anything happening" — the obvious
    /// implementation — and it reads IDLE in precisely the case where the pilot most needs reminding
    /// that they told the app to stop fetching weather. The thing they did to themselves is the thing
    /// the bar must remember for them.
    private enum Look { case idle, active, paused }

    private var look: Look {
        if !activity.pausedCategories.isEmpty { return .paused }
        return activity.activeJobs.isEmpty ? .idle : .active
    }

    var body: some View {
        let p = model.palette
        Button {
            Haptics.impact(.light)
            show = true
        } label: {
            // ⚠️ EXACTLY 30x30 IN EVERY STATE. The top bar is already over its width budget on every
            // iPhone in portrait — measured: 406pt incompressible against 440pt on the widest — and
            // it overflows by bleeding off BOTH edges with no clipping and no visual cue. A control
            // that grows into a capsule when busy (the RecordButton idiom) would push the Settings
            // gear off-screen exactly when the queue is busiest, which is when this icon matters.
            // State is carried by the glyph and the fill, both of which are free.
            Image(systemName: look == .paused ? "pause.circle.fill" : "arrow.up.arrow.down.circle")
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(tint(p))
                .background(fill(p))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
        }
        .buttonStyle(.plainHaptic)
        // ONE identifier for all three states. `EFBOnlyChromeUITests` asserts the beta's chrome with
        // `app.buttons[id].exists`, so an identifier that only appears in one state would make that
        // presence check pass or fail depending on whether a download happened to be running.
        .accessibilityIdentifier("data-activity-button")
        .accessibilityLabel("Data activity")
        .accessibilityValue(spokenState)
        .popover(isPresented: $show) {
            DataActivityPanel().environmentObject(model)
        }
    }

    /// The glyph CHANGES for paused rather than only the colour. On the Night theme `accent` is
    /// 0xFF6A50 and `bad`/`warn` sit beside it in the same red-only emission band, so colour alone
    /// cannot carry a state a pilot has to read at a glance under red light.
    private func tint(_ p: Palette) -> Color {
        switch look {
        case .idle:   return p.textDim
        case .active: return p.accent
        case .paused: return p.warn
        }
    }

    private func fill(_ p: Palette) -> Color {
        switch look {
        case .idle:   return .clear
        case .active: return p.accent.opacity(0.16)   // the bar's existing "this control is on" fill
        case .paused: return p.warn.opacity(0.16)
        }
    }

    private var spokenState: String {
        switch look {
        case .idle:   return "idle"
        case .active: return "\(activity.activeJobs.count) in progress"
        case .paused: return "paused: "
            + activity.pausedCategories.map(\.title).sorted().joined(separator: ", ")
        }
    }
}

/// `NetworkActivityView` sized and dressed for a popover.
///
/// The view itself is untouched so the Settings route keeps working unchanged — one screen, two
/// entry points. What a popover needs and a pushed page does not: an explicit frame (a bare `List`
/// has no intrinsic popover size and would render at the system default, cramped and scroll-clipped),
/// an opaque themed background, its own title (`.navigationTitle` is inert without a NavigationStack),
/// and `.presentationCompactAdaptation(.popover)` — without that last line SwiftUI silently turns
/// this into a sheet on iPhone, which is the full-screen presentation the one-tap goal exists to
/// avoid, and it would only show up on a device nobody tests on the iPad simulator.
struct DataActivityPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            Text("Data activity")
                .font(.dsHeadline).foregroundStyle(p.text)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
            NetworkActivityView()
                .environmentObject(model)
        }
        // ⚠️ THE MINIMUM HAS TO FIT THE PHONE, NOT THE iPAD. A flat `minWidth: 420` was wider than
        // the 390pt iPhone this was tested on: the popover cannot shrink below its content's
        // minimum, so it rendered clipped off the left edge with the title reading "ata activity".
        // A popover does not scroll sideways and gives no hint that anything is missing, so the
        // minimum is the one dimension that must be sized for the SMALLEST screen.
        .frame(minWidth: compact ? 280 : 420,
               idealWidth: compact ? 330 : 460,
               maxWidth: compact ? 340 : 560,
               minHeight: 320, idealHeight: 460, maxHeight: 560)
        .background(p.bg)
        .presentationCompactAdaptation(.popover)
    }

    private var compact: Bool { hSize == .compact }
}
