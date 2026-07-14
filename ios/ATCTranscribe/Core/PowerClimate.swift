import Foundation

// MARK: - Cached airport climatology (NASA POWER / MERRA-2)

/// Compact, cache-forever climatology for one airport, folded from NASA POWER hourly history
/// (reanalysis — historical averages, NOT current weather). Two flattened histograms carry
/// everything the UI derives: the windrose for any month/time-of-day filter, prevailing winds,
/// density-altitude percentiles, and all runway favored/crosswind stats — so runway math never
/// goes stale against AIRAC runway updates and no raw samples are stored (~30 KB per airport).
struct PowerClimateStats: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let ident: String
    let lat: Double
    let lon: Double
    let gridElevationM: Double        // MERRA-2 grid-cell elevation (response geometry z)
    let fieldElevationFt: Int?        // NavMeta at build time; nil → density altitude omitted
    let years: [Int]                  // ingested calendar years, ascending
    let sampleCount: Int              // accepted hourly samples (fill-value-filtered)
    /// Joint wind histogram, flattened [month 12][tod 4][dir 17][speed class 8];
    /// dir 0–15 = 16 compass sectors centered on N, dir 16 = calm (<2 kt, class forced 0).
    let windCounts: [UInt16]
    /// Density-altitude histogram, flattened [month 12][tod 4][bin 22];
    /// bin = clamp((DA + 2000) / 1000, 0, 21) → −2,000 … 20,000 ft in 1,000 ft bins.
    let daCounts: [UInt16]
    let builtAt: Date
}

extension PowerClimateStats {
    /// A deterministic synthetic climatology for previews, `--demo-climate`, and the UI test — NO
    /// network. Winds pick up in spring/fall and in the afternoon; density altitude climbs on summer
    /// afternoons, so every chart (rose, best-time matrix, seasonal strip, DA) shows a clear gradient.
    static func demo(ident: String, coord: Coord, fieldElevFt: Int?, now: Date = Date()) -> PowerClimateStats {
        assert(!ident.trimmingCharacters(in: .whitespaces).isEmpty, "ident required")
        assert((-90...90).contains(coord.lat) && (-180...180).contains(coord.lon), "coordinate in range")
        var wind = [UInt16](repeating: 0, count: ClimateMath.windCellCount)
        var da = [UInt16](repeating: 0, count: ClimateMath.daCellCount)
        let elev = fieldElevFt ?? 5_000
        for month in 1...12 {                                        // bounded
            let dir = (month * 2) % 16                               // prevailing rotates through the year
            let seasonKt = 8.0 + 6.0 * sin(Double(month - 3) / 12.0 * 2 * .pi)     // windier spring/fall
            for tod in 0..<4 {
                let todBoost = [0.0, 2.0, 5.0, 2.5][tod]            // afternoon (tod 2) windiest
                let meanKt = max(2.0, seasonKt + todBoost)
                let cls = ClimateMath.classForKt(meanKt)
                wind[ClimateMath.windIndex(month: month, tod: tod, dir: dir, cls: cls)] = 120
                wind[ClimateMath.windIndex(month: month, tod: tod, dir: (dir + 1) % 16, cls: max(0, cls - 1))] = 60
                wind[ClimateMath.windIndex(month: month, tod: tod, dir: ClimateMath.calmDirIndex, cls: 0)] = 40
                let heatFt = Double(elev) + 1500.0 * max(0, sin(Double(month - 4) / 12.0 * 2 * .pi)) * Double(tod + 1)
                let bin = ClimateMath.daBin(heatFt)
                da[ClimateMath.daIndex(month: month, tod: tod, bin: bin)] = 150
                da[ClimateMath.daIndex(month: month, tod: tod, bin: min(bin + 1, ClimateMath.daBinCount - 1))] = 70
            }
        }
        let total = wind.reduce(0) { $0 + Int($1) }
        assert(total > 0 && wind.count == ClimateMath.windCellCount, "demo well-formed")
        return PowerClimateStats(version: PowerClimateStats.currentVersion, ident: ident,
                                 lat: coord.lat, lon: coord.lon, gridElevationM: Double(elev) * 0.3048,
                                 fieldElevationFt: elev, years: [2023, 2024, 2025],
                                 sampleCount: total, windCounts: wind, daCounts: da, builtAt: now)
    }
}

