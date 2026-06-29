import Foundation

/// One feature/change called out in the "What's new" screen.
struct WhatsNewHighlight: Identifiable {
    let icon: String        // SF Symbol name
    let title: String
    let detail: String      // plain English — what it does and what to try
    var id: String { title }
}

/// The release notes for one shipped build (TestFlight `CFBundleVersion`). Plain-English, ordered
/// newest-first in `WhatsNew.releaseNotes`.
struct ReleaseNote: Identifiable {
    let build: Int          // CFBundleVersion — the TestFlight build number
    let version: String     // CFBundleShortVersionString — the marketing version, e.g. "1.0"
    let headline: String    // short title for this build
    let highlights: [WhatsNewHighlight]
    var id: Int { build }
}

/// The in-app changelog + the version-gating logic behind the "What's new" popup. The popup appears
/// once after the app updates to a newer build; Settings → About re-shows the full log anytime.
///
/// Gating is intentionally pure + injectable (`autoShowEntries`) so it's unit-tested without a real
/// bundle/UserDefaults. The running build comes from the Info.plist `CFBundleVersion`, which is bound
/// to `CURRENT_PROJECT_VERSION` (the `BUILD_NUMBER` set at archive time) — so it's the real TestFlight
/// number on a shipped build and "1" in a dev/Simulator build.
enum WhatsNew {

    /// Newest build first. Keep each new shipped build's notes at the top; the gate shows everything a
    /// tester hasn't seen since their last build, so a tester who skips builds still gets a full
    /// catch-up. Builds need not be contiguous.
    static let releaseNotes: [ReleaseNote] = [
        ReleaseNote(
            build: 13, version: "1.0", headline: "Model-loading fixes",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.down.circle",
                    title: "Fixed: stuck on “Loading model…”",
                    detail: "If a speech model (especially Large V2) is slow to load — or your device can’t load it — the app no longer hangs forever. It shows which model is loading, and if one won’t load it offers the smaller, reliable model instead of leaving you stuck. The widgets also stop showing the wrong model name while loading."),
                WhatsNewHighlight(
                    icon: "square.and.arrow.down",
                    title: "Download just the model you want",
                    detail: "On first launch you can now download only Large or Large V2 and continue — you’re no longer forced to also download the Small model first."),
            ]),
        ReleaseNote(
            build: 12, version: "1.0", headline: "Reliability & what’s new",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Reliable model switching",
                    detail: "Switching speech models — especially Large V2 — no longer gets stuck or locks the picker. The model you’re on keeps working until the new one is fully loaded, and a slow load won’t trap you or peg the CPU."),
                WhatsNewHighlight(
                    icon: "battery.100.bolt",
                    title: "Much lower battery use in standby",
                    detail: "Standby now fully stops the background AI fixer and releases the audio session, so the device can idle instead of working while you’re paused. (Downloads still continue.)"),
                WhatsNewHighlight(
                    icon: "sparkles",
                    title: "“What’s new” after every update",
                    detail: "This screen now appears once after you install a new build, so you can see what changed and what to try — handy while testing. You can re-read it anytime in Settings → About."),
            ]),
        ReleaseNote(
            build: 11, version: "1.0", headline: "Live traffic & callsign tools",
            highlights: [
                WhatsNewHighlight(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Live ADS-B traffic",
                    detail: "Turn on Settings → Live traffic and CommSight pulls aircraft within 30 NM of your airport, so the corrector can match a misheard callsign to a plane actually on frequency. Only fresh data is ever used. Needs a network connection and an airport, and runs only while transcribing."),
                WhatsNewHighlight(
                    icon: "airplane",
                    title: "Tap a callsign to follow one aircraft",
                    detail: "Each transmission now shows its callsign as a chip. Tap it to filter the transcript to just that aircraft’s conversation; a green plane means it’s currently in range on the live ADS-B feed."),
                WhatsNewHighlight(
                    icon: "chart.bar.doc.horizontal",
                    title: "New “Large V2” model",
                    detail: "An optional stock OpenAI speech model you can download in Settings → Models to compare real-world accuracy against the fine-tuned models."),
            ]),
        ReleaseNote(
            build: 10, version: "1.0", headline: "AI fixer, flight bag & more",
            highlights: [
                WhatsNewHighlight(
                    icon: "wand.and.stars",
                    title: "Correction works out of the box",
                    detail: "The on-device AI context fixer now installs automatically with the speech model and is on by default — it cleans up misheard callsigns, spoken numbers, and phraseology. The raw transcript is always kept and every edit is shown."),
                WhatsNewHighlight(
                    icon: "briefcase.fill",
                    title: "Electronic Flight Bag",
                    detail: "Tap the briefcase to file a flight plan — paste a ForeFlight route and it parses into departure, destination, and waypoints. Your callsign, airports, and route then feed the corrector so they’re recognized."),
                WhatsNewHighlight(
                    icon: "square.stack.3d.up",
                    title: "Swipeable notification carousel",
                    detail: "The top strip now pages between live status, your filed flight plan, and live traffic — swipe between them."),
                WhatsNewHighlight(
                    icon: "slider.horizontal.3",
                    title: "Customize the sidebar, sort the transcript, settings that stick",
                    detail: "Long-press a sidebar widget to add, remove, or reorder it; sort the transcript and jump to the newest line; and your settings now persist between launches."),
            ]),
        ReleaseNote(
            build: 8, version: "1.0", headline: "Separate speakers",
            highlights: [
                WhatsNewHighlight(
                    icon: "person.2.fill",
                    title: "Controller and aircraft on their own lines",
                    detail: "Merged transmissions are split at push-to-talk breaks and each speaker is tagged (S1, S2…) on its own color-coded line, so ATC and the aircraft don’t share a line."),
                WhatsNewHighlight(
                    icon: "app.badge.checkmark",
                    title: "New app icon",
                    detail: "A fresh CommSight icon on your home screen."),
            ]),
    ]

    // MARK: - Running build (Info.plist)

    /// The running build number (`CFBundleVersion`). Real TestFlight number on a shipped build; "1"
    /// (→ 1 here) in a dev/Simulator build, where the auto-popup therefore stays dormant (use the
    /// `--whats-new` launch arg or Settings → About to view it).
    static func currentBuild() -> Int {
        Int((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "") ?? 0
    }

    /// The running marketing version (`CFBundleShortVersionString`, e.g. "1.0").
    static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    // MARK: - Gating (pure, unit-tested)

    /// Release notes for builds the tester hasn't seen yet — newer than `lastSeen`, no newer than the
    /// `current` running build (so a note for a not-yet-installed build never leaks early).
    static func entries(newerThan lastSeen: Int, upTo current: Int) -> [ReleaseNote] {
        releaseNotes.filter { $0.build > lastSeen && $0.build <= current }
    }

    /// What the auto-popup should show on launch (empty → don't show): nothing while the first-launch
    /// download gate is up (a fresh install hasn't "changed"), nothing when the build isn't newer than
    /// last seen (relaunch / downgrade), otherwise the catch-up of unseen builds.
    static func autoShowEntries(lastSeen: Int, current: Int, onboarding: Bool) -> [ReleaseNote] {
        guard !onboarding, current > lastSeen else { return [] }
        return entries(newerThan: lastSeen, upTo: current)
    }

    /// The persisted "last seen build" only ever moves forward, so a downgrade reinstall (build 12 →
    /// build 11) can never replay an old changelog. Pure + injectable for tests.
    static func advancedBaseline(stored: Int, current: Int) -> Int { max(stored, current) }
}
