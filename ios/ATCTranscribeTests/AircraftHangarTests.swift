import XCTest
@testable import ATCTranscribe

/// The hangar editor: correcting a saved aircraft without re-filing the flight plan.
///
/// ⚠️ WHAT THESE PIN, AND WHY IT IS NOT MERELY TIDINESS. Editing a saved aircraft was reachable
/// only through the flight-plan strip's "Edit …", which appears for the FILED aeroplane alone — so
/// reaching any other one meant selecting it first, and selecting rewrites the plan's callsign and
/// aircraft type. A pilot correcting a landing distance had to change their flight plan to do it.
/// `AppModel.updateAircraft` is the path that does not, and the whole value of it is a negative
/// claim — that the plan did NOT move — which is exactly the kind of thing that silently regresses.
final class AircraftHangarTests: XCTestCase {

    override func tearDown() {
        AircraftStore.clear()      // never leak a hangar into another test or the running app
        FlightPlan.clear()
        super.tearDown()
    }

    private func seneca() -> AircraftProfile {
        AircraftProfile(callsign: "N8925T", type: "Piper Seneca", cruiseKts: 165, burnGPH: 16.5)
    }
    private func skyhawk() -> AircraftProfile {
        AircraftProfile(callsign: "N345AB", type: "Cessna 172", cruiseKts: 110, burnGPH: 8.5)
    }

    /// Two aeroplanes on file, the first one flying. Returns the model with the plan already filed.
    @MainActor private func hangar(filing filed: AircraftProfile,
                                  _ others: AircraftProfile...) -> AppModel {
        let model = AppModel()
        model.aircraftProfiles = [filed] + others
        model.selectAircraft(filed)
        XCTAssertEqual(model.flightPlan?.callsign, filed.callsign, "setup: the plan must be filed")
        XCTAssertEqual(model.selectedAircraft?.id, filed.id, "setup: and matched back to the profile")
        return model
    }

    /// THE REPORTED BUG. Correcting the aeroplane you are not flying must leave the plan alone.
    @MainActor
    func testEditingAnUnfiledAircraftDoesNotTouchTheFlightPlan() {
        let flying = seneca(), other = skyhawk()
        let model = hangar(filing: flying, other)

        var corrected = other
        corrected.landingOver50Ft = 1_335
        corrected.type = "Cessna 172S"
        model.updateAircraft(corrected)

        XCTAssertEqual(model.flightPlan?.callsign, "N8925T", "the filed callsign must not move")
        XCTAssertEqual(model.flightPlan?.aircraftType, "Piper Seneca", "nor the filed type")
        XCTAssertEqual(model.selectedAircraft?.id, flying.id, "still flying the same aeroplane")
        XCTAssertEqual(model.aircraftProfiles.first(where: { $0.id == other.id })?.landingOver50Ft,
                       1_335, "and the correction was actually saved")
    }

    /// ⚠️ THE ONE EXCEPTION. `selectedAircraft` matches the plan to a profile BY CALLSIGN, so a
    /// corrected tail number on the aeroplane already filed has to follow onto the plan — otherwise
    /// the plan points at a callsign no profile has, the strip's checkmark disappears, and the trip
    /// stats drop back to "–" with nothing on screen to explain why.
    @MainActor
    func testCorrectingTheFiledAircraftsTailNumberFollowsOntoThePlan() {
        let flying = seneca()
        let model = hangar(filing: flying, skyhawk())

        var corrected = flying
        corrected.callsign = "N8925Q"          // one transposed character, the usual slip
        model.updateAircraft(corrected)

        XCTAssertEqual(model.flightPlan?.callsign, "N8925Q", "the plan follows the corrected tail")
        XCTAssertEqual(model.selectedAircraft?.id, flying.id,
                       "so the profile is still matched, rather than orphaned by its own rename")
    }

    /// A performance edit to the aeroplane being flown keeps it filed and keeps feeding the stats.
    @MainActor
    func testEditingTheFiledAircraftsPerformanceKeepsItFiled() {
        let flying = seneca()
        let model = hangar(filing: flying, skyhawk())

        var corrected = flying
        corrected.cruiseKts = 172
        corrected.glideRatio = 10.5
        model.updateAircraft(corrected)

        XCTAssertEqual(model.flightPlan?.callsign, "N8925T")
        XCTAssertEqual(model.selectedAircraft?.cruiseKts, 172, "the stats read the corrected number")
        XCTAssertEqual(model.selectedAircraft?.glideRatio, 10.5)
    }