/// Mutable fold state while year chunks stream in. Fixed-size arrays (rule 2); UInt16 saturates
/// (max per cell for 3 years ≈ 558, so overflow needs ~100 years of data).
struct ClimateAccumulator {
    var windCounts = [UInt16](repeating: 0, count: ClimateMath.windCellCount)
    var daCounts = [UInt16](repeating: 0, count: ClimateMath.daCellCount)
    var sampleCount = 0
    var years: Set<Int> = []
}

/// One windrose readout for a month/time-of-day filter.
struct WindRose: Equatable {
    let petalPct: [Double]        // 16 sectors, % of ALL hours in the filter (petals + calm = 100)
    let calmPct: Double
    let meanKtBySector: [Double]  // 16, speed-class-midpoint weighted
    let totalHours: Int
}

// MARK: - Pure climatology math

/// All statistics over `PowerClimateStats` are pure functions here — no network, no actor, no UI —
/// so every formula is fixture-testable. Bounded loops throughout (rule 2).
enum ClimateMath {
    // Histogram layout.
    static let monthCount = 12, todCount = 4, dirCount = 17, classCount = 8
    static let calmDirIndex = 16
    static let daBinCount = 22
    static let windCellCount = monthCount * todCount * dirCount * classCount   // 6,528
    static let daCellCount = monthCount * todCount * daBinCount               // 1,056

    // Binning.
    static let calmThresholdKt = 2.0
    static let mpsToKt = 1.94384
    /// Non-calm speed classes (kt): [2,5) [5,8) [8,11) [11,14) [14,17) [17,21) [21,27) [27,∞).
    static let classMidKt: [Double] = [3.5, 6.5, 9.5, 12.5, 15.5, 19, 24, 30]
    static let sectorNames = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                              "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    static let todNames = ["Night", "Morning", "Afternoon", "Evening"]   // 00–05 / 06–11 / 12–17 / 18–23

    // Ingestion guards.
    static let maxHourKeys = 8_800     // 366 × 24 + slack; bigger chunks are rejected upstream
    static let fillValue = -900.0      // anything ≤ this is POWER's −999 fill

    static func speedClass(kt: Double) -> Int {
        assert(kt >= 0, "wind speed non-negative")
        assert(kt < 500, "plausible wind speed")
        let upper: [Double] = [5, 8, 11, 14, 17, 21, 27]
        for (i, bound) in upper.enumerated() where kt < bound { return i }   // bounded: 7
        return 7
    }

