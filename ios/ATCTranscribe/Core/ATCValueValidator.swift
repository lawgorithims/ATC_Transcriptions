import Foundation

/// A final gate a parsed `ATCInstruction` must pass BEFORE it becomes a one-tap suggestion — the
/// extraction-side analogue of `CorrectionValidator`. Defense-in-depth on top of the composer: it
/// re-checks the per-kind RANGE and confirms the value's digits are LICENSED by the source transcript
/// (a magnitude value's trailing zeros only where a magnitude word — thousand/hundred/flight level —
/// was actually spoken), so a mis-parse cannot silently stage a plan change. Pure + static.
enum ATCValueValidator {

    /// True when the instruction is structurally sound and its value is licensed by the audio.
    static func validate(_ instruction: ATCInstruction) -> Bool {
        switch instruction.kind {
        case .directTo, .clearedApproach, .loadSID, .loadStar:
            return !instruction.target.isEmpty                      // legacy: grounded against real data upstream
        case .altitude:
            guard let v = instruction.value, v >= 0, v <= 60_000, v % 100 == 0 else { return false }
            return digitsLicensed(instruction)
        case .heading:
            guard let v = instruction.value, v >= 1, v <= 360 else { return false }
            if !instruction.modifier.isEmpty, instruction.modifier != "left", instruction.modifier != "right" {
                return false                                        // a heading modifier may only be a turn direction
            }
            return digitsLicensed(instruction)
        case .speed:
            guard let v = instruction.value, v >= 40, v <= 400 else { return false }
            return digitsLicensed(instruction)
        case .squawk:
            let octal = instruction.target.count == 4 && instruction.target.allSatisfy { "01234567".contains($0) }
            return octal && digitsLicensed(instruction)
        case .frequencyChange:
            guard let mhz = Double(instruction.target) else { return false }
            return mhz >= 118.0 && mhz <= 136.975 && digitsLicensed(instruction)
        }
    }

    /// Digit-preservation: the value's digits must appear in the normalized source, OR — for a magnitude
    /// value whose trailing zeros come from a spoken multiplier — a magnitude word must be present. Since
    /// the normalized transcript spells numbers as single spaced digits, the target's digit string is a
    /// substring of the source's digit run unless magnitude multiplication was applied. Never invents.
    private static func digitsLicensed(_ instruction: ATCInstruction) -> Bool {
        let targetDigits = instruction.target.filter(\.isNumber)
        guard !targetDigits.isEmpty else { return false }
        let rawDigits = instruction.rawTranscript.filter(\.isNumber)
        if rawDigits.contains(targetDigits) { return true }
        let raw = instruction.rawTranscript
        return raw.contains("thousand") || raw.contains("hundred") || raw.contains("flight")
    }
}
