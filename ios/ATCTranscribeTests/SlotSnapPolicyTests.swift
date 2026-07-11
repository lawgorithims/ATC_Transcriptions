import XCTest
@testable import ATCTranscribe

/// H3 (remediation): the conservative frequency-snap policy. A heard frequency that is already a
/// valid airband channel (in-band + on-raster) is NEVER rewritten — it is most likely a handoff to
/// a facility outside this airport's published table, and a Levenshtein-1 "snap" would silently
/// corrupt a correctly-heard frequency. Only a garbled/impossible value may snap.
///
/// The published table here is a single TWR frequency 126.55; each heard value below is exactly
/// Levenshtein-1 from it, so the ONLY thing deciding snap-vs-protect is the policy. Boundary values
/// verified numerically against `onRaster` before these were written.
final class SlotSnapPolicyTests: XCTestCase {

    /// KBOS-shaped context whose only comms frequency is 126.55.
    private func ctx() -> AirportContextData {
        AirportContextData(ident: "KBOS", frequencies: ["TWR": [126.55]])
    }

    private func freqEdit(_ edits: [SlotSnap.Edit]) -> SlotSnap.Edit? {
        edits.first { $0.slot == "frequency" }
    }

    // MARK: - conservative policy ON (the shipped LivePipeline path)

    func testValidChannelIsNeverSnapped() {
        // 127.55 is in-band AND on-raster → a real channel. It must be LEFT ALONE even though it is
        // one digit from the published 126.55. This is the exact HIGH bug: a correctly-heard handoff
        // frequency silently rewritten to a wrong-but-plausible one.
        let (text, edits) = SlotSnap.apply("contact tower one two seven point five five",
                                           context: ctx(), conservativeFrequencies: true)
        let e = freqEdit(edits)
        XCTAssertEqual(e?.verdict, "unverified", "a valid channel must read unverified, not snapped")
        XCTAssertNotEqual(e?.verdict, "snapped")
        XCTAssertFalse(e?.applied ?? false)
        XCTAssertTrue(text.contains("2 7") || text.contains("27"), "the heard value must survive: \(text)")
    }

    func testShorthandXx5ChannelIsProtected() {
        // 126.52 is the 2-decimal shorthand for the .xx5 channel 126.525 → on-raster ONLY via the
        // restored second arm of onRaster. Pins that restore: without it 126.52 reads as garbled and
        // would snap to 126.55.
        let (_, edits) = SlotSnap.apply("contact tower one two six point five two",
                                        context: ctx(), conservativeFrequencies: true)
        XCTAssertEqual(freqEdit(edits)?.verdict, "unverified",
                       "an .xx5-shorthand channel must be recognized as on-raster and protected")
    }

    func testGarbledValueStillSnaps() {
        // 126.54 is in-band but off-raster on BOTH arms → genuinely garbled → still snaps to the
        // unique edit-1 published neighbor. Conservatism must not suppress a real correction.
        let (_, edits) = SlotSnap.apply("contact tower one two six point five four",
                                        context: ctx(), conservativeFrequencies: true)
        let e = freqEdit(edits)
        XCTAssertEqual(e?.verdict, "snapped", "a garbled off-raster value must still snap")
        XCTAssertEqual(e?.applied, true)
    }

    func testExactValueVerifies() {
        let (_, edits) = SlotSnap.apply("contact tower one two six point five five",
                                        context: ctx(), conservativeFrequencies: true)
        XCTAssertEqual(freqEdit(edits)?.verdict, "verified")
    }

    func testOutOfBandValueIsInvalid() {
        // 141.2 is above the airband ceiling → the conservative gate does not fire (not a valid
        // channel), no edit-1 neighbor exists → invalid, as before.
        let (_, edits) = SlotSnap.apply("contact tower one four one point two",
                                        context: ctx(), conservativeFrequencies: true)
        XCTAssertEqual(freqEdit(edits)?.verdict, "invalid")
    }

    func testNavBandSnapUnaffectedByPolicy() {
        // The airband-only conservative gate must not touch nav-band (ILS) snapping.
        let navCtx = AirportContextData(ident: "KBOS", navFrequencies: [109.30])
        let (_, edits) = SlotSnap.apply("contact localizer one zero nine point five",
                                        context: navCtx, conservativeFrequencies: true)
        XCTAssertEqual(freqEdit(edits)?.verdict, "snapped",
                       "an ILS near-miss must still snap in the nav band under the policy")
    }

    // MARK: - policy OFF (default): the byte-parity path is unchanged

    func testLegacyPathStillSnapsValidChannel() {
        // The fixture twin: WITHOUT the flag (the byte-parity default the fixtures replay), the same
        // valid 127.55 snaps to 126.55 — proving the flag alone gates the new behavior and the
        // Python-locked path is untouched.
        let (_, edits) = SlotSnap.apply("contact tower one two seven point five five", context: ctx())
        let e = freqEdit(edits)
        XCTAssertEqual(e?.verdict, "snapped", "the default (parity) path must snap exactly as before")
        XCTAssertEqual(e?.applied, true)
    }
}
