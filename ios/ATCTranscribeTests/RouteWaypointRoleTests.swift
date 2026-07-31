import XCTest
import UIKit
@testable import ATCTranscribe

/// Colouring the route's waypoints by the segment role the FAA publishes for them.
///
/// The role was always READ from CIFP (`LegRole`, used to split the missed approach) and then dropped
/// at the `ResolvedLeg` boundary, so the map drew the final approach fix and the missed-approach point
/// in exactly the same white as an enroute intersection. These tests pin the two halves of carrying it
/// through: which role survives when the same fix is coded twice, and that the three tints stay legible
/// and distinct in every theme.
final class RouteWaypointRoleTests: XCTestCase {

    private func leg(_ ident: String, _ role: LegRole, lat: Double = 42.0, lon: Double = -71.0) -> ResolvedLeg {
        ResolvedLeg(ident: ident, kind: .waypoint, coord: Coord(lat: lat, lon: lon), role: role)
    }

    // MARK: - the join fix is coded from both sides

    func testEnrouteLegsCarryNoRole() {
        // The default matters: every enroute construction site omits `role`, and roles exist only on
        // approaches — all 66,103 role-marked legs in the shipped cycle sit on IAP rows.
        let r = RouteResolver.resolve([RouteLeg(ident: "BOS", kind: .vor)]).points
        for p in r { XCTAssertEqual(p.role, .none, "an enroute leg must not claim a published role") }
    }

    func testRoleRankPutsTheUnmarkedLegLast() {
        // `.none` means "the source marks nothing here", never "no role applies" — so it must lose
        // every tie, which is what makes the promotion below fire.
        for r in [LegRole.missedApproachPoint, .finalApproachFix, .initialApproachFix,
                  .finalApproachCourseFix, .intermediateFix] {
            XCTAssertGreaterThan(ProcedureRoute.roleRank(r), ProcedureRoute.roleRank(.none),
                                 "\(r) must outrank an unmarked leg")
        }
        XCTAssertGreaterThan(ProcedureRoute.roleRank(.finalApproachFix),
                             ProcedureRoute.roleRank(.initialApproachFix))
        XCTAssertGreaterThan(ProcedureRoute.roleRank(.missedApproachPoint),
                             ProcedureRoute.roleRank(.finalApproachFix))
    }

