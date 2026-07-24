import Foundation

/// The header that ships beside `terrain_conus.bin` (written by `Tools/build_terrain_grid.py`).
///
/// Everything the reader needs to turn a lat/lon into a byte offset lives here rather than being
/// hard-coded in Swift, so a re-build at a different resolution or bbox is a data change and not a
/// code change. The metadata fields below the geometry are optional on purpose: they are provenance
/// for the UI's disclaimer, and a header that omits them is still a usable grid — whereas a header
/// missing `rows` is not, and must fail to decode.
struct TerrainGridHeader: Decodable, Equatable {
    let version: Int
    let latMax: Double            // north edge — grid row 0
    let latMin: Double            // south edge
    let lonMin: Double            // west edge — grid column 0
    let lonMax: Double            // east edge
    let rows: Int
    let cols: Int
    let cellsPerDegree: Double    // 60 = one arc-minute cells (~1.85 km)
    let noData: Int               // int16 sentinel, -32768

    var units: String?            // "metres"
    var datum: String?            // orthometric — see the datum rule on `TerrainElevation.agl`
    var aggregation: String?      // "max" — why the lookup is nearest-cell and never bilinear
    var sourceZoom: Int?
    var source: String?
    /// The cockpit-facing disclaimer, carried in the data so the UI can never drift from the build
    /// that produced the grid it is actually reading.
    var advisory: String?

    /// The only layout this reader knows how to index. A future grid with a different cell encoding
    /// must bump this so an old app refuses the file outright rather than mis-indexing it.
    static let supportedVersion = 1
    /// Hard ceiling on either grid dimension — see `isSelfConsistent`. Generous enough for a global
    /// arc-second grid, small enough that rows * cols * 2 cannot overflow.
    static let maxDimension = 2_000_000

    /// Exact size the `.bin` must be. Only meaningful once `isSelfConsistent` has bounded the shape —
    /// it is that guard, not the platform's 64-bit Int, that makes this multiplication safe.
    var byteCount: Int { rows * cols * 2 }

    /// Cross-check the header against ITSELF before trusting any of it. A header is the one part of
    /// the payload we parse rather than index, so it is also the one part an editing accident can
    /// corrupt silently: a bbox that disagrees with `rows`/`cols` would still decode fine and then
    /// place every lookup a few cells off — a wrong terrain elevation, which is worse than none.
    var isSelfConsistent: Bool {
        guard version == Self.supportedVersion else { return false }
        guard rows > 0, cols > 0, cellsPerDegree > 0 else { return false }
        // Bound the SHAPE before multiplying anywhere. `rows * cols * 2` on a hostile or corrupt header
        // (rows = cols = 4e18 satisfies every geometric check below) overflows Int and traps — Swift's
        // `*` is checked in release too, so this would be a crash on malformed data, which this file
        // promises never to do. The cap is far above any real grid (a global 1-arc-minute grid is
        // 21600 x 10800).
        guard rows <= Self.maxDimension, cols <= Self.maxDimension else { return false }
        guard latMax > latMin, lonMax > lonMin else { return false }
        guard (-90.0...90.0).contains(latMin), (-90.0...90.0).contains(latMax) else { return false }
        guard (-180.0...180.0).contains(lonMin), (-180.0...180.0).contains(lonMax) else { return false }
        // The shape must be derivable from the bbox — this is the check that catches a hand-edited
        // bound. `.rounded()` because the builder computes the same product in floating point.
        guard Int(((latMax - latMin) * cellsPerDegree).rounded()) == rows else { return false }
        guard Int(((lonMax - lonMin) * cellsPerDegree).rounded()) == cols else { return false }
        assert(rows * cols > 0, "a consistent header describes at least one cell")
        assert(byteCount == rows * cols * 2, "byte count derives from the shape, int16 per cell")
        return true
    }
}

