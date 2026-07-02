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
            build: 27, version: "1.0", headline: "Calibrate the mic to your room",
            highlights: [
                WhatsNewHighlight(
                    icon: "mic.badge.plus",
                    title: "One-tap microphone calibration",
                    detail: "In Settings (or tap the input meter), open “Calibrate microphone…”. Stay quiet for a moment while it measures your background noise, then say a short test call — it sets the squelch to sit right between the two, so a noisy cockpit or room is ignored and your voice still comes through. Best when the automatic threshold isn't quite gating your environment. You can still fine-tune it afterward with the slider."),
            ]),
        ReleaseNote(
            build: 26, version: "1.0", headline: "Device-microphone input fixed",
            highlights: [
                WhatsNewHighlight(
                    icon: "mic.fill",
                    title: "The mic no longer gets stuck on “Transcribing…”",
                    detail: "Using your iPad's built-in microphone, the app would sit on “Transcribing…” and almost never show anything. It was treating the constant background room tone as if someone were always talking, so it never finished a transmission. It now learns the room's background level in the first moment of listening and only wakes on speech above it — so real calls come through and the quiet room is ignored. If you're in a very loud space you can still fine-tune it with the squelch control (tap the input meter). Radio/Stratux input is unchanged."),
            ]),
        ReleaseNote(
            build: 25, version: "1.0", headline: "Each call appears the moment the next one starts",
            highlights: [
                WhatsNewHighlight(
                    icon: "person.wave.2.fill",
                    title: "Turns surface the instant the speaker changes",
                    detail: "During a quick back-and-forth between the controller and an aircraft, the app now closes and shows a transmission the moment it hears a different voice key up — instead of holding it until the exchange goes quiet. A rapid ATC↔pilot volley reads out call-by-call in near real time. If it's ever unsure who's talking it waits the extra beat rather than split a single speaker, so lines stay clean. Turn it on or off with Separate speakers in Settings."),
            ]),
        ReleaseNote(
            build: 24, version: "1.0", headline: "Faster transcription + manage your models",
            highlights: [
                WhatsNewHighlight(
                    icon: "bolt.horizontal.fill",
                    title: "Transmissions come through sooner",
                    detail: "During fast, back-to-back exchanges the transcript no longer arrives in one big delayed batch — the app splits calls on their push-to-talk gaps and surfaces each within a couple of seconds instead of waiting up to ~12 s."),
                WhatsNewHighlight(
                    icon: "arrow.clockwise",
                    title: "Re-download or delete a model",
                    detail: "In Settings → Models, tap the ••• on any downloaded model to re-download it (fixes a bad or interrupted download) or delete it to free up space. The speech model is built in, so it always just works."),
                WhatsNewHighlight(
                    icon: "shippingbox",
                    title: "Smaller download",
                    detail: "The speech model is bundled so transcription works offline the moment you install. The optional AI context fixer now downloads on first launch instead of shipping inside the app — roughly half the size."),
            ]),
        ReleaseNote(
            build: 23, version: "1.0", headline: "Everything's built in — no downloads",
            highlights: [
                WhatsNewHighlight(
                    icon: "shippingbox.fill",
                    title: "Speech model + AI fixer preloaded",
                    detail: "The US-tuned Small speech model and the on-device AI context fixer now ship inside the app. A fresh install works immediately — no waiting on a download, and nothing to re-fetch if you reinstall. (The app download is larger as a result.)"),
            ]),
        ReleaseNote(
            build: 22, version: "1.0", headline: "Change your mind while a model loads",
            highlights: [
                WhatsNewHighlight(
                    icon: "hand.tap",
                    title: "Switch or cancel a model mid-load",
                    detail: "While a speech model is loading you can now pick a different model — it takes over — or tap the one you’re already using to cancel and stay put. No more waiting out a slow Large-model compile with every button greyed out."),
                WhatsNewHighlight(
                    icon: "arrow.uturn.backward",
                    title: "Better recovery when a model won’t load",
                    detail: "If a model’s files are corrupt, CommSight now re-offers the download instead of dead-ending, and it no longer claims you’re “still using” a model when there’s nothing loaded."),
                WhatsNewHighlight(
                    icon: "memorychip",
                    title: "Lighter, cleaner Settings",
                    detail: "The performance check no longer loads a second copy of the model into memory, and a speed setting that never actually did anything was removed."),
            ]),
        ReleaseNote(
            build: 21, version: "1.0", headline: "US-tuned Small model + rock-solid Stratux switching",
            highlights: [
                WhatsNewHighlight(
                    icon: "target",
                    title: "Small model retuned for US ATC",
                    detail: "The Small model is now fine-tuned on US air-traffic audio — US callsigns, phraseology, and numbers. It downloads automatically the first time you open this build. If you mainly fly US airspace, this is the model to use; on US audio it’s markedly more accurate than before."),
                WhatsNewHighlight(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Switch models without dropping your Stratux link",
                    detail: "Changing speech models while connected to a Stratux no longer interrupts your cockpit audio, live traffic, or GPS — the current model keeps running until the new one is ready, then swaps seamlessly. Even if a big model won’t load, your live feed stays up."),
                WhatsNewHighlight(
                    icon: "battery.100.bolt",
                    title: "No background AI after a model switch",
                    detail: "If a model finishes loading while CommSight is in the background, it no longer quietly starts transcribing (and draining the battery) off-screen — it waits until you bring the app back."),
            ]),
        ReleaseNote(
            build: 18, version: "1.0", headline: "Connect a Stratux receiver",
            highlights: [
                WhatsNewHighlight(
                    icon: "dot.radiowaves.up.forward",
                    title: "Cockpit audio over Wi-Fi",
                    detail: "Pick “Stratux receiver” as your input source to transcribe live cockpit audio streamed from a Stratux box over its own Wi-Fi — no cable to the iPad, and no internet needed in flight. Set the receiver’s address in Settings › Stratux receiver."),
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "On-board traffic & GPS",
                    detail: "Connected to a Stratux, nearby ADS-B traffic and your GPS fix come straight from the receiver instead of the internet — feeding the same callsign corrector and traffic view, in flight."),
            ]),
        ReleaseNote(
            build: 17, version: "1.0", headline: "Fix: Start button after a model won’t load",
            highlights: [
                WhatsNewHighlight(
                    icon: "play.slash",
                    title: "No more stuck Start button",
                    detail: "If a model (e.g. Large V2) won’t load on your device, CommSight now automatically falls back to the Small model so you can actually Start a feed — instead of looking like it loaded Small while leaving Start dead. It also remembers Small for next time so it won’t keep retrying the model that won’t load."),
            ]),
        ReleaseNote(
            build: 16, version: "1.0", headline: "Large V2 is actually fast now",
            highlights: [
                WhatsNewHighlight(
                    icon: "bolt.fill",
                    title: "Large V2 fixed — loads and transcribes at full speed",
                    detail: "Large V2 now uses a stock model we converted through the same on-device-optimized pipeline as the fine-tuned models — so it loads in seconds and transcribes in real time, instead of stalling and overheating. Re-download Large V2 in Settings → Models to get the fixed version."),
            ]),
        ReleaseNote(
            build: 15, version: "1.0", headline: "Clearer naming & a transcribing indicator",
            highlights: [
                WhatsNewHighlight(
                    icon: "textformat",
                    title: "Consistent model names",
                    detail: "Each speech model now reads the same everywhere — the download list, the model picker, the widgets, and the loading screen all use the same name (e.g. “Large V2”), with the longer description moved to the subtitle."),
                WhatsNewHighlight(
                    icon: "waveform",
                    title: "“Transcribing…” indicator",
                    detail: "While the app is decoding a transmission you’ll see a “Transcribing… Ns” indicator with elapsed time — so a slow model reads as working (just slow), not stalled. If it climbs to many seconds per transmission, the model is the bottleneck on your device."),
            ]),
        ReleaseNote(
            build: 14, version: "1.0", headline: "Battery, speed & a faster Large V2",
            highlights: [
                WhatsNewHighlight(
                    icon: "iphone.slash",
                    title: "Pauses when you leave the app",
                    detail: "CommSight now stops capturing and releases audio when you go to the home screen or switch apps — so it no longer keeps playing the live feed or draining the battery in the background. It resumes when you come back."),
                WhatsNewHighlight(
                    icon: "bolt.fill",
                    title: "Large V2 loads fast now",
                    detail: "Large V2 now uses a compressed on-device build of the same stock model (~632 MB instead of ~1.6 GB). It loads in seconds instead of minutes and runs much cooler — re-download it in Settings → Models to get the faster version."),
                WhatsNewHighlight(
                    icon: "gauge.with.needle",
                    title: "Model-loading diagnostics",
                    detail: "While a speech model loads you now see which model is loading, an elapsed timer, and your device temperature — so a slow first load reads as progressing, not frozen."),
            ]),
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
