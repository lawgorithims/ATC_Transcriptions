import Foundation

/// Is the aircraft outside the published altitude restriction on the leg it is flying?
///
/// This is an ADVISORY built on GPS data, and the honest framing matters more than the arithmetic.
/// The iPad measures GPS (geometric) altitude; every published crossing restriction is BAROMETRIC. The
/// two disagree by an amount that varies with pressure and temperature — routinely a couple of hundred
/// feet, more in a cold or low-pressure airmass — and the app has no altimeter setting to reconcile
/// them. So this fires only on a deviation large enough that no plausible baro/GPS spread explains it,
/// and the UI says plainly that it is GPS-derived.
///
/// Speed is deliberately NOT checked. Published speed limits are INDICATED airspeed; the iPad has GPS
/// groundspeed, which differs by the wind and by the TAS/IAS spread — 50 kt or more at altitude. There
/// is no margin that makes that comparison honest, so the leg's speed limit is shown as information and
/// never judged.
///
/// Pure value logic, no clock and no I/O, so every branch is unit-testable.
enum LegConstraintCheck {
    /// How far outside a published altitude the aircraft must be before this says anything.
    ///
    /// Sized to clear the GPS-vs-barometric spread rather than to catch small busts, because a warning
    /// that fires on a datum difference teaches the pilot to ignore it. That spread is bigger than it
    /// first looks: geometric-vs-pressure altitude diverges with both altimeter setting and temperature,
    /// and a cold day at altitude can reach several hundred feet on its own. 700 ft still catches the
    /// gross error — a crossing restriction missed by a thousand feet or more — and stays quiet through
    /// any plausible datum difference.
    static let toleranceFt = 700

    /// Vertical accuracy beyond which the fix cannot support any altitude claim.
    static let maxVerticalAccuracyM = 40.0

    /// How far off the leg the aircraft may be and still be considered to be flying it.
    static let maxCrossTrackNm = 5.0

    /// How close to the fix the aircraft must be before its crossing restriction is judged.
    ///
    /// A published altitude applies AT the fix, not along the whole leg leading to it — the leg is where
    /// you descend to meet it. Without this gate the advisory fired for the entire leg, so a normal
    /// climb-out or descent looked like a bust, and an aircraft parked on the ground with an approach
    /// loaded was permanently "1,900 ft low" at its first fix. 4 NM is roughly a minute of slow flight
    /// and about half a minute at approach speed: close enough that the restriction is genuinely
    /// imminent, far enough to be useful rather than an after-the-fact report.
    static let arrivalWindowNm = 4.0

    struct Warning: Equatable {
        enum Sense: Equatable { case above, below }
        let fix: String
        let sense: Sense
        /// The published rule, pilot-readable ("at or above 2000 ft").
        let limitText: String
        /// Signed feet outside the rule; positive is high.
        let deviationFt: Int

        var headline: String {
            let d = abs(deviationFt)
            return sense == .above ? "\(d) ft high at \(fix)" : "\(d) ft low at \(fix)"
        }
    }

    /// `nil` means say nothing — which is the answer whenever we are not entitled to an opinion.
    ///
    /// Every guard here is a reason the comparison would be dishonest rather than merely inconvenient:
    /// no published rule, a qualifier we do not model, a fix that is not georeferenced, an aircraft not
    /// actually on this leg, a degraded or spoofed GPS, or a vertical solution too loose to mean
    /// anything.
    static func evaluate(constraint: LegConstraint,
                         fix: String,
                         altitudeFtMSL: Int?,
                         crossTrackNm: Double?,
                         distanceToFixNm: Double?,
                         verticalAccuracyM: Double?,
                         integrityOK: Bool) -> Warning? {
        assert(toleranceFt > 0, "a zero tolerance would warn on the GPS/baro datum difference alone")
        assert(maxCrossTrackNm > 0, "cross-track limit must be positive")

        guard !constraint.altUnmodelled else { return nil }      // never guess at an unmodelled qualifier
        guard let limitText = constraint.altText else { return nil }
        guard !fix.isEmpty, integrityOK, let altitudeFtMSL else { return nil }
        if let acc = verticalAccuracyM, acc > maxVerticalAccuracyM { return nil }
        if verticalAccuracyM == nil { return nil }               // unknown accuracy is not good accuracy
        if let xtk = crossTrackNm, abs(xtk) > maxCrossTrackNm { return nil }
        guard crossTrackNm != nil else { return nil }            // not established on the leg → no claim
        // The restriction applies AT the fix. Judged along the whole leg it flags every normal climb or
        // descent, and never stops flagging an aircraft sitting on the ground.
        guard let distanceToFixNm, distanceToFixNm <= arrivalWindowNm else { return nil }

        guard let deviation = constraint.altitudeDeviation(altitudeFtMSL),
              abs(deviation) > toleranceFt else { return nil }
        return Warning(fix: fix,
                       sense: deviation > 0 ? .above : .below,
                       limitText: limitText,
                       deviationFt: deviation)
    }
}
