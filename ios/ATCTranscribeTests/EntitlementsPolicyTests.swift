import XCTest
@testable import ATCTranscribe

/// The entitlement policy, asserted as a table rather than trusted as a switch statement.
///
/// `Entitlements.allows` is a pure function of (capability, tier, currency), so the whole policy is
/// enumerable — every capability × every tier × every currency is 24 × 4 × 5 = 480 cases, which is
/// cheap to check exhaustively and is the only way the invariants below stay true as the tier
/// boundaries move. They WILL move: the boundaries are a pricing hypothesis, and the point of
/// gating on capability is that a repackage is one edit to `minimumTier`. These tests are what makes
/// that edit safe.
final class EntitlementsPolicyTests: XCTestCase {

    private let currencies: [EntitlementCurrency] = [
        .verified(asOf: Date()),
        .unverified(lastVerified: Date()),
        .lapsed(since: Date()),
        .revoked(at: Date()),
        .none,
    ]

    // MARK: The never-gate list

    /// THE MOST IMPORTANT TEST IN THIS FILE.
    ///
    /// Every always-free capability must stay granted at `Tier.none` and at EVERY currency —
    /// including `.lapsed` and `.revoked`. These are the safety surfaces and the costs-us-nothing
    /// surfaces: nav-data currency, the nearest-airport glide page, the GPS integrity banner, plate
    /// PDFs, weather, TFRs, notes and the logbook.
    ///
    /// If this fails, a pilot who let a subscription lapse — or whose card simply expired — is
    /// looking at an EFB that has taken away the engine-failure page and is showing them stale
    /// navigation data it refuses to update. That is the failure
    /// `UI/DataCurrencyBanner.swift` says this project keeps designing against, reintroduced
    /// through the billing system.
    func testAlwaysFreeCapabilitiesAreNeverGated() {
        let alwaysFree = Capability.allCases.filter(\.isAlwaysFree)
        XCTAssertFalse(alwaysFree.isEmpty, "the never-gate list cannot be empty")

        for capability in alwaysFree {
            for tier in Tier.allCases {
                for currency in currencies {
                    XCTAssertTrue(
                        Entitlements.allows(capability, tier: tier, currency: currency),
                        "\(capability.rawValue) must be free at tier \(tier) / currency \(currency). "
                        + "It is on the never-gate list because it is either a safety surface or costs "
                        + "us nothing to serve. Removing it from `isAlwaysFree` is a product decision, "
                        + "not a refactor.")
                }
            }
        }
    }

    /// A lapsed or revoked entitlement grants the never-gate list and nothing more, whatever tier
    /// was previously held. Pins the exact blast radius of a lapse.
    func testLapsedAndRevokedGrantExactlyTheFreeSet() {
        let free = Entitlements.granted(tier: .none, currency: .none)
        for tier in Tier.allCases {
            XCTAssertEqual(Entitlements.granted(tier: tier, currency: .lapsed(since: Date())), free,
                           "a lapsed \(tier) must fall back to exactly the free set")
            XCTAssertEqual(Entitlements.granted(tier: tier, currency: .revoked(at: Date())), free,
                           "a revoked \(tier) must fall back to exactly the free set")
        }
    }

    // MARK: Fail open / fail closed

    /// `.unverified` grants exactly what `.verified` grants, at every tier.
    ///
    /// This is the fail-OPEN half of the design, and it is deliberate: a network failure must never
    /// downgrade an entitlement. `ChartLibrary.refreshCatalog()` documents the precedent — *"A pilot
    /// who taps 'check' while taxiing must not lose the charts they already have."* An entitlement
    /// that fails closed on a timeout is that bug with a worse blast radius.
    func testUnverifiedGrantsTheSameAsVerified() {
        for tier in Tier.allCases {
            XCTAssertEqual(
                Entitlements.granted(tier: tier, currency: .unverified(lastVerified: Date())),
                Entitlements.granted(tier: tier, currency: .verified(asOf: Date())),
                "offline must not downgrade \(tier). If this is ever changed deliberately, a paying "
                + "pilot loses charts mid-flight when the backend is unreachable.")
        }
    }

    /// Revocation is the one case with no grace — it means the money came back.
    func testRevocationIsNotTreatedAsGrace() {
        XCTAssertFalse(EntitlementCurrency.revoked(at: Date()).grants)
        XCTAssertFalse(Entitlements.allows(.ifrLowCharts, tier: .pro, currency: .revoked(at: Date())))
    }

    // MARK: Ladder containment

