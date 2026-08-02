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
    ///
    /// 105 IS ABSENT ON PURPOSE. It was 104 plus one Swift 6 compiler fix and changed nothing a
    /// tester can see, so it has no entry rather than a manufactured one. The gap is what "builds
    /// need not be contiguous" is for.
    static let releaseNotes: [ReleaseNote] = [
        ReleaseNote(
            build: 107, version: "1.0", headline: "Reachable ground, ranked — and a glide you can rehearse",
            highlights: [
                WhatsNewHighlight(
                    icon: "list.number",
                    title: "The strongest ground, named",
                    detail: "The layers menu has a new control: Show reachable ground, ranked. It lists the best ground within glide, best first, with a bearing, a distance, how much open run it found and which way that run lies. Deliberately a list and not marks on the chart — the shading is what should guide the turn, and a symbol saying \"here\" would borrow the chart's authority for a patch of dirt nobody has seen. Every row carries what is not known about it."),
                WhatsNewHighlight(
                    icon: "play.circle",
                    title: "Rehearse the glide before you commit to it",
                    detail: "Pick one of those areas and the app flies it: a run-in to a key position, then a normal left-hand circuit onto a final laid along the run and pointed into whatever wind there is. It budgets height leg by leg, tells you whether you arrive with a circuit in hand or short and by how much, and plans the height loss overhead if you arrive high. It also names your commit point — the last place on the run-in from which the next-best area is still reachable. Past that there is one field left, and you should know where that is rather than discover it. Arm it and the track is drawn on the map, dashed, because it is not a published procedure."),
                WhatsNewHighlight(
                    icon: "square.grid.3x3.square",
                    title: "Room to land now changes the colour",
                    detail: "A 60-metre patch of perfect flat cropland ringed by forest used to score exactly like the middle of a mile-wide field — same surface, same slope, same colour. The packs now measure the longest open run through every point, and your landing distance decides what counts as enough. Ground too short for your aeroplane is excluded outright; ground that is tight is capped. Packs built before this still score exactly as they did."),
                WhatsNewHighlight(
                    icon: "dice",
                    title: "A demo flight, for showing someone",
                    detail: "Under the developer section: parks a hypothetical aeroplane over ground you actually have data for, at a height with something to glide to, and hands you the emergency button. Everything about it is the real path — a real point checked against the real scoring, and the real button. It refuses to arm if anything is moving, if a Stratux is connected, or while a flight is recording, and the position is marked fabricated on every screen while it is on."),
            ]),
        ReleaseNote(
            build: 106, version: "1.0", headline: "Off-field landability, now something you can actually download",
            highlights: [
                WhatsNewHighlight(
                    icon: "square.grid.3x3.square",
                    title: "The landability layer works now",
                    detail: "Last build shipped this layer dark — there was no way to get the data it needs. Downloads now has an Off-field landability section: pick your region, watch it come down with real progress, and the map paints without a restart. Southern New Mexico is up first (Las Cruces, the Mesilla Valley, the Organ and San Andres ranges); more regions follow as they are built. Each pack is around 90 MB and stays until you remove it — nothing evicts it behind your back."),
                WhatsNewHighlight(
                    icon: "airplane.departure",
                    title: "Your landing numbers now change the map",
                    detail: "The aircraft editor takes your approach speed and your POH landing distance over a 50 ft obstacle. Give it those and the same ground scores differently: an aeroplane needing 2,600 ft cannot use rough or soft ground the way one needing 900 ft can, and the shading says so. Firm open ground scores the same for everything that flies, so the top of the scale stays put — what changes is how much of the marginal ground below it is worth considering. Ask for the total over a 50 ft obstacle rather than the ground roll, because an unprepared field usually has a fence or trees at the approach end."),
                WhatsNewHighlight(
                    icon: "speedometer",
                    title: "A correction: approach speed was being read from best glide",
                    detail: "The landability scoring took your best-glide speed and used it as your approach speed. They are different numbers — best glide is flown well above the speed you cross a fence at — so the ground was scored as though you touched down faster than you do. The error was in the cautious direction, and it is now its own field."),
                WhatsNewHighlight(
                    icon: "map",
                    title: "Coverage for where you fly, offered rather than assumed",
                    detail: "File a route and the Downloads screen tells you how many landability cells it crosses that you do not have. Pan the map somewhere covered and it offers the download. It never starts one on its own — 90 MB is not something to spend on your data plan because you moved the map."),
            ]),
        ReleaseNote(
            build: 104, version: "1.0", headline: "The plate and the procedure now agree on the runway",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.triangle.branch",
                    title: "An approach plate now loads its own runway's procedure",
                    detail: "Matching a plate to its coded procedure looked at the approach type and never at the runway, so every ILS at a field looked alike and the app picked whichever sorted first — usually the opposite end. Measured across every charted approach in the cycle, 4,705 of 9,535 loaded a different runway's procedure, taking its crossing altitudes, its published minimum and its temperature limits with it. Boston's RNAV to 04R was showing 04L's numbers. All of them now match on the runway the plate names."),
                WhatsNewHighlight(
                    icon: "arrow.uturn.down.circle",
                    title: "Alternate minimums, read for the field you are looking at",
                    detail: "The IFR alternate minimums booklet is one document covering up to 145 airports, so finding your field in it in the air is a page hunt. The Arrival tab now reads your airport's block out of it and lists each approach with the ceiling and visibility it needs, and whether it is usable at all — tell it whether local weather is reporting and whether the tower is open, and approaches that are not authorised are marked. An airport the booklet does not list is stated as standard 600-2 / 800-2, which is a real answer rather than a blank."),
                WhatsNewHighlight(
                    icon: "thermometer.snowflake",
                    title: "Cold-temperature limits shown where they begin",
                    detail: "An LNAV/VNAV line is not authorised below the temperature its plate publishes, and the limitation starts at the final approach fix. When the field is reporting colder than that, the vertical profile now marks the fix and shades the segment it applies to, rather than leaving it to be remembered. It is stated only when the temperature is known to be below the limit — an unknown temperature shows nothing."),
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "Alaska and Hawaii get their runway data back",
                    detail: "Runways, runway ends and frequencies were looked up by stripping the ICAO prefix, which only works in the lower 48: Bethel is PABE but its data is filed under BET, Adak PADK under ADK. 307 airports — 258 in Alaska, 20 in Hawaii, the rest in Puerto Rico, Guam, Samoa, the Marianas and the Virgin Islands — returned nothing at all, so the approach brief, the airport card and the runway diagram were blank for them."),
                WhatsNewHighlight(
                    icon: "ruler",
                    title: "Glidepath angles and runway detail from the source",
                    detail: "The runway database was being read for 15 of the 80 fields it publishes. Recovered: the visual glidepath angle for 7,463 runway ends, threshold crossing heights, runway markings, the controlling obstacle for 15,224 ends, weight-bearing capacity, and the hold-short line positions the FAA publishes coordinates for."),
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle.fill",
                    title: "One press for an engine failure",
                    detail: "A red button beside the logo, on screen on every tab. One press brings up the nearest-airport panel and lights the off-field layers below. It only ever arms — pressing it again re-arms rather than undoing it, because the outcome of pressing this in an emergency must never be that it went away. Press and hold to stand down."),
                WhatsNewHighlight(
                    icon: "scope",
                    title: "Where you can reach from where you are",
                    detail: "A live glide footprint swept against the terrain grid, shaded by how you would arrive: reachable, marginal, blocked by rising ground — and ground you would arrive at with more height than you can shed, which is a different problem from not reaching it at all. It is drawn from your present altitude and updates as you fly; with no trusted position or altitude it draws nothing and says why, rather than leaving a footprint on screen that describes a situation that has passed."),
                WhatsNewHighlight(
                    icon: "square.grid.3x3.square",
                    title: "Off-field landability, scored for your aeroplane (preview)",
                    detail: "Groundwork for a terrain layer that scores open ground the way a forced landing would care about: surface, slope, roughness, and a hazard field built from towers, roads and transmission corridors. The data is aircraft-agnostic and the scoring is not — your glide ratio and best-glide speed re-tint the same ground, so switching aircraft visibly changes the map. Tapping a cell lists the rules behind its score by name. NOT YET USABLE IN THIS BUILD: it needs a regional data pack, and there is no way to download one yet — the switch is present and will stay dark. Turning it on tells you that, rather than showing you an unchanged map. The glide energy bands above need no pack and work now. ADVISORY ONLY when it does arrive: it scores candidate ground, never a landing recommendation, and surface condition, fences, livestock and current obstructions are not modelled."),
            ]),
        ReleaseNote(
            build: 103, version: "1.0", headline: "Data the app had all along, finally reaching the chart",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.down.right.circle",
                    title: "Departures and arrivals draw in full",
                    detail: "A departure is published as several separate coded rows — the runway transition, the common route, and each enroute exit — and the app had been drawing only one of them. Measured against the current cycle, that meant the typical SID showed about a fifth of itself: Denver's EMMYS EIGHT drew 2 legs of 67, often starting tens of miles from the field with nothing joining it to the runway. Arrivals had a matching gap, where 1,423 of them lost their whole common segment because it is named \"ALL\" rather than left blank — taking 1,686 published crossing altitudes with it. Both now assemble the branch actually being flown."),
                WhatsNewHighlight(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Arcs curve, and airways follow their fixes",
                    detail: "DME arcs and RNP radius-to-fix turns were drawn as straight lines between their endpoints, cutting inside the real track by up to 13 nautical miles — at Pendleton the line ran directly over the VOR instead of arcing around it at 20 DME. Both now follow the published curve. A filed airway was drawn the same way: type \"GDM V1 ORW\" and you got a straight line with none of V1's fixes on it, and the distance, time and fuel were computed along that line."),
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle",
                    title: "Crossing altitudes that were being dropped",
                    detail: "Five ARINC altitude codes were not modelled, and refusing them discarded the ordinary crossing altitude published alongside — 5,856 legs across 4,576 approaches, including the FINAL APPROACH FIX itself on 1,187 of them. Bethel's ILS 19R publishes its final approach fix at 1,800 feet and the app drew nothing there, and never compared your altitude against it. Approaches at fields below sea level lost theirs too."),
                WhatsNewHighlight(
                    icon: "mappin.slash",
                    title: "Fixes that were on the wrong side of the country",
                    detail: "A short navaid identifier is only unique within its region, and the app resolved them globally, first match wins. San Angelo's NDB RWY 03 took its fix from San Juan, Puerto Rico — so the whole approach, including the missed-approach hold, was drawn 2,028 miles away, with distance and fuel computed along it. Nineteen published approaches were affected. All are corrected, and the map now refuses to draw an approach leg that cannot belong to its own airport."),
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "Airports that were showing as unknown",
                    detail: "Most fields on the map were drawing as the FAA's circled U — information lacking — even though their full record was already on board: 10,360 of them, including 6,880 private strips, 254 closed airports and 74 heliports, all rendered identically to each other. Separately, 707 charted airports were unreachable entirely because the app files them under one identifier and their procedures under another, hiding 1,271 approach plates. Both fixed."),
                WhatsNewHighlight(
                    icon: "chart.line.downtrend.xyaxis",
                    title: "The profile knows a decision altitude from a minimum",
                    detail: "Whether an approach is flown down to a decision altitude or levelled at a minimum descent altitude is printed on the plate and cannot be told from the procedure's name — \"RNAV (GPS) RWY 17\" is the title either way. The profile had been guessing from the title and drawing a glidepath through a decision altitude on 1,335 approaches that publish an MDA. It now reads your own plate, automatically, from the copy already on your device, and says nothing rather than guessing when it cannot. The vertical profile also now appears on 266 approaches where it simply did not draw."),
            ]),
        ReleaseNote(
            build: 102, version: "1.0", headline: "The minimums, read off your own plate",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.down.to.line",
                    title: "Minimums, answered",
                    detail: "Open a plate and tap Minima. Pick your approach category and the line you are flying, and you get ONE decision altitude and ONE visibility instead of a table to interpret — with the figure it was read from shown underneath so you can check it against the chart in a couple of seconds. Categories the plate does not publish are blacked out, because that is information. The plate's own conditional notes become questions you answer: Boston's \"when the control tower reports tall vessels in the approach area\" is a switch that swaps 218/RVR 1800 for 374/RVR 4000, rather than fine print to notice under load. Inoperative approach lighting, a remote altimeter setting and the cold-temperature limit on LNAV/VNAV are applied for you, each one showing where the rule came from. Minima are chart-only data, so every figure is read from the plate you already downloaded — and anything that does not read cleanly is reported as a gap rather than guessed at."),
                WhatsNewHighlight(
                    icon: "list.number",
                    title: "Which approach gets you lowest",
                    detail: "An airport binder with more than one approach now has a By minima button: every approach ranked by the lowest line it publishes for your category, naming that line, so \"the ILS gets you to 218\" is only claimed when you can fly the ILS. Ties break on visibility. Approaches that could not be ranked are listed separately with the reason instead of being quietly dropped."),
                WhatsNewHighlight(
                    icon: "mountain.2.fill",
                    title: "Terrain you can actually see on the dark chart",
                    detail: "The decluttered night base was rendering low ground DARKER than the land silhouette around it and almost exactly the same as the ocean, so the coastline stopped reading and mountains carried about 1.16:1 of contrast — which is to say none. The relief has been rebuilt: sea-level land now sits just above the silhouette, the ranges open upward, and the shading was pivoted on flat ground after measuring that the old mapping could never reach the top of its own range. The amber route is still the brightest thing on the map."),
                WhatsNewHighlight(
                    icon: "square.grid.3x3",
                    title: "Fixed: the chart going soft too early, and low-resolution strips",
                    detail: "Zooming out dropped the chart to a coarser tile half a zoom before it needed to, so half of every zoom range was drawn magnified. That transition now happens where it should, and the chart is never blown up. Separately, strips of very low resolution ran along the seams between adjacent sectionals: charts are cut to their neatlines so neighbours show through, but only one of the two was being drawn, leaving a transparent column one tile wide with a heavily magnified base showing through it. Overlapping charts are now composited the way they were built to be."),
                WhatsNewHighlight(
                    icon: "bell.badge",
                    title: "NOTAMs, pinned to the approach you are flying",
                    detail: "The airport card's NOTAM tab now pulls the real feed and pins what bears on the procedure in use — runway closures, navaids and lighting out of service, approach-not-authorised notices — with the full list one tap away and the counts stated. Nothing is ever filtered out: a NOTAM this cannot categorise is shown at the TOP rather than set aside, and one that names no runway is treated as applying to all of them. The FAA's NOTAM service needs a free developer key, so add one in Settings under NOTAM feed; until you do, the tab says exactly that rather than showing an empty list, because an empty list would read as there being no NOTAMs."),
            ]),
        ReleaseNote(
            build: 101, version: "1.0", headline: "See where you are on the glidepath",
            highlights: [
                WhatsNewHighlight(
                    icon: "chart.line.downtrend.xyaxis",
                    title: "A vertical profile for the approach you are flying",
                    detail: "Load an approach and a side-on view of the final segment appears above the map, with your aeroplane drawn in it. It reads left to right the way the profile on a plate does: the published path, every fix with its crossing altitude, the FAF and the missed approach point, and the ground underneath. Instead of comparing a DME distance against a printed altitude while flying, you can see whether you are on the path, above it or below it — and by how many feet. A precision approach draws its glidepath as a solid line; a non-precision one draws its crossing altitudes as steps, because those are limits you descend within rather than a beam you track. Decision altitudes and MDAs are not in the coded procedure, so the profile never prints one — the plate is still the authority for minimums."),
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "Fixed: online traffic never appeared if you own a Stratux",
                    detail: "If you had ever switched the Stratux link on in Settings, the internet traffic feed shut itself off whenever the app came to the foreground — whether or not the receiver was actually powered on, in range, or connected. On cell data, away from the aircraft, that meant no traffic from either source and a status pill that said Stratux was providing it. The online feed now stands down only for a receiver that is genuinely talking, and takes over again within one poll if the link drops."),
                WhatsNewHighlight(
                    icon: "doc.text.image",
                    title: "Fixed: the plate disappearing, and a Smart base to read it against",
                    detail: "Opening a plate could leave the map framed somewhere else entirely, which looked like the plate vanishing — most often on the Dark chart. The map now frames on the plate itself, every time. The plate menu also gained a \"Smart base\" button: one tap swaps the chart underneath for the decluttered dark base so the sectional's ink stops fighting the approach chart's, and one tap puts your chart back. Airspace is no longer hidden on that base — a Class B shelf is a constraint on where you may legally be, not clutter."),
                WhatsNewHighlight(
                    icon: "wind",
                    title: "Winds aloft: bigger, clearer, and honest about their age",
                    detail: "Panning the map used to stretch every wind streak in the direction you dragged, which looked like the wind changing as you moved the chart. Fixed — the streaks now show wind and nothing else. The sprites are twice the size by default, with size and contrast sliders and a colour picker in the layers menu (a single bright colour reads far better against a night chart than the speed spectrum does). And a stamp on the chart itself now names the valid time in Zulu, because animated particles look live whatever their age."),
                WhatsNewHighlight(
                    icon: "mountain.2",
                    title: "Fixed: phantom terrain that could hide an emergency airport",
                    detail: "The bundled elevation grid carried false high ground in flat country — 1,558 ft on Nantucket, where nothing is above 110 ft, and similar around Martha's Vineyard, the Outer Banks and the Mississippi delta. NRST sweeps that grid, so an invented ridge beside a sea-level island field could report the only airport within glide as blocked. The grid has been rebuilt; every real summit is unchanged."),
            ]),
        ReleaseNote(
            build: 100, version: "1.0", headline: "Winds aloft, a night chart, and somewhere to put it down",
            highlights: [
                WhatsNewHighlight(
                    icon: "cross.circle",
                    title: "NRST: where can you glide to, right now",
                    detail: "A new NRST button on the map answers the engine-out question. It takes your altitude and your aircraft's best-glide ratio, works out every airport inside the glide cone, and then SWEEPS THE TERRAIN along each direct path against the bundled elevation grid — so a field that is inside your range but behind a ridge is shown as blocked rather than offered. What survives is ranked the way a pilot would: reachable and clear first, then weather (a field reporting VFR always outranks one reporting IFR, however long its runway), then terrain around the field, then runways, then fire/rescue and services. Tap DIRECT and the route goes there immediately — no confirm alert, because one tap on \"Restore plan\" puts your filed route AND your loaded approach back exactly as they were. Still air, and the arrival reserve keeps you over the field at pattern height."),
                WhatsNewHighlight(
                    icon: "moon.stars.fill",
                    title: "A new \"Dark (minimal)\" chart",
                    detail: "A fifth base layer for night and IMC: a near-black chart with soft terrain relief, your route in amber, and every waypoint on it marked with its ident and its published crossing restrictions. Everything you are NOT flying — airways, airspace, off-route navaids and fixes — is taken away. Airports stay. Nothing that warns you is ever decluttered: TFRs, traffic, weather radar, holds and your own aircraft are all still there."),
                WhatsNewHighlight(
                    icon: "arrow.triangle.turn.up.right.circle",
                    title: "Published holds, with the right entry",
                    detail: "Load an approach and any holding pattern it publishes — the hold in lieu of a procedure turn at the front, the hold that ends the missed approach — is drawn on the map as a real racetrack, on the correct side, with the entry (direct, parallel or teardrop) worked out for the direction you are actually arriving from. Left-hand patterns are drawn and entered left-hand. The course reversal can be skipped in one tap when you have been cleared straight in or vectored to final; the missed-approach hold stays, because it is where the go-around ends."),
                WhatsNewHighlight(
                    icon: "wind",
                    title: "Animated winds aloft on the map",
                    detail: "Switch on \"Winds aloft\" in the layers menu and the chart fills with drifting wind streaks, coloured by speed — blue in calm air through to violet in a jet core. It is the same read as a Windy-style wind map: you see where the flow is going, where it shears, and where the jet sits, without reading a single number. Data is NOAA's GFS model, fetched for whatever area you are looking at."),
                WhatsNewHighlight(
                    icon: "slider.vertical.3",
                    title: "An altitude slider down the left edge",
                    detail: "Ten levels, surface to FL390, labelled the way you would file them. Moving it is instant — the whole column downloads at once, so switching from 5,000 ft to FL340 never waits on the network. Handy for the actual question: would climbing get you out of the headwind?"),
                WhatsNewHighlight(
                    icon: "clock.badge.checkmark",
                    title: "The model run is always on screen",
                    detail: "The chip under the slider names the GFS cycle and forecast hour it is showing and how long ago it was fetched, so you can see at a glance whether you are looking at fresh data. It is a model forecast, not an official briefing."),
                WhatsNewHighlight(
                    icon: "moon.stars",
                    title: "Night theme keeps its night vision",
                    detail: "Under the night theme — and on the new Dark chart, whatever theme you are in — the wind colours switch to red-only intensity instead of the full spectrum, so the overlay never floods the cockpit with the blue light your dark adaptation is most sensitive to."),
                WhatsNewHighlight(
                    icon: "checkmark.seal",
                    title: "Fixes that came out of flying all of this together",
                    detail: "The altitude slider's two lowest levels could sit underneath the Transcript card on an 11-inch iPad, where their taps went to the card — every level is now reachable on every device, and so is the NRST button when an airport card is open. The wind chip now says \"Paused — device warm\" instead of quietly showing a model run for a layer the heat protection has stopped. And \"Restore plan\" now puts your approach back armed, not just your route."),
            ]),
        ReleaseNote(
            build: 99, version: "1.0", headline: "Radar loads on its own, and the controls sit where they belong",
            highlights: [
                WhatsNewHighlight(
                    icon: "cloud.rain",
                    title: "Fixed: weather radar never started after a restart",
                    detail: "If you left the radar layer switched on, a fresh launch never actually started fetching it — the map sat on \"Loading radar…\" for the whole session, and the only way out was to toggle the layer off and back on. Every other live layer was being restarted at launch; radar was the one that was missed."),
                WhatsNewHighlight(
                    icon: "rectangle.bottomthird.inset.filled",
                    title: "The radar play/scrub bar is flush with the bottom bar",
                    detail: "It used to float in the middle of the lower map, and it could overlap the data-expiry notice. It now sits directly on the GPS bar — or on the tab bar when the GPS bar is hidden."),
                WhatsNewHighlight(
                    icon: "scope",
                    title: "Radar loads the area you're looking at first",
                    detail: "The loop used to warm a single tile near the aircraft, so panning ahead to read weather along the route left the screen filling in slowly. It now loads the tiles actually on screen, working outward from the middle."),
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "The traffic indicator tells you the truth",
                    detail: "The traffic pill showed a spinning \"Loading traffic…\" whenever no aircraft had arrived — including when the feed was not running at all. It now says what is actually happening and what to do: paused for Standby, paused in the background, idle, or genuinely unavailable."),
            ]),
        ReleaseNote(
            build: 98, version: "1.0", headline: "TFRs draw their real shapes — and tell you why they exist",
            highlights: [
                WhatsNewHighlight(
                    icon: "exclamationmark.octagon",
                    title: "Fixed: multi-area TFRs drew a bogus wedge",
                    detail: "A NOTAM that defines several areas — the Washington DC SFRA and its inner Flight Restricted Zone are two — was drawn as one connected outline, which smeared a wedge between the areas that restricted nothing. Each area now draws as its own shape with its own altitude block, matching the official FAA graphic. About half the live feed also encodes its circle twice; the duplicate is now recognized and drawn once."),
                WhatsNewHighlight(
                    icon: "questionmark.circle",
                    title: "Tap a TFR to see why it exists",
                    detail: "The TFR card now states the reason for the restriction, read from the NOTAM itself — \"to provide a safe environment for fire fighting aircraft operations\", \"national defense airspace\", \"protection of large public gatherings\" — alongside the altitudes, times, and the link to the full NOTAM. Where a NOTAM's areas carry different altitude limits, the card says so instead of showing one number as if it applied everywhere."),
                WhatsNewHighlight(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Fixed: internet traffic never loaded without a GPS fix",
                    detail: "The live traffic layer polls around your position — but before a GPS fix existed it had no center at all, so it sat on \"Loading traffic…\" forever. It now loads around whatever the chart is showing, then follows the aircraft once a fix arrives."),
            ]),
        ReleaseNote(
            build: 97, version: "1.0", headline: "Airport symbols show the runways you can actually use",
            highlights: [
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "Only paved runways are drawn",
                    detail: "Every published runway used to be drawn the same way, so a field with one paved strip and four gravel ones looked like it had five ways to land — Truth or Consequences is exactly that. The symbol now draws only paved, in-service runways. Across the country that removes about 15,800 marks: grass, gravel, dirt, water, landing mats and rooftops."),
                WhatsNewHighlight(
                    icon: "circle",
                    title: "Grass and water fields read as grass and water fields",
                    detail: "A soft-surface field now gets the plain open circle the sectional uses, instead of a runway outline that implied pavement. Helipads are no longer drawn as runway strips across an airport that has none."),
                WhatsNewHighlight(
                    icon: "checkmark.shield",
                    title: "Fixed: airport and runway data could come back empty",
                    detail: "A memory bug in the airport database reader let a lookup key be freed while the query was still using it, so airport, runway and frequency results could intermittently return nothing or garbage. It affected builds 92 through 96. Found by chasing an intermittent test failure I had twice written off as flaky — it was not."),
                WhatsNewHighlight(
                    icon: "checkmark.seal",
                    title: "The surface comes from the FAA, not an estimate",
                    detail: "Whether a field counts as hard-surfaced is now read from the published runway record rather than a value inferred from a weather feed. Where the FAA lists a mixed surface, the order tells you which is primary — asphalt with a turf shoulder is paved, a grass strip with some paving is not."),
            ]),
        ReleaseNote(
            build: 96, version: "1.0", headline: "A new look: cinematic cockpit, day, and night themes",
            highlights: [
                WhatsNewHighlight(
                    icon: "circle.lefthalf.filled",
                    title: "The whole app has been restyled",
                    detail: "Pure-black cockpit theme with a single sectional-blue accent, a flat-white day theme, and a true red night-vision theme. Industrial condensed typography, hairline separators, and flat surfaces replace the old glassy look — it should read like avionics, not a consumer app."),
                WhatsNewHighlight(
                    icon: "moon.fill",
                    title: "Night mode is now dark-adaptation safe",
                    detail: "In the Night theme the chart dims and desaturates under a faint red wash, callsign and speaker colors shift to warm reds and ambers, approach plates open pre-inverted, and the whole interface emits essentially no blue or green light. TFRs stay the brightest, most alarming mark on the map."),
                WhatsNewHighlight(
                    icon: "sun.min",
                    title: "Chart brightness is yours to set",
                    detail: "A new Chart Brightness slider in the Map layers panel dims the FAA chart imagery only — your route, traffic, TFRs and labels stay at full strength. It scales each theme's own level, so you can trim glare in the day and deepen the dim at night."),
                WhatsNewHighlight(
                    icon: "paintpalette",
                    title: "Switch themes from Settings too",
                    detail: "The theme picker now also lives in Settings → General → Appearance, alongside the quick switcher in the map's top bar. The map recolors in place when you switch — no reload, no lost position."),
                WhatsNewHighlight(
                    icon: "pencil.and.scribble",
                    title: "Notes: the pencil palette puts itself away",
                    detail: "Closing a note no longer leaves the drawing tool palette floating over the bottom tab bar."),
            ]),
        ReleaseNote(
            build: 95, version: "1.0", headline: "A live TFR opens first, and your offline kit survives an interrupted update",
            highlights: [
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle.fill",
                    title: "Live TFRs are back at the top of a tap",
                    detail: "Build 93 promoted restricted areas above nearby waypoints, which was right — but it accidentally pushed LIVE temporary restrictions below the permanent ones, so the only thing on the list with a reason and an expiry ended up underneath the chart furniture. A live TFR now opens first, then standing prohibited and national-defense areas, then fixes and navaids, then ordinary Class B/C/D."),
                WhatsNewHighlight(
                    icon: "list.bullet.rectangle",
                    title: "No more duplicate rows in the tap list",
                    detail: "The same restriction could appear two to four times with nothing to tell the rows apart. Where an area is genuinely published in separate altitude shelves — White Sands R-5111C runs 13,000 to 24,000 and again from 45,000 up — both now show with their altitudes, and a truly duplicated record collapses to one."),
                WhatsNewHighlight(
                    icon: "internaldrive.fill",
                    title: "An interrupted chart update no longer forgets what you had",
                    detail: "The app recorded which regions you had downloaded only as each one finished, and a new cycle clears that record first — so an update stopped partway left it believing you had only ever wanted the few that completed, and the next cleanup deleted the rest. Your full list is now recorded before anything downloads."),
                WhatsNewHighlight(
                    icon: "map",
                    title: "Both map engines behave the same",
                    detail: "The classic map is what you land on if the main engine stalls in flight. It now uses the same tap ordering as the globe, so a restriction opens the same way whichever engine you are on."),
            ]),
        ReleaseNote(
            build: 94, version: "1.0", headline: "Your downloaded charts survive a cycle change",
            highlights: [
                WhatsNewHighlight(
                    icon: "internaldrive",
                    title: "Downloaded charts are no longer deleted at a cycle rollover",
                    detail: "The app matched a chart file to its region by splitting the filename at the last dash — but a chart cycle is a date like 05-14-2026, which has dashes of its own, so nothing ever matched. The cleanup that runs at a new cycle is supposed to spare the charts you deliberately downloaded, and it could not recognise a single one of them. If you have downloaded regions for offline use, this is the fix that keeps them."),
                WhatsNewHighlight(
                    icon: "wifi.exclamationmark",
                    title: "Checking for charts while offline no longer blanks the map",
                    detail: "Tapping \u{201C}check for a new cycle\u{201D} without a connection discarded the chart index and did not put it back, so the map stopped drawing charts that were sitting on the device and the expiry warning quietly disappeared. The index is now kept whenever the check fails."),
                WhatsNewHighlight(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Cycle updates respect a metered connection",
                    detail: "A cycle update could start a multi-gigabyte download over cellular or a hotspot without asking — every other bulk download in the app already checked. It now skips and tells you to reconnect to Wi-Fi."),
                WhatsNewHighlight(
                    icon: "text.bubble",
                    title: "Straight answers about chart currency",
                    detail: "The expiry notice claimed a newer cycle had been published while the check underneath it reported none available. The notice now states only what it knows, and the check reports what the server actually offers."),
            ]),
        ReleaseNote(
            build: 93, version: "1.0", headline: "Restricted airspace you can see, and charts you can actually update",
            highlights: [
                WhatsNewHighlight(
                    icon: "exclamationmark.octagon",
                    title: "National defense areas are visible again",
                    detail: "Build 92 dimmed the standing national-defense areas almost to nothing while trying to tell them apart from live TFRs — which left red altitude numbers floating with no shading under them. They are drawn clearly again, and now carry a NAT’L DEFENSE label so you can tell what they are without tapping. Prohibited and restricted areas show their designator the same way. Live TFRs draw brighter still."),
                WhatsNewHighlight(
                    icon: "hand.tap",
                    title: "Tapping a restriction opens the restriction",
                    detail: "Airspace you may not simply fly into — national defense, prohibited, restricted — now goes to the top of the tap list. It used to sit below every nearby waypoint, so tapping one in a busy area opened on a VOR and you never reached the row explaining what you were pointing at. Class B, C, D and MOAs stay where they were, so tapping an airport still opens the airport."),
                WhatsNewHighlight(
                    icon: "arrow.down.circle",
                    title: "The chart update button now does something and tells you what",
                    detail: "Checking for a new cycle used to complete silently, so there was no way to tell a successful check from a broken button. It now says what it found: if a newer cycle exists it downloads replacements for the charts you already had, and if none has been published yet it says so plainly rather than leaving you guessing."),
                WhatsNewHighlight(
                    icon: "ant",
                    title: "Crash reports from the map engine are readable",
                    detail: "Debug symbols for the custom map renderer are included again, so a crash inside the globe reports where it happened instead of an address."),
            ]),
        ReleaseNote(
            build: 92, version: "1.0", headline: "Approach data you can trust, and a globe without seams",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.triangle.branch",
                    title: "Y and Z approaches are finally told apart",
                    detail: "Two RNAV approaches to the same runway are not the same procedure — they have different minimums, different step-down fixes, and different missed approaches. The app used to show both as one name, so the Activate list gave you two identical rows. It now carries the published letter, and if the exact approach on your plate isn’t coded, it offers nothing rather than something close. RNP approaches, which need specific authorization, no longer come up when you asked for the ordinary RNAV."),
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle",
                    title: "Tap a TFR and find out why it’s there",
                    detail: "Live TFRs are now on by default and tap through to the reason, the effective times, the altitudes and the NOTAM. The permanent national-defense areas that used to look identical to them are drawn faintly and say what they are, so a red block on the chart is no longer ambiguous."),
                WhatsNewHighlight(
                    icon: "globe.americas",
                    title: "The globe no longer tears at the date line",
                    detail: "Looking toward the antimeridian showed a thin sheet of map stretched through the middle of the earth. Chart tiles and approach plates were being drawn as flat panels laid across a round planet; they now curve onto its surface properly."),
                WhatsNewHighlight(
                    icon: "arrow.down.to.line",
                    title: "An altitude advisory in the GPS bar",
                    detail: "When you’re approaching a fix with a published crossing altitude and your GPS altitude is well outside it, the ALT reading turns amber. Tap it to see the restriction and which fix it belongs to. It is deliberately quiet: it stays silent unless the fix is close, the GPS is healthy, and the difference is far larger than the normal gap between GPS and barometric altitude — your altimeter is still the authority. Speed limits are shown but never judged, because ground speed isn’t airspeed."),
                WhatsNewHighlight(
                    icon: "building.2",
                    title: "Every airport in the country, with its real frequencies",
                    detail: "Runway geometry now comes from the FAA’s own airport database, covering nearly 10,000 fields that previously had none. Frequency lists went from a handful per airport to the full published set — 211 at Dallas-Fort Worth alone — which also means the transcript corrector can verify far more of what it hears."),
                WhatsNewHighlight(
                    icon: "calendar.badge.exclamationmark",
                    title: "You’ll know when your data expires",
                    detail: "A notice appears app-wide when the procedures, plates or charts fall out of cycle, instead of waiting to be found in Settings. And a new AIRAC cycle can now be installed without waiting for an app update — verified before it replaces anything, with the built-in copy always kept as a fallback."),
                WhatsNewHighlight(
                    icon: "circle.hexagongrid",
                    title: "Smaller, quieter airport symbols",
                    detail: "The large flight-category ring is now a small colored dot in the corner of each airport symbol, and the runway marks are 30% smaller — so the airport reads as an airport first and the weather second."),
            ]),
        ReleaseNote(
            build: 91, version: "1.0", headline: "Real airport symbols, weather trends, and a map fix",
            highlights: [
                WhatsNewHighlight(
                    icon: "mappin.and.ellipse",
                    title: "Airports look like they do on a sectional",
                    detail: "Every airport on the map now draws its real FAA symbol: blue when the field has a control tower and magenta when it doesn’t, its actual runway layout, tick marks for fuel and a star for a rotating beacon, and the distinct symbols for heliports, seaplane bases, military fields, private and unverified airports. Long-runway fields drop the circle and show the runways themselves, exactly as the chart does."),
                WhatsNewHighlight(
                    icon: "circle.circle",
                    title: "Flight category at a glance",
                    detail: "A colored ring around each reporting airport shows its current flight category — green VFR, blue MVFR, red IFR, magenta LIFR. The symbol underneath keeps its FAA color, so you can read the conditions and the field type at the same time. Airports that aren’t reporting get no ring rather than a misleading one."),
                WhatsNewHighlight(
                    icon: "chart.line.downtrend.xyaxis",
                    title: "Where the weather is going, not just where it is",
                    detail: "The airport card now fits a trend across the last several observations: how fast the ceiling and visibility are moving, and the category projected an hour and two hours out — the question that actually matters when you’re still 45 minutes from the field. Fields going downhill fast get a marker on the chart, drawn heavier when the drop is projected to cross into a worse category."),
                WhatsNewHighlight(
                    icon: "square.3.layers.3d",
                    title: "Fixed: the map could come up with only the chart",
                    detail: "On some launches the map drew the chart and nothing else — no aircraft symbol, no route, no traffic, no airspace or airways. It depended on a startup race, so it came and went. The map now rebuilds its layers on whichever chart style it ends up using, so the full picture is always there."),
                WhatsNewHighlight(
                    icon: "calendar.badge.exclamationmark",
                    title: "Data currency you can see",
                    detail: "Approach procedures and downloadable charts now carry their source and cycle dates, with a badge that stays quiet while everything is current and speaks up when something is expiring, expired, or undated — including on the approach activation sheet, right where it matters. The downloadable chart catalog is currently out of cycle, and the app now says so instead of drawing it silently."),
            ]),
        ReleaseNote(
            build: 90, version: "1.0", headline: "A more accurate speech model that runs everywhere",
            highlights: [
                WhatsNewHighlight(
                    icon: "waveform.badge.magnifyingglass",
                    title: "New, more accurate Small model",
                    detail: "The Small speech model was retrained on a much larger, perfectly-labeled ATC dataset. It transcribes more accurately and — most importantly for readbacks — gets callsigns right more often and misreads them less. It updates automatically next time you’re online; the old model is cleaned up for you."),
                WhatsNewHighlight(
                    icon: "checkmark.circle",
                    title: "Small is now the only speech model",
                    detail: "The optional Large and Large V2 models were removed. They couldn’t run reliably on every supported device, and the new Small model now matches or beats them on real ATC audio while staying fast and light — so there’s one model, tuned to run well on your device."),
            ]),
        ReleaseNote(
            build: 88, version: "1.0", headline: "Sharper terrain height near mountains",
            highlights: [
                WhatsNewHighlight(
                    icon: "mountain.2.fill",
                    title: "Accurate AGL over peaks",
                    detail: "The built-in terrain map now reads mountain summits far more accurately, so your height-above-ground (AGL) is much closer to the truth in the high country — the elevation near sharp peaks was reading low, which made AGL read a little high. Over the western ranges it’s now within about 35 feet. It’s still a situational aid, not a terrain-avoidance system, and always errs toward showing you closer to the ground."),
            ]),
        ReleaseNote(
            build: 87, version: "1.0", headline: "GPS integrity, height above ground, and a satellite view",
            highlights: [
                WhatsNewHighlight(
                    icon: "location.slash",
                    title: "GPS accuracy & interference warnings",
                    detail: "CommSight now watches your GPS for trouble: it warns when accuracy degrades below what an approach needs, hides your aircraft rather than showing a position it doesn\u{2019}t trust, and \u{2014} using where the satellites actually are right now \u{2014} tells the difference between signal jamming and possible spoofing. Your position on the map is ringed by its accuracy and colored by how trustworthy it is. Awareness only; always cross-check your navaids."),
                WhatsNewHighlight(
                    icon: "mountain.2",
                    title: "Height above ground (AGL)",
                    detail: "The GPS bar can now show your height above the terrain, from a built-in elevation map of the Lower 48 \u{2014} handy when the device has no barometer. It reads \u{201C}SFC\u{201D} at the surface and stays blank rather than guess when the GPS altitude isn\u{2019}t good enough. It is a situational aid built from a public terrain model, not a terrain-avoidance system."),
                WhatsNewHighlight(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Satellites page",
                    detail: "A new Settings \u{203A} Satellites page shows where the GPS constellation is over you right now \u{2014} a sky plot, how many satellites are usable, and the resulting geometry (HDOP/VDOP/PDOP) \u{2014} then compares that prediction against the accuracy your device is actually reporting. Because Apple doesn\u{2019}t expose live satellite data to apps, these positions are computed from published orbits, and the page says so."),
            ]),
        ReleaseNote(
            build: 77, version: "1.0", headline: "Zoom controls + tidier layers menu",
            highlights: [
                WhatsNewHighlight(
                    icon: "plus.magnifyingglass",
                    title: "Manual zoom + center-on-aircraft",
                    detail: "A slim, semi-transparent control bar on the right edge of the map lets you zoom in / out and re-center on your aircraft with a tap \u{2014} handy with gloves or in turbulence. Turn it on or off in the map layers menu."),
                WhatsNewHighlight(
                    icon: "square.3.layers.3d",
                    title: "Two-column layers menu",
                    detail: "The map layers menu is now two columns \u{2014} base maps on the left, overlays and map controls on the right \u{2014} so it\u{2019}s far quicker to scan and less cluttered."),
            ]),
        ReleaseNote(
            build: 76, version: "1.0", headline: "Search results pin on the map",
            highlights: [
                WhatsNewHighlight(
                    icon: "mappin.circle.fill",
                    title: "Searched waypoints show a pulsing marker",
                    detail: "When you search the map for an airport, VOR, or fix, it now drops a highlighted, gently pulsing marker right where it is \u{2014} even if that layer is turned off \u{2014} so you can always see what you searched for. The marker clears when you close its card, unless you\u{2019}ve added it to your flight plan (then it stays as a route point)."),
            ]),
        ReleaseNote(
            build: 75, version: "1.0", headline: "Plates: back, swipe, edge-to-edge",
            highlights: [
                WhatsNewHighlight(
                    icon: "chevron.left",
                    title: "Back button + swipe-back in binders",
                    detail: "Opening an airport binder now gives a proper back button, and you can swipe from the left edge to go back to your binder list \u{2014} the same gesture as everywhere else in iOS."),
                WhatsNewHighlight(
                    icon: "rectangle.grid.2x2.fill",
                    title: "Edge-to-edge plate thumbnails",
                    detail: "Plate thumbnails now fill their tiles with no white border around the chart, sized to each plate\u{2019}s own shape \u{2014} two clean columns in portrait, three in landscape, grouped by category (Approaches by runway, Departures, Arrivals)."),
            ]),
        ReleaseNote(
            build: 74, version: "1.0", headline: "WX updates, radar scrubber, bigger plates",
            highlights: [
                WhatsNewHighlight(
                    icon: "arrow.clockwise.circle.fill",
                    title: "Update button for weather charts",
                    detail: "The WX tab has a one-tap update that re-downloads your charts, with a status color: green when your charts are current, yellow when some may be aging, red when they\u{2019}re out of date. It never clears a cached chart \u{2014} a failed refresh keeps the copy you already have."),
                WhatsNewHighlight(
                    icon: "slider.horizontal.below.rectangle",
                    title: "Radar loop scrubber + tidier status",
                    detail: "Scrub the weather-radar loop frame-by-frame on a time slider (past \u{2192} now \u{2192} forecast) to see exactly where the weather is heading. The radar \u{201c}loading\u{201d} status moved to a top corner with a buffering %, out of the way of the map."),
                WhatsNewHighlight(
                    icon: "rectangle.grid.2x2",
                    title: "Bigger plate thumbnails + zoom slider",
                    detail: "Plate binders now show large thumbnails \u{2014} two columns in portrait, three in landscape \u{2014} with a lower-right slider to size them to your liking. And the plate\u{2019}s corner gear now stays pinned to the chart\u{2019}s corner instead of drifting as you zoom."),
            ]),
        ReleaseNote(
            build: 73, version: "1.0", headline: "Offline safety + battery + WX polish",
            highlights: [
                WhatsNewHighlight(
                    icon: "externaldrive.badge.checkmark",
                    title: "Your downloaded charts are now protected",
                    detail: "Downloaded chart packs were living in a folder iOS can silently erase when storage runs low — they now live in protected storage that survives, and an existing download is migrated automatically. A chart-cycle rollover also no longer wipes your pinned downloads. Removing downloads now asks first."),
                WhatsNewHighlight(
                    icon: "bolt.badge.checkmark",
                    title: "Battery: the map recovers to the efficient engine",
                    detail: "If the GPU map stalled at launch, the app was stranded on the older, power-hungry map engine for the whole flight. It now automatically retries the efficient engine whenever you return to the Map tab."),
                WhatsNewHighlight(
                    icon: "cloud.sun.fill",
                    title: "Weather tab: favorites + fixes",
                    detail: "Star your go-to charts into a Favorites list on top; favorited charts are kept offline and never evicted. Fixed the GPS bar covering the bottom of charts in landscape, the radar-loop button hiding behind the tab bar, and radar dropping out when zoomed in or panned."),
            ]),
        ReleaseNote(
            build: 72, version: "1.0", headline: "Radar loop, ETE, chart times",
            highlights: [
                WhatsNewHighlight(
                    icon: "play.circle",
                    title: "Animated weather radar",
                    detail: "Play the radar as a loop (past \u{2192} now \u{2192} short-term forecast) so you can see which way the storms are moving. Tap the radar-loop button on the map when the radar layer is on. The radar also stays put now when you zoom in instead of dropping out."),
                WhatsNewHighlight(
                    icon: "timer",
                    title: "Time remaining (ETE) on the GPS bar",
                    detail: "The GPS bar now shows the time REMAINING to the next waypoint and to the destination as a countdown (e.g. \"1:23\"), alongside the clock arrival time \u{2014} not just clock times."),
                WhatsNewHighlight(
                    icon: "clock.badge.checkmark",
                    title: "Chart release times + shareable battery log",
                    detail: "Each weather chart shows when NOAA released it, in your iPad\u{2019}s local time. And the battery diagnostics can now be shared as a file (AirDrop / Mail / Save to Files), including the per-activity CPU breakdown \u{2014} no more copying long logs by hand."),
            ]),
        ReleaseNote(
            build: 71, version: "1.0", headline: "Weather briefing tab",
            highlights: [
                WhatsNewHighlight(
                    icon: "cloud.sun.fill",
                    title: "New WX tab — NOAA charts, cached for offline",
                    detail: "A weather-imagery briefing room: GOES satellite (color, infrared, water vapor, regional close-ups), GFA cloud & surface-weather forecasts, WPC prog charts out to 60 h, convective forecasts (TCF 4/6/8 h + SPC Day 1–3 outlooks), precipitation probability & amounts, winds aloft for nine flight levels, icing & freezing levels, turbulence & LLWS, and active AIRMETs/SIGMETs. Every chart you open is saved on the device, so you can review it later with no signal — each shows when it was downloaded."),
                WhatsNewHighlight(
                    icon: "cloud.rain",
                    title: "Radar zoom fix",
                    detail: "The weather-radar layer no longer tiles \"Zoom Level Not Supported\" across the chart when zoomed in — the radar now upscales smoothly past its native resolution."),
                WhatsNewHighlight(
                    icon: "airplane",
                    title: "Traffic & radar loading status",
                    detail: "The map now says when traffic or radar is still loading, when a feed is unavailable, and when traffic is live with no aircraft nearby — so an empty sky is never ambiguous."),
            ]),
        ReleaseNote(
            build: 70, version: "1.0", headline: "Weather radar",
            highlights: [
                WhatsNewHighlight(
                    icon: "cloud.rain",
                    title: "Live precipitation radar on the map",
                    detail: "Turn on \"Weather radar\" in the map's Layers menu to see live precipitation (rain/snow) painted over your chart, updated continuously from a public radar feed. It's translucent so the chart still reads underneath, and it needs an internet connection."),
            ]),
        ReleaseNote(
            build: 69, version: "1.0", headline: "Online traffic layer",
            highlights: [
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "See nearby traffic without a Stratux",
                    detail: "Turn on \"Traffic (online ADS-B)\" in the map's Layers menu to stream nearby aircraft from a public ADS-B feed and see them on the map. It follows your position and needs only an internet connection — no receiver required. If you do have a Stratux connected, its on-board traffic is used instead. (It now works anytime the app is open, not just while transcribing.)"),
            ]),
        ReleaseNote(
            build: 68, version: "1.0", headline: "Route ETAs & flight replay",
            highlights: [
                WhatsNewHighlight(
                    icon: "clock.arrow.circlepath",
                    title: "Live ETAs on the GPS bar",
                    detail: "With a flight plan loaded, the GPS bar now shows your ETA to the next waypoint, your ETA to the destination, and the local arrival time at the destination — all from your present position and current ground speed."),
                WhatsNewHighlight(
                    icon: "play.circle.fill",
                    title: "Replay a logged flight",
                    detail: "Open any flight in the Logbook and press play — an aircraft retraces your route with the recorded altitude, ground speed and track at each point. Scrub the slider to any moment."),
                WhatsNewHighlight(
                    icon: "bolt.badge.clock",
                    title: "Battery improvements",
                    detail: "Tracked down a real-flight battery drain: the map now pauses when you're on another tab, the efficient map engine recovers on its own instead of getting stuck on the older one, and the diagnostics now record which map engine ran — so we can keep tightening it."),
            ]),
        ReleaseNote(
            build: 66, version: "1.0", headline: "Flight recorder & logbook",
            highlights: [
                WhatsNewHighlight(
                    icon: "record.circle",
                    title: "Record your flight",
                    detail: "Tap the new ⏺ button in the map's top bar to record. It leaves a breadcrumb trail of where you've been and tracks your GPS speed and altitude the whole way. Stop when you land and you'll be prompted to save the trip."),
                WhatsNewHighlight(
                    icon: "book.closed.fill",
                    title: "A logbook for your trips",
                    detail: "Every saved flight lands in the new Logbook tab with its time in flight, distance, top and average speed, altitude, the stops you made (with the nearest airport), the aircraft you flew, and room for your own notes — plus a map of the whole route."),
                WhatsNewHighlight(
                    icon: "location.north.line.fill",
                    title: "Live GPS bar",
                    detail: "Your live GPS quality, altitude, ground speed and track can now ride as a slim bar along the bottom of the screen (toggle it in the Widgets menu) — Stratux when connected, on-device GPS otherwise."),
            ]),
        ReleaseNote(
            build: 65, version: "1.0", headline: "TAFs, a GPS readout, and battery instrumentation",
            highlights: [
                WhatsNewHighlight(
                    icon: "cloud.sun.fill",
                    title: "TAFs load again",
                    detail: "The Terminal Aerodrome Forecast tab on the airport card was stuck loading forever — the fetch simply wasn't being kicked off. Fixed; open any airport → Weather → TAF."),
                WhatsNewHighlight(
                    icon: "location.north.line.fill",
                    title: "New GPS readout widget",
                    detail: "A GPS panel showing signal quality, altitude, ground speed and track. It uses your Stratux fix when connected (with satellite count), and falls back to the on-device GPS otherwise — with a badge so you always know which one you're seeing. Turn it on from the Widgets menu in the top bar."),
                WhatsNewHighlight(
                    icon: "gauge.with.dots.needle.bottom.50percent",
                    title: "Granular battery diagnostics",
                    detail: "Settings → General → Battery diagnostics now breaks the drain down by subsystem — live CPU load, the map's actual frame rate (to catch the map redrawing when it should be idle), and how much of each minute transcription is running — grouped by what the app was doing. This is how we pin down what's heating the device. Enable it, fly a session (try it once with transcription stopped for a clean read), then Copy the log."),
            ]),
        ReleaseNote(
            build: 64, version: "1.0", headline: "Map fixes from your feedback",
            highlights: [
                WhatsNewHighlight(
                    icon: "bolt.badge.checkmark",
                    title: "Cooler and lighter on the battery",
                    detail: "The map was quietly redrawing about once a second even parked, from GPS jitter nudging the ownship and traffic icons. It now only redraws when you actually move, and the renderer is capped to a battery-friendly frame rate — so the map idles closer to zero GPU. (Heads-up: live transcription itself is a heavy draw, so for a clean battery read, compare with transcription stopped.)"),
                WhatsNewHighlight(
                    icon: "location.north.line.fill",
                    title: "\"Direct to\" now starts at your position",
                    detail: "Sending a Direct-To (from the map or an ATC \"cleared direct\" call) now draws the course from your present GPS position to the fix — not from your flight plan's first waypoint. With no GPS fix it keeps the filed departure."),
                WhatsNewHighlight(
                    icon: "square.and.arrow.down.on.square",
                    title: "Charts load reliably after switching layers",
                    detail: "Switching to IFR-low/high over a slow connection could leave the chart blank until you panned. Freshly-downloaded charts now appear as soon as they finish, and a small pill tells you when charts are loading, need a zoom-in, or failed to download."),
            ]),
        ReleaseNote(
            build: 63, version: "1.0", headline: "A new, fully-offline chart engine",
            highlights: [
                WhatsNewHighlight(
                    icon: "map.fill",
                    title: "A faster, offline-first map",
                    detail: "The moving map now runs on a new GPU chart engine (MapLibre) built to sip power. It renders your FAA charts, route, airspace, airways, navaids, traffic, TFRs and approach plates entirely on-device — with NO internet needed. Even outside your downloaded charts you'll see a bundled world land-and-coastline base instead of a blank screen. This is the reason for the migration; please fly with it and tell us how the battery and warmth compare."),
                WhatsNewHighlight(
                    icon: "arrow.triangle.2.circlepath",
                    title: "The classic map is one tap away",
                    detail: "The new engine is on by default. If you ever prefer the previous map — or need a feature not yet moved over (the full-screen Route map, weather/hazard overlays, or the CIFP procedure preview line) — flip Settings → General → Map engine off to return to it instantly. And if the new map ever fails to draw, the app falls back to the classic map on its own, so you're never left without a chart."),
            ]),
        ReleaseNote(
            build: 62, version: "1.0", headline: "Lighter on the battery, and TAFs in plain English",
            highlights: [
                WhatsNewHighlight(
                    icon: "bolt.badge.a",
                    title: "The map sips less power",
                    detail: "Your position now shows as a single lightweight aircraft marker instead of the animated system dot, which was quietly running a second GPS and redrawing the map non-stop. The GPS also eases off when you're parked and pauses in the background — so the map runs much cooler while it sits open. (Turn on Settings → General → Battery diagnostics if you'd like to help us confirm the improvement.)"),
                WhatsNewHighlight(
                    icon: "text.alignleft",
                    title: "TAFs you can just read",
                    detail: "The TAF tab now translates each forecast period into plain English — \"From 01:00Z: wind from 320° at 6 kt, visibility 6+ SM, scattered clouds at 7,000 ft\" — with weather codes spelled out (BR → mist, TSRA → thunderstorm with rain). The raw coded TAF is still shown above it for those who prefer it."),
            ]),
        ReleaseNote(
            build: 61, version: "1.0", headline: "Approach fixes, FAA chart symbols, and fuller TFR info",
            highlights: [
                WhatsNewHighlight(
                    icon: "triangle",
                    title: "Approach fixes on the map",
                    detail: "Zoom in and you'll now see named approach and terminal fixes (from every instrument procedure), not just enroute GPS fixes — the nearest ones to what you're looking at."),
                WhatsNewHighlight(
                    icon: "hexagon",
                    title: "Real FAA chart symbols",
                    detail: "Navaids are drawn the way they look on a sectional: a VOR is a blue hexagon, a VORTAC has its corner spurs, a VOR-DME sits in a box, and an NDB is a magenta stippled circle. TACAN- and DME-only stations no longer borrow the VOR shape."),
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle",
                    title: "Fuller TFR and airspace info",
                    detail: "The TFR card now links straight to the official FAA NOTAM for the full text, and tapping a Restricted, Prohibited, Warning, Alert, or MOA area explains what it is and reminds you to check NOTAMs."),
            ]),
        ReleaseNote(
            build: 60, version: "1.0", headline: "TAFs, tap-a-TFR details, clearer map, and a battery meter",
            highlights: [
                WhatsNewHighlight(
                    icon: "wind",
                    title: "TAF + a reorganized Weather tab",
                    detail: "The airport Weather tab is now METAR · TAF · 7-Day · History. The new TAF sub-tab shows the raw Terminal Aerodrome Forecast plus decoded periods, and the 7-day outlook has its own tab."),
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle",
                    title: "Tap a TFR for the details",
                    detail: "Tapping a TFR now shows an Active / Upcoming / Expired badge, its effective and expiry times, the controlling ARTCC, floor/ceiling, and the full NOTAM description."),
                WhatsNewHighlight(
                    icon: "mappin.and.ellipse",
                    title: "Bigger icons, and GPS fixes on the map",
                    detail: "Map symbols are 25% larger for legibility, and named GPS/RNAV fixes (intersections) now appear as blue triangles when you're zoomed in — without crowding out airports or navaids."),
                WhatsNewHighlight(
                    icon: "battery.100.bolt",
                    title: "Battery meter (help us find the drain)",
                    detail: "Settings → General → Battery diagnostics can record, once a minute, the battery level and what the app is doing (transcription, map layer, GPS, Stratux), then show a real discharge rate — so we can pin down what actually uses power in flight. Off by default; flip it on for a session and Copy the log."),
            ]),
        ReleaseNote(
            build: 59, version: "1.0", headline: "Sturdier widget docking and a hardening pass",
            highlights: [
                WhatsNewHighlight(
                    icon: "rectangle.trailinghalf.inset.filled",
                    title: "Docking that only docks when you mean it",
                    detail: "Dragging a widget into a side panel now takes a deliberate push toward the edge — dragging a card up or down along an edge, or nudging it near one, no longer snaps it into a pane by accident. A real toss to the side still docks instantly."),
                WhatsNewHighlight(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Cleaner airways up north",
                    detail: "RNAV T-routes with long legs (common in Alaska) no longer show a false gap — only true route discontinuities are broken, so what you see matches the charts."),
                WhatsNewHighlight(
                    icon: "wrench.and.screwdriver",
                    title: "Reliability hardening",
                    detail: "A deep review pass tightened the model-loading recovery (a load interrupted by backgrounding is always recovered), so the app can't get stuck on “Loading…”, plus assorted robustness fixes throughout."),
            ]),
        ReleaseNote(
            build: 58, version: "1.0", headline: "A 7-day outlook, reliable airway altitudes, and a map that never blanks",
            highlights: [
                WhatsNewHighlight(
                    icon: "calendar",
                    title: "7-day weather outlook",
                    detail: "The airport card's Weather tab now shows the NWS 7-day forecast — day/night temps, wind, and conditions — under the live METAR. Reach it from the map or the new ⓘ on any row of the Airports tab."),
                WhatsNewHighlight(
                    icon: "arrow.up.and.down.circle",
                    title: "Airway altitudes, done right",
                    detail: "Tap an airway and you'll see its minimum enroute and maximum authorized altitudes. Airways with a revoked middle section no longer draw a fake straight line across the country, and same-named airways in different regions no longer share the wrong altitudes."),
                WhatsNewHighlight(
                    icon: "map.fill",
                    title: "The map never goes blank",
                    detail: "“Live map background” now defaults off to save battery — and with it off your FAA chart still shows everywhere it has coverage, with the base map filling any fringe. Picking Map or Satellite always shows that map."),
                WhatsNewHighlight(
                    icon: "cloud.sun",
                    title: "Weather that tells you the truth",
                    detail: "Airports that don't report a METAR now say so instead of spinning forever, and a dropped connection shows a clear “unavailable” you can retry."),
                WhatsNewHighlight(
                    icon: "checkmark.shield",
                    title: "Reliability pass",
                    detail: "A round of hardening: the airport info button now works for every airport, a tapped-object card updates when you tap something new, the Transcript tab's controls all work, and your own tail number is never stripped from a saved plan."),
            ]),
        ReleaseNote(
            build: 57, version: "1.0", headline: "Cooler map rendering, airway altitudes, and transcript controls",
            highlights: [
                WhatsNewHighlight(
                    icon: "battery.100.bolt",
                    title: "The map renders far cheaper",
                    detail: "FAA chart tiles now render natively instead of being converted one-by-one — the map's biggest remaining battery cost while panning. If chart tiles ever look blank, flip “Compatibility chart rendering” on the Downloads page."),
                WhatsNewHighlight(
                    icon: "shield.checkered",
                    title: "Nothing covers your plate anymore",
                    detail: "Airspace altitude boxes, navaid markers, and airway labels could draw ON TOP of an overlaid approach plate, masking it even at full opacity. Labels inside the plate's footprint are now hidden while the plate is up and return when you close it."),
                WhatsNewHighlight(
                    icon: "list.bullet.rectangle",
                    title: "Transcript tab, now with controls",
                    detail: "The Transcript tab carries the full control bar — input source, Start/Stop, flight plan, and settings — so you can run a session without switching to the Map. The tapped-airport card can also be docked to a screen edge as a side panel now, like any other widget."),
                WhatsNewHighlight(
                    icon: "arrow.up.and.down",
                    title: "Airway altitudes",
                    detail: "Tap an airway and its card now shows the FAA-coded minimum enroute altitude range (it varies segment to segment) and the maximum authorized altitude, alongside its class — Victor, Jet, or RNAV T/Q."),
            ]),
        ReleaseNote(
            build: 56, version: "1.0", headline: "Airways on the map, a richer airport card, and big battery savings",
            highlights: [
                WhatsNewHighlight(
                    icon: "battery.100",
                    title: "Much easier on the battery",
                    detail: "The speech model no longer loads when the app opens — it loads on your first Start instead, so launch touches no AI at all. Chart pre-downloads now wait a few seconds and only run on Wi-Fi. And turning “Live map background” off now keeps your FAA chart up (it used to blank the whole map) while completely stopping the Apple base map underneath — a real power saving in flight."),
                WhatsNewHighlight(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "Airways, drawn and tappable",
                    detail: "Victor and Jet routes (plus RNAV T/Q routes) now draw on the map with their idents, from the FAA's own data. Tap anywhere along one to identify it. Toggle in the map layers menu. Nearby airport and navaid markers are also bolder with black borders, so they pop on any chart."),
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "The airport card shows what matters",
                    detail: "Tap an airport on the map and the card now leads with its diagram thumbnail, flight-category flag, live weather, key frequencies, approach types, field elevation, and pattern altitude. The Weather tab shows the live METAR too. The Airports tab gains Favorites (star any field) and a Recent list."),
                WhatsNewHighlight(
                    icon: "square.and.arrow.down",
                    title: "Import a ForeFlight plan · notes on black",
                    detail: "Share a plan from ForeFlight (“Open in CommSight”) or use the Import button in the flight-plan strip to load a .fpl route. Notes now write on a black page with a white pen — strokes were invisible on the old light page in the dark cockpit UI. Also fixed: widgets docking to the screen edge now trigger when the card reaches the edge, and a leftover test aircraft (N8925T) is cleared from the plan."),
            ]),
        ReleaseNote(
            build: 55, version: "1.0", headline: "An Airports directory with live weather, and Plates binders",
            highlights: [
                WhatsNewHighlight(
                    icon: "airplane",
                    title: "New Airports tab",
                    detail: "Next to Plates: a ForeFlight-style airport directory. Each field shows its airport-diagram thumbnail plus a pilot caption — live weather with a colour-coded flight-category flag (VFR / MVFR / IFR / LIFR), the key frequencies, approach types, field elevation, and pattern altitude. Defaults to your route and nearby fields; search finds any airport."),
                WhatsNewHighlight(
                    icon: "books.vertical",
                    title: "Plates, organised into binders",
                    detail: "The Plates tab is now a set of binders — one per airport. Open a binder to browse its charts as LARGE thumbnails you can eyeball, grouped by category with approaches split out by runway, instead of a long text list. Airport diagrams render upright and readable."),
            ]),
        ReleaseNote(
            build: 54, version: "1.0", headline: "Transcript & Notes tabs, snap-to-side panels, and a cooler app",
            highlights: [
                WhatsNewHighlight(
                    icon: "rectangle.split.2x1",
                    title: "Snap a widget to the side",
                    detail: "Drag any floating widget (with one finger on its title bar, or two fingers anywhere) to the left or right screen edge and it docks as a resizable side panel — like snapping a window on a computer. Drag the panel's inner edge to resize it (it remembers the width), tap the ↗ button to pop it back out to a floating widget, and close it with the ✕ or a two-finger swipe. Drop a second widget on the same side and it takes over."),
                WhatsNewHighlight(
                    icon: "text.bubble",
                    title: "New Transcript and Notes tabs",
                    detail: "The bottom bar now has a Transcript tab on the far left (the live ATC transcript, full screen) and a Notes tab on the far right — hand-write notes with your finger or Apple Pencil and keep them in a library. There's also a quick transcript-widget on/off button in the input controls."),
                WhatsNewHighlight(
                    icon: "thermometer.snowflake",
                    title: "Runs much cooler on launch",
                    detail: "The app no longer heats up the moment you open it. Realistic 3D terrain is now an opt-in choice (turn it on in the Map layers menu) so the map opens flat and cool, and the AI-correction model now loads when you press Start instead of at startup."),
                WhatsNewHighlight(
                    icon: "doc.richtext",
                    title: "Airport diagram, front and center",
                    detail: "Tapping an airport on the map now shows its airport-diagram chart as a thumbnail right at the top of the info card. Tap the thumbnail to open the full plate in the Plates tab."),
            ]),
        ReleaseNote(
            build: 53, version: "1.0", headline: "Plate controls on the map, a smarter Plates tab, and multi-touch",
            highlights: [
                WhatsNewHighlight(
                    icon: "slider.horizontal.below.rectangle",
                    title: "Adjust or hide a plate right on the map",
                    detail: "Tap the small gear in the corner of a plate you’ve sent to the map and a menu drops down from the top: fade it with a transparency slider (which now genuinely lets the chart show through), flip it to night colors, open it full-page, or hide it. A plate can never go fully invisible, and the gear stays reachable even if you pan the plate toward the edge of the screen."),
                WhatsNewHighlight(
                    icon: "location.magnifyingglass",
                    title: "The Plates tab finds your airport",
                    detail: "The Plates tab now opens on the airport you’re actually at — using GPS — instead of a far-off filed destination, and it follows you as you fly. Search jumps to any field instantly. Approaches are grouped into tidy, collapsible per-runway sections instead of one long scroll."),
                WhatsNewHighlight(
                    icon: "map",
                    title: "Tap an airport to see its diagram",
                    detail: "Tapping an airport on the map now shows its airport diagram as a thumbnail in the info card. Tap the thumbnail to open the full plate in the Plates tab."),
                WhatsNewHighlight(
                    icon: "hand.draw",
                    title: "Move and resize with two fingers",
                    detail: "Drag a floating widget with two fingers to move it anywhere, pinch to resize it, and swipe up with two fingers to tuck away the top bars. Every button now gives a subtle tap you can feel — a small thing that makes the whole app feel more solid in the cockpit."),
            ]),
        ReleaseNote(
            build: 51, version: "1.0", headline: "Map reliability, cleaner plates, and organized settings",
            highlights: [
                WhatsNewHighlight(
                    icon: "thermometer.medium.slash",
                    title: "The map never blanks out anymore",
                    detail: "The map used to disappear behind a “paused to cool down” screen when the device got warm — a bad surprise in the cockpit. It now stays up no matter what. Under heat it just eases off quietly (the 3D terrain flattens and background weather layers pause) so it keeps running cooler without ever leaving you without a map."),
                WhatsNewHighlight(
                    icon: "doc.richtext",
                    title: "Approach plates just work on the map",
                    detail: "Plates you send to the map now place themselves precisely from the FAA’s built-in georeferencing — no more hand-nudging, resizing, or rotating. The only control left is a transparency slider, which now actually fades the plate. The “Send to map” button appears only on plates that can be placed accurately."),
                WhatsNewHighlight(
                    icon: "slider.horizontal.3",
                    title: "Settings, organized",
                    detail: "Settings is now grouped into clear categories — Transcription & AI, Audio & speakers, Traffic & connections, Charts & downloads, and General — instead of one long list."),
            ]),
        ReleaseNote(
            build: 49, version: "1.0", headline: "IFR high-altitude charts, a Downloads manager, and more weather",
            highlights: [
                WhatsNewHighlight(
                    icon: "airplane.circle",
                    title: "IFR high-altitude enroute charts",
                    detail: "The map layer switcher now has an IFR-H layer with the FAA high-altitude enroute charts — jet routes and high-altitude fixes — alongside VFR, IFR-low, Map, and Satellite."),
                WhatsNewHighlight(
                    icon: "arrow.down.circle",
                    title: "One place to manage offline downloads",
                    detail: "A new Downloads screen (Settings → Downloads) groups all offline content: VFR/IFR charts by region and approach plates by area. Every item shows whether it’s downloaded and — using the FAA’s cycle — whether it’s up to date, with per-region or download-all buttons."),
                WhatsNewHighlight(
                    icon: "mountain.2",
                    title: "3D terrain on the base map",
                    detail: "The Map and Satellite base layers now render realistic terrain relief, so mountains and valleys read at a glance when the FAA chart layers are off."),
                WhatsNewHighlight(
                    icon: "smoke",
                    title: "More weather & hazard detail",
                    detail: "A wildfire-smoke map layer, real magnitude units when you tap a hazard, and airport weather split into Current and Historical views — including best-time-of-day and seasonal wind charts."),
            ]),
        ReleaseNote(
            build: 47, version: "1.0", headline: "Airspace & TFR accuracy refinements",
            highlights: [
                WhatsNewHighlight(
                    icon: "scope",
                    title: "Curved TFR boundaries drawn correctly",
                    detail: "Some TFRs (notably rocket-launch areas) have curved arc edges. Those arcs are now drawn as true curves instead of being mis-plotted, so the restricted area's shape and extent match the official NOTAM. TFRs also survive a brief network drop now — a hiccup while refreshing no longer blanks the layer or throws away the last known set. Still awareness only; confirm against an official briefing."),
                WhatsNewHighlight(
                    icon: "hexagon",
                    title: "Consistent special-use airspace everywhere",
                    detail: "The full-screen route map now labels its airspace toggle “Airspace & special use” with a matching legend for Restricted, Prohibited, Warning, Alert, MOA, and TFR — same as the home map — and special-use names read correctly in the tap-to-identify card."),
            ]),
        ReleaseNote(
            build: 46, version: "1.0", headline: "Restricted airspace and live TFRs on the map",
            highlights: [
                WhatsNewHighlight(
                    icon: "exclamationmark.triangle.fill",
                    title: "Special-use airspace, colour-coded",
                    detail: "The map now draws special-use airspace over the whole country — Restricted, Prohibited, Warning, and Alert areas plus Military Operations Areas (MOAs) — each in its own colour, with a small block on the top edge showing the floor and ceiling (e.g. FL180 over the surface). It's built into the app, so it works with no signal. Toggle it under “Airspace & special use” in the layers menu."),
                WhatsNewHighlight(
                    icon: "exclamationmark.octagon.fill",
                    title: "Live TFRs, refreshed daily",
                    detail: "Turn on “TFRs (FAA, live)” in the layers menu and CommSight pulls the current Temporary Flight Restrictions from the FAA and draws them in red, with their altitudes on the edge. Tap one to see its type (security, hazard, VIP movement, airshow, space ops…), altitudes, NOTAM number, and description. It caches the last set for offline and shows how fresh it is. Awareness only — always confirm against an official briefing before you fly."),
            ]),
        ReleaseNote(
            build: 45, version: "1.0", headline: "Approach plates that align themselves — precisely",
            highlights: [
                WhatsNewHighlight(
                    icon: "scope",
                    title: "Every approach snaps onto the map exactly",
                    detail: "CommSight now reads the georeferencing the FAA embeds inside each approach chart, so plates drop onto the moving map at exactly the right place, scale and orientation — no dragging to line them up. This jumps from about 1,100 approaches to roughly 9,000 (nearly every US instrument approach), and it's precise, not approximate. Look for the ✛ marker on a plate. Still a visual aid — always fly the official published chart."),
            ]),
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