/// Why the grid is or isn't answering. Distinct cases because they need distinct engineering
/// responses: `missing` means the resource was never bundled (a packaging bug), `headerInvalid` and
/// `sizeMismatch` mean it was bundled and is broken (a build-script or LFS bug). All three present
/// to the pilot identically — no AGL row at all — but they must not be indistinguishable in the log.
enum TerrainGridStatus: Equatable, Sendable {
    case ready
    case missing         // no file at the URL (or nothing at that name in the bundle)
    case headerInvalid   // header absent, undecodable, an unknown version, or self-inconsistent
    case sizeMismatch    // truncated or padded — rows*cols*2 != file size

    var label: String {
        switch self {
        case .ready:         return "ready"
        case .missing:       return "terrain grid not installed"
        case .headerInvalid: return "terrain header unreadable"
        case .sizeMismatch:  return "terrain grid truncated"
        }
    }
}

/// How much weight the AGL number deserves. This is deliberately NOT a numeric confidence: the
/// pilot-facing decision is binary — show it plainly, or show it caveated (dimmed, with a ± band, or
/// as a dashed value) — and a percentage invites the reader to over-trust a figure whose dominant
/// error term is the grid's own coarseness, not the GPS.
enum AGLTrust: String, Equatable, Sendable {
    case usable   // tight vertical sigma and a position solution the integrity monitor believes
    case coarse   // wide vertical sigma or a degraded position — display, but visibly hedged
}

/// Every reason an AGL reading is refused. Modelled explicitly rather than as a bare `nil` because
/// the UI must distinguish them: "outside coverage" is a permanent property of where you are flying
/// (say so once, over Canada or the Gulf), "no altitude" is a transient GPS state that will clear,
/// and "position not trusted" is an active warning the pilot is already seeing elsewhere. Collapsing
/// them into nil produces a readout that blinks out for unexplained reasons.
enum AGLUnavailable: String, Equatable, Sendable, CaseIterable {
    case gridUnavailable          // the bundled grid is missing/short/corrupt — feature is off
    case positionNotTrusted       // caller's GPS integrity says don't derive anything from this fix
    case noAltitude               // the fix carries no MSL altitude at all
    case verticalAccuracyUnknown  // no vertical sigma — we cannot bound the error, so we won't guess
    case verticalAccuracyPoor     // vertical sigma past the usable limit
    case horizontalAccuracyPoor   // horizontal sigma spans multiple cells — the cell choice is arbitrary
    case outsideCoverage          // beyond the grid bbox, or a no-data cell (ocean / source gap)

    /// Short cockpit-readable phrase for the readout's placeholder line.
    var label: String {
        switch self {
        case .gridUnavailable:         return "terrain data unavailable"
        case .positionNotTrusted:      return "GPS not trusted"
        case .noAltitude:              return "no GPS altitude"
        case .verticalAccuracyUnknown: return "altitude accuracy unknown"
        case .verticalAccuracyPoor:    return "GPS altitude too coarse"
        case .horizontalAccuracyPoor:  return "GPS position too coarse for terrain"
        case .outsideCoverage:         return "outside terrain coverage"
        }
    }
}

/// A computed height above the terrain model, carrying the inputs it was derived from so the UI can
/// show its work (terrain elevation under the aircraft is itself a useful readout) and the log can be
/// audited after the fact.
struct AGLReading: Equatable, Sendable {
    /// Height above the SURFACE model in feet. May be negative — see `isBelowSurfaceModel`.
    let aglFt: Double
    /// The grid cell's value in metres, in the same orthometric datum as `altitudeMSLm`.
    let terrainElevationM: Double
    /// The MSL altitude used, in metres. Kept so a disagreement with the pilot's baro is traceable.
    let altitudeMSLm: Double
    /// The fix's 1-sigma vertical accuracy in metres — the honest ± on `aglFt` before the grid's own
    /// error is added, and the reason `trust` is what it is.
    let verticalAccuracyM: Double
    let trust: AGLTrust

    var terrainElevationFt: Double { terrainElevationM * GPSReadout.mToFt }

    /// How much this reading could be OVERSTATING clearance, in feet, combining the fix's vertical
    /// 1-sigma with the grid's measured peak under-read. The two ADD — the grid does not offset GPS
    /// error, it compounds it (see `TerrainElevation.peakUnderReadM`) — so this is the number a cautious
    /// pilot should subtract, and the reason the readout is advisory.
    var marginFt: Double {
        (verticalAccuracyM + TerrainElevation.peakUnderReadM) * GPSReadout.mToFt
    }