    /// The ladder must be strictly nested: Flight Bag ⊂ Pro ⊂ Pro + Performance.
    ///
    /// Not a packaging preference — a StoreKit constraint. Subscription-group *levels* only give
    /// correct automatic upgrade (immediate, prorated) and downgrade (at renewal) semantics when the
    /// tiers contain one another. Non-overlapping tiers need separate groups, and then one person
    /// can hold two live subscriptions at once and we own the reconciliation.
    func testTiersAreStrictlyNested() {
        let verified = EntitlementCurrency.verified(asOf: Date())
        let ordered = Tier.allCases.sorted()
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            let a = Entitlements.granted(tier: lower, currency: verified)
            let b = Entitlements.granted(tier: higher, currency: verified)
            XCTAssertTrue(a.isSubset(of: b),
                          "\(higher) must grant everything \(lower) does. Missing: \(a.subtracting(b))")
        }
    }

    /// Each paid tier must actually add something, or it is not a tier a customer can be sold.
    func testEachPaidTierAddsAtLeastOneCapability() {
        let verified = EntitlementCurrency.verified(asOf: Date())
        let ordered = Tier.allCases.sorted()
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            let added = Entitlements.granted(tier: higher, currency: verified)
                .subtracting(Entitlements.granted(tier: lower, currency: verified))
            XCTAssertFalse(added.isEmpty,
                           "\(higher) grants nothing \(lower) does not — there is no reason to buy it.")
        }
    }

    // MARK: Not-sold capabilities

    /// A capability with no `minimumTier` is refused at EVERY tier, including the top one.
    ///
    /// This is what keeps an unfinished or unlicensed feature out of a paid tier by construction
    /// rather than by remembering. Transcription is the live case: compiled out, and its model is
    /// trained on data whose licence says research use only.
    func testUnsoldCapabilitiesAreRefusedAtEveryTier() {
        let unsold = Capability.allCases.filter { $0.minimumTier == nil }
        XCTAssertTrue(unsold.contains(.transcription),
                      "transcription must stay unsold until the model licence and the cockpit audio "
                      + "path both clear — see Capability.minimumTier.")
        for capability in unsold {
            for tier in Tier.allCases {
                for currency in currencies {
                    XCTAssertFalse(
                        Entitlements.allows(capability, tier: tier, currency: currency),
                        "\(capability.rawValue) has no minimumTier (not sold) but was granted at "
                        + "\(tier)/\(currency)")
                }
            }
        }
    }

    /// Landability must not be sellable. It is a developer preview behind the diagnostics unlock
    /// (`AppModel.offFieldLayerAvailable`) after failing its ground-truth eval — build 110's notes
    /// record that it offered solar farms and orchards as landing candidates. It must never appear
    /// in a tier's feature list, and the policy is where that is enforced rather than remembered.
    func testLandabilityIsNotAPaidCapability() {
        XCTAssertEqual(Capability.landability.minimumTier, Tier.none,
                       "landability must not require a paid tier — it is a hidden developer preview, "
                       + "not a feature we sell.")
    }

    /// The cockpit hardware link is free for anyone who gets a receiver working. The Obelisk
    /// appliance does not exist as a shipping product and the Stratux path is unresolved, so it
    /// cannot be a paid entitlement.
    func testCockpitHardwareLinkIsNotAPaidCapability() {
        XCTAssertEqual(Capability.cockpitHardwareLink.minimumTier, Tier.none,
                       "the hardware link must not be sold — the appliance it depends on is unfinished.")
    }

    // MARK: The gate value

    /// `EntitlementGate` must agree with `Entitlements.allows` for every combination, since view
    /// code reads the gate and never calls the policy directly.
    func testGateMatchesThePolicy() {
        for tier in Tier.allCases {
            for currency in currencies {
                let gate = EntitlementGate(tier: tier, currency: currency)
                for capability in Capability.allCases {
                    XCTAssertEqual(gate.can(capability),
                                   Entitlements.allows(capability, tier: tier, currency: currency),
                                   "gate disagrees with policy for \(capability.rawValue) at "
                                   + "\(tier)/\(currency)")
                }
            }
        }
    }

    /// The free gate is the value every failure path resolves to, so it must be genuinely free —
    /// not accidentally carrying a paid capability.
    func testFreeGateGrantsNoPaidCapability() {
        for capability in Capability.allCases where (capability.minimumTier ?? .none) > .none {
            XCTAssertFalse(EntitlementGate.free.can(capability),
                           "EntitlementGate.free grants paid capability \(capability.rawValue)")
        }
    }

    func testFreeGateIsNotPaid() {
        XCTAssertFalse(EntitlementGate.free.isPaid)
        XCTAssertTrue(EntitlementGate(tier: .pro, currency: .verified(asOf: Date())).isPaid)
        XCTAssertFalse(EntitlementGate(tier: .pro, currency: .lapsed(since: Date())).isPaid)
    }

    // MARK: Tier ordering

    func testTierOrderingIsMonotonicWithRawValue() {
        XCTAssertEqual(Tier.allCases.sorted(), [.none, .flightBag, .pro, .proPerformance],
                       "Tier ordering is load-bearing: `tier >= minimum` is the whole check.")
        XCTAssertTrue(Tier.none < Tier.flightBag)
        XCTAssertTrue(Tier.pro < Tier.proPerformance)
    }
}
