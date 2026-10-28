import Foundation

// MARK: - Tier

/// What a pilot has paid for. Ordered, so a gate reads `tier >= .pro` and a new middle tier does not
/// have to touch every call site.
///
/// `none` is 0 and is the **unwritten** state: an absent, unreadable, unverifiable or tampered
/// entitlement decodes to `none`. See the polarity note on `Entitlements` for why that matters.
enum Tier: Int, Comparable, Codable, CaseIterable, Sendable {
    case none = 0
    case flightBag
    case pro
    case proPerformance

    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    /// Customer-facing name. Not localized yet; the paywall reads `Product.displayName` from
    /// StoreKit for anything a customer is about to pay for, so this is for diagnostics and the
    /// account screen.
    var label: String {
        switch self {
        case .none:           return "Free"
        case .flightBag:      return "Flight Bag"
        case .pro:            return "Pro"
        case .proPerformance: return "Pro + Performance"
        }
    }
}

// MARK: - Capability

/// One gated thing. **Call sites ask for a capability, never for a tier.**
///
/// WHY. The tier boundaries in this product are a pricing hypothesis, not a fact — they will move
/// once there is real conversion data. Gating on capability makes a repackage one edit to
/// `minimumTier(for:)` instead of a sweep through ~40 view sites, and it makes the whole policy
/// one table a test can enumerate exhaustively.
enum Capability: String, CaseIterable, Sendable {
    // Always free — see `isAlwaysFree`.
    case navDataCurrency
    case platePDFs
    case weatherReports          // METAR / TAF / 7-day outlook / flight category
    case tfrs
    case nearestAirportGlide     // the engine-failure page, the glide footprint, AGL
    case gpsIntegrity
    case notesAndLogbook
    case flightRecorder

    // Flight Bag and up.
    case vfrCharts

    // Pro and up.
    case ifrLowCharts
    case plateGeoreferencing     // ownship on the plate, plate-as-map overlay
    case plateBinders
    case codedProcedures         // CIFP approaches / SIDs / STARs, holds, vertical profile
    case traffic                 // internet ADS-B
    case hazardLayers            // EONET events + route corridor, GIBS smoke
    case radarAndWXProducts

    // Pro + Performance only.
    case ifrHighCharts
    case minimaSolver            // computed minima, approach ranking, alternate + cold-temp
    case windsAloft              // NOAA GRIB2 decode + animated altitude layer
    case airportClimate          // NASA POWER windrose / density altitude / crosswind
    case routeGlideExposure
    case approachNotams

    /// Not sold, not marketed, not in any tier.
    ///
    /// `transcription` is additionally gated at COMPILE time — see `Entitlements.allows`. The
    /// cockpit hardware link (Obelisk appliance / Stratux receiver) is unfinished and stays free to
    /// use for anyone who gets it working, rather than becoming a paid entitlement for a thing that
    /// may not exist. `landability` is behind the diagnostics unlock
    /// (`AppModel.offFieldLayerAvailable`) after failing its ground-truth eval.
    case transcription
    case cockpitHardwareLink
    case landability

    /// The never-gate list, as a property rather than a comment so `EntitlementsPolicyTests` can
    /// assert the invariant that matters: every one of these stays granted at `Tier.none` and at
    /// EVERY currency, including `.lapsed` and `.revoked`. (It is a subset of what the free tier
    /// gets, not the whole of it — the capabilities we simply do not sell are free too.)
    ///
    /// WHY THESE. Two reasons, and both are deliberate rather than generous:
    ///
    /// 1. **Safety surfaces are never a paywall lever.** `UI/DataCurrencyBanner.swift` states the
    ///    governing principle in the code itself — *"Expired navigation data that looks
    ///    authoritative is exactly the failure this project keeps designing against"* — and
    ///    `ios/RELEASING.md` records a 76-day-expired bundle as a real incident. Gating nav
    ///    currency means every free and every lapsed user eventually opens the app to a red EXPIRED
    ///    banner sitting over procedures we shipped them. Same argument for the nearest-airport
    ///    glide page and the GPS integrity banner: a pilot in trouble does not get a paywall.
    /// 2. **Some of it costs us nothing.** Plate PDFs come straight from `aeronav.faa.gov`, reports
    ///    from `aviationweather.gov`, TFRs from `tfr.faa.gov`. Charging for a byte we never serve
    ///    buys goodwill at a worse exchange rate than giving it away.
    ///
    /// Note the honest consequence for packaging: the plate *PDF* is free to read, so what Pro
    /// sells is the software **around** the plate — `plateGeoreferencing` and `plateBinders`.
    var isAlwaysFree: Bool {
        switch self {
        case .navDataCurrency, .platePDFs, .weatherReports, .tfrs,
             .nearestAirportGlide, .gpsIntegrity, .notesAndLogbook, .flightRecorder:
            return true
        default:
            return false
        }
    }
}

// MARK: - The policy table

