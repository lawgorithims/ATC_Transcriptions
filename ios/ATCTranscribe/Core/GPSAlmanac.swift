import Foundation

// MARK: - Almanac record

/// One satellite's coarse Keplerian elements as published in a YUMA almanac.
///
/// These are ORBIT PREDICTIONS, not observations. iOS exposes no measured GNSS data at all — no DOP,
/// no satellite count, no per-SV SNR, no pseudoranges (that is Android's `GnssMeasurement` API) — so the
/// only way this app can say anything about constellation geometry is to propagate published elements
/// forward, exactly as a pre-flight RAIM-prediction tool does. Nothing derived from this file may ever
/// be presented as a live receiver state; every consumer type below carries `Predicted` in its name so
/// that distinction cannot be lost at a call site.
///
/// The almanac is deliberately coarse. It omits the ephemeris' harmonic correction terms (Cuc/Cus/Crc/
/// Crs/Cic/Cis), the rate-of-inclination term and the relativistic clock correction, so satellite
/// positions are good to a few kilometres rather than a few metres. That is irrelevant for azimuth,
/// elevation and DOP — a kilometre of along-track error at 20 000 km slant range moves a look angle by
/// millidegrees — and it is why one almanac stays useful for weeks instead of the ephemeris' four hours.
struct GPSAlmanacEntry: Equatable, Sendable {
    let prn: Int             // space vehicle PRN, 1...32 for GPS
    let health: Int          // 6-bit health word, 0 = all signals nominal; anything else = do not use
    let e: Double            // eccentricity, dimensionless (GPS flies near-circular, ~0.02 at most)
    let toa: Double          // time of applicability, seconds into `week`
    let i0: Double           // orbital inclination, radians (YUMA gives the TOTAL angle, ~0.96 rad = 55°)
    let omegaDot: Double     // rate of right ascension, rad/s (nodal regression, ~-8e-9)
    let sqrtA: Double        // square root of the semi-major axis, m^(1/2)
    let omega0: Double       // right ascension of the ascending node at the START of `week`, radians
    let omega: Double        // argument of perigee, radians
    let m0: Double           // mean anomaly at `toa`, radians
    let af0: Double          // SV clock bias, seconds
    let af1: Double          // SV clock drift, s/s
    let week: Int            // GPS week the almanac was issued in, MODULO 1024 in every YUMA file

    /// The health word is a bit field, but every non-zero value means "do not use this SV for
    /// navigation". Predicted geometry deliberately EXCLUDES unhealthy vehicles: a RAIM prediction that
    /// counted a satellite the constellation has flagged out of service would be optimistic, which is
    /// the one direction an availability prediction must never err in.
    var isHealthy: Bool { health == 0 }

    /// Semi-major axis in metres. Derived rather than stored because YUMA publishes the square root —
    /// the ICD's own parameterisation, chosen so the value fits the broadcast message's bit budget.
    var semiMajorAxisM: Double { sqrtA * sqrtA }

    /// Orbital period in seconds from Kepler's third law. GPS is a half-sidereal-day orbit, so this
    /// must land near 43 082 s (11 h 58 m); a parse that lands anywhere else has mangled `sqrtA`.
    var orbitalPeriodS: Double {
        let a = semiMajorAxisM
        assert(a > 0, "semi-major axis must be positive")
        assert(GPSAlmanac.mu > 0, "gravitational parameter must be positive")
        return 2 * .pi * (a * a * a / GPSAlmanac.mu).squareRoot()
    }

    /// Range-check every field against what a real GPS almanac can physically contain. The parser is
    /// tolerant by design — a truncated download or a stray line must be SKIPPED, never crash and never
    /// silently produce a satellite in an impossible orbit that then poisons the DOP for the whole sky.
    var isPhysicallyPlausible: Bool {
        guard (1...210).contains(prn), health >= 0, week >= 0 else { return false }
        // GPS flies near-circular (e ~ 0.02 at most). Bounding to 0.1 — still over 3x any real value —
        // rejects a pathological high-eccentricity record that would slow the Kepler solve and, worse,
        // hand a physically absurd orbit to the DOP computation for the whole sky. Elliptical alone
        // (e < 1) is not a tight enough gate for a navigation almanac.
        guard e.isFinite, e >= 0, e < 0.1 else { return false }
        guard toa.isFinite, toa >= 0, toa < GPSAlmanac.secondsPerWeek else { return false }
        guard sqrtA.isFinite, sqrtA > 1_000, sqrtA < 10_000 else { return false }   // GPS is ~5153.5
        guard i0.isFinite, abs(i0) <= .pi, omegaDot.isFinite, abs(omegaDot) < 1e-6 else { return false }
        return omega0.isFinite && omega.isFinite && m0.isFinite && af0.isFinite && af1.isFinite
    }
}