    /// The conservative reading: AGL minus the margin, floored at zero. This is what a warning should
    /// ever be computed from — never `aglFt` — because being early is survivable and being late is not.
    var conservativeAglFt: Double { max(aglFt - marginFt, 0) }

    /// True when the aircraft is below the surface model. This happens routinely and legitimately:
    /// the source is a SURFACE model (tree canopy and buildings are in it) that is additionally
    /// MAX-aggregated over ~1 NM cells, so anything low over forest, over a city, or in a valley beside
    /// a ridge reads negative. The UI should render that as "SFC" or a floored "0 ft AGL" with the
    /// value dimmed — never as a negative altitude, which reads as an instrument fault — but the raw
    /// negative MUST survive into this struct and the log. Clamping it inside the model would erase
    /// the one signal that distinguishes ordinary canopy bias from a genuinely wrong altitude or a
    /// mis-indexed grid, and a clamped zero silently masquerades as "just barely clear".
    var isBelowSurfaceModel: Bool { aglFt < 0 }
}

/// The result of asking for AGL: a reading, or the specific reason there isn't one.
enum AGLResult: Equatable, Sendable {
    case reading(AGLReading)
    case unavailable(AGLUnavailable)

    var reading: AGLReading? { if case .reading(let r) = self { return r }; return nil }
    var unavailable: AGLUnavailable? { if case .unavailable(let u) = self { return u }; return nil }
}

/// Bundled terrain-elevation lookup behind the AGL readout.
///
/// The grid is a raw little-endian int16 array of metres, row-major, first row = north edge, first
/// column = west edge, produced by `Tools/build_terrain_grid.py` (read its header comment — it is the
/// authoritative spec and explains the datum and max-aggregation decisions this reader depends on).
/// It is MEMORY-MAPPED, never read into a Swift array: an ~11 MB CONUS grid then costs effectively no
/// resident memory, pages in only the handful of pages an actual flight touches, and is evicted under
/// pressure like any other clean file page. A lookup is one index computation and two byte reads —
/// no decode, no cache, no allocation, and therefore safe to call every fix.
///
/// NOT thread-safe, by the same convention as `GPSIntegrityMonitor`: `AppModel` owns the shared
/// instance on the main actor and calls it from the location delegate, which already delivers there.
/// Nothing here mutates after `init`, so the object is in fact read-only — but `Data`'s mapped buffer
/// is not documented as concurrency-safe to fault in from multiple threads, so keep it on one.
///
/// Every failure mode degrades to `.unavailable`: a missing, truncated, or corrupt file yields a
/// working object that simply refuses to answer. Nothing in this file can trap on bad data — the
/// assertions state post-conditions of paths already guarded, so they document invariants without
/// giving a corrupt resource a way to kill the app in a debug build.
final class TerrainElevation {

    /// The app-wide instance over the bundled CONUS grid. Main actor only (see the type comment).
    static let shared = TerrainElevation()

    static let defaultName = "terrain_conus"
    static let bundleSubdirectory = "terrain"

    /// Above this 1-sigma vertical accuracy the reading is hedged rather than shown plainly. ~15 m is
    /// roughly what a healthy WAAS-class solution reports; past it the GPS altitude is still right but
    /// soft, and the pilot should be told so before they compare it to a chart.
    static let coarseVerticalAccuracyM = 15.0

    /// Above this 1-sigma vertical accuracy no reading is produced at all. At 50 m sigma the 95% band
    /// is ±330 ft — a third of a typical pattern altitude, in exactly the low-and-slow regime where an
    /// AGL number is the only reason anyone looks at it. A figure that wrong is worse than a blank,
    /// because a blank does not invite a decision.
    static let maxVerticalAccuracyM = 50.0