    /// An id the hangar has never seen is an ADD, and an add does file — the pilot who adds an
    /// aeroplane added it to fly it. The hangar's own Add button goes through this path.
    @MainActor
    func testAddingThroughTheHangarStillFilesTheNewAircraft() {
        let model = AppModel()
        model.aircraftProfiles = []
        model.flightPlan = nil

        model.updateAircraft(skyhawk())

        XCTAssertEqual(model.aircraftProfiles.count, 1)
        XCTAssertEqual(model.flightPlan?.callsign, "N345AB", "an add files, unlike an edit")
    }

    @MainActor
    func testAnEmptyProfileIsNotSaved() {
        let model = AppModel()
        model.aircraftProfiles = []
        model.updateAircraft(AircraftProfile())
        XCTAssertTrue(model.aircraftProfiles.isEmpty, "nothing worth keeping, nothing kept")
    }

    /// Deleting is left where it already was — inside the editor — and must not disturb the plan,
    /// because the plan, not the hangar, is the source of truth for the current flight.
    @MainActor
    func testDeletingAnUnfiledAircraftLeavesThePlanAlone() {
        let flying = seneca(), other = skyhawk()
        let model = hangar(filing: flying, other)
        model.deleteAircraft(other)
        XCTAssertEqual(model.aircraftProfiles.map(\.id), [flying.id])
        XCTAssertEqual(model.flightPlan?.callsign, "N8925T")
    }

    // MARK: - What the list says about each aeroplane

    /// The row's warning names what is still a default. A blank field is not neutral: each one
    /// substitutes a conservative value the pilot did not choose, and this line is the only place
    /// that says so before the number matters.
    func testGapsNameWhatIsStillADefault() {
        let bare = AircraftProfile(callsign: "N1", type: "Thing")
        let g = AircraftHangarView.gaps(bare)
        XCTAssertEqual(g, ["trip stats", "glide ratio", "landing distance", "turn-back height"])

        var full = bare
        full.cruiseKts = 110; full.burnGPH = 8.5; full.glideRatio = 9
        full.landingOver50Ft = 1_335; full.turnbackMinimumFtAGL = 800
        XCTAssertTrue(AircraftHangarView.gaps(full).isEmpty, "nothing left to a default")
    }

    /// ⚠️ Half-filled trip stats are still a gap: the strip needs BOTH cruise and burn before it can
    /// show an ETE and a fuel figure, so reporting "done" on one of them would be a lie.
    func testHalfFilledTripStatsAreStillAGap() {
        var half = AircraftProfile(callsign: "N1", type: "Thing", cruiseKts: 110)
        half.glideRatio = 9; half.landingOver50Ft = 1_335; half.turnbackMinimumFtAGL = 800
        XCTAssertEqual(AircraftHangarView.gaps(half), ["trip stats"])
    }

    /// ⚠️ A helicopter must not be nagged for two numbers the app deliberately refuses to use: there
    /// is no fixed-wing landing distance for an autorotation (`AircraftSheet.save` nils it) and no
    /// impossible turn to brief. Asking for them would be asking the pilot to fix a non-problem.
    func testGapsDoNotNagARotorcraftAboutFixedWingNumbers() {
        var heli = AircraftProfile(callsign: "N99HL", type: "R44")
        heli.isRotorcraft = true
        heli.cruiseKts = 100; heli.burnGPH = 15; heli.glideRatio = 4
        XCTAssertTrue(AircraftHangarView.gaps(heli).isEmpty,
                      "no landing distance and no turn-back is the CORRECT state for a rotorcraft")
    }

    func testDetailLineShowsOnlyWhatIsSet() {
        XCTAssertEqual(AircraftHangarView.detailLine(skyhawk()), "Cessna 172 · 110 kt · 8.5 gph")
        XCTAssertEqual(AircraftHangarView.detailLine(AircraftProfile(callsign: "N1")), "No details yet",
                       "a profile with nothing but a tail says so rather than showing an empty line")
        var floats = skyhawk()
        floats.waterOps = .floatOnly
        XCTAssertTrue(AircraftHangarView.detailLine(floats).hasSuffix("floats"),
                      "the water configuration is worth seeing without opening the editor")
    }
}
