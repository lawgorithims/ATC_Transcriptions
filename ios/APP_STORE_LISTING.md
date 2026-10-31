# Obelisk — App Store Connect submission pack

Paste-ready metadata for the 1.0 listing. Pairs with `APP_STORE_SUBMISSION.md`, which covers the
build and what still blocks it; this file is only what goes in the App Store Connect form.

Every character count below was measured against Apple's limit, not estimated.

---

## 0. The rename — already done, correctly

**Checked against App Store Connect on 2026-10-30: the record is already named `Obelisk EFB`,
still on bundle id `com.flycommsight.atctranscribe` (app id 6784833874).** So the rename landed the
right way — the existing record was renamed, not replaced. Nothing further to do here.

The bare name `Obelisk` was evidently unavailable, which §1 anticipated; `Obelisk EFB` was the
first fallback.

> One consequence worth knowing: the **store listing** reads `Obelisk EFB` while the **home-screen
> name** (`CFBundleDisplayName`) is just `Obelisk`. That is normal and usually desirable — the
> store name carries the search term, the icon caption stays short — but they are two different
> fields and they will not track each other automatically.

The reasoning is kept below, because it is the thing to re-read if anyone proposes a new record
later.

**It does not need a new app record, and creating one would cost real things.**

The App Store **name** is an editable text field. What is permanent is the **bundle ID**, and
`com.flycommsight.atctranscribe` is unchanged in this build precisely so the existing record keeps
working. Two app records cannot share a bundle ID, so "make a new app called Obelisk" really means
"abandon the old record and mint a new bundle ID", which costs:

