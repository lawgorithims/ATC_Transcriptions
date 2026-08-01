import Foundation

/// The two forms an American airport's identifier takes across CommSight's bundled data, and the rule
/// for trying both.
///
/// ⚠️ THE APP'S OWN DATA IS NOT IN ONE NAMESPACE. `nav_coords.json` and the UI layer key an airport by
/// its ICAO identifier ("K00R"); `cifp.sqlite` and `procedures.json` key the same field by its bare FAA
/// code ("00R"). Measured on the shipped cycle, 707 charted airports exist ONLY as K+code in the first
/// and ONLY as the bare code in the second, and a lookup with either alone returns nothing — silently,
/// which is the dangerous part: an empty result is indistinguishable from an honest "this airport
/// publishes no procedures". Between them those 707 hold 3,760 IAP rows (1,251 distinct approaches),
/// 1,804 coded runway thresholds and 1,271 approach plates, none of it reachable.
///
/// Tapping Elizabethton (K0A9) filled in the Info tab normally, then reported "No runway data — no
/// coded runways for K0A9 in this cycle" while both thresholds sat in `cifp.runway`, showed no charts,
/// and offered no Activate button for any of its published approaches.
enum AirportKey {

    /// The US ICAO prefixes. NOT only K: Alaska is PA, Hawaii PH, Guam PG, Puerto Rico and the Virgin
    /// Islands TJ/TI, plus the Pacific PM/PO/PW. Stripping only a leading K left PANC, PHNL, PGUM and
    /// TJSJ resolving to nothing.
    private static let icaoPrefixes = ["K", "PA", "PH", "PG", "PM", "PO", "PW", "TJ", "TI"]

    /// `(asGiven, alternate)` — the identifier as supplied, and the other form to try if it misses.
    /// The two are equal when there is no alternate, which is the caller's signal not to query twice.
    ///
    /// Only a 4-character identifier is split, and only when at least two characters remain: "K0A9"
    /// yields ("K0A9", "0A9"), while "BOS" and "ABCDE" yield themselves.
    static func forms(_ ident: String) -> (asGiven: String, alternate: String) {
        let s = ident.trimmingCharacters(in: .whitespaces).uppercased()
        guard s.count == 4 else { return (s, s) }
        for p in icaoPrefixes where s.hasPrefix(p) && s.count - p.count >= 2 {
            return (s, String(s.dropFirst(p.count)))
        }
        return (s, s)
    }

    /// Run `lookup` on the identifier as given, and only if that finds nothing, on the alternate form.
    ///
    /// FALLBACK, never preference: the ICAO form is tried first and a hit ends it, so this can only ever
    /// find rows that were previously unreachable. It cannot silently redirect an airport that already
    /// resolves — which is the property that makes widening the lookup safe.
    static func resolving<T>(_ ident: String, _ lookup: (String) -> [T]) -> [T] {
        let (given, alternate) = forms(ident)
        let first = lookup(given)
        guard first.isEmpty, alternate != given else { return first }
        return lookup(alternate)
    }
}