    /// Meteorological direction (blowing FROM, degrees) → 16-sector index centered on N.
    static func sector(deg: Double) -> Int {
        assert(deg.isFinite, "finite direction")
        let norm = ((deg.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let s = Int((norm + 11.25) / 22.5) % 16
        assert((0..<16).contains(s), "sector in range")
        return s
    }

    static func timeOfDay(hour: Int) -> Int {
        assert((0...23).contains(hour), "hour in range")
        let tod = hour / 6
        assert((0..<todCount).contains(tod), "time-of-day bucket in range")
        return tod
    }

    /// "YYYYMMDDHH" (LST — the store requests time-standard=LST, so hours are already local by
    /// longitude) → (month 1–12, hour 0–23); nil for anything malformed.
    static func parseKey(_ key: String) -> (month: Int, hour: Int)? {
        assert(key.utf8.count <= 32, "hourly key length sane (untrusted network input)")
        guard key.count == 10, key.allSatisfy(\.isNumber) else { return nil }
        let c = Array(key)
        assert(c.count == 10, "key fixed at 10 digits past the guard")
        let month = (c[4].wholeNumberValue ?? 0) * 10 + (c[5].wholeNumberValue ?? 0)
        let hour = (c[8].wholeNumberValue ?? 0) * 10 + (c[9].wholeNumberValue ?? 0)
        guard (1...12).contains(month), (0...23).contains(hour) else { return nil }
        return (month, hour)
    }

    static func windIndex(month: Int, tod: Int, dir: Int, cls: Int) -> Int {
        assert((1...monthCount).contains(month) && (0..<todCount).contains(tod), "month/tod in range")
        assert((0..<dirCount).contains(dir) && (0..<classCount).contains(cls), "dir/class in range")
        return (((month - 1) * todCount + tod) * dirCount + dir) * classCount + cls
    }

    static func daIndex(month: Int, tod: Int, bin: Int) -> Int {
        assert((1...monthCount).contains(month) && (0..<todCount).contains(tod), "month/tod in range")
        assert((0..<daBinCount).contains(bin), "bin in range")
        return ((month - 1) * todCount + tod) * daBinCount + bin
    }

    static func daBin(_ daFt: Double) -> Int {
        assert(daFt > -100_000 && daFt < 100_000, "plausible density altitude")
        assert(daFt.isFinite, "density altitude is finite")
        let bin = min(max(Int((daFt + 2000) / 1000), 0), daBinCount - 1)
        assert((0..<daBinCount).contains(bin), "DA bin in range")
        return bin
    }

    // MARK: Density altitude

    /// Standard-atmosphere pressure altitude (ft) from station pressure in kPa.
    static func pressureAltitudeFt(psKPa: Double) -> Double {
        assert(psKPa > 40 && psKPa < 110, "plausible surface pressure")
        let pa = 145366.45 * (1 - pow(psKPa / 101.325, 0.190284))
        assert(pa > -5000 && pa < 40000, "plausible pressure altitude")
        return pa
    }

    /// Density altitude at the FIELD from a grid-cell sample: shift the grid pressure altitude to
    /// field elevation (PA moves ~1:1 for small height differences), lapse the 2 m temperature the
    /// same height (ISA 6.5 °C/km), then the standard DA offset (118.8 ft per °C above ISA).
    /// Anchors: 101.325 kPa / 15 °C / sea level → ≈0 ft; +15 °C above ISA → ≈ +1,782 ft.
    static func densityAltitudeFt(psKPa: Double, t2mC: Double, gridElevM: Double, fieldElevFt: Double) -> Double {
        assert(t2mC > -60 && t2mC < 60, "plausible 2 m temperature")
        assert(abs(fieldElevFt - gridElevM * 3.28084) < 15_000, "grid-to-field shift sane")
        let dhFt = fieldElevFt - gridElevM * 3.28084
        let paField = pressureAltitudeFt(psKPa: psKPa) + dhFt
        let tFieldC = t2mC - 0.0065 * (dhFt / 3.28084)
        let isaC = 15.0 - 0.0019812 * paField
        return paField + 118.8 * (tFieldC - isaC)
    }

    // MARK: Ingestion fold

    /// Fold one calendar year's four hourly series into the histograms. A sample needs valid
    /// wind speed + direction to count; temperature/pressure additionally feed the DA histogram
    /// when the field elevation is known. Fill values (−999) drop the sample, never poison it.
    static func fold(year: Int, ws: [String: Double], wd: [String: Double],
                     t2m: [String: Double], ps: [String: Double],
                     gridElevM: Double, fieldElevFt: Int?,
                     into acc: inout ClimateAccumulator) {
        assert(ws.count <= maxHourKeys, "chunk key count bounded upstream")
        assert(acc.windCounts.count == windCellCount && acc.daCounts.count == daCellCount, "layout intact")
        var accepted = 0
        for (key, wsRaw) in ws {                                   // bounded by maxHourKeys
            guard let (month, hour) = parseKey(key), wsRaw > fillValue, wsRaw >= 0, wsRaw < 200,
                  let wdRaw = wd[key], wdRaw > fillValue, wdRaw.isFinite else { continue }
            let tod = timeOfDay(hour: hour)
            let kt = wsRaw * mpsToKt
            let calm = kt < calmThresholdKt
            bump(&acc.windCounts, windIndex(month: month, tod: tod,
                                            dir: calm ? calmDirIndex : sector(deg: wdRaw),
                                            cls: calm ? 0 : speedClass(kt: kt)))
            if let elev = fieldElevFt,
               let t = t2m[key], t > -60, t < 60,
               let p = ps[key], p > 40, p < 110 {
                let da = densityAltitudeFt(psKPa: p, t2mC: t, gridElevM: gridElevM,
                                           fieldElevFt: Double(elev))
                bump(&acc.daCounts, daIndex(month: month, tod: tod, bin: daBin(da)))
            }
            accepted += 1
        }
        if accepted > 0 { acc.years.insert(year); acc.sampleCount += accepted }
    }

    private static func bump(_ counts: inout [UInt16], _ idx: Int) {
        assert(idx >= 0 && idx < counts.count, "histogram index in range")
        assert(counts.count == windCellCount || counts.count == daCellCount, "known histogram")
        if counts[idx] < UInt16.max { counts[idx] += 1 }           // saturate, never overflow
    }

    // MARK: Queries (all bounded 12×4×17×8 walks)

    /// The windrose for a filter. Empty sets mean "all months" / "all hours".
    static func rose(stats: PowerClimateStats, months: Set<Int>, tods: Set<Int>) -> WindRose {
        assert(stats.windCounts.count == windCellCount, "layout intact")
        assert(months.allSatisfy { (1...12).contains($0) } && tods.allSatisfy { (0..<4).contains($0) },
               "filter values in range")
        let monthsSel = months.isEmpty ? Set(1...monthCount) : months
        let todsSel = tods.isEmpty ? Set(0..<todCount) : tods
        var sectorHours = [Double](repeating: 0, count: 16)
        var sectorKtSum = [Double](repeating: 0, count: 16)
        var calm = 0.0, total = 0.0
        for month in 1...monthCount where monthsSel.contains(month) {
            for tod in 0..<todCount where todsSel.contains(tod) {
                for dir in 0..<dirCount {
                    for cls in 0..<classCount {
                        let n = Double(stats.windCounts[windIndex(month: month, tod: tod, dir: dir, cls: cls)])
                        guard n > 0 else { continue }
                        total += n
                        if dir == calmDirIndex {
                            calm += n
                        } else {
                            sectorHours[dir] += n
                            sectorKtSum[dir] += n * classMidKt[cls]
                        }
                    }
                }
            }
        }
        guard total > 0 else {
            return WindRose(petalPct: .init(repeating: 0, count: 16), calmPct: 0,
                            meanKtBySector: .init(repeating: 0, count: 16), totalHours: 0)
        }
        return WindRose(petalPct: sectorHours.map { $0 / total * 100 },
                        calmPct: calm / total * 100,
                        meanKtBySector: (0..<16).map { sectorHours[$0] > 0 ? sectorKtSum[$0] / sectorHours[$0] : 0 },
                        totalHours: Int(total))
    }

    /// The dominant sector of a rose; nil when there is no data or every hour was calm.
    static func prevailing(_ rose: WindRose) -> (sector: Int, pct: Double, meanKt: Double)? {
        assert(rose.petalPct.count == 16 && rose.meanKtBySector.count == 16, "rose has 16 sectors")
        guard rose.totalHours > 0, let maxPct = rose.petalPct.max(), maxPct > 0,
              let sector = rose.petalPct.firstIndex(of: maxPct) else { return nil }
        assert((0..<16).contains(sector), "sector in range")
        return (sector, maxPct, rose.meanKtBySector[sector])
    }

    /// Density-altitude p50/p90 for a filter (nil without field elevation or data). Cumulative
    /// walk with in-bin linear interpolation over the 1,000 ft bins.
    static func daPercentiles(stats: PowerClimateStats, months: Set<Int>, tods: Set<Int>) -> (p50: Double, p90: Double)? {
        assert(stats.daCounts.count == daCellCount, "layout intact")
        assert(months.allSatisfy { (1...12).contains($0) } && tods.allSatisfy { (0..<4).contains($0) },
               "filter values in range")
        guard stats.fieldElevationFt != nil else { return nil }
        let monthsSel = months.isEmpty ? Set(1...monthCount) : months
        let todsSel = tods.isEmpty ? Set(0..<todCount) : tods
        var bins = [Double](repeating: 0, count: daBinCount)
        var total = 0.0
        for month in 1...monthCount where monthsSel.contains(month) {
            for tod in 0..<todCount where todsSel.contains(tod) {
                for bin in 0..<daBinCount {
                    let n = Double(stats.daCounts[daIndex(month: month, tod: tod, bin: bin)])
                    bins[bin] += n
                    total += n
                }
            }
        }
        guard total > 0 else { return nil }
        return (percentile(bins: bins, total: total, q: 0.5),
                percentile(bins: bins, total: total, q: 0.9))
    }

    private static func percentile(bins: [Double], total: Double, q: Double) -> Double {
        assert(q > 0 && q < 1, "quantile in (0,1)")
        assert(total > 0, "non-empty distribution")
        let target = total * q
        var cum = 0.0
        for (i, n) in bins.enumerated() {                          // bounded: daBinCount
            if n > 0, cum + n >= target {
                let lower = -2000.0 + Double(i) * 1000.0
                return lower + (target - cum) / n * 1000.0
            }
            cum += n
        }
        return -2000.0 + Double(bins.count) * 1000.0
    }

    // MARK: Best-time-of-day + seasonal charts (data for the climate view; all pure + bounded)

    /// Mean surface wind (kt) and sample-hours for ONE month×time-of-day cell. `meanKt` counts calm
    /// hours as 0 kt, so a calm cell reads low. nil cell = no samples.
    struct WindCell: Equatable, Sendable { let meanKt: Double; let hours: Int }

    /// The 12×4 (month × time-of-day) grid of typical wind — the data behind the best-time-of-day
    /// heatmap. Bounded 12×4×17×8 walk, same marginals as `rose`.
    static func windGrid(stats: PowerClimateStats) -> [[WindCell?]] {
        assert(stats.windCounts.count == windCellCount, "layout intact")
        var grid = [[WindCell?]](repeating: [WindCell?](repeating: nil, count: todCount), count: monthCount)
        for month in 1...monthCount {
            for tod in 0..<todCount {
                var ktSum = 0.0, total = 0.0
                for dir in 0..<dirCount {
                    for cls in 0..<classCount {
                        let n = Double(stats.windCounts[windIndex(month: month, tod: tod, dir: dir, cls: cls)])
                        guard n > 0 else { continue }
                        total += n
                        if dir != calmDirIndex { ktSum += n * classMidKt[cls] }   // calm contributes 0 kt
                    }
                }
                if total > 0 { grid[month - 1][tod] = WindCell(meanKt: ktSum / total, hours: Int(total)) }
            }
        }
        assert(grid.count == monthCount && grid[0].count == todCount, "grid is 12×4")
        return grid
    }

    /// Per-month mean wind (kt), hours-weighted across the day, from a `windGrid`; nil month = no data.
    /// Drives the 12-month seasonal strip.
    static func monthlyMeanKt(_ grid: [[WindCell?]]) -> [Double?] {
        assert(grid.count == monthCount, "grid is 12 months")
        assert(grid.allSatisfy { $0.count == todCount }, "each month has 4 tod cells")
        return grid.map { row in
            var ktHours = 0.0, hours = 0.0
            for cell in row where cell != nil {
                ktHours += cell!.meanKt * Double(cell!.hours)
                hours += Double(cell!.hours)
            }
            return hours > 0 ? ktHours / hours : nil
        }
    }

    /// GA wind tier for the heatmap colour ramp: 0 calm (<7), 1 light (7–12), 2 moderate (12–18),
    /// 3 strong (≥18) kt. Stable thresholds so a tier never flips on a rounding boundary.
    static func windTier(kt: Double) -> Int {
        assert(kt.isFinite && kt >= 0, "wind non-negative + finite")
        let tier = kt < 7 ? 0 : kt < 12 ? 1 : kt < 18 ? 2 : 3
        assert((0...3).contains(tier), "tier in 0…3")
        return tier
    }

    /// Nearest speed-class index (inverse of `classMidKt`) for a kt value — for building synthetic data.
    static func classForKt(_ kt: Double) -> Int {
        assert(kt.isFinite && kt >= 0, "wind non-negative + finite")
        var best = 0, bestDist = Double.greatestFiniteMagnitude
        for i in 0..<classCount {                                   // bounded 8
            let d = abs(classMidKt[i] - kt)
            if d < bestDist { bestDist = d; best = i }
        }
        assert((0..<classCount).contains(best), "class in range")
        return best
    }

    // MARK: Runway statistics (Feature D)

    /// Per-end favored percentage: of the NON-CALM hours in the filter, how often this end is the
    /// most headwind-aligned choice among all ends. Ties break to the lexicographically first
    /// designator so the split is deterministic. Which end is favored depends only on direction —
    /// speed cancels — so the sector marginals suffice.
    static func favoredPct(ends: [(designator: String, trueHeadingDeg: Double)],
                           stats: PowerClimateStats, months: Set<Int>, tods: Set<Int>) -> [String: Double] {
        assert(ends.count <= RunwayGeometry.maxPairs * 2, "runway ends bounded")
        assert(months.allSatisfy { (1...12).contains($0) } && tods.allSatisfy { (0..<4).contains($0) },
               "filter values in range")
        guard !ends.isEmpty else { return [:] }
        let r = rose(stats: stats, months: months, tods: tods)
        let windyPct = r.petalPct.reduce(0, +)
        guard windyPct > 0 else { return [:] }
        var favored: [String: Double] = [:]
        for sectorIdx in 0..<16 {                                  // bounded
            let windFrom = Double(sectorIdx) * 22.5
            var best: (designator: String, cosine: Double)?
            for e in ends.prefix(RunwayGeometry.maxPairs * 2) {
                let c = cos((windFrom - e.trueHeadingDeg) * .pi / 180)
                let wins = best.map { c > $0.cosine + 1e-9 || (abs(c - $0.cosine) <= 1e-9 && e.designator < $0.designator) } ?? true
                if wins { best = (e.designator, c) }
            }
            if let best { favored[best.designator, default: 0] += r.petalPct[sectorIdx] }
        }
        return favored.mapValues { $0 / windyPct * 100 }
    }

    /// P(crosswind component > threshold) for a runway PAIR (|sin| is symmetric across both ends),
    /// as a % of non-calm hours in the filter; nil with no windy hours. Quantized by sector center
    /// and speed-class midpoint — appropriate for climatology, not a forecast.
    static func crosswindExceedancePct(runwayTrueHeadingDeg: Double, thresholdKt: Double,
                                       stats: PowerClimateStats, months: Set<Int>, tods: Set<Int>) -> Double? {
        assert(thresholdKt > 0 && thresholdKt < 100, "sane crosswind threshold")
        assert(runwayTrueHeadingDeg.isFinite, "finite heading")
        let monthsSel = months.isEmpty ? Set(1...monthCount) : months
        let todsSel = tods.isEmpty ? Set(0..<todCount) : tods
        var windy = 0.0, exceed = 0.0
        for month in 1...monthCount where monthsSel.contains(month) {
            for tod in 0..<todCount where todsSel.contains(tod) {
                for dir in 0..<16 {
                    let sinAbs = abs(sin((Double(dir) * 22.5 - runwayTrueHeadingDeg) * .pi / 180))
                    for cls in 0..<classCount {
                        let n = Double(stats.windCounts[windIndex(month: month, tod: tod, dir: dir, cls: cls)])
                        guard n > 0 else { continue }
                        windy += n
                        if classMidKt[cls] * sinAbs > thresholdKt { exceed += n }
                    }
                }
            }
        }
        guard windy > 0 else { return nil }
        return exceed / windy * 100
    }
}

// MARK: - Runway pairing (CIFP threshold rows → pairs with true headings)

/// One runway pair with TRUE headings derived from the two threshold coordinates (both ends are in
/// the CIFP table, so `Geo.bearing` between them needs no magnetic-variation model).
struct RunwayPair: Equatable, Sendable, Identifiable {
    struct End: Equatable, Sendable {
        let designator: String        // display form, e.g. "22L"
        let trueHeadingDeg: Double    // the landing/departure direction on this end
    }
    let a: End
    let b: End
    let lengthFt: Int?
    var id: String { "\(a.designator)/\(b.designator)" }
}

enum RunwayGeometry {
    static let maxPairs = 16

    /// Pair CIFP runway ends ("RW04L" ↔ "RW22R") and derive true headings. Ends without a
    /// reciprocal row (or with non-standard designators) are skipped — fail-soft.
    static func pairs(from ends: [CIFPRunway]) -> [RunwayPair] {
        assert(ends.count <= 64, "airport runway-end count sane")
        var byDesignator: [String: CIFPRunway] = [:]
        for e in ends.prefix(maxPairs * 2) where byDesignator[e.designator] == nil {
            byDesignator[e.designator] = e
        }
        var out: [RunwayPair] = []
        var used = Set<String>()
        for e in ends.prefix(maxPairs * 2) {
            guard !used.contains(e.designator),
                  let recipName = reciprocal(of: e.designator),
                  let recip = byDesignator[recipName] else { continue }
            used.insert(e.designator)
            used.insert(recipName)
            out.append(RunwayPair(
                a: .init(designator: label(e.designator), trueHeadingDeg: Geo.bearing(e.coord, recip.coord)),
                b: .init(designator: label(recipName), trueHeadingDeg: Geo.bearing(recip.coord, e.coord)),
                lengthFt: e.lengthFt ?? recip.lengthFt))
            if out.count >= maxPairs { break }
        }
        assert(out.count <= maxPairs, "pair count bounded")
        return out.sorted { $0.id < $1.id }
    }

    /// "RW04L" → "RW22R", "RW36" → "RW18"; nil for malformed/non-standard designators.
    static func reciprocal(of designator: String) -> String? {
        guard designator.hasPrefix("RW") else { return nil }
        let body = designator.dropFirst(2)
        let digits = body.prefix(while: \.isNumber)
        guard let num = Int(digits), (1...36).contains(num) else { return nil }
        let recipNum = num > 18 ? num - 18 : num + 18
        assert((1...36).contains(recipNum), "reciprocal number in range")
        switch body.dropFirst(digits.count) {
        case "L": return String(format: "RW%02dR", recipNum)
        case "R": return String(format: "RW%02dL", recipNum)
        case "C": return String(format: "RW%02dC", recipNum)
        case "":  return String(format: "RW%02d", recipNum)
        default:  return nil                                     // "W" (water) etc. — skip
        }
    }

    /// "RW04L" → "04L" for display.
    static func label(_ designator: String) -> String {
        designator.hasPrefix("RW") ? String(designator.dropFirst(2)) : designator
    }
}