extension Capability {
    /// The lowest tier that grants this capability, or `nil` if no tier does.
    ///
    /// `nil` is not "free" — `isAlwaysFree` says that. `nil` means **not sold**, and
    /// `Entitlements.allows` refuses it at every tier including the top one. That is what keeps an
    /// unfinished feature out of a paid tier by construction instead of by remembering.
    var minimumTier: Tier? {
        switch self {
        case .navDataCurrency, .platePDFs, .weatherReports, .tfrs,
             .nearestAirportGlide, .gpsIntegrity, .notesAndLogbook, .flightRecorder:
            return .none

        case .vfrCharts:
            return .flightBag

        case .ifrLowCharts, .plateGeoreferencing, .plateBinders, .codedProcedures,
             .traffic, .hazardLayers, .radarAndWXProducts:
            return .pro

        case .ifrHighCharts, .minimaSolver, .windsAloft, .airportClimate,
             .routeGlideExposure, .approachNotams:
            return .proPerformance

        // Not sold. `transcription` becomes `.proPerformance` only when BOTH of its external
        // blockers clear (a usable cockpit audio path, and a model whose training data permits
        // commercial use); until then no tier reaches it and the compile gate below refuses it
        // regardless. `cockpitHardwareLink` and `landability` are free-but-hidden, not paid.
        case .transcription:
            return nil
        case .cockpitHardwareLink, .landability:
            return .none
        }
    }
}

// MARK: - Currency

/// How an entitlement record stands relative to its own expiry and to the last time a server
/// vouched for it.
///
/// Deliberately shaped like `DataCurrency` in `Core/DataProvenance.swift`, including its central
/// rule: **an absent date is never defaulted to "fine"**. The difference is which way the middle
/// case falls, and that is the whole safety argument below.
enum EntitlementCurrency: Equatable, Sendable {
    /// A server or StoreKit vouched for this recently.
    case verified(asOf: Date)
    /// Inside the grace window: we cannot reach anyone to confirm, so we **honour it**.
    case unverified(lastVerified: Date)
    /// A definite negative — the record's own expiry has passed and the grace window with it.
    case lapsed(since: Date)
    /// The money came back (refund, chargeback, family removal). The one case with no grace.
    case revoked(at: Date)
    /// No record at all.
    case none

    /// Whether this currency grants anything beyond the always-free set.
    ///
    /// # Fail OPEN on a verification failure, CLOSED on a definite negative
    ///
    /// This is the load-bearing decision in the file, so here is the reasoning, because it is
    /// safety-adjacent and not merely commercial.
    ///
    /// A network failure must **never** downgrade an entitlement. The precedent is already in this
    /// codebase and is explicit about the consequence: `ChartLibrary.refreshCatalog()` used to nil
    /// the catalog before re-fetching, and *"one tap on a marginal connection left `catalog == nil`
    /// for the rest of the offline period — and a nil catalog means ChartStore draws NO charts even
    /// though the packs are sitting on disk. A pilot who taps 'check' while taxiing must not lose
    /// the charts they already have."* An entitlement check that fails closed on a timeout is that
    /// same bug with a worse blast radius: a paying pilot at FL080 with no signal loses the
    /// sectional under the aircraft for a billing reason.
    ///
    /// So `.unverified` grants exactly what `.verified` grants. Only a *definite* negative — an
    /// expiry we can see has passed, plus the grace window — closes the gate, and only a
    /// revocation closes it immediately.
    ///
    /// **The cost, stated plainly:** a determined user can fly on a cached record for the whole
    /// grace window, or stay offline indefinitely on an `.unverified` Pro. That leakage is the
    /// price of never taking charts from a paying pilot in flight. It is the right trade for an EFB
    /// and the wrong trade for a streaming app; this app is an EFB.
    var grants: Bool {
        switch self {
        case .verified, .unverified: return true
        case .lapsed, .revoked, .none: return false
        }
    }

    /// Short diagnostic label for the account screen. Never shown as a reassuring green for
    /// `.unverified` — the pilot is told we are going on a cached answer.
    var label: String {
        switch self {
        case .verified:   return "Active"
        case .unverified: return "Active (offline)"
        case .lapsed:     return "Expired"
        case .revoked:    return "Refunded"
        case .none:       return "Free"
        }
    }
}

// MARK: - The decision

/// The entitlement policy, as pure functions over a tier and a currency.
///
/// # Polarity: there is no boolean anywhere, on purpose
///
/// `Core/Features.swift` records why this project is careful here: nothing calls
/// `UserDefaults.register(defaults:)` anywhere in the tree, so `bool(forKey:)` on an unwritten key
/// returns `false`. That is safe for a flag named for what it *enables* and catastrophic for one
/// named for what it *withholds* — `DownloadPolicy.defaultsTrue(_:)` exists to work around exactly
/// that trap for its two default-ON settings.
///
/// An entitlement must not imitate that workaround. A `defaultsTrue("atc.entitlement.pro")` would
/// be a free unlock on every fresh install. So entitlement state is **never** a UserDefaults
/// boolean: it is one signed record in the Keychain, and absence, garbage or a failed signature all
/// decode to `Tier.none`. "Off" is the unwritten state by construction rather than by care.
enum Entitlements {