// MARK: - Parsing and GPS time

/// YUMA almanac parsing plus the GPS time scale the almanac's epoch is expressed in.
///
/// Everything here is pure and bounded: the parser has a hard record cap and a hard line cap, the week
/// rollover is resolved arithmetically rather than by iteration, and `Date` is always passed in rather
/// than read from the clock so callers and tests get the same answer for the same instant.
enum GPSAlmanac {

    // MARK: Physical constants (GPS ICD-200 / WGS-84)

    /// WGS-84 Earth gravitational constant. Note this is the GPS ICD value (3.986005e14), NOT the newer
    /// WGS-84(G873) 3.986004418e14 — the broadcast elements are FITTED against the ICD constant, so
    /// substituting the "better" one would make the propagation slightly worse, not better.
    static let mu = 3.986005e14                  // m^3/s^2
    static let earthRotationRate = 7.2921151467e-5  // rad/s, WGS-84 Omega-dot-e
    static let wgs84SemiMajorAxisM = 6_378_137.0
    static let wgs84Flattening = 1 / 298.257223563

    /// GPS epoch 1980-01-06T00:00:00Z expressed in Unix seconds.
    static let gpsEpochUnix = 315_964_800.0
    /// GPS time does not observe leap seconds, so it has drifted ahead of UTC by one second per
    /// insertion since 1980. 18 s has held since 2017-01-01 and no further leap second has been
    /// announced. `Date` is POSIX time (leap seconds smeared/ignored), so this offset is the whole of
    /// the conversion. If IERS ever announces another, this constant is the single place to change.
    static let leapSecondsAheadOfUTC = 18.0
    static let secondsPerWeek = 604_800.0
    /// The YUMA `week` field is 10 bits wide, so it wraps every 1024 weeks (~19.6 years).
    static let rolloverWeeks = 1024

    // MARK: Bounds (rule 2 — every loop below is capped by one of these)

    static let maxRecords = 64      // GPS tops out at 32 PRNs; the slack absorbs augmented almanacs
    static let maxLines = 4_096     // 64 records x 16 lines, with room for banners and blank lines

