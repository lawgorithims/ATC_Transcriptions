# Obelisk — App Store submission checklist

Written 2026-10-30, in the pass that renamed the app to **Obelisk** and gave it accounts.
Pairs with `RELEASING.md` (what to refresh before a build) and `RECOVERY.md` (how to ship from a
bare machine). This file is about what Apple needs, and what is still missing.

All of it sits on **`main`**, rebased onto `origin/main` at `16ad620` — which brought the Avoid
layer, the turnback briefing, and the Keychain/install-id fix (PR #16) that `AccountStore` now
builds on. The rename sweep was re-run over that new code.

---

## 0. The short version

The app **builds, passes its suite, and is structurally ready**. The nav data is current again
(§2.1). Checked against App Store Connect on 2026-10-30, most of what this file listed as blocking
is already done:

| Was listed as blocking | Actual state |
|---|---|
| Rename the ASC record | ✅ already **`Obelisk EFB`** — the name `Obelisk` was evidently taken |
| Enable Sign In with Apple on the App ID | ✅ already on — `APPLE_ID_AUTH` is in the App ID's capabilities |
| The agreement 403 | ✅ cleared — the API returns 200 |
| Build number | ⚠️ **112**, not 111 — see §2.3 |

| The website | ✅ live, **including the new native auth routes** — see §2.4 |

**Nothing on this list is blocking any more.** The build can go to TestFlight and the listing can
be filled in. What is left is the ordinary submission work in §3–§7 of `APP_STORE_LISTING.md`:
screenshots, the App Review demo account, and the App Privacy answers.

---

## 1. What this pass did, and what was verified

### Verified on this machine

| Check | Result |
|---|---|
| `xcodegen generate` + Debug build (iPad Pro 13-inch M5) | ✅ succeeds |
| **Release** build, `generic/platform=iOS` | ✅ succeeds (the config the simulator loop never exercises) |
| Unit suite `ATCTranscribeTests` | ✅ **2,185 tests, 0 failures**, 9 skipped (re-run after merging `origin/main` and after the nav refresh) |
| The 9 skips | all environmental — speech models absent in an EFB build, Stratux hardware absent, and `InstallIdentityTests.testCohortSplitOnceThePaywallBuildIsSet` (expected: `paywallFirstBuild` is still 0) |
| UI suite `ATCTranscribeUITests` | ✅ **67 executed, 11 skipped, 0 failures** (`bash Tools/uitests.sh`, iPad Pro 13-inch M5, ~20 min) |
| The 11 UI skips | 6 × `ConsoleUITests` (transcription compiled out of an EFB build) · 3 × `LZLayerUITests` (the `n33w107` landability pack is not in the simulator) · `ScreenshotTests` (opt-in) · `AvoidDownloadUITests` (opt-in, downloads ~1.5 GB) |
| Why the skip count moved 10 → 11 | `RELEASING.md` says a changed skip count must be explained, not counted. The new one is `AvoidDownloadUITests`, which arrived with the Avoid feature in `origin/main`. Nothing in this change caused it. |
| Invariant suites | ✅ `TranscriptionGateTests`, `EntitlementsPolicyTests`, `InstallIdentityTests`, `DownloadPolicyTests`, `BundledNavDataTests`, `PlateGeorefTests` all pass |
| Bundled nav data | ✅ refreshed to **cycle 2611** (effective 2026-10-29) — see §2.1 |
| **Build 112 on TestFlight** | ✅ uploaded 2026-10-30, Apple reports `VALID` — add testers in App Store Connect → Obelisk EFB → TestFlight |
| `CFBundleDisplayName` in the built `.app` | ✅ `Obelisk` |
| `PrivacyInfo.xcprivacy` in the built `.app` | ✅ present |
| Website `npm run build` | ✅ compiles, all 7 native auth routes registered |
| App icon | ✅ replaced with the site's obelisk mark, white on black; 1024×1024 **RGB with no alpha** (an alpha channel is an automatic rejection) |

### Accounts (new)

Optional sign-in, reachable only at **Settings → Account**. Nothing gates the flying surface: no
launch wall, no modal, no `fullScreenCover` (invariant 5). Three ways in:

- **Sign in with Apple** — native, via `ASAuthorizationAppleIDCredential`.
- **Google** — the website's existing OAuth flow in an `ASWebAuthenticationSession`.
- **Email + password** — the same scrypt-hashed accounts the website already uses.

All three land on **one `users` row**, shared with obeliskaerospace.com, so a pilot who signed up on
the web gets their existing account and subscription in the app rather than a duplicate.

New on the app side (`ios/ATCTranscribe/Core/Account/`, `ios/ATCTranscribe/UI/Account/`):

| File | What it is |
|---|---|
| `AccountAPI.swift` | the HTTP client, the wire types, and `AccountError` |
| `AccountStore.swift` | `@MainActor ObservableObject`; Keychain-backed; fail-open refresh |
| `AppleSignIn.swift` | nonce, request configuration, credential extraction |
| `WebOAuthSignIn.swift` | the Google sheet + the PKCE verifier |
| `SignInView.swift` / `AccountView.swift` | the two pages behind Settings → Account |

New on the server (`~/CommSight/website`): `/api/auth/native/{signup,login,apple,me,logout,account}`
plus `/api/auth/native/oauth/exchange`, and `lib/auth/{native,apple-native,native-handoff}.ts`.

Two things worth knowing about how it is built:

- **The session token is never put in a URL.** The obvious Google handoff redirects to
  `obelisk://auth/callback?token=…`, and Caddy logs query strings — that would write a live 30-day
  credential into a log file on the box. The callback carries a one-time code bound to a PKCE
  challenge instead; the verifier only ever travels in one TLS POST body.
- **Only a definite `401` signs anyone out.** A timeout or a captive portal leaves the pilot signed
  in on the last cached snapshot. Same fail-open rule as `EntitlementCurrency` — the alternative is
  signing a pilot out of their own app mid-flight.

**Account deletion is in-app** (Settings → Account → Delete account). That is App Store guideline
5.1.1(v) and not optional: an app that can create an account must be able to delete it without
sending the pilot to a web form. The server cancels Stripe billing *before* deleting the row, so a
cancellation failure can never orphan a live subscription.

### The icon

`AppIcon` and `BrandMark` now carry the **obelisk mark from the website's favicon**
(`public/brand/obelisk-black.svg`), white on black, replacing the CommSight antenna-and-arrow art.
Both are written from one source by `Tools/make_icon.py`, which was rewritten for it — they must
not drift, because `BrandMark` is the mark beside the wordmark in the top bar, the What's-new sheet
and onboarding.

Two things in that script are deliberate: the mark is lifted out as a coverage mask and white is
painted through it (inverting the bitmap instead leaves grey fringing on every anti-aliased edge),
and it is framed by **centroid rather than bounding box** — the stepped base carries more ink than
the shaft, so a bbox-centred obelisk sits visibly low, by 3.6% of its own height here.

Note the website's own `public/brand/app-icon.png` is still the OLD CommSight art, and it is what
the site serves as its `og:image` and Twitter card. Worth re-cutting from the same mark.

### Acknowledgements page

**Settings → General → About → Acknowledgements** is new, and one line on it is a compliance item
rather than a courtesy: *"NASA does not endorse Obelisk or any commercial product or service."*
The app uses NASA EONET and NASA POWER in a product that is sold, and NASA's media guidelines
require that its data not be used in a way implying endorsement. The website footer already
carried that sentence; the app did not.

The page also gathers the runtime data sources (FAA, NOAA, airplanes.live, RainViewer) and the
open-source notices for what is actually linked into the binary — MapLibre Native, llama.cpp,
WhisperKit and the D-DIN type family — plus the Privacy Policy and Terms links, which is where a
reviewer looks for them.

Per-layer attributions stay where they are: right under the thing they describe, which is the
correct place in flight.

> Not addressed, because it is a legal question rather than an engineering one: `charts/README.md`
> records that the chart collar clip shapes come from `jlmcgraw/aviationCharts` under **GPL-3.0**.
> They are a build-time `gdalwarp` cutline on public-domain FAA rasters and are not shipped in the
> app, but whether the resulting tiles are a derivative work is worth a real answer before selling.

### The rename

440 occurrences reviewed, **176 renamed** across 62 files; 264 deliberately left. The rule:

> **Rename everything a human reads. Change nothing a machine matches on.**

So these were **deliberately left alone**, and each one breaks something real if "finished" later:

| Left as-is | Why |
|---|---|
| `com.flycommsight.atctranscribe` and the `.tests`/`.uitests`/`.probe` ids | your decision — keeps the existing App Store Connect record, TestFlight testers and build history. Users never see a bundle id. |
| `KeychainBox` services `com.flycommsight.{install,notamapi,…}` | renaming orphans the stored NOTAM key and the install identity (the grandfathering signal) |
| `huggingface.co/…/commsight-nav`, `commsight-lz` | live dataset URLs; renaming is a 404 for every user |
| `commsight-cockpit-audio`, `commsight_source` | wire protocol with the Stratux/Obelisk appliance |
| `com.commsight.fpl` | declared UTI; changing it breaks the "Open in…" file association |
| `CloudKitTransport.zoneName = "CommSight"` | CloudKit **schema**. Changing it orphans every synced record. Now carries a comment saying so. |
| `COMMSIGHT_TRANSCRIPTION` / `COMMSIGHT_CLOUDSYNC` | compile conditions, invisible to users, and the transcription flag is one leg of a three-part atomic invariant. Zero benefit, non-zero risk. |
| Target/scheme `ATCTranscribe` | internal; renaming breaks every script in `Tools/`, the xcarchive naming and the test target names |

A blanket find-and-replace would have broken five things, so each was caught and reverted:
the appliance's Python package `commsight_cockpit_audio`, its install prefix `/opt/commsight`
(both set by scripts the sweep never touched, so renaming them in prose alone would hand you
commands that fail), the memory-note name `commsight-ux-decisions`, and — the one that matters
most — the **App Store Connect SKU `commsight-ios`**, which is fixed at app creation and can
never be changed. `RECOVERY.md` now says so next to it.

One naming collision is now live and worth knowing about: the **app** is Obelisk and the **cockpit
appliance** is also Obelisk, so `AppModel.swift:4807` reads "Set a valid Obelisk address in Settings
› Obelisk." It is dev-only surface (the hardware link is not sold), but reword it if it ever ships.

### Privacy manifest

`ATCTranscribe/PrivacyInfo.xcprivacy` — required since May 2024; without it the upload is accepted
and then bounced by email (ITMS-91053). Every entry was found by auditing the source:

- **Required-reason APIs:** UserDefaults `CA92.1` · file timestamps `C617.1` · disk space `E174.1` ·
  system boot time `35F9.1` (`CACurrentMediaTime()` in the wind renderer and the haptics debounce
  sits in this category even though neither has anything to do with the boot clock).
- **Collected:** email, name, user id (account only, linked) and **precise location** (not linked).

> The location entry is a judgment call and you should know why it is there. When the online traffic
> layer is on, `ADSBService` asks `api.airplanes.live` for traffic around a point, and that point is
> ownship's present position. It is a third-party request, so it is declared. It is marked *not
> linked* because that request carries no account, no device id and no cookie — it is an
> unauthenticated GET. Nothing else sends position anywhere.

**The App Privacy answers in App Store Connect must match this file** — Apple compares them.

---

## 2. Blockers — clear these before you submit

### 2.1 Bundled nav data — refreshed to cycle 2611 ✅

Done in this pass. The bundle was cycle 2610 (expired 2026-10-29) and a clean install opened on a
red "4 datasets have expired" banner — the exact failure `RELEASING.md` §1 was written about.
Everything now carries **cycle 2611, effective 2026-10-29, expires 2026-11-26**: the cycle IN
FORCE, never the next one (§2 of that file explains why a future cycle is the more dangerous
mistake — it is served as current with nothing on screen to notice).

`cifp.sqlite`, `apt.sqlite` and `procedures.json` did not need rebuilding: cycle 2611 had already
been built into `~/CommSight/navbuild/2611` on 2026-10-20 for the staging pipeline, with correct
provenance. They were verified and copied in. `airspace.json` and `plate_georef.json` were built
fresh.

Counts compared against the outgoing files, because a builder that fetches a bad source and writes
a valid, nearly-empty database is a failure that has actually happened here:

| Dataset | 2610 → 2611 |
|---|---|
| `apt.sqlite` | airports 19,427 → **19,434** · runways 23,191 → **23,195** · frequencies 40,480 → **40,634** |
| `cifp.sqlite` | procedures 52,352 → **52,317** · legs 201,030 → **200,853** · airways 19,391 → **19,392** · ILS 1,279 → **1,278** |
| `procedures.json` | airports 3,197 → **3,198** · plate rows 24,069 → **24,181** |
| `airspace.json` | 2,830 → **2,833** (class B/C/D 1,286 unchanged; SUA 1,544 → 1,547) |
| `plate_georef.json` | 9,987 → **9,898** georeferenced |

All small churn in both directions — nothing collapsed.

Two notes on how it was rebuilt, for the next person:

- **`airspace.json` takes two passes, in order.** `build_airspace_db.py` writes class B/C/D and the
  cycle, then `build_sua.py` merges special-use airspace into that file. Running them the other way
  round aborts by design, and `build_airspace_db.py` needs `pyshp` (installed into
  `~/CommSight/plate-georef-venv`) plus the 259 MB NASR subscription zip. `nfdc.faa.gov` answers
  **503 to a HEAD request** while serving GET perfectly well, so a reachability probe lies.
- **The plate georef roll cost a 2.6 GB fetch** of 11,049 IAP PDFs (~7 min) and a ~10 min build.
  `PlateGeorefTests` passes: cycles equal, no orphan rows, coverage above its 85% floor. The
  `no-embedded-geo=1151` count is the documented ~10% the FAA does not publish as geospatial PDFs.
  The cache lives at `~/CommSight/plate-georef-out/plates_cache_2611`; with 2610 still beside it
  that is **5.2 GB of plate PDFs** outside the repo. Safe to delete the 2610 one — it is
  reproducible from `fetch_plates.py` and nothing reads it after its cycle has rolled.

Committing this costs roughly **30 MB of git history, permanently** — the databases are plain
binary in `.gitattributes`, not LFS. That is the known price `RELEASING.md` §1 sets against doing
this per release rather than per cycle.

**The refresh surfaced a latent test bug, now fixed.** `FlightBagTests.testCycleWindowOrdered`
asserts a d-TPP cycle is 28 days, and it measured the span with `Calendar.current` — the device
timezone — while both dates are 0901Z instants. Cycle 2611 runs 2026-10-29 to 2026-11-26 and US
DST ends on 2026-11-01, so in America/Denver those instants are 27 days 23 hours apart and the
assertion failed on perfectly correct data. The app code was never wrong: `daysUntilExpiry`
already counts in UTC and says why. The test now does the same. Left alone it would have fired
every autumn, and the natural reading of a red test here — "the nav data is bad" — is the
expensive one.

Verified afterwards: `BundledNavDataTests` and `PlateGeorefTests` green.

### 2.2 Sign In with Apple on the App ID ✅

Done. `ATCTranscribe/ATCTranscribe.entitlements` declares `com.apple.developer.applesignin`, and
the App ID `com.flycommsight.atctranscribe` already carries the matching capability — queried on
2026-10-30, it reports `['APPLE_ID_AUTH', 'IN_APP_PURCHASE']`.

Worth keeping the failure mode written down anyway: without that capability the Apple button fails
at runtime with error 1000, which reads like a network fault and is not one.

### 2.3 App Store Connect listing changes ⛔

- Rename the app record **CommSight → Obelisk** (free-text field; the bundle id does not change).
- **Privacy Policy URL:** `https://obeliskaerospace.com/legal/privacy`
- Fill in **App Privacy** to match `PrivacyInfo.xcprivacy` (§1).
- **Build number: 112.** Not 111 — and this is exactly the trap `RELEASING.md` §4 warns about.
  Local archives stop at `ATCTranscribe_109.xcarchive`, which suggests 110 or 111, but App Store
  Connect already holds **111, uploaded 2026-10-29** from somewhere other than this box. ASC is the
  authority and rejects a number it has seen. Always ask it, never the local `build/` directory:
  `GET /v1/builds?filter[app]={id}&sort=-version`.

### 2.4 The website and the native auth API ✅ (live)

Verified against production on 2026-10-30. The site answers 200 on `/`, `/legal/privacy`,
`/legal/terms` and `/forgot-password`, and **all seven native auth routes are deployed and
behaving correctly** — each returns this code's own error strings, so these are the handlers from
this change and not a coincidence:

| Request | Response |
|---|---|
| `GET /api/auth/native/me` (no token) | `401 {"error":"Not signed in."}` |
| `POST /api/auth/native/login` `{}` | `401 {"error":"Incorrect email or password."}` |
| `POST /api/auth/native/signup` `{}` | `400 {"error":"Enter a valid email address."}` |
| `POST /api/auth/native/apple` `{}` | `400 {"error":"Missing identity token."}` |
| `POST /api/auth/native/oauth/exchange` | `401 {"error":"This sign-in link is invalid or has expired."}` |
| `DELETE /api/auth/native/account` (no token) | `401 {"error":"Not signed in."}` |
| `GET` on a POST-only route | `405` |

Sign-in in a build shipped today therefore works.

> An earlier revision of this file asserted the site was not deployed. That was an assumption
> drawn from `appStoreComingSoon: true` in `config/site.ts`, never checked, and wrong. The check
> is one `curl` and it is now written down above.

Optional server config: `APPLE_NATIVE_CLIENT_IDS` (defaults to `com.flycommsight.atctranscribe`, so
nothing to do unless the bundle id ever changes). Google sign-in needs `GOOGLE_CLIENT_ID` /
`GOOGLE_CLIENT_SECRET`; without them the app degrades gracefully to "that sign-in option isn't
available right now".

### 2.5 The App Store Connect agreement ✅ (cleared)

Cleared. On 2026-10-21 every API endpoint returned
`403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`; on 2026-10-30 the same read-only check
returns **200** and lists the app. Nothing more to do.

Keeping the note because the failure recurs whenever Apple issues a new agreement: it is **not** a
credential problem and no key can clear it — only the Account Holder, in App Store Connect →
Business / Agreements. It blocks uploads, certificate minting and build-number queries alike.

Run the read-only JWT check in `RECOVERY.md` **before** spending ~15 minutes on an archive. Do not
regenerate the `.p8` in response to a 403: Apple will not re-issue it.

---

## 3. Decisions I made, in case you'd choose differently

- **No upgrade button, no price, and no "subscribe on the web" link anywhere in the app.**
  Guideline 3.1.1 forbids buttons, links or other calls to action pointing at a purchasing
  mechanism other than IAP, and that covers a politely-worded website link. `AccountView` reports
  subscription *status* and stops, which is what 3.1.3(b) permits for a multiplatform service. The
  upgrade path belongs here as a real StoreKit purchase when M3 lands.
- **Accounts do not feed `EntitlementStore`.** It still grants everything (M1), deliberately. Wiring
  them now would mean a pilot's charts could go dark because a Stripe webhook was slow. The seam is
  documented at the top of `AccountStore`.
- **The sign-in page leads with "an account is optional."** Guideline 5.1.1(i) forbids forcing
  registration for features that do not need it, and an EFB that wants a login before it shows a
  sectional is the wrong product anyway.
- **The privacy policy keeps its "this is a starting template, review with counsel" banner.**
  Removing it is a legal judgment that is yours, not mine. A reviewer will read that page.
  I updated its substance: it previously said "nothing is sent to us from the app", which this
  change made false.
- **Night theme gets the black Apple button.** Apple ships three styles and none is red; a white
  rectangle in front of a pilot at altitude costs dark adaptation.

---

## 4. Not blocking, but worth a decision

- ⚠️ **The website is not in version control.** `~/CommSight/website` has a `.git` directory but
  **zero commits and no remote** — all 212 files are untracked. That includes the entire account
  backend this pass added, so the server half of sign-in exists on one disk and nowhere else, with
  no history and no backup. Its `.gitignore` already covers `.env*.local`, so an initial commit
  would not leak the Stripe or SMTP secrets. Worth doing before the first deploy.
- **No `LICENSE` file** on a public repo, and `charts/README.md` notes the chart clip geometry is
  GPL-3.0 (`jlmcgraw/aviationCharts`, geometry only). Worth settling deliberately before selling.
- **No CI.** 2,185 unit + 64 UI tests, all run by hand on one box. `HANDOFF_MONETIZATION.md` §12
  calls this the largest execution risk in the programme, and that was before a paywall.
- **`plate_index.json` is cycle 2607**, four cycles behind, and it carries no dates so the currency
  sweep cannot see it. Harmless in this build — it only primes the Whisper decode, and
  transcription is compiled out — but it would matter the day that gate flips. It is rebuilt from
  the OCR corpus, not a cycle download, which is why `RELEASING.md` does not list it.
- **Docs are stale** beyond the rename: root `README.md` says build 41 and 438 tests (reality: 110
  and ~2,185); `ARCHITECTURE.md` says ~33k LOC against ~70k actual.
- **Forgot-password opens the website**, whose navigation includes a pricing page. Routinely
  accepted and standard for any app with web accounts, but it is the one external link in the
  account flow.
- **UI suite not re-run in this pass.** It needs an iPad destination via `bash Tools/uitests.sh`;
  the unit suite was the one that covers everything this change touched.

---

## 5. Trying the account flow before you ship

Against a local server — a DEBUG-only launch argument, because a release build that could be
pointed at an arbitrary host by a configuration profile is a credential-harvesting primitive:

```bash
xcrun simctl launch --console booted com.flycommsight.atctranscribe --account-host http://localhost:3000
```

Worth walking once each: create an account with email, sign out, sign back in, Sign in with Apple
(on a device — the simulator's Apple ID support is limited), and **delete the account**, then check
the `users` row is gone and any Stripe subscription is cancelled.