    /// Whether `capability` is granted. **The one place the policy lives.**
    static func allows(_ capability: Capability, tier: Tier, currency: EntitlementCurrency) -> Bool {
        // ⚠️ COMPILE-TIME GATE FIRST, AND NON-NEGOTIABLE.
        //
        // `Features.transcription` is a compilation condition, not a flag, because transcription
        // needs Info.plist keys (`NSMicrophoneUsageDescription`, `UIBackgroundModes: [audio]`) that
        // cannot be added at runtime — and `AVAudioApplication.requestRecordPermission` TERMINATES
        // an app that asks for a permission it never declared. See `Core/Features.swift` for the
        // full reasoning.
        //
        // This means a runtime entitlement must compose with it by AND, never override it. No tier,
        // no server record, no launch argument and no tampered cache can reach past this line. It
        // is `guard`ed before the tier is even consulted so the ordering cannot be refactored away,
        // and `TranscriptionGateTests` asserts it across every tier × currency combination.
        //
        // The check is placed BEFORE the `minimumTier` lookup even though `transcription` currently
        // returns `nil` there (so it would be refused anyway). That is deliberate: when the two
        // external blockers clear and `minimumTier` becomes `.proPerformance`, this line is what
        // still refuses it in a build whose plist cannot support it. Ordering it first means the
        // guarantee does not depend on the table.
        if !Features.transcription, Features.transcriptionGatedCapabilities.contains(capability) {
            return false
        }

        guard let minimum = capability.minimumTier else { return false }  // not sold at any tier

        // No payment required — the currency is irrelevant. This covers the always-free safety set
        // AND the features we do not sell but do not hide behind a tier (the cockpit hardware link,
        // the landability preview). A lapsed subscriber, a refunded one and someone who never paid
        // all keep every one of these.
        //
        // ⚠️ This MUST come before the `currency.grants` check. With the two reversed, a free user
        // (whose currency is `.none`, which does not grant) would be refused the nearest-airport
        // glide page and the data-currency banner — i.e. the paywall would eat the safety surfaces
        // for exactly the users most likely to need them.
        if minimum == .none { return true }

        guard currency.grants else { return false }
        return tier >= minimum
    }

    /// Which capabilities a tier+currency grants. Used by the tests and the account screen; view
    /// code reads `EntitlementGate` instead.
    static func granted(tier: Tier, currency: EntitlementCurrency) -> Set<Capability> {
        Set(Capability.allCases.filter { allows($0, tier: tier, currency: currency) })
    }
}

// MARK: - The gate

/// A flattened snapshot of the policy, so a view site learns **one** bool rather than re-deriving
/// a tier comparison and a compile-flag check.
///
/// A plain `Equatable` value, not a nested `ObservableObject`: ARCHITECTURE §5's `WidgetStore` note
/// records that *"nested `ObservableObject`s don't republish their parent"*, so a gate hung off
/// another store would both fail to republish and drag paywall views into the several-times-a-second
/// live-data storm. `EntitlementStore` publishes a new value of this type instead.
struct EntitlementGate: Equatable, Sendable {
    let tier: Tier
    let currency: EntitlementCurrency
    private let granted: Set<Capability>

    init(tier: Tier, currency: EntitlementCurrency) {
        self.tier = tier
        self.currency = currency
        self.granted = Entitlements.granted(tier: tier, currency: currency)
    }

    /// The free, unentitled state — and the value every failure path resolves to.
    static let free = EntitlementGate(tier: .none, currency: .none)

    func can(_ capability: Capability) -> Bool { granted.contains(capability) }

    // Named accessors for the hot call sites, so a view reads `gate.vfrCharts` rather than
    // stringly-indirect lookups. Deliberately not exhaustive — `can(_:)` covers the rest.
    var vfrCharts: Bool          { can(.vfrCharts) }
    var ifrLowCharts: Bool       { can(.ifrLowCharts) }
    var ifrHighCharts: Bool      { can(.ifrHighCharts) }
    var plateGeoreferencing: Bool { can(.plateGeoreferencing) }
    var plateBinders: Bool       { can(.plateBinders) }
    var codedProcedures: Bool    { can(.codedProcedures) }
    var traffic: Bool            { can(.traffic) }
    var hazardLayers: Bool       { can(.hazardLayers) }
    var radarAndWXProducts: Bool { can(.radarAndWXProducts) }
    var minimaSolver: Bool       { can(.minimaSolver) }
    var windsAloft: Bool         { can(.windsAloft) }
    var airportClimate: Bool     { can(.airportClimate) }
    var routeGlideExposure: Bool { can(.routeGlideExposure) }
    var approachNotams: Bool     { can(.approachNotams) }
    var transcription: Bool      { can(.transcription) }

    /// Whether anything at all is paid for — drives "Upgrade" vs "Manage" in the UI.
    var isPaid: Bool { tier > .none && currency.grants }
}