- every TestFlight tester, re-invited from scratch;
- the build history (you would restart at build 1, and the old record's numbers stay burned);
- the App ID, its provisioning, and the Sign in with Apple capability, all set up again;
- the SKU `commsight-ios`, which is fixed at creation either way.

**Rename the existing record instead:** App Store Connect → the app → **App Information** →
*Localizable Information* → **Name**. Change `CommSight` to `Obelisk`, and set **Subtitle** while
you are there. The app has never been publicly released (TestFlight only), so this edit is
straightforward; for a live app the new name would ship with the next approved version.

Three things that do **not** change, and that nobody sees:

| Field | Value | Why it stays |
|---|---|---|
| Bundle ID | `com.flycommsight.atctranscribe` | immutable on an existing record |
| SKU | `commsight-ios` | fixed at app creation, permanently |
| Apple ID (numeric) | unchanged | Apple's own key for the record |

⚠️ **"Obelisk" may already be taken.** App Store names are globally unique. If Apple rejects it,
the fallbacks in §1 are ready. Check availability *before* you plan the launch around the bare
name.

---

## 1. Name, subtitle, keywords

| Field | Value | Count |
|---|---|---|
| **Name** | `Obelisk EFB` — **in use** | 11 / 30 |
| ↳ was preferred | `Obelisk` (apparently unavailable) | 7 / 30 |
| ↳ other fallback | `Obelisk Flight Bag` | 18 / 30 |
| **Subtitle** | `Offline electronic flight bag` | 29 / 30 |
| ↳ alternative | `Charts, plates & planning` | 25 / 30 |

**Keywords** (94 / 100) — comma-separated, no spaces, and deliberately free of words already in the
name or subtitle, since Apple indexes those anyway and repeating them wastes the budget:

```
aviation,sectional,VFR,IFR,approach,plate,METAR,TAF,ADS-B,pilot,chart,airport,glide,TFR,navlog
```

Note the name is now `Obelisk EFB`, so **EFB** is already indexed — do not spend keyword budget on
it. "electronic flight bag" is likewise covered by the subtitle.

**Promotional text** (142 / 170) — editable any time without review, so this is the field to use
for cycle news:

```
Cycle 2611 is aboard. Offline FAA charts, coded approaches, georeferenced plates and engine-out glide planning — built to work with no signal.
```

---

## 2. Description

Under the 4,000-character limit. Written from what the build actually does — nothing here describes
a feature that is compiled out.

```
Obelisk is an electronic flight bag that works with no signal.

Charts, procedures, plates and planning all run on your device. There is no account to create
before you can fly, nothing about your flying leaves the iPad, and the moving map keeps working
when the cell service does not.

OFFLINE CHARTS
• FAA VFR sectionals and IFR low and high enroute charts, full CONUS
• Download by route or by area, then fly them with no connection
• Cockpit, Day and Night themes — Night emits red only, to protect dark adaptation

PROCEDURES AND PLATES
• Coded approaches, SIDs and STARs drawn on the map, with holds and a vertical profile
• Around 9,900 georeferenced approach plates: your aircraft on the plate, and the plate as a
  map layer
• Terminal procedure charts for more than 3,100 airports

AIRPORTS
• A nationwide directory — over 19,000 airports, runway geometry and 40,000+ frequencies
• Field elevation, runway dimensions, and the frequencies you actually need on the ramp

WEATHER AND HAZARDS
• METAR, TAF and a 7-day outlook, with flight category at a glance
• Radar, animated winds aloft, and density altitude
• Temporary Flight Restrictions and natural-hazard events on the map

WHEN THE ENGINE QUITS
• Nearest-airport ranking by what you can actually glide to, not just what is closest
• Glide footprint on the map, height above ground, and a departure turnback briefing built
  around a number you set yourself from practice — Obelisk never invents one for you

FLIGHT PLANNING
• Type a route in plain language and see it on the chart
• Import and export Garmin .fpl, including straight from ForeFlight's share sheet
• A logbook and a hand-written note library that travel with you

TRAFFIC
• Live ADS-B traffic over the internet, or from a Stratux receiver on the aircraft's own Wi-Fi

NAVIGATION DATA THAT TELLS YOU THE TRUTH
Obelisk ships with a current FAA cycle and updates procedures, airports and the plate index over
the air. When a dataset goes out of cycle it says so, in a banner you cannot miss. Expired data
that looks authoritative is the failure this app is built to avoid, so currency is never behind a
paywall.

IMPORTANT
Obelisk is an aid to situational awareness. It is not certified for navigation and does not replace
official charts, an official weather briefing, or the pilot in command's judgement. Always verify
against current official sources.

Requires iOS 17 or later. iPhone and iPad.
```

---

## 3. URLs, category, rating

| Field | Value |
|---|---|
| **Privacy Policy URL** | `https://obeliskaerospace.com/legal/privacy` |
| **Support URL** | `https://obeliskaerospace.com` |
| **Marketing URL** | `https://obeliskaerospace.com` |
| **Copyright** | `2026 Obelisk Aerospace LLC` |
| **Primary category** | Navigation |
| **Secondary category** | Weather |
| **Age rating** | 4+ — no objectionable content; answer "None" to every questionnaire item |
| **Pricing** | Free (no in-app purchases in this build — see §5) |

✅ The privacy policy URL resolves — `https://obeliskaerospace.com/legal/privacy` returns 200,
checked 2026-10-30. A reviewer will be able to open it.

---

## 4. App Privacy answers

These must agree with `ATCTranscribe/PrivacyInfo.xcprivacy` — Apple compares them.

**"Do you or your third-party partners collect data from this app?" → Yes.**

| Data type | Linked to identity | Used for tracking | Purpose |
|---|---|---|---|
| Contact Info → **Email Address** | Yes | No | App Functionality |
| Contact Info → **Name** | Yes | No | App Functionality |
| Identifiers → **User ID** | Yes | No | App Functionality |
| Location → **Precise Location** | **No** | No | App Functionality |

Answer **No** to tracking across apps and websites, and leave the tracking-domains list empty.

Everything else is **not** collected: no usage data, no diagnostics, no contacts, no photos, no
purchase history, no search history, no identifiers beyond the account's own user id.

Two answers that deserve a sentence of reasoning, in case a reviewer asks:

- **Email, name and user id are collected only if the pilot signs in.** The account is optional;
  an app that is never signed into makes no request to our servers at all.
- **Precise location is "collected" but NOT linked.** With the online traffic layer switched on,
  the app asks `api.airplanes.live` for traffic around a point, and that point is ownship's
  position. It is a third-party request, so it is declared. It is unlinked because that request
  carries no account, no device id and no cookie. Nothing else sends position anywhere — the map,
  plates, glide rings and logbook are all computed on-device.

---

## 5. App Review notes

Paste into **App Review Information → Notes**. Written to pre-empt the three questions this app
will actually draw.

```
WHAT THIS APP IS
Obelisk is an electronic flight bag for general-aviation pilots. Charts, instrument procedures,
approach plates, airport data and flight planning run on the device and work with no network
connection.

SIGNING IN IS OPTIONAL — PLEASE TRY IT BOTH WAYS
No account is needed to use any feature. Launch the app and everything is available immediately.
An account exists only so a subscription can follow a pilot to another device; it unlocks nothing
in this build.

A demo account is provided below if you would like to exercise the account screens
(Settings -> Account). It supports Sign in with Apple, Google, and email + password, and account
deletion is available in-app at Settings -> Account -> Delete account.

NO PURCHASES IN THIS BUILD
There is no in-app purchase, no paywall, no price shown anywhere, and no link to any external
purchase mechanism. Every feature is available to every user.

DATA SOURCES AND ATTRIBUTION
Aeronautical data is United States FAA public-domain data (CIFP, NASR, d-TPP, TFRs). Weather is
NOAA/NWS. Hazard and climate layers use NASA EONET and NASA POWER; NASA does not endorse Obelisk.
Live traffic is from airplanes.live. Each source is attributed in the app where it is displayed.

SAFETY POSITIONING
Obelisk is an aid to situational awareness and is not certified for navigation. The app states
this, and it warns the pilot with an unmissable banner whenever any bundled dataset falls out of
its FAA cycle rather than presenting stale data as current.

LOCATION
Location is used to show the aircraft's position on the chart and to compute glide range, all
on-device. It is sent off the device only when the optional online traffic layer is enabled, to
request traffic near that point, with no identifier attached.
```

**Demo account** — create one on the live site and put it in the Review Information fields:

| Field | Value |
|---|---|
| Username | `appreview@obeliskaerospace.com` *(create this)* |
| Password | *(set one; it goes in the ASC field, not in this repo)* |

⚠️ **Do not commit the password.** This repo is public.

---

## 6. Screenshots

Apple requires one set per device class you support. The app is universal, so **both**:

| Device class | Accepted size | Simulator to use |
|---|---|---|
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max |
| iPad 13" | 2064 × 2752 | iPad Pro 13-inch (M5) |

Up to 10 each; the first two or three are what most people actually see.

Suggested order, strongest first:
1. Moving map with a sectional and the route drawn
2. A georeferenced approach plate with ownship on it
3. Nearest-airport / engine-out glide ranking
4. Airport page — runways, frequencies, weather
5. Weather: radar or winds aloft
6. Night theme, to show the red-only cockpit mode

The repo already has a harness: `ATCTranscribeUITests/ScreenshotTests` with `Tools/screenshots.sh`,
which arranges the model-less demo build so the shots are deterministic. It was built for the
README, so the framing is close but not an App Store set — expect to curate.

```bash
SCREENSHOTS=1 bash ios/Tools/screenshots.sh
```

⚠️ Screenshots must show the app as it ships. Do not include the developer-only flight simulator,
the demo-flight view or the test bench — all three are behind the seven-tap unlock and publish a
fake GPS position.

---

## 7. Version and build

| Field | Value |
|---|---|
| Version | `1.0` |
| Build | **112** — App Store Connect already holds 111 (uploaded 2026-10-29). Ask ASC, never the local `build/` dir. |
| Minimum iOS | 17.0 |
| Devices | iPhone + iPad (universal) |
| Export compliance | already answered by `ITSAppUsesNonExemptEncryption = false` in the plist; ASC will not ask |

**What to put in "What's New in This Version":** for a first release Apple ignores it, but the app
has its own release-notes history in `UI/WhatsNew.swift` if you want to draw on it.

---

## 8. Order of operations

1. ~~Rename the ASC record~~ — done, `Obelisk EFB`.
2. ~~Enable Sign In with Apple on the App ID~~ — done, `APPLE_ID_AUTH` present.
3. ~~Confirm the ASC agreements~~ — done, the API returns 200.
4. ~~Deploy the website~~ — done; the site and all seven native auth routes are live.
5. Create the App Review demo account on the live site. **This is now the only prerequisite left
   before the listing can be completed.**
6. Set the **Subtitle** in App Information if it is not set yet (§1).
7. Archive and upload the next build via `Tools/ship_testflight.sh` — **ask ASC for the build
   number first**; it already holds 111.
8. Fill in §1–§5 above, upload screenshots, submit.
