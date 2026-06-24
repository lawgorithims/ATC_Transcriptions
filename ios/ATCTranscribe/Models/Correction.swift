import Foundation

/// One edit made by a corrector: a `from` token/phrase rewritten `to` another,
/// with the backend that made it and (for fuzzy matches) a confidence score.
/// Mirrors the edit dicts in `atc_corrector.py`.
struct CorrectionEdit: Equatable, Codable {
    var from: String
    var to: String
    var reason: String
    var confidence: Double?
    var backend: String

    init(from: String, to: String, reason: String, confidence: Double? = nil, backend: String) {
        self.from = from
        self.to = to
        self.reason = reason
        self.confidence = confidence
        self.backend = backend
    }
}

/// Result of running the correction layer on one transcript.
///
/// `corrected` is empty when nothing changed (`changed == false`). The caller keeps
/// `raw` as the source of truth and only displays `corrected` when `changed` —
/// always with `edits` visible so the operator sees what moved. A corrector never
/// silently rewrites text. Mirrors `atc_corrector.Correction`.
struct Correction: Equatable {
    var raw: String
    var corrected: String
    var changed: Bool
    var edits: [CorrectionEdit]
    var backend: String

    init(raw: String, corrected: String = "", changed: Bool = false,
         edits: [CorrectionEdit] = [], backend: String = "") {
        self.raw = raw
        self.corrected = corrected
        self.changed = changed
        self.edits = edits
        self.backend = backend
    }

    /// What the UI shows: the corrected text when changed, otherwise the raw text.
    var display: String { changed && !corrected.isEmpty ? corrected : raw }

    /// The "nothing changed" result, preserving the raw text. Mirrors `_unchanged`.
    static func unchanged(_ text: String, backend: String = "") -> Correction {
        Correction(raw: text, corrected: "", changed: false, edits: [], backend: backend)
    }
}
