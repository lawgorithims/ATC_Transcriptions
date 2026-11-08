import Foundation

/// Center Weather Advisories (AWC `api/data/cwa`) → `ConvectiveCell`.
///
/// # Why this is a separate parser and not a parameter to the SIGMET one
///
/// Because the endpoint looks like the airsigmet endpoint and is not. Captured live on 2026-11-03, the
/// Houston CWSU's advisory for `AREA SEV EMBD TS MOV FROM 24035KT. TOPS ABV FL450` arrived as:
///
/// ```json
/// {"cwsu":"ZHU","seriesId":"103","hazard":null,"base":null,"top":null,
///  "coords":[{"lat":"31.886","lon":"-90.953"}, …], "rawText":"…"}
/// ```
///
/// Three traps in one record, and each of them fails silently:
///
/// 1. **`hazard` is null on a severe-thunderstorm advisory.** Other records in the same response carry
///    `"TURB"` and `"TS"`, so the field exists and is populated — just not reliably. Filtering on
///    `hazard == "TS"`, which is the obvious thing to write, drops the severe embedded thunderstorm and
///    keeps the mountain-wave turbulence.
/// 2. **`base` and `top` are null while the text states `TOPS ABV FL450`.** The structured altitude
///    fields the SIGMET feed populates are simply not populated here.
/// 3. **`coords` are JSON STRINGS**, where the airsigmet endpoint returns numbers. A `Double`-typed
///    decode of this throws, which — behind `Failable` — means the record vanishes rather than errors.
///
/// So the hazard class, the tops and the motion all come out of `rawText`, which is the actual bulletin
/// and is the one field that has never been missing. That is unusual for this codebase and is the reason
/// the text scanners below are separated out into `CWAText` and tested on their own.
///
/// CWAs are issued for conditions **below** Convective SIGMET criteria and are valid at most two hours,
/// which is exactly why they are worth reading: they are the cheapest partial answer to "what about the
/// cell nobody issued a SIGMET for".
enum CWAParser {

    private struct Record: Decodable {
        let cwsu: String?
        let seriesId: String?
        let hazard: String?
        let validTimeFrom: Int?
        let validTimeTo: Int?
        let base: Int?
        let top: Int?
        let rawText: String?
        let coords: [Point]?

        /// ⚠️ Lenient on purpose — see trap 3. The AWC serves these as strings here and as numbers on
        /// the airsigmet endpoint, and a strict `Double` decode silently loses every CWA.
        struct Point: Decodable {
            let lat: Double
            let lon: Double
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                lat = try Self.number(c, .lat)
                lon = try Self.number(c, .lon)
            }
            private enum Key: String, CodingKey { case lat, lon }
            private static func number(_ c: KeyedDecodingContainer<Key>, _ k: Key) throws -> Double {
                if let d = try? c.decode(Double.self, forKey: k) { return d }
                let s = try c.decode(String.self, forKey: k)
                guard let d = Double(s) else {
                    throw DecodingError.dataCorruptedError(forKey: k, in: c,
                                                           debugDescription: "not a number")
                }
                return d
            }
        }
    }

    private struct Failable: Decodable {
        let record: Record?
        init(from decoder: Decoder) throws { record = try? Record(from: decoder) }
    }

    static func cells(_ data: Data) -> [ConvectiveCell] {
        assert(ConvectiveAlert.maxCells > 0, "CWAParser: cell cap must be positive")
        guard !data.isEmpty else { return [] }      // the endpoint answers 204 on a quiet day
        guard let rows = try? JSONDecoder().decode([Failable].self, from: data) else { return [] }
        var out: [ConvectiveCell] = []
        out.reserveCapacity(min(rows.count, ConvectiveAlert.maxCells))
        for row in rows.prefix(ConvectiveAlert.maxCells) {
            if let c = cell(from: row.record) { out.append(c) }
        }
        assert(out.count <= ConvectiveAlert.maxCells, "CWAParser: snapshot bounded for the alert")
        return out
    }

    private static func cell(from r: Record?) -> ConvectiveCell? {
        guard let r else { return nil }
        let raw = r.rawText ?? ""
        // Trap 1: the structured field is authoritative when it says TS, and worthless when it is null.
        let hazard = (r.hazard ?? "").uppercased()
        let convective = hazard == "TS" || (hazard.isEmpty && CWAText.isConvective(raw))
        guard convective else { return nil }
        guard let from = r.validTimeFrom, let to = r.validTimeTo, to > from else { return nil }
        let ring = (r.coords ?? []).prefix(ConvectiveAlert.maxVertices)
            .map { Coord(lat: $0.lat, lon: $0.lon) }
        // The feed closes its rings (first vertex repeated last); the alert's ring convention does not.
        let open = Self.openRing(Array(ring))
        guard open.count >= 2 else { return nil }
        // ⚠️ A BAD VERTEX REJECTS THE WHOLE CELL, it does not get dropped from the ring. Dropping it
        // leaves a ring that still parses and still draws, but is SMALLER than the hazard it came from —
        // and smaller is the direction that stops the alert firing. Losing the cell is also an
        // under-warning, but an honest one: the other two sources still cover the same storm, and
        // `ConvectiveCellMerge` folds whichever of them survived into the same banner.
        guard open.allSatisfy(ConvectiveAlert.isPlausible) else { return nil }

        let series = r.seriesId ?? "?"
        let centre = r.cwsu ?? "CWA"
        // Trap 2: prefer the structured altitudes if they ever arrive, else read the bulletin.
        let tops = r.top.map { Double($0) * 100 } ?? CWAText.topsFt(raw)
        let base = r.base.map { Double($0) * 100 }
        let motion = CWAText.motion(raw)

        return ConvectiveCell(
            id: "CWA-\(centre)-\(series)",
            // Worded exactly as the bulletin heads itself ("ZHU CWA 103"), so the pilot can look it up
            // or hear a controller refer to it and know it is the same thing.
            label: "\(centre) CWA \(series)",
            polygon: open,
            topsFtMSL: tops,
            baseFtMSL: base,
            observedAt: Date(timeIntervalSince1970: Double(from)),
            validUntil: Date(timeIntervalSince1970: Double(to)),
            // The feed publishes no severity for CWAs. A CWA is by definition below SIGMET criteria,
            // so leaving it nil is also the truthful ordering against one.
            severity: nil,
            movingFromDeg: motion?.fromDeg,
            motionKt: motion?.kt,
            source: .cwa)
    }

    /// Drop a repeated closing vertex. Leaving it in puts a zero-length edge in the ring, which the
    /// segment-distance math handles but the containment test need not.
    static func openRing(_ ring: [Coord]) -> [Coord] {
        assert(ring.count <= ConvectiveAlert.maxVertices, "CWAParser: ring clamped upstream")
        guard let first = ring.first, let last = ring.last, ring.count > 2 else { return ring }
        let same = abs(first.lat - last.lat) < 1e-9 && abs(first.lon - last.lon) < 1e-9
        return same ? Array(ring.dropLast()) : ring
    }
}