    /// How far the grid can UNDER-read real terrain, in metres, and therefore how far AGL can OVERSTATE
    /// clearance. This is the correction to an earlier, wrong claim in this file that the grid's error
    /// was one-sided in the safe direction because of max-aggregation. It is not.
    ///
    /// Max-aggregation guarantees a cell is at least the highest SAMPLE it saw — not the highest ground
    /// inside it. The source is an already-smoothed ~245 m-posting DEM, so a sharp summit is missing
    /// from the samples before aggregation ever runs. Measured against the shipped grid, 17 of 18 CONUS
    /// summits read BELOW their surveyed elevation (Grand Teton by 161 m / 528 ft), and the grid's global
    /// maximum, 4368 m, is below Mount Whitney's 4421 m — the grid cannot represent the highest point in
    /// the country. Over open terrain and at airports the agreement is within tens of metres (Denver
    /// +2 m, Dallas -1 m); it is peaks specifically that are under-read.
    ///
    /// So the error ADDS to the GPS vertical error rather than offsetting it, and near mountains the
    /// readout is optimistic. `AGLReading.marginFt` carries this outward so the UI can hedge it, and it
    /// is the reason the readout is advisory and must never be used for terrain avoidance.
    static let peakUnderReadM = 165.0

    /// Above this horizontal 1-sigma the fix cannot pick a cell (cells are ~1852 m N-S, ~1439 m E-W at
    /// 39 degrees N). Set to roughly half a cell so the chosen cell is more likely right than not.
    static let maxHorizontalAccuracyM = 700.0

    let status: TerrainGridStatus
    private let header: TerrainGridHeader?
    /// The mapped file. Held as `Data` with `.mappedIfSafe`, so this reference is the mapping's
    /// lifetime — nothing copies it, and `withUnsafeBytes` hands out a pointer straight into the pages.
    private let grid: Data?

    var isAvailable: Bool { status == .ready }

    /// Provenance for the UI's disclaimer line and for the diagnostics log; nil when the grid failed
    /// to load. Read `advisory` off this rather than restating the disclaimer in the view.
    var gridHeader: TerrainGridHeader? { header }

    /// Designated init. Takes optional URLs so a bundle lookup that found nothing flows through the
    /// same degradation path as a file that turned out to be corrupt, with no call-site branching.
    init(headerURL: URL?, binURL: URL?) {
        let loaded = Self.load(headerURL: headerURL, binURL: binURL)
        self.status = loaded.status
        self.header = loaded.header
        self.grid = loaded.grid
        assert(loaded.status == .ready || (loaded.header == nil && loaded.grid == nil),
               "a failed load must publish neither a header nor a mapping")
        assert(loaded.status != .ready || loaded.grid?.count == loaded.header?.byteCount,
               "a ready grid is exactly rows*cols*2 bytes")
    }

    /// Load a grid pair out of an arbitrary directory. This is the injection seam the tests use: a
    /// synthetic grid written to a temp directory exercises the identical code path as the bundle.
    convenience init(directory: URL, name: String = TerrainElevation.defaultName) {
        self.init(headerURL: directory.appendingPathComponent(name + ".json"),
                  binURL: directory.appendingPathComponent(name + ".bin"))
    }

    /// Load the bundled grid. The `subdirectory:` lookup is tried first and a flat lookup second,
    /// matching how the rest of `Core/` finds its resources — Xcode's folder-reference vs group
    /// handling has flattened these before, and a silently missing grid is a shipped bug.
    convenience init(bundle: Bundle = .main, name: String = TerrainElevation.defaultName) {
        let json = bundle.url(forResource: name, withExtension: "json",
                              subdirectory: TerrainElevation.bundleSubdirectory)
            ?? bundle.url(forResource: name, withExtension: "json")
        let bin = bundle.url(forResource: name, withExtension: "bin",
                             subdirectory: TerrainElevation.bundleSubdirectory)
            ?? bundle.url(forResource: name, withExtension: "bin")
        self.init(headerURL: json, binURL: bin)
    }

    // MARK: - Lookup

