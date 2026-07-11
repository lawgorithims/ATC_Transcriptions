import XCTest
@testable import ATCTranscribe

/// Speaker-label fusion: parity of the pure `SpeakerFusion` mapping with the offline Python reference
/// (`atc_speaker_cluster.cluster_affinity` + `fuse_line`, via `fusion_fixtures.json` from
/// `Tools/gen_fusion_fixtures.py`), plus behavior tests for the runtime-only conservative fill guard
/// in `SpeakerLabeler` (which the offline pass has no equivalent of, so it is tested here, not for
/// parity).
final class SpeakerFusionTests: XCTestCase {

    // MARK: - Python parity (the faithful 1:1 mapping)

    private struct Member: Decodable { let role: String; let callsign: String? }
    private struct Expected: Decodable { let role_fused: String; let speaker_label: String; let fused_from: String }
    private struct Cluster: Decodable { let members: [Member]; let affinity: String; let expected: [Expected] }

    func testPythonParity() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fusion_fixtures",
                                                           withExtension: "json"),
                                "fusion_fixtures.json missing from the test bundle")
        let clusters = try JSONDecoder().decode([Cluster].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(clusters.count, 5)
        for cluster in clusters {
            // Affinity over the WHOLE cluster (offline computes it once, then fuses each member).
            var c = 0, p = 0
            var first: TurnRole?
            for m in cluster.members {
                switch TurnRole(rawValue: m.role) ?? .unknown {
                case .controller: c += 1; if first == nil { first = .controller }
                case .pilot:      p += 1; if first == nil { first = .pilot }
                case .unknown:    break
                }
            }
            let affinity = SpeakerFusion.affinity(controller: c, pilot: p, firstConfident: first)
            XCTAssertEqual(affinity.rawValue, cluster.affinity,
                           "affinity for \(cluster.members.map(\.role))")
            for (i, m) in cluster.members.enumerated() {
                let f = SpeakerFusion.fuse(ownRole: TurnRole(rawValue: m.role) ?? .unknown,
                                           affinity: affinity, callsign: m.callsign)
                XCTAssertEqual(f.roleFused.rawValue, cluster.expected[i].role_fused, "role_fused #\(i)")
                XCTAssertEqual(f.label.fixtureString, cluster.expected[i].speaker_label, "label #\(i)")
                XCTAssertEqual(f.from.rawValue, cluster.expected[i].fused_from, "fused_from #\(i)")
            }
        }
    }

    // MARK: - Pure mapping unit checks

    func testAffinityTieBreaksToFirstConfident() {
        XCTAssertEqual(SpeakerFusion.affinity(controller: 1, pilot: 1, firstConfident: .controller), .controller)
        XCTAssertEqual(SpeakerFusion.affinity(controller: 1, pilot: 1, firstConfident: .pilot), .pilot)
        XCTAssertEqual(SpeakerFusion.affinity(controller: 2, pilot: 1, firstConfident: .pilot), .controller)
        XCTAssertEqual(SpeakerFusion.affinity(controller: 0, pilot: 0, firstConfident: nil), .unknown)
    }

    func testConfidentContentRoleNeverOverridden() {
        // A controller line inside a pilot-affinity cluster stays ATC (content wins).
        let f = SpeakerFusion.fuse(ownRole: .controller, affinity: .pilot, callsign: nil)
        XCTAssertEqual(f.roleFused, .controller)
        XCTAssertEqual(f.label, .atc)
        XCTAssertEqual(f.from, .content)
    }

    func testUnknownFilledToPilotWithoutCallsignIsGenericPilot() {
        let f = SpeakerFusion.fuse(ownRole: .unknown, affinity: .pilot, callsign: nil)
        XCTAssertEqual(f.label, .pilot)
        XCTAssertEqual(f.from, .acoustic)
    }

    func testUnknownAffinityKeepsUnknownEvenWithCallsign() {
        // Offline asymmetry: role_fused==unknown beats a present callsign.
        let f = SpeakerFusion.fuse(ownRole: .unknown, affinity: .unknown, callsign: "delta 5")
        XCTAssertEqual(f.label, .unknown)
        XCTAssertEqual(f.from, .none)
    }

    // MARK: - Runtime conservative fill guard (SpeakerLabeler)

    /// A minimal record for the labeler (only the fields fusion reads).
    private func rec(_ role: TurnRole, speaker: Int? = nil,
                     callsign: String? = nil, distance: Float? = nil) -> TranscriptRecord {
        var r = TranscriptRecord(text: "x", streamStartS: 0, streamEndS: 0, audioDurationMs: 0,
                                 captureToTextMs: 0, transcribeMs: 0, realTimeFactor: 0, prompt: "",
                                 corrected: "", corrections: [], timestamp: "")
        r.role = role; r.speaker = speaker; r.callsign = callsign; r.speakerDistance = distance
        return r
    }

    /// Replays inputs through the labeler exactly as `TranscriptionSession.append` does (fuse each,
    /// then retroactively re-fuse the flipped speaker's unknown lines).
    private func runSession(_ labeler: SpeakerLabeler, _ inputs: [TranscriptRecord]) -> [TranscriptRecord] {
        var records: [TranscriptRecord] = []
        for input in inputs {
            var r = input
            let flipped = labeler.ingest(&r)
            records.append(r)
            if let spk = flipped {
                for i in records.indices where records[i].speaker == spk && records[i].role == .unknown {
                    var u = records[i]; labeler.refuse(&u); records[i] = u
                }
            }
        }
        return records
    }

    /// A labeler with acoustic fill ENABLED (the mechanism under test). The LIVE default is OFF —
    /// see `SpeakerLabeler.acousticFillEnabled` and `testAcousticFillDefaultsOff` — because the
    /// corpus study showed on-device MFCC can't separate same-feed speakers.
    private func filler() -> SpeakerLabeler {
        let l = SpeakerLabeler()
        l.acousticFillEnabled = true
        return l
    }

    func testAcousticFillDefaultsOff() {
        // Deployment default: even a mature, pure, tight controller cluster does NOT fill an unknown
        // line — the shipped feature is content-only fusion (acoustic separation is unreliable).
        let out = runSession(SpeakerLabeler(), [
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.unknown, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
        ])
        XCTAssertEqual(out[1].speakerLabel, .unknown)
        XCTAssertEqual(out[1].fusedFrom, FusedProvenance.none)
    }

    func testImmatureClusterDoesNotFill() {
        // 3 confident controllers (< the 4-member maturity bar) → the unknown line is not filled.
        let out = runSession(filler(), [
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.unknown, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
        ])
        XCTAssertEqual(out[1].speakerLabel, .unknown)
        XCTAssertEqual(out[1].fusedFrom, .none)
    }

    func testMatureControllerClusterRetroactivelyFillsUnknown() {
        // The unknown arrives 2nd, before the cluster matures; the 4th controller matures it and the
        // earlier unknown line is retroactively relabeled ATC (voice-inferred).
        let out = runSession(filler(), [
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.unknown, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
        ])
        XCTAssertEqual(out[1].speakerLabel, .atc)
        XCTAssertEqual(out[1].fusedFrom, .acoustic)
        // Confident controller lines are content-labeled ATC throughout.
        XCTAssertEqual(out[0].speakerLabel, .atc)
        XCTAssertEqual(out[0].fusedFrom, .content)
    }

    func testBorderlineAssignmentIsNotFilled() {
        // Mature, pure controller cluster, but the unknown line's voice only borderline matched
        // (distance ≥ maxFillDistance) → the tightness gate refuses to fill it.
        let out = runSession(filler(), [
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.unknown, speaker: 0, distance: 0.50),
        ])
        XCTAssertEqual(out.last?.speakerLabel, .unknown)
        XCTAssertEqual(out.last?.fusedFrom, FusedProvenance.none)
    }

    func testPilotClusterNeverFills() {
        // Direction gate: we never fill toward pilot even for a mature, pure pilot cluster.
        let out = runSession(filler(), [
            rec(.pilot, speaker: 0, callsign: "delta 1", distance: 0.01),
            rec(.pilot, speaker: 0, callsign: "delta 1", distance: 0.01),
            rec(.pilot, speaker: 0, callsign: "delta 1", distance: 0.01),
            rec(.pilot, speaker: 0, callsign: "delta 1", distance: 0.01),
            rec(.unknown, speaker: 0, distance: 0.01),
        ])
        XCTAssertEqual(out.last?.speakerLabel, .unknown)
    }

    func testImpureClusterDoesNotFill() {
        // 3 controller + 2 pilot = 60% purity (< 75%) → not confident enough to fill.
        let out = runSession(filler(), [
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.controller, speaker: 0, distance: 0.01),
            rec(.pilot, speaker: 0, callsign: "delta 1", distance: 0.01),
            rec(.pilot, speaker: 0, callsign: "delta 1", distance: 0.01),
            rec(.unknown, speaker: 0, distance: 0.01),
        ])
        XCTAssertEqual(out.last?.speakerLabel, .unknown)
    }

    func testDiarizationOffIsContentOnly() {
        let labeler = SpeakerLabeler()
        var ctl = rec(.controller, speaker: nil)
        XCTAssertNil(labeler.ingest(&ctl))
        XCTAssertEqual(ctl.speakerLabel, .atc)
        XCTAssertEqual(ctl.fusedFrom, .content)

        var unk = rec(.unknown, speaker: nil)
        XCTAssertNil(labeler.ingest(&unk))
        XCTAssertEqual(unk.speakerLabel, .unknown)
        XCTAssertEqual(unk.fusedFrom, .none)
    }
}
