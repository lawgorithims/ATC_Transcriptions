# CommSight — Monetization Handoff (M1: the entitlement layer)

> For the next session, running **locally on the Mac**. The cloud session that wrote this code had
> no Swift toolchain and no route to a Mac, so **none of it has ever been compiled.** Getting it to
> build and the suite green is the whole job. Pairs with `HANDOFF.md` (general app context) and
> `RECOVERY.md` (rebuild the ship box).

> ⚠️ **This repo is PUBLIC** (`"visibility": "public"`). Tier *names* and the capability→tier map are
> in the shipped code and unavoidable. **Prices, the perpetual-licence strategy, market research and
> the tax posture are deliberately NOT in this repo** — see §9.

---

## 0. The one thing to know

**~1,400 lines of new Swift, never compiled.** Brace balance, switch exhaustiveness and a few
invariants were checked with scripts; that is not a compiler. Expect failures and work them.

- Branch: **`claude/great-shannon-z0guvn`**
- Draft PR: **[#10](https://github.com/lawgorithims/ATC_Transcriptions/pull/10)**, 2 commits
  - `56b0eb9` The entitlement layer, before anything is for sale
  - `255dc93` A refused download says which plan includes it, instead of nothing

**Nothing changes for any user yet.** `EntitlementStore.resolve()` returns `.proPerformance` /
`.verified`, so every gate passes and the app behaves exactly as build 110. That is deliberate: the
plumbing, call sites and tests get proven under real use before money is involved.

---

## 1. What landed

**New (`ios/ATCTranscribe/Core/`)**

| File | What it is |
|---|---|
| `Entitlements.swift` | `Tier`, `Capability`, `EntitlementCurrency`, the policy table, `EntitlementGate`. The whole policy as pure functions. |
| `EntitlementStore.swift` | `@MainActor` singleton + `ObservableObject` publishing an `EntitlementGate`. Holds the M1 "grant everything" stub. |
| `InstallIdentity.swift` | Stable install id (the future `appAccountToken`) + the grandfathering signal. |
| `KeychainBox.swift` | The Security primitives extracted from `NotamService` (previously the app's only Keychain code). |

**Modified**

| File | Change |
|---|---|
| `Core/Features.swift` | `transcriptionGatedCapabilities` — the capabilities the compile gate dominates |
| `Core/DownloadPolicy.swift` | `Verdict.notEntitled(Capability)`; `decide`/`verdict` take an optional capability + gate |
| `App/ATCTranscribeApp.swift` | injects `EntitlementStore`, refreshes on foreground |
| `UI/ChartMapView.swift` | `ChartCatalog.Entry.capability` (path prefix → tier) and `ChartLayer.capability` |
| `UI/ChartLibrary.swift` | entitlement backstop in `ensureOnDisk`; filters `updateInstalledPacks`; names the capability at two verdict sites |
| `UI/DownloadsView.swift` | both download pre-checks pass `requires:`; new `EntitlementDialog` modifier |
| `Download/ModelDownloadManager.swift` | model download rides `.transcription` |
| `Hazards/NotamService.swift` | delegates to `KeychainBox`; public surface unchanged |
| `RECOVERY.md` | documents the missing `MapLibre.xcframework` build input (§2) |

**Tests** — 54 new across four files (2,106 unit + 64 UI in the tree now):
`EntitlementsPolicyTests` 13 · `InstallIdentityTests` 14 (incl. `ChartCapabilityTests`) ·
`DownloadPolicyTests` 18 (was 11) · `TranscriptionGateTests` 9 (was 5, **originals unchanged**).

---

## 2. ⚠️ A fresh clone does not build

`ios/Vendor/` holds only `.gitkeep`, but `project.yml` links **two** git-ignored xcframeworks
unconditionally with `embed: true`:

| Framework | How to get it |
|---|---|
| `Vendor/llama.xcframework` | `bash ios/Tools/build_llama_xcframework.sh` |
| `Vendor/MapLibre.xcframework` | **No script in this repo.** Built from the separate globe fork at `~/CommSight/maplibre-native` via `bazelisk build //platform/ios:MapLibre.dynamic --//:renderer=metal --compilation_mode=opt …` (see `project.yml` `packages:` note + `docs/GLOBE_FORK_PLAN.md`) |

**If this Mac is not the machine with that fork, do NOT rebuild it** — bazelisk is hours. Take the
one-line rollback already commented into `project.yml`: uncomment the `MapLibre` SwiftPM package and
swap `- framework: Vendor/MapLibre.xcframework` for `- package: MapLibre / product: MapLibre`. You
lose globe projection, which is irrelevant to verifying this change.

---

## 3. Build it

```bash
brew install xcodegen
```

```bash
bash ios/Tools/build_llama_xcframework.sh
```

```bash
cd ios && xcodegen generate
```

```bash
cd ios && xcodebuild -project ATCTranscribe.xcodeproj -scheme ATCTranscribe -destination 'platform=iOS Simulator,name=iPhone 15' test
```

`ios/Tools/setup.sh --build` bootstraps a fresh Apple-Silicon box end to end (idempotent, no sudo;
full Xcode must already be installed).

---

## 4. Verify

1. **It compiles.** The 17 touched files are the whole risk surface.
2. **`TranscriptionGateTests`' original five assertions pass UNCHANGED.** That is the signal the
   compile-time gate still governs. If one of those broke, stop and fix that first.
3. **The new suites pass.** Most load-bearing, in order:
   - `EntitlementsPolicyTests.testAlwaysFreeCapabilitiesAreNeverGated` — a lapsed subscriber keeps
     nav currency, the glide page, the GPS banner, plates, weather, TFRs. If this fails, billing has
     eaten a safety surface.
   - `TranscriptionGateTests.testEntitlementCannotEnableTranscriptionWithoutTheCompileFlag` — no
     tier can unlock transcription while the symbol is absent.
   - `EntitlementsPolicyTests.testTiersAreStrictlyNested` — required for StoreKit group levels.
   - `InstallIdentityTests.testFirstSeenBuildInheritsAppModelsLastSeenBuild` — the grandfathering
     signal.
   - `InstallIdentityTests.testPreCheckRefusesAnUnentitledPackInsteadOfAllowingIt` — the
     dead-button regression from `255dc93`.
4. **Nothing changed for a user.** Launch it. Every tab, layer and download behaves as build 110.
5. **The gate actually gates.** Run with `--entitlement flightbag`: IFR-low and IFR-high rows in
   Downloads should refuse with "Not included in your plan", naming the tier — **not** a dead button
   and **not** a mobile-data override. Also try `pro`, `none`, `lapsed`, `offline`.
6. **NOTAMs still work.** `NotamCredential` now goes through `KeychainBox`. Enter a FAA NOTAM key in
   Settings, relaunch, confirm it persisted and NOTAMs load.

---

## 5. Where I'd look first when it fails

Honest list of what was never checked by a compiler:

- **`.alert(_:isPresented:presenting:actions:message:)`** in `EntitlementDialog`
  (`DownloadsView.swift`). The overload set here is fiddly. If it complains, the fallback is a plain
  `.alert(title, isPresented:)` with the message built outside the closure.
- **`DownloadsView.body` type-checking.** `DownloadsView.swift:~1040` documents that each dialog
  modifier wraps the whole accumulated generic type and that adding one inline tipped it past the
  solver — *failing on an unrelated `Binding` twelve modifiers earlier*. `EntitlementDialog` is a
  separate `ViewModifier` for exactly that reason. If you see "unable to type-check this expression
  in reasonable time", that is this, and the fix is to move more out, never to simplify the error
  site.
- **`EntitlementGate` synthesized `Equatable`/`Sendable`.** It stores a `Set<Capability>`; relies on
  `Capability` being `Hashable`+`Sendable` by raw-value synthesis.
- **`@StateObject private var entitlements = EntitlementStore.shared`** in the `App` struct. Mirrors
  the existing `AppModel()` usage (also `@MainActor`), so it should be fine, but it is a singleton
  behind `@StateObject`, which is unusual.
- **Default argument `gate: EntitlementGate = .free`** on a `nonisolated static func`.
- **Unused-import / unused-variable warnings.** `import Security` was removed from
  `NotamService.swift` (its last Security symbol is now only in a doc comment).

---

## 6. Known gaps — deliberate, not bugs

- **No paywall UI.** By design: M1 ships invisibly. `EntitlementDialog` is a stopgap notice, not a
  paywall. The real `UI/Paywall/` (tier comparison, upgrade sheet, account view, restore) is next.
- **No `/v1/catalog` URL indirection.** It rewrites the content base URLs and was judged too risky
  to do blind in an unverified change — a wrong base URL bricks charts for every tester. Do it
  after green.
- **The metered-override path skips the policy check by design.** `startBulkDownload(allowMetered:
  true)` bypasses `verdict()`, so entitlement there is enforced only by `ensureOnDisk`'s silent
  backstop. Not reachable in practice now that the pre-check refuses before the metered dialog can
  open, but it deserves a test.
- **`EntitlementStore.resolve()` is a stub.** Replacing it is M3's job, and the comment in it names
  exactly what has to change.

---

## 7. Invariants — do not break these

1. **The never-gate list.** `Capability.isAlwaysFree` must stay granted at every tier and every
   currency, including `.lapsed` and `.revoked`. `UI/DataCurrencyBanner.swift:8` states the
   principle: *"Expired navigation data that looks authoritative is exactly the failure this project
   keeps designing against."* Charge for convenience, never for currency.
2. **Fail OPEN inside grace, closed only on a definite negative.** A network failure must never
   downgrade an entitlement, and content already on disk is never revoked. Precedent and reasoning
   are in `EntitlementCurrency.grants`.
3. **The transcription flip is a THREE-part atomic unit** — the `COMMSIGHT_TRANSCRIPTION`
   compilation condition, the two Info.plist blocks beside it, **and**
   `Capability.transcription.minimumTier` (currently `nil`). Flip only the first two and the model
   download refuses, which looks like a bug rather than a policy.
4. **No entitlement state in `UserDefaults`.** Nothing calls `register(defaults:)` in this tree, so
   `bool(forKey:)` on an unwritten key returns `false`; a `defaultsTrue("…pro")` would be a free
   unlock on every fresh install. State is one signed record in the Keychain; absence decodes to
   `Tier.none`.
5. **The paywall must never be a `fullScreenCover`.** `UI/ConsoleView.swift:85` records the
   incident: a cover with no interactive dismiss and a flag nothing clears = *"bricked, with no way
   out but a reinstall."* Lock at point of use; no launch paywall.
6. **`--entitlement` stays `#if DEBUG`.** In release it is a free unlock for anyone with a debugger.

---

## 8. Orientation (read in this order)

1. `Core/Features.swift` — the pre-existing compile gate and its polarity reasoning. Everything
   else follows its discipline.
2. `Core/Entitlements.swift` — `Entitlements.allows` is the whole policy. Note the guard ordering:
   compile gate → not-sold → no-payment-required → currency → tier. The comments say why each sits
   where it does; the no-payment check **must** precede the currency check or free users lose the
   safety surfaces.
3. `Core/DownloadPolicy.swift` — the primary enforcement seam, chosen because its own class note
   already promises to be "the one place that decides whether a given download is allowed right
   now", so every bulk path inherits the check.
4. `Core/EntitlementStore.swift` — where M3 plugs in.

---

## 9. Decisions: locked, and still open

**Locked** (settled with the owner; the ladder shape is already encoded in `Capability.minimumTier`):

- Hybrid rails — subscriptions via StoreKit 2 IAP; the perpetual licence and all owner-issued
  coupons via Stripe on obeliskaerospace.com, converging on one server-side entitlement record.
- EFB-led ladder: **Flight Bag → Pro → Pro + Performance**, strictly nested.
- Nav-data currency free at every level, including the free tier.
- Transcription, the cockpit hardware link and landability are in **no** tier.
- Content gating is phased: sell first, migrate to signed URLs after.

**Open, and each one blocks a later milestone:**

| Decision | Blocks | Note |
|---|---|---|
| `InstallIdentity.paywallFirstBuild` — the real build number | M3 | It is `0` today, which grandfathers nobody. That polarity is deliberate; set it in the same change that stops `resolve()` granting everything. |
| The grandfathering grant for the existing build-110 beta cohort | M3 | Recommendation was 12 months of the top tier, `kind: .legacy` — not perpetual. |
| Raw Stripe + Stripe Tax vs a merchant-of-record | the web rail | Decides who files US sales tax; painful to switch once there are live customers. |

**Prices, the perpetual-licence terms and cap, the market research and the tax analysis are not in
this repo** — this repo is public. They are in the private monetization plan the owner holds; ask
for it before touching anything commercial. Do not add price figures to this repo: the app reads
`Product.displayPrice` from StoreKit, and App Store Connect is the source of truth.

---

## 10. After green

In order. Each is independently shippable.

1. **Finish M1** — the paywall UI (`UI/Paywall/`: tier comparison, contextual upgrade sheet, account
   view, restore), replacing `EntitlementDialog`. Must render in all three themes (Cockpit / Day /
   Night) and respect invariant 5.
2. **`/v1/catalog` indirection** — server-returned content base URLs with the current Hugging Face
   URLs compiled in as fallback, so the later S3/CloudFront move is a config flip, not an app
   release.
3. **M2 backend** — AWS SAM + Lambda + DynamoDB + FastAPI on `api.obeliskaerospace.com`: entitlement
   token issuance, Apple ASSN V2 + Stripe webhooks behind an idempotency ledger, reconciliation.
4. **M3 StoreKit** — six products in one subscription group, `Transaction.updates` started in
   `ATCTranscribeApp.init()`, `appAccountToken` on **every** purchase (it cannot be backfilled),
   restore, `SKTestSession` tests. First revenue.

---

## 11. Do not

- **Do not market or sell transcription.** Compiled out, *and*
  `python-legacy/models/whisper-atc-turbo/README.md` says the fine-tune "is intended for research
  use — confirm the applicable terms before any commercial use." Needs a retrain on cleanly-licensed
  data (the pipeline in `python-legacy/dataset/` was built for exactly this and never run — see the
  root `HANDOFF.md`) **and** a usable cockpit audio path.
- **Do not sell the cockpit hardware link.** The Obelisk appliance does not exist as a product and
  the Stratux receiver work is of unknown status.
- **Do not put landability in a tier.** Developer preview behind the diagnostics unlock after
  failing its ground-truth eval; its OSM power-line layer is ODbL-quarantined.
- **Do not clear a transcription-dependent product for sale in App Store Connect** before invariant
  3 is fully satisfied.
- **Do not commit prices, secrets, the `.p8`, App Store Connect key IDs or the build-box host** —
  public repo, same rule as `HANDOFF.md`.

---

## 12. Also worth fixing (noticed, out of scope)

- **No CI builds or runs the suite.** 2,106 unit + 64 UI tests, all run by hand on one box.
  Shipping a paywall that way is the largest execution risk in this programme. `cycle-watch.yml`
  warns about Actions storage — a build-and-test job uploading no artifacts is fine.
- **`PrivacyInfo.xcprivacy` is absent** — required for App Store submission, independent of payments.
- **Docs are stale.** Root `README.md` says build 41 and 438 tests; reality is build 110 and ~2,170.
  `ARCHITECTURE.md` says ~33k LOC against ~70k actual, and §6.9 still describes four model artifacts
  when `ModelCatalog` has two (`ModelCatalog.swift:63` — the turbo variants were removed because
  they cannot run on an M1 iPad Air). `EXPERIMENTAL_DO_NOT_MERGE.md` describes what is now the
  default map engine.
- **No LICENSE file** on a public repo, and `charts/README.md` notes the chart clip geometry is
  GPL-3.0 (`jlmcgraw/aviationCharts`, geometry only). Worth a deliberate decision before selling.