    /// Terrain elevation in METRES at `coord`, or nil outside coverage.
    ///
    /// NEAREST CELL — specifically, the cell CONTAINING the point, computed with the same floor
    /// binning the builder used to fill it, so reader and writer can never disagree by a cell. There
    /// is deliberately no bilinear interpolation: each cell holds the MAXIMUM source sample inside it,
    /// and blending maxima is not an estimate of anything. Worse, it is unsafe in one direction —
    /// interpolating between two ridge cells LOWERS the terrain in the valley the aircraft is actually
    /// in, turning the grid's conservative bias into an optimistic one.
    ///
    /// Returns nil for the `noData` sentinel (ocean, or a source tile that failed to fetch) rather
    /// than -32768 m, which a caller would otherwise cheerfully subtract.
    func elevationM(at coord: Coord) -> Double? {
        guard let header, let grid else { return nil }
        assert(status == .ready, "a header and mapping are only published in the ready state")
        assert(grid.count == header.byteCount, "mapping size fixed at load")
        guard coord.lat.isFinite, coord.lon.isFinite else { return nil }
        guard coord.lat >= header.latMin, coord.lat <= header.latMax,
              coord.lon >= header.lonMin, coord.lon <= header.lonMax else { return nil }

        // Both products are in [0, rows] / [0, cols] given the bounds check above; the clamp only
        // matters on the exact south and east edges, which floor to one past the last cell and
        // belong to it. No unbounded conversion can trap here.
        let rowRaw = Int(((header.latMax - coord.lat) * header.cellsPerDegree).rounded(.down))
        let colRaw = Int(((coord.lon - header.lonMin) * header.cellsPerDegree).rounded(.down))
        let row = min(header.rows - 1, max(0, rowRaw))
        let col = min(header.cols - 1, max(0, colRaw))

        let raw = Self.cell(row: row, col: col, header: header, grid: grid)
        guard Int(raw) != header.noData else { return nil }
        return Double(raw)
    }

    /// Terrain elevation in FEET at `coord` — the unit the map and the object card display.
    func elevationFt(at coord: Coord) -> Double? {
        elevationM(at: coord).map { $0 * GPSReadout.mToFt }
    }

    // MARK: - AGL

    /// Height above the terrain model for a device fix, in FEET, or the reason there isn't one.
    ///
    /// CRITICAL DATUM RULE: this uses `fix.altitudeMSLm` — CoreLocation's ORTHOMETRIC (geoid-
    /// referenced) altitude — and must NEVER use `fix.altitudeEllipsoidalM`. The grid's source DEMs
    /// are geoid-referenced too (SRTM/NASADEM = EGM96, 3DEP = NAVD88, both within a metre of the
    /// EGM2008 model Core Location applies), so the two terms cancel correctly only in that datum.
    /// The geoid undulation across CONUS runs about -17 m at Denver to -35 m at Los Angeles, so
    /// pairing the ellipsoidal height with this grid does not fail loudly — it silently OVERSTATES
    /// clearance by 55 to 115 feet, everywhere, always in the dangerous direction.
    ///
    /// `integrity` is the caller's current `GPSIntegrityMonitor` assessment. Pass it whenever one
    /// exists: a position the monitor has disowned must not be turned into a terrain clearance, since
    /// the horizontal error is what selects the cell. nil means the caller runs no monitor and is
    /// vouching for the fix itself.
    ///
    /// Refusal precedence is deliberate: grid first (the feature is simply off, say nothing else),
    /// then position trust (never derive from a fix we don't believe), then the altitude terms, then
    /// coverage — so the pilot sees the most actionable cause rather than an incidental one.
    func agl(fix: DeviceFix, integrity: GPSIntegrityAssessment? = nil) -> AGLResult {
        assert(fix.horizontalAccuracyM.isFinite, "an invalid fix must not reach the AGL computation")
        assert(Self.coarseVerticalAccuracyM < Self.maxVerticalAccuracyM, "hedge before refusing")

        guard isAvailable else { return .unavailable(.gridUnavailable) }
        if let integrity, integrity.shouldSuppressOwnship { return .unavailable(.positionNotTrusted) }
        guard let altM = fix.altitudeMSLm, altM.isFinite else { return .unavailable(.noAltitude) }
        // `DeviceLocation` already resolves CoreLocation's `verticalAccuracy <= 0` sentinel to nil, so
        // a non-positive value arriving here is a malformed fix and is treated the same as a missing
        // one: we cannot bound the error, and an unbounded AGL is not a number worth showing.
        guard let vAccM = fix.verticalAccuracyM, vAccM.isFinite, vAccM > 0 else {
            return .unavailable(.verticalAccuracyUnknown)
        }
        guard vAccM <= Self.maxVerticalAccuracyM else { return .unavailable(.verticalAccuracyPoor) }
        // The HORIZONTAL error is what selects the cell, and neighbouring cells can differ by a great
        // deal — measured p99 is 290 m and the worst adjacent pair in the shipped grid differs by
        // 2026 m (6647 ft). A fix whose horizontal uncertainty spans multiple cells is not selecting a
        // cell at all, so the terrain it returns is arbitrary and the AGL built on it is fiction.
        guard fix.horizontalAccuracyM <= Self.maxHorizontalAccuracyM else {
            return .unavailable(.horizontalAccuracyPoor)
        }
        guard let terrainM = elevationM(at: fix.coord) else { return .unavailable(.outsideCoverage) }

        let degradedFix = integrity.map { $0.state >= .degraded } ?? false
        let trust: AGLTrust = (vAccM > Self.coarseVerticalAccuracyM || degradedFix) ? .coarse : .usable
        return .reading(AGLReading(aglFt: (altM - terrainM) * GPSReadout.mToFt,
                                   terrainElevationM: terrainM,
                                   altitudeMSLm: altM,
                                   verticalAccuracyM: vAccM,
                                   trust: trust))
    }

