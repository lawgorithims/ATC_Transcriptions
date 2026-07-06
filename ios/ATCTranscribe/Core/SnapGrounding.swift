import Foundation

/// The combined outcome of the deterministic snap stages for ONE transmission — the bridge
/// between them and the rest of the pipeline (LLM-layer augmentation, PR #5 Deliverable 3):
///  * `promptBlock` grounds the background LLM: a compact VERIFIED / UNVERIFIED summary appended
///    to the retrieved KNOWN CONTEXT so the 0.5B model corrects WITH the facts instead of
///    guessing (and is told what it must not alter).
///  * `gateReasons` adds snap signal(s) to `ConfidenceGate` — an unverified callsign or an
///    invalid/unverified slot is exactly the "something is suspicious" cue the gate wants
///    (genuinely additive: `noSpeechProb` is stubbed in this WhisperKit build).
///  * `groundedRunways` arms the `CorrectionValidator` veto: the LLM may never introduce a
///    runway designator that does not exist at the facility.
struct SnapGrounding: Sendable, Equatable {
    var callsign: CallsignSnap.Result?
    var slots: [SlotSnap.Edit] = []
    var airportIdent: String?
    var airportRunways: [String] = []

    /// Compact grounding lines for the LLM prompt (kept well under the ChatML budget).
    var promptBlock: String {
        var verified: [String] = []
        var unverified: [String] = []
        if let cs = callsign {
            switch cs.verdict {
            case "verified_exact", "snapped":
                if let v = cs.snapped { verified.append("callsign \(v)") }
            case "unverified":
                if let o = cs.original { unverified.append("callsign \(o)") }
            default: break
            }
        }
        for e in slots {
            switch e.verdict {
            case "verified", "snapped":
                verified.append("\(e.slot) \(e.snapped ?? e.original)")
            case "unverified", "invalid":
                unverified.append("\(e.slot) \(e.original)")
            default: break
            }
        }
        var lines: [String] = []
        if !verified.isEmpty {
            lines.append("Verified against live data (do NOT alter): " + verified.joined(separator: "; ") + ".")
        }
        if !unverified.isEmpty {
            lines.append("Heard but NOT verified at \(airportIdent ?? "this facility") "
                + "(fix only with strong evidence): " + unverified.joined(separator: "; ") + ".")
        }
        if !airportRunways.isEmpty {
            lines.append("Runways at \(airportIdent ?? "facility"): "
                + airportRunways.prefix(14).joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Gate signals: why this transmission deserves the LLM's attention.
    var gateReasons: [String] {
        var reasons: [String] = []
        if callsign?.verdict == "unverified" { reasons.append("unverified callsign") }
        if slots.contains(where: { $0.verdict == "invalid" }) { reasons.append("impossible value") }
        if slots.contains(where: { $0.verdict == "unverified" }) { reasons.append("unverified \(slots.first(where: { $0.verdict == "unverified" })!.slot)") }
        return reasons
    }

    /// True when the callsign may be attributed to an aircraft (grouping / ADS-B match).
    var callsignAttributable: Bool {
        callsign.map { $0.verdict == "verified_exact" || $0.verdict == "snapped" } ?? false
    }

    /// The snap stages' text edits, rendered for the transcript's transparent edit list.
    var correctionEdits: [CorrectionEdit] {
        var out: [CorrectionEdit] = []
        if let cs = callsign, cs.applied, let from = cs.original, let to = cs.snapped {
            out.append(CorrectionEdit(from: from, to: to, reason: "callsign snap", backend: "snap"))
        }
        for e in slots where e.applied {
            out.append(CorrectionEdit(from: e.original, to: e.snapped ?? e.original,
                                      reason: "\(e.slot) snap", backend: "snap"))
        }
        return out
    }
}