    func testJoinFixKeepsTheFAFOverAnUnmarkedTransitionLeg() {
        // THE case this promotion exists for. Measured on the shipped cycle: 1,026 approaches have a
        // transition whose last leg carries no role joining a proper row whose first leg is the FAF.
        // First-wins would keep the unmarked coding and the FAF would draw as an ordinary waypoint.
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("CRLTN", .none), to: &out)
        ProcedureRoute.appendDeduped(leg("CRLTN", .finalApproachFix), to: &out)
        XCTAssertEqual(out.count, 1, "the duplicated join fix must still collapse to one label")
        XCTAssertEqual(out.first?.role, .finalApproachFix, "the FAF mark must survive the collapse")
    }

    func testJoinFixKeepsTheFAFOverAnIAFCoding() {
        // 102 approaches code the join fix IAF on the transition and FAF on the proper row: it really
        // is both, and the fix where you go down is the one worth pointing at.
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("SQ", .initialApproachFix), to: &out)
        ProcedureRoute.appendDeduped(leg("SQ", .finalApproachFix), to: &out)
        XCTAssertEqual(out.first?.role, .finalApproachFix)
    }

    func testJoinFixDoesNotDemoteTheIAF() {
        // The overwhelmingly common join — 6,325 A→I — must keep the transition's IAF, because the
        // final approach COURSE fix is not a colour we draw and demoting would lose the entry mark.
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("GOSHI", .initialApproachFix), to: &out)
        ProcedureRoute.appendDeduped(leg("GOSHI", .finalApproachCourseFix), to: &out)
        XCTAssertEqual(out.first?.role, .initialApproachFix, "promotion must never run downhill")
    }

    func testTwoDistinctFixesAreNotCollapsed() {
        var out: [ResolvedLeg] = []
        ProcedureRoute.appendDeduped(leg("GOSHI", .initialApproachFix), to: &out)
        ProcedureRoute.appendDeduped(leg("CRLTN", .finalApproachFix), to: &out)
        XCTAssertEqual(out.map(\.ident), ["GOSHI", "CRLTN"])
    }

    // MARK: - the map features

    func testFeatureCarriesTheRoleAttribute() {
        let feats = MapLibreChartView.Coordinator.routeWptFeatures([
            leg("GOSHI", .initialApproachFix, lat: 42.1, lon: -70.9),
            leg("CRLTN", .finalApproachFix, lat: 42.2, lon: -70.8),
            leg("RUMBL", .none, lat: 42.3, lon: -70.7),
        ])
        XCTAssertEqual(feats.count, 3)
        XCTAssertEqual(feats[0].attributes["role"] as? String, LegRole.initialApproachFix.rawValue)
        XCTAssertEqual(feats[1].attributes["role"] as? String, LegRole.finalApproachFix.rawValue)
        XCTAssertEqual(feats[2].attributes["role"] as? String, LegRole.none.rawValue)
    }

    func testRevisitedFixKeepsTheMoreSpecificRole() {
        // A course reversal brings the route back through a fix it already passed. The two visits are
        // coded from different sides and only ONE label survives the ident@coord dedupe — it must not
        // be whichever visit happened to come first.
        let feats = MapLibreChartView.Coordinator.routeWptFeatures([
            leg("KAYSE", .none, lat: 60.7, lon: -161.8),
            leg("OTHER", .none, lat: 60.8, lon: -161.7),
            leg("KAYSE", .finalApproachFix, lat: 60.7, lon: -161.8),
        ])
        XCTAssertEqual(feats.count, 2, "the revisited fix must still produce one label")
        XCTAssertEqual(feats[0].attributes["role"] as? String, LegRole.finalApproachFix.rawValue)
    }

    func testSameIdentAtADifferentPositionIsNotMerged() {
        // Two different fixes really do share an ident; they are both real points on the route.
        let feats = MapLibreChartView.Coordinator.routeWptFeatures([
            leg("ABC", .none, lat: 42.0, lon: -71.0),
            leg("ABC", .finalApproachFix, lat: 33.0, lon: -84.0),
        ])
        XCTAssertEqual(feats.count, 2)
    }

    // MARK: - the palette

    /// Every theme the map can resolve, including the two `.smartDark` variants.
    private var allThemes: [(String, MapTheme)] {
        [("cockpit", .forTheme(.cockpit)), ("day", .forTheme(.day)), ("night", .forTheme(.night)),
         ("smartDark", .smartDark(appTheme: .day)), ("smartDark-night", .smartDark(appTheme: .night))]
    }

    func testRoleColoursAreDistinctInEveryTheme() {
        for (name, t) in allThemes {
            let set = Set([t.routeWptText, t.routeWptIAF, t.routeWptFAF, t.routeWptMAP].map(MapTheme.hexString))
            XCTAssertEqual(set.count, 4, "\(name): a role colour collides with another — the coding is invisible")
        }
    }

    func testRoleColoursDoNotCollideWithTheConstraintSublabels() {
        // The altitude and speed sublabels sit directly under the ident; a shared colour would read as
        // one run of text rather than an ident plus its restrictions.
        for (name, t) in allThemes {
            for c in [t.routeWptIAF, t.routeWptFAF, t.routeWptMAP] {
                XCTAssertNotEqual(MapTheme.hexString(c), MapTheme.hexString(t.routeWptAlt), "\(name)")
                XCTAssertNotEqual(MapTheme.hexString(c), MapTheme.hexString(t.routeWptSpeed), "\(name)")
            }
        }
    }

    func testNightKeepsEveryRoleColourRedDominant() {
        // The night theme is red-preserving for dark adaptation, so the roles CANNOT be told apart by
        // hue there. Green/amber would defeat the whole point of the theme.
        for (name, t) in [("night", MapTheme.forTheme(.night)), ("smartDark-night", MapTheme.smartDark(appTheme: .night))] {
            for (label, c) in [("IAF", t.routeWptIAF), ("FAF", t.routeWptFAF), ("MAP", t.routeWptMAP)] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThan(r, g, "\(name) \(label) is not red-dominant")
                XCTAssertGreaterThan(r, b, "\(name) \(label) is not red-dominant")
            }
        }
    }

    func testNightOrdersTheRolesBySaturationNotBrightness() {
        // Hue is unavailable at night and so is luminance: Rec. 709 weights green at 0.72, so the ONLY
        // way to make a red label measurably brighter is to add green — the one thing a dark-adaptation
        // theme must not do. (An earlier revision of this palette failed exactly that way: the alarm red
        // computed DIMMER than the muted lead-in it was supposed to outrank.) The ordering that is both
        // available and correct is purity of red, which is what `nightAirspace` already uses.
        for (name, t) in [("night", MapTheme.forTheme(.night)), ("smartDark-night", MapTheme.smartDark(appTheme: .night))] {
            func green(_ c: UIColor) -> CGFloat {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                return g
            }
            let ladder = [("unmarked", t.routeWptText), ("IAF", t.routeWptIAF),
                          ("FAF", t.routeWptFAF), ("MAP", t.routeWptMAP)]
            for (i, step) in ladder.dropFirst().enumerated() {
                XCTAssertLessThan(green(step.1), green(ladder[i].1),
                                  "\(name): \(step.0) must be a purer red than \(ladder[i].0)")
            }
        }
    }

    func testNightRoleColoursNeverEmitMoreGreenThanTheDayThemeWould() {
        // A cheap guard against someone "fixing" night legibility by pasting the day tints in: the day
        // amber is 0x4B green, which on a dark-adapted eye is exactly the emission this theme avoids.
        let night = MapTheme.forTheme(.night)
        for c in [night.routeWptIAF, night.routeWptFAF, night.routeWptMAP] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertLessThan(g, r * 0.75, "a night role colour drifted toward amber/green")
        }
    }

    func testTextExpressionIsDataDrivenAndCoversTheThreeRoles() {
        for (name, t) in allThemes {
            let e = MapLibreChartView.Coordinator.routeWptTextExpr(t)
            let s = e.description
            XCTAssertTrue(s.contains("role"), "\(name): the expression must key on the role attribute")
            for role in [LegRole.initialApproachFix, .finalApproachFix, .missedApproachPoint] {
                XCTAssertTrue(s.contains(role.rawValue), "\(name): \(role.rawValue) missing from the match")
            }
        }
    }

    func testTextExpressionIsNotAConstant() {
        // The regression guard: assigning a constant here — which is what shipped, and what the theme
        // re-apply pass did until this change — silently removes the whole feature.
        let e = MapLibreChartView.Coordinator.routeWptTextExpr(.forTheme(.day))
        XCTAssertNotEqual(e.expressionType, .constantValue,
                          "route-wpt-sym textColor collapsed back to a constant")
    }
}