    // MARK: - Loading

    /// Read the header, map the grid, and cross-check the two. Static so the whole load is one
    /// expression at the call site and every `let` property is assigned exactly once.
    ///
    /// The size check is a GUARD rather than an assertion on purpose: a truncated resource (an LFS
    /// pointer that never resolved, a half-written build) is a plausible field condition, and the
    /// required behaviour is a dark AGL row, not a crash. The assertions below it state what is true
    /// once that guard has passed.
    private static func load(headerURL: URL?, binURL: URL?)
        -> (status: TerrainGridStatus, header: TerrainGridHeader?, grid: Data?) {
        guard let headerURL, let binURL else { return (.missing, nil, nil) }
        guard let headerBytes = try? Data(contentsOf: headerURL) else { return (.missing, nil, nil) }
        guard let header = try? JSONDecoder().decode(TerrainGridHeader.self, from: headerBytes),
              header.isSelfConsistent else { return (.headerInvalid, nil, nil) }
        // .mappedIfSafe: mapped for a regular local file, quietly read normally for anything the
        // kernel would not map safely (a network volume), so this can never be the reason a lookup
        // faults on a stale mapping.
        guard let grid = try? Data(contentsOf: binURL, options: .mappedIfSafe) else {
            return (.missing, nil, nil)
        }
        guard grid.count == header.byteCount else { return (.sizeMismatch, nil, nil) }
        assert(header.rows > 0 && header.cols > 0, "a self-consistent header has a positive shape")
        assert(grid.count == header.rows * header.cols * 2, "int16 per cell, row-major, no padding")
        return (.ready, header, grid)
    }

    /// One cell, straight out of the mapped pages.
    ///
    /// The two bytes are composed explicitly rather than loaded as an `Int16`: the format is defined
    /// as little-endian independent of the host, and this way the code says so. `withUnsafeBytes` on
    /// mapped `Data` hands back a pointer to the mapping itself, so there is no copy and no
    /// allocation per lookup — only the page fault the first touch of a region costs.
    private static func cell(row: Int, col: Int, header: TerrainGridHeader, grid: Data) -> Int16 {
        assert(row >= 0 && row < header.rows, "row index inside the grid")
        assert(col >= 0 && col < header.cols, "column index inside the grid")
        let offset = (row * header.cols + col) * 2
        assert(offset + 1 < grid.count, "cell offset inside the mapping")
        return grid.withUnsafeBytes { raw -> Int16 in
            let lo = UInt16(raw[offset])
            let hi = UInt16(raw[offset + 1])
            return Int16(bitPattern: lo | (hi << 8))
        }
    }
}