/// The bulletin-text scanners CWAs force on us. Pure string work, separated out so each shape below can
/// be pinned against a real bulletin line.
///
/// Hand-written scanning rather than regular expressions: these three patterns are each a fixed sequence
/// of a keyword, some optional qualifiers and a fixed-width number group, and the word-boundary rule in
/// `isConvective` is the one subtlety — which is far easier to state and test as code than to read out
/// of an escaped pattern.
enum CWAText {

    /// Longest bulletin worth scanning. CWAs are a few hundred characters.
    static let maxScan = 4_096

    /// Is this advisory about convection?
    ///
    /// ⚠️ THE WORD BOUNDARY IS THE WHOLE TRICK. A CWA's text is dense with abbreviations, and a naive
    /// `contains("TS")` matches `GUSTS` (and so tags a wind advisory as a thunderstorm) while a naive
    /// `contains(" TS ")` misses `TS.` at the end of a sentence. The tokens below are matched only when
    /// bounded by a non-alphanumeric on both sides, so `GUSTS`, `KTS` and `PRESFR` do not match and
    /// `SEV EMBD TS MOV`, `ISOL TS.` and `LN TSTM` do.
    static func isConvective(_ raw: String) -> Bool {
        assert(maxScan > 0, "CWAText: scan cap must be positive")
        let s = String(raw.prefix(maxScan)).uppercased()
        for token in ["TS", "TSTM", "TSTMS", "CB", "TORNADO", "FUNNEL"] {   // bounded: 6 (rule 2)
            if containsToken(s, token) { return true }
        }
        return false
    }

