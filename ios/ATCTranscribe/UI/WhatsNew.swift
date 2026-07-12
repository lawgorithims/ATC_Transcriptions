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
            build: 44, version: "1.0", headline: "Plate fixes: send-to-map for every airport + your position on the chart",
            highlights: [
                WhatsNewHighlight(
                    icon: "map",
                    title: "Send-to-map now works for every airport",
                    detail: "“Overlay on map” previously did nothing for airports outside a small built-in list (like KLRU). It now finds the airport from its runway data, drops the plate on the map, and centres the map on it — so the plate always appears, ready to fine-tune."),
                WhatsNewHighlight(
                    icon: "location.fill",
                    title: "Your GPS position on the approach plate",
                    detail: "On a georeferenced plate, your own aircraft now shows as a blue dot using your device's built-in GPS — no Stratux required. Tap “My Position” in the plate viewer to toggle it (and any ADS-B traffic) on or off."),
            ]),
        ReleaseNote(
            build: 43, version: "1.0", headline: "Plates that place themselves — plus a real Flight Bag",
            highlights: [
                WhatsNewHighlight(
                    icon: "scope",
                    title: "Approach plates that snap onto the map",
                    detail: "CommSight now reads an approach plate's fixes and georeferences it, so plates drop onto the moving map at the right place, scale, and heading on their own — no dragging to line them up. It's precomputed for 1,097 approaches across 567 US airports (look for the ✛ marker); where it can't align one confidently, you still place it by hand. A visual aid — always fly from the official published chart."),
                WhatsNewHighlight(
                    icon: "airplane.circle.fill",
                    title: "Tap an airport for a full ForeFlight-style card",
                    detail: "Tapping an airport on the map now opens a card with Info, Weather, Runway, Procedure, and NOTAM tabs. Under Procedure, sub-tabs for Airport, Departure, Arrival, Approach, and Other list every chart — each showing whether it's saved to your device, with a one-tap “Map” button to lay it on the moving map. There's also a Plates tab on the bottom bar to search any airport and browse its charts full-screen."),
                WhatsNewHighlight(
                    icon: "briefcase.fill",
                    title: "A Flight Bag that packs itself",
                    detail: "Download every plate for your filed route in one tap — or leave “Auto-pack” on and it happens the moment you file a plan. Grab whole regions of the country, see how much you've stored and clear it, and get a heads-up badge when the 28-day chart cycle is about to expire. Open it from the briefcase on the Plates tab."),
                WhatsNewHighlight(
                    icon: "location.north.circle.fill",
                    title: "Your position and traffic, on the plate",
                    detail: "On a georeferenced approach plate you can now show your own aircraft and nearby ADS-B traffic right on the chart, so you can picture where you are on the approach. Needs a GPS/traffic source (e.g. Stratux); your dot only appears with a valid fix."),
                WhatsNewHighlight(
                    icon: "waveform.badge.magnifyingglass",
                    title: "Sharper transcription on your route",
                    detail: "When you file a flight plan, CommSight primes its ear to the frequencies and fixes printed on that route's charts, so it recognises them more reliably on frequency."),
            ]),
        ReleaseNote(
            build: 42, version: "1.0", headline: "A new flight plan up top — plus plates and weather",
            highlights: [
                WhatsNewHighlight(
                    icon: "airplane",
                    title: "Your flight plan, right at the top",
                    detail: "The flight plan moves out of the pop-up and into a strip you open from the top bar, like the feed picker. Type the route in plain text — “KMSP GEP KAMMA KORD” — and CommSight recognises each entry as you go, colour-coding airports, VORs, fixes, and airways. Boxes for your aircraft, cruise altitude, and alternate sit alongside a live trip readout: distance, time enroute, ETA, and fuel. Save the aircraft you fly (tail, type, cruise speed, and burn) and pick one with a tap."),
                WhatsNewHighlight(
                    icon: "paperplane.fill",
                    title: "Send to ForeFlight always matches what you see",
                    detail: "Edits now apply live as you type, so the “Send to ForeFlight” button hands over exactly the route on screen — no more saving, closing, and reopening first. And if CommSight loads a clearance while you're editing, the clearance wins rather than being quietly overwritten. Still app-to-app on your iPad, so it works with no cell signal and no internet. Always review the route in ForeFlight before using it."),
                WhatsNewHighlight(
                    icon: "doc.text.image",
                    title: "Approach & departure plates, offline",
                    detail: "View the full FAA approach and departure plate for an airport, cached on first open so it's there when you're off the grid. You can also lay an approach plate over the moving map as a georeferenced reference to picture the procedure in place. A visual aid — fly from the official published chart."),
                WhatsNewHighlight(
                    icon: "cloud.sun.bolt.fill",
                    title: "Weather hazards & airport climate",
                    detail: "A new hazard layer draws active events — wildfires, severe storms, volcanic activity — from NASA's EONET feed on the map, with a heads-up when one sits near your route or destination. And an Airport Climate card shows the typical wind pattern (windrose), density altitude, and runway crosswind for where you're headed, from NASA POWER climate data. Planning context, not a substitute for a current weather briefing."),
            ]),
        ReleaseNote(
            build: 41, version: "1.0", headline: "Send your amended plan to ForeFlight — no internet needed",
            highlights: [
                WhatsNewHighlight(
                    icon: "paperplane.fill",
                    title: "Accept ➔ ForeFlight, one tap",
                    detail: "When CommSight hears your clearance and you accept it, a new “Accept ➔ ForeFlight” button applies the amendment AND opens ForeFlight with the amended route on its map. It's app-to-app on your iPad, so it works with no cell signal and no internet — Stratux-only cockpits included. Loaded departures and arrivals are sent as their individual fixes; approaches aren't sent (load those in ForeFlight's procedure advisor). Always review the route in ForeFlight before using it."),
                WhatsNewHighlight(
                    icon: "briefcase.fill",
                    title: "Send or share from the flight bag",
                    detail: "The flight bag gets a ForeFlight card: send the saved route to ForeFlight any time, or share it as a Garmin .fpl file — “Copy to ForeFlight” imports it as a route, and the same file works with other EFBs that read Garmin flight plans. Turn the whole hand-off on or off in Settings → ForeFlight."),
            ]),
        ReleaseNote(
            build: 40, version: "1.0", headline: "Approaches & SIDs on the map — and CommSight loads your clearance",
            highlights: [
                WhatsNewHighlight(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Coded approaches, SIDs & STARs on the chart",
                    detail: "CommSight now draws real coded procedures — instrument approaches, departures (SIDs), and arrivals (STARs) — right on the map, and can load one into your flight plan. Tap a procedure on an airport to preview it, then load it so its fixes join your route. The same coded data also helps the transcript get procedure and fix names right."),
                WhatsNewHighlight(
                    icon: "text.bubble.fill",
                    title: "It hears your clearance and offers to load it",
                    detail: "When the controller gives YOUR aircraft a clearance — “November 8 9 2 5 Tango, cleared direct BOSOX,” “…cleared the ILS runway 4 right,” “…cleared the CIVET arrival” — a one-tap chip appears to load it (direct-to a fix or airport, an approach for a runway, or a SID/STAR). It recognises your tail’s shorthands (N8925T, 8925T, “Seneca 25T”) but only ever acts on a clearance to YOUR aircraft — never one it overhears to another plane, and never a cancelled one. File your callsign and aircraft type in the flight bag to use it; every load is a tap you confirm."),
                WhatsNewHighlight(
                    icon: "checkmark.shield.fill",
                    title: "More dependable in the cockpit",
                    detail: "A large reliability pass: CommSight now recovers on its own after Siri, a phone call, or unplugging a USB adapter interrupts the audio — instead of quietly going silent while still looking live. A garbled transmission is flagged rather than dropped without a trace, a constantly-noisy channel tells you to calibrate the squelch, and a correctly-heard handoff frequency is never “corrected” to a different one. Plus smoother map traffic and lower battery/heat."),
            ]),
        ReleaseNote(
            build: 39, version: "1.0", headline: "Your charts are the home screen",
            highlights: [
                WhatsNewHighlight(
                    icon: "map.fill",
                    title: "The moving map is now your home screen",
                    detail: "CommSight opens straight to the chart. Your live transcript, flight plan, and status panels float on top as cards you can drag anywhere, resize, and pin in place — set up your cockpit the way you like it and CommSight remembers it."),
                WhatsNewHighlight(
                    icon: "circle.lefthalf.filled",
                    title: "See-through panels, laid out your way",
                    detail: "Give any panel its own background opacity — from solid to fully see-through so the chart shows underneath — and show or hide panels from the new Widgets button. Performance and diagnostics panels stay hidden until you want them."),
                WhatsNewHighlight(
                    icon: "square.3.layers.3d",
                    title: "Switch charts and overlays up top",
                    detail: "A new map button in the top bar switches the base map between VFR, IFR-low, standard, and satellite and toggles airspace and nearby navaids (weather radar is coming soon). Panning the chart is smoother now, too — the airspace and navaid layers no longer flicker."),
            ]),
        ReleaseNote(
            build: 38, version: "1.0", headline: "Tap the map — identify anything, and build your route",
            highlights: [
                WhatsNewHighlight(
                    icon: "hand.tap",
                    title: "Tap anything to identify it",
                    detail: "Tap an airport, VOR, fix, or airspace on the map and CommSight shows what it is — an airport's runways and tower/ground/approach/ATIS frequencies and elevation, a navaid's type and frequency, an airspace's class and floor/ceiling — plus its bearing and distance from you. Tap where a few things overlap and it asks which one you meant."),
                WhatsNewHighlight(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Build your route right on the map",
                    detail: "From any airport, VOR, or fix, add it to your route, insert it in the right place along your course, go Direct-To it, or set it as your departure or destination — and the magenta line redraws instantly. Remove a filed waypoint just as easily."),
                WhatsNewHighlight(
                    icon: "magnifyingglass",
                    title: "Search, and drop your own waypoints",
                    detail: "Tap the search button to find any airport, VOR, or fix by identifier or name (e.g. “Logan”), then jump the map to it. Or press and hold anywhere to drop a custom point and add it to your route or go direct — no fix required."),
            ]),
        ReleaseNote(
            build: 37, version: "1.0", headline: "Download the whole US for offline — and the chart opens instantly",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.down.circle.fill",
                    title: "Download every US chart for offline",
                    detail: "In Settings → Offline charts you can now store the entire lower-48 on your device — VFR sectionals (~1.4 GB), IFR-low (~0.5 GB), or both (~1.9 GB) — so the map works with no signal anywhere you fly, not just along your filed route. It asks first before using cellular data, shows how much is stored, and refreshes each 56-day chart cycle."),
                WhatsNewHighlight(
                    icon: "bolt.fill",
                    title: "The chart opens instantly",
                    detail: "CommSight now fetches charts quietly in the background — for the area around you when you open the app, and for your route the moment you file a plan — so the map is ready the instant you open it instead of pausing to download. Once a chart's on the device it loads straight from storage."),
                WhatsNewHighlight(
                    icon: "square.2.layers.3d.fill",
                    title: "One map that remembers your layer",
                    detail: "The FAA chart is now a base layer right on the route map — switch between VFR sectional, IFR low, Map, and Satellite from the top, with your route, airspace, navaids, and traffic drawn over all of them. No more drilling into a separate chart screen, and it reopens on whichever layer you used last (VFR to start)."),
            ]),
        ReleaseNote(
            build: 36, version: "1.0", headline: "Pan the chart anywhere — now covering the whole country",
            highlights: [
                WhatsNewHighlight(
                    icon: "hand.draw",
                    title: "Free-pan chart loading",
                    detail: "You're no longer limited to your filed route — pan and zoom the chart map anywhere in the country and CommSight loads that area's sectional or IFR chart automatically, then keeps it for offline. It only fetches charts where you actually look, so it stays light on data."),
                WhatsNewHighlight(
                    icon: "checkmark.seal",
                    title: "Complete nationwide coverage",
                    detail: "Every conterminous-US sectional and IFR-low enroute chart is now available, including the Dallas–Fort Worth sectional and the last IFR gaps. Charts are cached per 28-day cycle and refresh automatically when a new cycle publishes, so you're never reading an expired chart."),
            ]),
        ReleaseNote(
            build: 35, version: "1.0", headline: "Real FAA sectional & IFR charts — offline",
            highlights: [
                WhatsNewHighlight(
                    icon: "map.fill",
                    title: "See the actual FAA charts under your route",
                    detail: "The route map now has a chart layer. Open the layers menu → FAA sectional chart, then switch between the real VFR sectional, the IFR low-enroute chart, and standard/satellite. These are the official FAA charts — airspace, frequencies, navaids, terrain, airways — the same ones you'd fly with."),
                WhatsNewHighlight(
                    icon: "arrow.down.circle",
                    title: "Only downloads the charts your route crosses — then works offline",
                    detail: "CommSight fetches just the sectionals and IFR charts your filed route passes through, caches them, and renders them with no signal — so the chart is there in the cockpit. File a plan, open the chart, and the right charts load automatically. It's all self-hosted from FAA public-domain data."),
                WhatsNewHighlight(
                    icon: "location.north.circle.fill",
                    title: "Your aircraft and waypoints on the chart",
                    detail: "Your position (from the device GPS, or a connected Stratux) shows as a plane on the chart, with your filed route drawn through its waypoints and live ADS-B traffic around you."),
            ]),
        ReleaseNote(
            build: 34, version: "1.0", headline: "Airspace and nearby navaids on the route map",
            highlights: [
                WhatsNewHighlight(
                    icon: "hexagon",
                    title: "Class B, C, and D airspace outlines",
                    detail: "The route map now draws controlled airspace in the classic sectional colours — solid blue for Class B, magenta for Class C, dashed blue for Class D — so you can see the airspace your route crosses. Zoom in and the outlines fill in around what's in view. It's all built into the app, so it works with no signal."),
                WhatsNewHighlight(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Nearby navaids, airports, and leg distances",
                    detail: "As you zoom in, nearby VOR navaids and airports appear for context alongside your filed waypoints. Open the layers menu (top-right) to toggle airspace or nearby aids, switch to satellite, or open Route details for each leg's distance and true bearing plus the total."),
            ]),
        ReleaseNote(
            build: 33, version: "1.0", headline: "See your route and live traffic on a map",
            highlights: [
                WhatsNewHighlight(
                    icon: "map",
                    title: "Route map with live traffic",
                    detail: "Tap Map on the flight-plan bar to see your filed route drawn as the classic magenta line through its waypoints — airports, VOR navaids, and RNAV/GPS fixes — with live ADS-B traffic and, when your Stratux link has a fix, your own position. Pinch to zoom and pan. The waypoint coordinates are built into the app, so it works with no signal in the cockpit."),
            ]),
        ReleaseNote(
            build: 31, version: "1.0", headline: "Stratux traffic always on — and everything's built in",
            highlights: [
                WhatsNewHighlight(
                    icon: "dot.radiowaves.up.forward",
                    title: "Keep the Stratux link on, whatever you're listening to",
                    detail: "Your Stratux receiver's traffic and GPS now stream on their own — turn the Stratux link on (in the Stratux bar or Settings › Stratux receiver) and you get in-range aircraft plus your GPS fix even while you listen to a different source. Picking “Stratux receiver” as your input still adds its cockpit audio."),
                WhatsNewHighlight(
                    icon: "internaldrive.fill",
                    title: "No first-launch download",
                    detail: "The fine-tuned Small speech model and the on-device AI fixer are bundled into the app again, so a fresh install is ready to transcribe immediately — no waiting on a download, which matters before you lose signal."),
            ]),
        ReleaseNote(
            build: 30, version: "1.0", headline: "A cleaner console you control from the top",
            highlights: [
                WhatsNewHighlight(
                    icon: "slider.horizontal.3",
                    title: "Show only what you need",
                    detail: "The top of the screen is now a control bar: tap an icon to drop down the input controls, diagnostics, flight plan, or Stratux — tap again to tuck them away. The transcript stays front and center, and your layout is remembered between flights."),
                WhatsNewHighlight(
                    icon: "power",
                    title: "One power button, easier to hit",
                    detail: "Start, stop, and standby are now a single colour-coded button in the top bar — tap to start or stop transcribing, touch and hold for low-power standby. Buttons are bigger, better spaced, and give a haptic tap so they're easier to use in a bumpy cockpit."),
            ]),
        ReleaseNote(
            build: 29, version: "1.0", headline: "Locks onto the aircraft actually on frequency",
            highlights: [
                WhatsNewHighlight(
                    icon: "airplane.circle.fill",
                    title: "Live traffic now sharpens callsigns",
                    detail: "When you set your airport and turn on Live traffic, the app now tells the speech model which airline flights are actually in range — so a garbled “Rockfish 5546” is far more likely to come out as the real callsign. It only nudges toward airlines that are genuinely nearby, so it won't invent one. Set your airport in Settings and enable Live traffic to use it."),
            ]),
        ReleaseNote(
            build: 28, version: "1.0", headline: "Clearer transcripts on the internet feed",
            highlights: [
                WhatsNewHighlight(
                    icon: "waveform.badge.magnifyingglass",
                    title: "Better accuracy on live internet feeds",
                    detail: "Internet ATC streams are heavily compressed, and the radio “cleanup” we ran was actually over-processing them — causing misheard words and made-up numbers. On an internet feed the app now uses a lighter touch tuned for that audio, which testing showed clearly reduces errors. (Stratux and mic input are unchanged.)"),
                WhatsNewHighlight(
                    icon: "character.book.closed",
                    title: "Fixes common ATC mishears",
                    detail: "A new correction pass repairs frequent phraseology slips — e.g. “heal short” → “hold short,” “flight lever” → “flight level” — without touching correct readbacks."),
                WhatsNewHighlight(
                    icon: "mappin.slash",
                    title: "No more wrong-airport guessing",
                    detail: "The app no longer assumes Dallas/Fort Worth when you haven't set an airport — which had been nudging it toward the wrong runways and facilities on other fields. Set your airport in Settings for the best results."),
            ]),
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