    /// Parse the almanac bundled at `Resources/gps/almanac.yuma.txt` (refreshed by
    /// `Tools/fetch_gps_almanac.sh`). Returns [] when the resource is missing or unreadable — every
    /// consumer already treats "no almanac" as "no predicted geometry", which degrades the Satellites
    /// page and makes the threat classifier refuse to claim jamming rather than guess at it.
    static func loadBundled(bundle: Bundle = .main) -> [GPSAlmanacEntry] {
        let url = bundle.url(forResource: "almanac.yuma", withExtension: "txt", subdirectory: "gps")
            ?? bundle.url(forResource: "almanac.yuma", withExtension: "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let out = parseYUMA(text)
        assert(out.count <= 64, "an almanac should never carry more than the GPS PRN space")
        return out
    }


    // MARK: Parsing

    /// Parse a CelesTrak-style YUMA almanac. Unknown keys are ignored, records missing any required
    /// field are dropped, and the whole thing is capped at `maxRecords` — a corrupt or hostile file
    /// can waste time but cannot allocate without bound or crash the app.
    ///
    /// Records are delimited by the `******** Week nnn almanac for PRN-nn ********` banner. A file with
    /// no banners at all is still parsed, by treating a repeated `ID:` key as the start of a new record;
    /// that fallback costs one dictionary probe per line and makes hand-trimmed fixtures work.
    static func parseYUMA(_ text: String) -> [GPSAlmanacEntry] {
        assert(maxRecords > 0 && maxLines > 0, "parser caps must be positive")
        assert(text.utf8.count < 4_000_000, "an almanac is kilobytes; this is not one")
        var out: [GPSAlmanacEntry] = []
        out.reserveCapacity(maxRecords)
        var fields: [String: String] = [:]
        // CelesTrak serves CRLF. Splitting on "\n" alone would leave a trailing carriage return glued
        // to every value, and `Double("5153.551758\r")` is nil — so normalise the line endings first.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") { flush(&fields, into: &out); continue }   // record banner
            guard let colon = line.firstIndex(of: ":") else { continue }      // blank or stray line
            let key = normalizedKey(String(line[..<colon]))
            guard !key.isEmpty else { continue }
            if key == "id", fields["id"] != nil { flush(&fields, into: &out) }
            fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        flush(&fields, into: &out)                                            // the final record
        assert(out.count <= maxRecords, "record cap held")
        return out
    }

    /// Fold the accumulated key/value pairs into an entry (when they form a complete, plausible one)
    /// and clear them for the next record. Silently dropping an incomplete record is the whole point:
    /// a download truncated mid-file must still yield the satellites that arrived intact.
    private static func flush(_ fields: inout [String: String], into out: inout [GPSAlmanacEntry]) {
        assert(out.count <= maxRecords, "record cap held before append")
        if !fields.isEmpty, out.count < maxRecords, let e = entry(from: fields) { out.append(e) }
        fields.removeAll(keepingCapacity: true)
    }

    /// Canonicalise a YUMA label to a lookup key: drop everything from the first parenthesis (which is
    /// where the units live — `SQRT(A)  (m 1/2)` → `sqrt`), trim, lowercase. Matching on the unit-free
    /// stem means a file that writes `Eccentricity:` where another writes `Eccentricity():` still hits.
    private static func normalizedKey(_ label: String) -> String {
        String(label.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Build one entry, or nil if any field is missing, unparseable, or physically impossible.
    private static func entry(from f: [String: String]) -> GPSAlmanacEntry? {
        assert(f.count <= 64, "a YUMA record has 13 fields; far more means the flush logic broke")
        assert(!f.isEmpty, "flush must not call this with nothing accumulated")
        guard let prn = f["id"].flatMap({ Int($0) }),
              let health = f["health"].flatMap({ Int($0) }),
              let e = f["eccentricity"].flatMap({ Double($0) }),
              let toa = f["time of applicability"].flatMap({ Double($0) }),
              let i0 = f["orbital inclination"].flatMap({ Double($0) }),
              let omegaDot = f["rate of right ascen"].flatMap({ Double($0) }),
              let sqrtA = f["sqrt"].flatMap({ Double($0) }),
              let omega0 = f["right ascen at week"].flatMap({ Double($0) }),
              let omega = f["argument of perigee"].flatMap({ Double($0) }),
              let m0 = f["mean anom"].flatMap({ Double($0) }),
              let af0 = f["af0"].flatMap({ Double($0) }),
              let af1 = f["af1"].flatMap({ Double($0) }),
              let week = f["week"].flatMap({ Int($0) })
        else { return nil }
        let candidate = GPSAlmanacEntry(prn: prn, health: health, e: e, toa: toa, i0: i0,
                                        omegaDot: omegaDot, sqrtA: sqrtA, omega0: omega0,
                                        omega: omega, m0: m0, af0: af0, af1: af1, week: week)
        return candidate.isPhysicallyPlausible ? candidate : nil
    }

    // MARK: GPS time scale

    /// Seconds since the GPS epoch, in GPS time (i.e. with the leap-second offset applied).
    static func gpsSeconds(at date: Date) -> Double {
        assert(date.timeIntervalSince1970 > gpsEpochUnix, "dates before 1980-01-06 are not GPS time")
        assert(leapSecondsAheadOfUTC >= 0, "GPS runs ahead of UTC, never behind")
        return date.timeIntervalSince1970 - gpsEpochUnix + leapSecondsAheadOfUTC
    }

    /// The absolute (un-rolled-over) GPS week number containing `date`.
    static func gpsWeek(at date: Date) -> Int {
        let s = gpsSeconds(at: date)
        assert(s >= 0, "GPS seconds must be non-negative")
        assert(secondsPerWeek > 0, "week length must be positive")
        return Int((s / secondsPerWeek).rounded(.down))
    }

    /// Lift a 10-bit almanac week field to an absolute GPS week by snapping it to the rollover cycle
    /// NEAREST the observation date.
    ///
    /// Hard-coding a cycle (the "week 381 means 2429" shortcut) is exactly the bug that grounded fleets
    /// at the 1999 and 2019 rollovers, and it would silently start returning satellites half a
    /// constellation away in 2038. Resolving against the caller's date instead means the code has no
    /// expiry. A field that already carries the full week (some vendors emit one) passes through
    /// unchanged, because the nearest cycle to itself is zero cycles away.
    static func resolvedWeek(rawWeek raw: Int, at date: Date) -> Int {
        assert(raw >= 0, "an almanac week field is never negative")
        assert(rolloverWeeks > 0, "the rollover period must be positive")
        let now = gpsWeek(at: date)
        let cycles = (Double(now - raw) / Double(rolloverWeeks)).rounded()
        let resolved = raw + Int(cycles) * rolloverWeeks
        assert(abs(resolved - now) <= rolloverWeeks, "resolution must land in an adjacent cycle")
        return resolved
    }

    /// The almanac's reference epoch (its `toa` in its resolved week) as a UTC `Date`. Exposed so the
    /// UI can say how old the prediction's source data is — a prediction from a six-month-old almanac
    /// is still geometrically useful but the pilot deserves to know.
    static func referenceDate(_ entry: GPSAlmanacEntry, resolvedAt date: Date) -> Date {
        assert(entry.toa >= 0 && entry.toa < secondsPerWeek, "toa must be a second-of-week")
        let week = resolvedWeek(rawWeek: entry.week, at: date)
        let gps = Double(week) * secondsPerWeek + entry.toa
        assert(gps > 0, "resolved epoch must be after the GPS epoch")
        return Date(timeIntervalSince1970: gps + gpsEpochUnix - leapSecondsAheadOfUTC)
    }

    /// Age of the almanac in days at `date`. Negative means the almanac is stamped slightly in the
    /// future, which is normal for a file uploaded ahead of its own time of applicability.
    static func ageDays(_ entry: GPSAlmanacEntry, at date: Date) -> Double {
        assert(entry.isPhysicallyPlausible, "age of an implausible entry is meaningless")
        assert(date.timeIntervalSince1970 > gpsEpochUnix, "date must be in the GPS era")
        return date.timeIntervalSince(referenceDate(entry, resolvedAt: date)) / 86_400.0
    }

    /// Time from the almanac's reference epoch — `tk` in the ICD — as a TRUE elapsed interval.
    ///
    /// It is NOT folded, and that is the whole point of this comment, because folding it is the obvious
    /// mistake and it is silent. The ICD's +/-302 400 s correction exists only to reconcile a
    /// second-of-week `t` against a second-of-week `toa` ACROSS A WEEK BOUNDARY, in a receiver that
    /// never sees the week number. This function already forms the ABSOLUTE difference (it resolves the
    /// almanac's modulo-1024 week first), so `tk` is already right and a fold can only corrupt it.
    ///
    /// The tempting justification for folding — "the orbit repeats, so a week later is the same sky" —
    /// is false. The GPS ground track repeats on the SIDEREAL day (86 164.0905 s), and one week is
    /// 7.0192 sidereal days, not 7. Folding by a week therefore slews the whole constellation by about
    /// 7 degrees of Earth rotation and 13 degrees of mean anomaly. Measured, that error reached 13
    /// degrees of elevation after a single week and over 100 degrees within a year — and because the
    /// app bundles a STATIC almanac and propagates it to `Date()`, that is the normal case, not an edge
    /// case. It also feeds `GPSThreatClassifier`, where fictional "good geometry" turns into a
    /// fabricated jamming verdict.
    ///
    /// Propagating a long way from `toa` is still an accuracy question — the elements themselves go
    /// stale — which is what `ageDays` is for and why the Satellites page warns past 90 days. That is a
    /// different problem from aliasing the geometry, and it must not be "fixed" by folding.
    static func secondsFromReference(_ entry: GPSAlmanacEntry, at date: Date) -> Double {
        assert(entry.toa >= 0 && entry.toa < secondsPerWeek, "toa must be a second-of-week")
        assert(secondsPerWeek > 0, "week length must be positive")
        let week = resolvedWeek(rawWeek: entry.week, at: date)
        let tk = gpsSeconds(at: date) - (Double(week) * secondsPerWeek + entry.toa)
        assert(tk.isFinite, "tk must be finite")
        return tk
    }

}

// MARK: - Predicted sky

/// Where the almanac says one satellite WILL BE, as seen from a ground site — never where a receiver
/// reports it is. The name carries `Predicted` because the difference is safety-relevant: a pilot who
/// reads this as live satellite tracking would believe the app can see a jamming event it is
/// structurally incapable of seeing.
struct PredictedSatellite: Equatable, Sendable {
    var prn: Int
    /// True bearing to the satellite, degrees, normalised to [0, 360).
    var azimuthDeg: Double
    /// Angle above the local geodetic horizon, degrees, in [-90, 90]. Negative means below the horizon;
    /// those SVs are still returned so a sky plot can show the whole constellation, and are filtered
    /// out by the elevation mask at the point where geometry is actually computed.
    var elevationDeg: Double
    /// Mirrors the almanac's health word. Defaulted true so synthetic geometries (tests, textbook
    /// configurations) read cleanly without repeating it at every construction site.
    var healthy: Bool = true
}

/// Predicted dilution of precision — how much the constellation's GEOMETRY alone multiplies ranging
/// error into position error, assuming every satellite ranges equally well.
///
/// This is emphatically not a measured DOP. A receiver's reported DOP reflects which satellites it
/// actually acquired, after masking, multipath and interference; this one assumes every healthy SV
/// above the mask is tracked perfectly. It therefore represents the BEST geometry available at that
/// place and time — a floor, useful for "will the approach have adequate geometry at my ETA", useless
/// as evidence about the fix the receiver has right now.
struct PredictedDOP: Equatable, Sendable {
    var gdop: Double   // geometric: position and time together
    var pdop: Double   // 3-D position
    var hdop: Double   // horizontal — the one that matters for lateral navigation
    var vdop: Double   // vertical — always the worst, because every satellite is above the receiver
    var tdop: Double   // time

    /// Plain-English rating of the predicted geometry, keyed on PDOP using the conventional GNSS
    /// bands. Rated on PDOP rather than HDOP because it is the number the RAIM literature and the
    /// receiver manuals both quote, so a pilot comparing this against an avionics page sees the same
    /// scale.
    enum Quality: String, Sendable, CaseIterable {
        case ideal, excellent, good, moderate, fair, poor

        init(pdop: Double) {
            switch pdop {
            case ..<1:  self = .ideal
            case ..<2:  self = .excellent
            case ..<5:  self = .good
            case ..<10: self = .moderate
            case ..<20: self = .fair
            default:    self = .poor
            }
        }

        /// Cockpit-readable phrase for the geometry card.
        var label: String {
            switch self {
            case .ideal:     return "Ideal"
            case .excellent: return "Excellent"
            case .good:      return "Good"
            case .moderate:  return "Moderate"
            case .fair:      return "Fair"
            case .poor:      return "Poor"
            }
        }
    }

    var quality: Quality { Quality(pdop: pdop) }
}

/// An Earth-centred, Earth-fixed position in metres. Internal to the prediction chain — satellite
/// positions and the observer both live here before the difference is rotated into local ENU.
struct ECEFPosition: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    var radiusM: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Propagates almanac elements to look angles and geometry for a ground site.
///
/// Every function is pure, every loop is bounded, and there is no recursion (the Kepler solve is a
/// capped Newton iteration, the matrix inverse is a fixed 4x4 Gauss-Jordan). Feeding it the same
/// almanac, instant and site always yields bit-identical output, which is what makes a briefing
/// screenshot reproducible after the fact.
enum GPSSkyPrediction {

    /// Newton on Kepler's equation converges in 3 iterations for GPS eccentricities (<0.03) and in 8
    /// even at e = 0.95; 12 leaves headroom while still being a hard bound (rule 2).
    static let keplerMaxIterations = 12
    /// Convergence is judged on the Newton STEP, not the residual: the step is the error estimate, and
    /// stopping at 1e-13 rad leaves a residual near double-precision floor for E of order 1.
    static let keplerToleranceRad = 1e-13
    /// Matches the parser's cap so a caller cannot smuggle an unbounded list past the loop bounds.
    static let maxSatellites = GPSAlmanac.maxRecords

    // MARK: Orbit

    /// Solve Kepler's equation `M = E - e·sin E` for the eccentric anomaly by Newton iteration.
    ///
    /// `M` is reduced to [-pi, pi] first. That is not cosmetic: propagated mean anomaly reaches ~44 rad
    /// at the edge of the half-week fold, and Newton on a large argument both starts further from the
    /// root and loses significant bits in `E - e·sin E` when the two terms differ by orders of
    /// magnitude. Only sin E and cos E are used downstream, so shifting E by whole revolutions is free.
    static func eccentricAnomaly(meanAnomaly m: Double, eccentricity e: Double) -> Double {
        assert(e >= 0 && e < 1, "eccentricity must describe an ellipse")
        assert(m.isFinite, "mean anomaly must be finite")
        let reduced = m - (2 * Double.pi) * ((m + .pi) / (2 * .pi)).rounded(.down)
        var ek = reduced + e * sin(reduced)     // first-order start; exact when e == 0
        var converged = false
        for _ in 0..<keplerMaxIterations {      // bounded (rule 2)
            let derivative = 1 - e * cos(ek)
            // 1 - e·cos E vanishes only as e approaches 1 at perigee, which no GPS orbit does; bail
            // rather than divide by ~zero and let the assertion below report the failure.
            if abs(derivative) < 1e-12 { break }
            let step = (ek - e * sin(ek) - reduced) / derivative
            ek -= step
            if abs(step) <= keplerToleranceRad { converged = true; break }
        }
        assert(converged, "Kepler iteration failed to converge for e=\(e)")
        return ek
    }

    /// Satellite ECEF position from the almanac elements at `tk` seconds past the reference epoch —
    /// the GPS ICD-200 almanac algorithm, minus the ephemeris-only harmonic corrections the almanac
    /// does not carry.
    ///
    /// The node term is the subtle one: `omega0` is referenced to the START of the almanac week, not to
    /// `toa`, so the Earth's rotation has to be unwound over `toa` as well as accumulated over `tk` —
    /// that is what the trailing `-earthRotationRate * toa` does. Dropping it puts every satellite
    /// tens of degrees off in longitude, which looks plausible and is entirely wrong.
    static func ecefPosition(of entry: GPSAlmanacEntry, secondsFromReference tk: Double) -> ECEFPosition {
        assert(entry.sqrtA > 0, "semi-major axis must be positive")
        // tk is a TRUE elapsed interval, not a folded half-week (see `secondsFromReference` — the fold
        // was the removed week-aliasing bug). A static bundled almanac is legitimately propagated weeks
        // or months from its epoch, so the only invariants here are finiteness and a generous multi-year
        // sanity bound; a debug assert of "<= half a week" would SIGABRT the app the moment the almanac
        // aged past a week, and it would trap the debug test suite too.
        assert(tk.isFinite, "tk must be finite")
        assert(abs(tk) < 53 * GPSAlmanac.secondsPerWeek, "tk beyond a year of a valid almanac is a bug")
        let a = entry.semiMajorAxisM
        let meanMotion = (GPSAlmanac.mu / (a * a * a)).squareRoot()
        let mk = entry.m0 + meanMotion * tk
        let ek = eccentricAnomaly(meanAnomaly: mk, eccentricity: entry.e)
        let sinE = sin(ek), cosE = cos(ek)

        let trueAnomaly = atan2((1 - entry.e * entry.e).squareRoot() * sinE, cosE - entry.e)
        let argLatitude = trueAnomaly + entry.omega
        let radius = a * (1 - entry.e * cosE)
        let xOrbital = radius * cos(argLatitude)
        let yOrbital = radius * sin(argLatitude)

        let node = entry.omega0 + (entry.omegaDot - GPSAlmanac.earthRotationRate) * tk
                 - GPSAlmanac.earthRotationRate * entry.toa
        let cosNode = cos(node), sinNode = sin(node)
        let cosInc = cos(entry.i0), sinInc = sin(entry.i0)
        return ECEFPosition(x: xOrbital * cosNode - yOrbital * cosInc * sinNode,
                            y: xOrbital * sinNode + yOrbital * cosInc * cosNode,
                            z: yOrbital * sinInc)
    }

    /// Convenience overload that resolves the week and folds `tk` from a wall-clock instant.
    static func ecefPosition(of entry: GPSAlmanacEntry, at date: Date) -> ECEFPosition {
        assert(entry.isPhysicallyPlausible, "refusing to propagate an implausible entry")
        assert(date.timeIntervalSince1970 > GPSAlmanac.gpsEpochUnix, "date must be in the GPS era")
        return ecefPosition(of: entry, secondsFromReference: GPSAlmanac.secondsFromReference(entry, at: date))
    }

    // MARK: Observer

    /// Geodetic latitude/longitude/height to WGS-84 ECEF. The prime-vertical radius `N` is the whole
    /// point of doing this properly: the Earth's 21 km equatorial bulge means a spherical
    /// approximation misplaces a mid-latitude site by ~10 km, which tilts the local horizon enough to
    /// move a low satellite across a 5° mask.
    static func observerECEF(_ observer: Coord, altitudeM: Double) -> ECEFPosition {
        assert((-90...90).contains(observer.lat), "latitude out of range")
        assert(observer.lon.isFinite && altitudeM.isFinite, "observer position must be finite")
        let lat = observer.lat * .pi / 180, lon = observer.lon * .pi / 180
        let e2 = GPSAlmanac.wgs84Flattening * (2 - GPSAlmanac.wgs84Flattening)
        let primeVertical = GPSAlmanac.wgs84SemiMajorAxisM / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
        return ECEFPosition(x: (primeVertical + altitudeM) * cos(lat) * cos(lon),
                            y: (primeVertical + altitudeM) * cos(lat) * sin(lon),
                            z: (primeVertical * (1 - e2) + altitudeM) * sin(lat))
    }

    /// Rotate the ECEF satellite-minus-observer vector into the site's local East/North/Up frame and
    /// read off the look angles. Elevation uses `atan2(up, horizontal)` rather than `asin(up/range)`
    /// because the former stays well-conditioned near the zenith, where the range and the up component
    /// become nearly equal and the arcsine's derivative blows up.
    static func lookAngles(satellite: ECEFPosition, observerECEF site: ECEFPosition,
                           observer: Coord) -> (azimuthDeg: Double, elevationDeg: Double) {
        assert((-90...90).contains(observer.lat), "latitude out of range")
        assert(satellite.radiusM > 0, "a satellite at the geocentre has no look angle")
        let lat = observer.lat * .pi / 180, lon = observer.lon * .pi / 180
        let dx = satellite.x - site.x, dy = satellite.y - site.y, dz = satellite.z - site.z
        let east = -sin(lon) * dx + cos(lon) * dy
        let north = -sin(lat) * cos(lon) * dx - sin(lat) * sin(lon) * dy + cos(lat) * dz
        let up = cos(lat) * cos(lon) * dx + cos(lat) * sin(lon) * dy + sin(lat) * dz
        let azimuth = atan2(east, north) * 180 / .pi
        let elevation = atan2(up, (east * east + north * north).squareRoot()) * 180 / .pi
        return (azimuth < 0 ? azimuth + 360 : azimuth, elevation)
    }

    // MARK: Public prediction

    /// Predicted azimuth/elevation for every SV in the almanac at one instant, in almanac order.
    ///
    /// Satellites BELOW the horizon are included with a negative elevation rather than dropped: the
    /// caller decides the mask, and a sky plot that silently omits them cannot distinguish "below the
    /// horizon" from "missing from the almanac". Order is the input's order, so the output is stable.
    static func satellites(almanac: [GPSAlmanacEntry], at date: Date, observer: Coord,
                           observerAltitudeM: Double = 0) -> [PredictedSatellite] {
        assert(almanac.count <= maxSatellites, "almanac must already be capped by the parser")
        assert((-90...90).contains(observer.lat), "observer latitude out of range")
        let site = observerECEF(observer, altitudeM: observerAltitudeM)
        var out: [PredictedSatellite] = []
        out.reserveCapacity(min(almanac.count, maxSatellites))
        for entry in almanac.prefix(maxSatellites) {          // bounded (rule 2)
            let position = ecefPosition(of: entry, at: date)
            let look = lookAngles(satellite: position, observerECEF: site, observer: observer)
            out.append(PredictedSatellite(prn: entry.prn, azimuthDeg: look.azimuthDeg,
                                          elevationDeg: look.elevationDeg, healthy: entry.isHealthy))
        }
        return out
    }

    /// Predicted DOP for the healthy satellites above `maskDeg`.
    ///
    /// The geometry matrix rows are `[-e_east, -e_north, -e_up, 1]`, the linearised range-to-state
    /// partials of the navigation solution; DOP is the square root of the diagonal of `(GᵀG)⁻¹`, i.e.
    /// the error amplification the geometry contributes independent of ranging accuracy. Unhealthy SVs
    /// are excluded on purpose — counting a satellite the constellation has flagged out of service
    /// would make the predicted geometry look better than the receiver can actually achieve.
    ///
    /// Returns nil below four satellites (the solution is under-determined: three coordinates plus the
    /// receiver clock) and nil for a singular or ill-conditioned normal matrix, which is what a
    /// clustered constellation produces.
    static func dop(_ satellites: [PredictedSatellite], maskDeg: Double) -> PredictedDOP? {
        assert((-90...90).contains(maskDeg), "an elevation mask is an elevation angle")
        assert(satellites.count <= maxSatellites, "satellite list must be capped by the caller")
        var normal = [Double](repeating: 0, count: 16)
        var used = 0
        for sat in satellites.prefix(maxSatellites) {          // bounded (rule 2)
            guard sat.healthy, sat.elevationDeg >= maskDeg else { continue }
            let el = sat.elevationDeg * .pi / 180, az = sat.azimuthDeg * .pi / 180
            let row = [-cos(el) * sin(az), -cos(el) * cos(az), -sin(el), 1.0]
            for r in 0..<4 {                                   // bounded (rule 2)
                for c in 0..<4 { normal[r * 4 + c] += row[r] * row[c] }
            }
            used += 1
        }
        guard used >= 4, let inv = invert4x4(normal) else { return nil }
        let e = inv[0], n = inv[5], u = inv[10], t = inv[15]
        // Round-off in a near-singular inverse can push a variance negative; that is not a large DOP,
        // it is a meaningless one, so report no geometry rather than a NaN.
        guard e >= 0, n >= 0, u >= 0, t >= 0, (e + n + u + t).isFinite else { return nil }
        return PredictedDOP(gdop: (e + n + u + t).squareRoot(), pdop: (e + n + u).squareRoot(),
                            hdop: (e + n).squareRoot(), vdop: u.squareRoot(), tdop: t.squareRoot())
    }

    // MARK: Linear algebra

    /// Invert a row-major 4x4 by Gauss-Jordan with partial pivoting, or nil if it is singular to
    /// working precision. Fixed size, fully unrolled bounds, no recursion, no allocation beyond the two
    /// 16-element buffers — LAPACK would be overkill and Accelerate is not available to Core/.
    ///
    /// The pivot threshold is RELATIVE to the largest input magnitude, because the normal matrix scales
    /// with the satellite count: an absolute threshold that rejects a clustered 5-satellite geometry
    /// would wrongly accept the same cluster seen by 30 satellites.
    static func invert4x4(_ m: [Double]) -> [Double]? {
        assert(m.count == 16, "expected a row-major 4x4")
        assert(m.allSatisfy { $0.isFinite }, "cannot invert a matrix containing NaN or infinity")
        var a = m
        var inv: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        var scale = 0.0
        for v in a { scale = max(scale, abs(v)) }              // bounded: exactly 16
        let tolerance = max(scale, 1.0) * 1e-12

        for col in 0..<4 {                                     // bounded (rule 2)
            var pivot = col
            for r in (col + 1)..<4 where abs(a[r * 4 + col]) > abs(a[pivot * 4 + col]) { pivot = r }
            guard abs(a[pivot * 4 + col]) > tolerance else { return nil }
            if pivot != col {
                for c in 0..<4 {
                    a.swapAt(col * 4 + c, pivot * 4 + c)
                    inv.swapAt(col * 4 + c, pivot * 4 + c)
                }
            }
            let d = a[col * 4 + col]
            for c in 0..<4 { a[col * 4 + c] /= d; inv[col * 4 + c] /= d }
            for r in 0..<4 where r != col {
                let factor = a[r * 4 + col]
                if factor == 0 { continue }
                for c in 0..<4 {
                    a[r * 4 + c] -= factor * a[col * 4 + c]
                    inv[r * 4 + c] -= factor * inv[col * 4 + c]
                }
            }
        }
        return inv.allSatisfy { $0.isFinite } ? inv : nil
    }
}
