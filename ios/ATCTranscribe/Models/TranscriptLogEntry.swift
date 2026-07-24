import Foundation

/// The parsed structured instruction, as logged (a projection of `ATCInstruction`).
struct ParsedInstructionLog: Codable, Equatable {
    var callsign: String?
    var kind: String
    var target: String
    var value: Int?
    var unit: String?
    var modifier: String?
    var confidence: String?
}

/// Ownship position + GPS integrity at the moment a line was written — the "was the position
/// trustworthy here?" column. Stamped by the store (not carried on the record) so every line of a run
/// gets it, which is what makes a post-flight pass able to mark unreliable SEGMENTS of a track rather
/// than guess. Position is included only when the monitor trusts it: logging a coordinate the app
/// itself refused to plot would put a fiction in the flight-data record.
struct GPSLogStamp: Codable, Equatable {
    var state: String            // GPSIntegrityState — "nominal" | "degraded" | "unreliable" | "suspect"
    var reasons: [String]?       // worst-first, omitted when nominal
    var accuracyM: Double?       // 1-sigma horizontal radius
    var lat: Double?             // nil when the fix is untrusted (unreliable / suspect)
    var lon: Double?
    var altFt: Double?           // MSL
    var vsFpm: Double?           // derived GPS vertical speed
    var courseUsable: Bool?
    var speedUsable: Bool?
}

/// One line of the append-only JSONL transcript log — a Codable PROJECTION of a `TranscriptRecord`
/// (deliberately NOT `TranscriptRecord` itself: the disk schema is versioned independently, adds session
/// context + signals the record lacks, and avoids coupling the hot-path type to a file format). A record
/// may produce up to three lines joined by `id`: a `record` line at finalization, a `refine` line when the
/// background LLM lands, and a `parse` line when it becomes an EFB instruction. The gold-dataset reader
/// folds by `id`, last-write-wins per field. Foundation-only so the `ATCKitProbe` target still builds.
struct TranscriptLogEntry: Codable, Equatable {
    var v = 2                     // schema version — 2 adds the `gps` integrity stamp
    var type: String             // "record" | "refine" | "parse"
    var id: String               // record.id.uuidString — the join key

    // Session context — stamped by the store at write time (same for every line of a run).
    var loggedAtMs: Double = 0
    var sessionId = ""
    var source = ""              // "mic" | "usb" | "stream" | "stratux" | "replay"
    var modelId = ""
    /// Ownship/GPS integrity at write time — absent when the GPS feed isn't running (v2+).
    var gps: GPSLogStamp?

    // record-line payload
    var clock: String?
    var streamStartS: Double?
    var streamEndS: Double?
    var audioDurationMs: Double?
    var rawText: String?
    var correctedText: String?
    var corrections: [CorrectionEdit]?
    var gateReason: String?
    var gateConfidence: Double?
    var asrAvgLogprob: Float?
    var asrCompressionRatio: Float?
    var segmentRMS: Float?
    var captureToTextMs: Double?
    var transcribeMs: Double?
    var realTimeFactor: Double?
    var speaker: Int?
    var speakerDistance: Float?
    var role: String?
    var roleFused: String?
    var fusedFrom: String?
    var speakerLabel: String?
    var roleConfidence: Double?
    var callsign: String?
    var callsignKey: String?

    // refine-line payload
    var llmCorrectedText: String?
    var llmEdits: [CorrectionEdit]?
    var llmMs: Double?
    var refinementState: String?

    // parse-line payload
    var parsed: ParsedInstructionLog?

    /// The record line: the fully-fused transmission at finalization.
    static func record(from r: TranscriptRecord) -> TranscriptLogEntry {
        var e = TranscriptLogEntry(type: "record", id: r.id.uuidString)
        e.clock = r.timestamp.isEmpty ? nil : r.timestamp
        e.streamStartS = r.streamStartS
        e.streamEndS = r.streamEndS
        e.audioDurationMs = r.audioDurationMs
        e.rawText = r.text
        e.correctedText = r.corrected.isEmpty ? nil : r.corrected
        e.corrections = r.corrections.isEmpty ? nil : r.corrections
        e.gateReason = r.gateReason.isEmpty ? nil : r.gateReason
        e.gateConfidence = r.gateConfidence
        e.asrAvgLogprob = r.asr.avgLogprob
        e.asrCompressionRatio = r.asr.compressionRatio
        e.segmentRMS = r.segmentRMS
        e.captureToTextMs = r.captureToTextMs
        e.transcribeMs = r.transcribeMs
        e.realTimeFactor = r.realTimeFactor
        e.speaker = r.speaker
        e.speakerDistance = r.speakerDistance
        e.role = r.role.rawValue
        e.roleFused = r.roleFused.rawValue
        e.fusedFrom = r.fusedFrom.rawValue
        e.speakerLabel = r.speakerLabel.fixtureString
        e.roleConfidence = r.roleConfidence
        e.callsign = r.callsign
        e.callsignKey = r.callsignKey
        return e
    }

    /// The refine line: the background-LLM outcome for an already-logged record.
    static func refine(from r: TranscriptRecord) -> TranscriptLogEntry {
        var e = TranscriptLogEntry(type: "refine", id: r.id.uuidString)
        e.refinementState = r.refinementState.rawValue
        e.llmCorrectedText = r.llmCorrected.isEmpty ? nil : r.llmCorrected
        e.llmEdits = r.llmEdits.isEmpty ? nil : r.llmEdits
        e.llmMs = r.llmMs
        return e
    }

    /// The parse line: the structured EFB instruction extracted from a record.
    static func parse(id: String, instruction ins: ATCInstruction) -> TranscriptLogEntry {
        var e = TranscriptLogEntry(type: "parse", id: id)
        e.parsed = ParsedInstructionLog(
            callsign: ins.callsign.isEmpty ? nil : ins.callsign,
            kind: ins.kind.rawValue, target: ins.target, value: ins.value,
            unit: ins.unit.isEmpty ? nil : ins.unit,
            modifier: ins.modifier.isEmpty ? nil : ins.modifier,
            confidence: ins.confidence.rawValue)
        return e
    }
}
