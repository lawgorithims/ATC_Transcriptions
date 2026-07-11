import XCTest
@testable import ATCTranscribe

/// A "live feed" debug run in the Simulator: stream the 5 bundled REAL ATC clips through the REAL
/// on-device pipeline (VAD → Diarizer/SpeakerModel → TurnRoleTagger → SpeakerLabeler) with the debug
/// shadow log active, and print (a) the per-line fusion decisions the app's shadow log emits and
/// (b) the raw acoustic separation of the 3-scalar fingerprint — the baseline Stage-5a (MFCC) must
/// beat. No Whisper model is needed (the reference transcript is scripted through the `Transcribing`
/// seam; the AUDIO still drives real VAD + acoustic clustering).
final class FusionShadowLogTests: XCTestCase {

    private struct Clip { let file: String; let reference: String }
    private let clips = [
        Clip(file: "usgold_ewr_aal618", reference: "american 618 you can continue down to victor"),
        Clip(file: "usgold_dfw_aal2124", reference: "american 2124 descend and maintain 6000"),
        Clip(file: "usgold_bna_ual1616", reference: "tower united 1616 on approach 20l"),
        Clip(file: "usgold_dfw_frontier2471", reference: "frontier flight 2471 contact tower 12655"),
        Clip(file: "usgold_sfo_ils28r", reference: "san francisco tower mission 699 inbound ils 28r"),
    ]

    private actor ScriptedTranscriber: Transcribing {
        private var script: [String]
        init(_ script: [String]) { self.script = script }
        func transcribe(_ audio: [Float], context: String?) async throws -> TranscriptionOutput {
            TranscriptionOutput(text: script.isEmpty ? "" : script.removeFirst(), asr: .unknown)
        }
    }

    private final class RecordBox: @unchecked Sendable {
        private let lock = NSLock(); private var buf: [TranscriptRecord] = []
        func append(_ r: TranscriptRecord) { lock.lock(); buf.append(r); lock.unlock() }
        var records: [TranscriptRecord] { lock.lock(); defer { lock.unlock() }; return buf }
    }

    private func audio(_ file: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: file, withExtension: "wav", subdirectory: "DemoClips")
                ?? Bundle.main.url(forResource: file, withExtension: "wav"),
            "bundled clip \(file) missing")
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
    }

    func testLiveFeedShadowLogOverRealClips() async throws {
        // ONE shared pipeline so the SpeakerModel centroids persist across clips (session-scoped
        // clustering), exactly like a continuous feed. Diarization ON.
        let config = try AirportConfig.load(named: "kjfk")
        let context = ATCContext(config: config, feedKey: nil)
        let refs = clips.map(\.reference)
        let pipeline = LivePipeline(transcriber: ScriptedTranscriber(refs), context: context,
                                    diarizationEnabled: true)

        // Feed each clip as its own transmission on the shared pipeline (1 script line each).
        let box = RecordBox()
        for clip in clips {
            let a = try audio(clip.file)
            await pipeline.run(source: ArrayAudioSource(a, realtime: false)) { box.append($0) }
        }

        // Fuse exactly as TranscriptionSession.append does (ingest + retroactive relabel).
        let labeler = SpeakerLabeler()
        var fused: [TranscriptRecord] = []
        for input in box.records {
            var r = input
            let flipped = labeler.ingest(&r)
            fused.append(r)
            if let spk = flipped {
                for i in fused.indices where fused[i].speaker == spk && fused[i].role == .unknown {
                    var u = fused[i]; labeler.refuse(&u); fused[i] = u
                }
            }
        }

        // (a) The fusion shadow log — the exact fields TranscriptionSession.shadowLog prints live.
        print("\n===== FUSION SHADOW LOG (real clips, diarization on) =====")
        for (i, r) in fused.enumerated() {
            let d = r.speakerDistance.map { $0 > 1e6 ? "new" : String(format: "%.3f", $0) } ?? "—"
            print(String(format: "[%d] role=%@(%.2f) spk=%@ dist=%@ → label=%@ from=%@  | %@",
                         i,
                         r.role.rawValue,
                         r.roleConfidence,
                         r.speaker.map { "S\($0 + 1)" } ?? "—",
                         d,
                         r.speakerLabel.fixtureString,
                         r.fusedFrom.rawValue,
                         r.display))
        }

        // (b) Acoustic separation baseline: pairwise 3-scalar fingerprint distances. Same feed/facility
        // (the two DFW clips, #1 & #3 below) SHOULD be closer than cross-feed pairs if the fingerprint
        // is any good. This is the metric Stage-5a (MFCC) must improve.
        let model = SpeakerModel()
        let fps = try clips.map { model.fingerprint(try audio($0.file)) }
        print("\n===== ACOUSTIC FINGERPRINT (MFCC c0…c12, cosine distance) =====")
        for (i, clip) in clips.enumerated() {
            let f = fps[i]
            print(String(format: "  #%d %-26@ mfcc[c0..c3]=[%.2f, %.2f, %.2f, %.2f]",
                         i, clip.file, f[0], f[1], f[2], f[3]))
        }
        print("  pairwise cosine distance (lower = more alike):")
        print("     " + clips.indices.map { String(format: "  #%d", $0) }.joined())
        for i in clips.indices {
            var row = String(format: "  #%d", i)
            for j in clips.indices { row += String(format: " %.2f", model.dist(fps[i], fps[j])) }
            print(row)
        }
        print("  NOTE: clips #1 (dfw_aal2124) & #3 (dfw_frontier2471) are the SAME facility (DFW).")

        // Proper speaker-separation metric: split each clip in half. The two halves of ONE clip are
        // the SAME speaker (within), any two different clips are DIFFERENT speakers (cross). A useful
        // fingerprint has within << cross; the newSpeakerDist threshold should sit between them.
        var halves: [(a: [Float], b: [Float])] = []
        for clip in clips {
            let a = try audio(clip.file); let mid = a.count / 2
            halves.append((Array(a[0..<mid]), Array(a[mid...])))
        }
        var within: [Float] = [], crossVals: [Float] = []
        for i in clips.indices {
            within.append(model.dist(model.fingerprint(halves[i].a), model.fingerprint(halves[i].b)))
            for j in clips.indices where j != i {
                crossVals.append(model.dist(model.fingerprint(halves[i].a), model.fingerprint(halves[j].a)))
            }
        }
        let mean = { (v: [Float]) -> Float in v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count) }
        print(String(format: "  WITHIN-speaker (same clip, 2 halves): mean %.3f  max %.3f",
                     mean(within), within.max() ?? 0))
        print(String(format: "  CROSS-speaker  (different clips):      mean %.3f  min %.3f",
                     mean(crossVals), crossVals.min() ?? 0))
        print(String(format: "  → newSpeakerDist=%.2f should sit between within-max and cross-min",
                     SpeakerModel().newSpeakerDist))
        print("===== end =====\n")

        XCTAssertEqual(fused.count, clips.count, "each clip should yield one transmission line")
        for r in fused {
            XCTAssertNotNil(r.speaker, "diarization on → a speaker id per line")
            XCTAssertNotNil(r.speakerDistance)
        }
    }
}