    /// Whole-token search: `token` present, with a non-alphanumeric (or the string edge) each side.
    static func containsToken(_ s: String, _ token: String) -> Bool {
        assert(!token.isEmpty, "CWAText: empty token")
        guard !s.isEmpty else { return false }
        let chars = Array(s), t = Array(token)
        guard chars.count >= t.count else { return false }
        func alnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var i = 0
        while i <= chars.count - t.count {                   // bounded by the scan cap (rule 2)
            if chars[i] == t[0], Array(chars[i..<(i + t.count)]) == t {
                let beforeOK = i == 0 || !alnum(chars[i - 1])
                let afterIdx = i + t.count
                let afterOK = afterIdx == chars.count || !alnum(chars[afterIdx])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    /// `MOV FROM 24035KT` → (240°, 35 kt).
    ///
    /// ⚠️ THE BULLETIN SAYS "FROM" AND MEANS IT. 240 here is the direction the storms are coming FROM,
    /// travelling TOWARD 060 — the same convention as the airsigmet feed's `movementDir` and the NWS
    /// warnings' `eventMotionDescription`, both of which were verified against their own prose rather
    /// than assumed. `ConvectiveCell.movingFromDeg` holds it unchanged; `ConvectiveAlert.advance` takes
    /// the reciprocal exactly once.
    ///
    /// `LTL MOV` / `MOV LTL` (little movement) returns nil rather than 0 kt: a stated zero would be
    /// extrapolated as a stationary cell with a tight avoidance radius, while nil buys
    /// `unknownMotionUncertaintyNm` of slack, and "little" is not "none".
    static func motion(_ raw: String) -> (fromDeg: Double, kt: Double)? {
        let s = String(raw.prefix(maxScan)).uppercased()
        if containsToken(s, "LTL") { return nil }
        let chars = Array(s)
        var i = 0
        while i < chars.count {                              // bounded by the scan cap (rule 2)
            guard chars[i] == "M", matches(chars, i, "MOV") else { i += 1; continue }
            var j = i + 3
            // Optional inflection and the "FROM" keyword, each preceded by any run of spaces/letters
            // we are willing to skip: MOV, MOVG, MOVING, then FROM.
            while j < chars.count, chars[j].isLetter { j += 1 }         // bounded (rule 2)
            while j < chars.count, chars[j] == " " { j += 1 }           // bounded (rule 2)
            if matches(chars, j, "FROM") {
                j += 4
                while j < chars.count, chars[j] == " " { j += 1 }       // bounded (rule 2)
            }
            // A run of 5 or 6 digits immediately followed by KT: dddss or dddsss.
            var k = j
            while k < chars.count, chars[k].isNumber { k += 1 }         // bounded (rule 2)
            let digits = k - j
            if digits == 5 || digits == 6, matches(chars, k, "KT"),
               let deg = Double(String(chars[j..<(j + 3)])),
               let kt = Double(String(chars[(j + 3)..<k])),
               deg >= 0, deg <= 360, kt > 0, kt < 200 {
                return (deg == 360 ? 0 : deg, kt)
            }
            i += 1
        }
        return nil
    }

    /// `TOPS TO FL450` → 45,000 ft. `TOPS 450` → 45,000 ft.
    ///
    /// ⚠️ `TOPS ABV FLnnn` RETURNS NIL, AND THAT IS THE SAFE ANSWER, NOT A GAP. "Above FL450" is a
    /// LOWER BOUND, not a top. Recording 45,000 from it would let the vertical gate clear an aircraft at
    /// FL500 by the 5,000 ft overflight rule — against a storm the bulletin has just said it cannot see
    /// the top of. nil lands in `VerticalRelation.topsUnknown`, which alerts at every altitude, which is
    /// what an unmeasured top deserves.
    static func topsFt(_ raw: String) -> Double? {
        let s = String(raw.prefix(maxScan)).uppercased()
        let chars = Array(s)
        var i = 0
        while i < chars.count {                              // bounded by the scan cap (rule 2)
            guard chars[i] == "T", matches(chars, i, "TOPS") else { i += 1; continue }
            var j = i + 4
            var unbounded = false
            // Skip the qualifier words between TOPS and the number.
            var words = 0
            while j < chars.count, words < 4 {                          // bounded: 4 (rule 2)
                while j < chars.count, chars[j] == " " { j += 1 }       // bounded (rule 2)
                if matches(chars, j, "ABV") { unbounded = true; j += 3; words += 1; continue }
                if matches(chars, j, "ABOVE") { unbounded = true; j += 5; words += 1; continue }
                if matches(chars, j, "TO") { j += 2; words += 1; continue }
                if matches(chars, j, "AOB") { j += 3; words += 1; continue }
                if matches(chars, j, "FL") { j += 2; words += 1; continue }
                break
            }
            while j < chars.count, chars[j] == " " { j += 1 }           // bounded (rule 2)
            var k = j
            while k < chars.count, chars[k].isNumber { k += 1 }         // bounded (rule 2)
            if k - j == 3, let fl = Double(String(chars[j..<k])), fl > 0, fl <= 600 {
                return unbounded ? nil : fl * 100
            }
            i += 1
        }
        return nil
    }

    @inline(__always)
    private static func matches(_ chars: [Character], _ at: Int, _ word: String) -> Bool {
        assert(!word.isEmpty, "CWAText: empty word")
        let w = Array(word)
        guard at >= 0, at + w.count <= chars.count else { return false }
        for n in 0..<w.count where chars[at + n] != w[n] { return false }   // bounded by the word (rule 2)
        return true
    }
}
