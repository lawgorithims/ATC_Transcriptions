import Foundation
import MapKit
import CoreLocation

/// Legacy shim for the BACKGROUND prefetchers' "is this link metered" question.
///
/// The probe itself now lives in `DownloadPolicy.currentPath()`. There used to be THREE independent
/// `NWPathMonitor` implementations in the app — this one, `ChartLibrary.isExpensiveConnection()`, and
/// nothing at all in `NavDataLibrary` — which is how the same question got three different answers
/// depending on which button the pilot pressed. Kept as a named entry point because "expensive" is a
/// weaker test than the pilot's Wi-Fi-only setting and a few internal callers still want exactly it.
enum NetPath {
    static func isExpensive() async -> Bool {
        let path = await DownloadPolicy.currentPath()
        return path.expensive || path.constrained
    }
}

// MARK: - Shared chart cache + prefetch service

/// App-lifetime shared chart cache, owned by `AppModel`. It pulls the catalog fetch, the
/// on-disk pack cache, and background downloading OUT of the per-sheet `ChartStore` so charts
/// can be **warmed and prefetched before the map is ever opened** — which is what removes the
/// open-the-map-and-wait delay. The per-sheet `ChartStore` still owns the live MapKit reader set
/// and its memory eviction; it now asks this library for the (already-warm) catalog and reads the
/// (already-on-disk) packs, so opening the chart does no network round-trip in the common case.
///
/// Lives in `UI/` (not `Core/`) on purpose: it depends on the UI-only chart types
/// (`ChartCatalog`, `ChartLayer`, `MBTilesReader`) and on MapKit/UIKit, none of which the
/// Foundation-only `ATCKitProbe` macOS target compiles.
@MainActor
final class ChartLibrary: ObservableObject {
    /// App-lifetime singleton. `AppModel` drives its prefetch; the map sheet's per-open `ChartStore`
    /// reads packs from it. A single instance means the catalog is warmed once and the on-disk cache is
    /// shared across every map open.
    static let shared = ChartLibrary()

    private(set) var catalog: ChartCatalog?
    private(set) var cycle = ""

    /// Progress of an explicit "download all US charts" run, for the Settings UI.
    enum BulkDownload: Equatable {
        case idle, running(done: Int, total: Int), finished(added: Int), failed(String)
        var isRunning: Bool { if case .running = self { return true }; return false }
    }
    @Published var bulk: BulkDownload = .idle
    /// Total bytes of chart packs currently on disk (drives the "stored on device" readout).
    @Published private(set) var cachedBytes: Int = 0
    /// Of `cachedBytes`, how much belongs to the pre-cached NEXT cycle. Published rather than computed
    /// on demand because the Downloads screen shows it: a directory scan inside a SwiftUI body runs on
    /// every layout pass, and this one would run beside a list of 86 rows.
    @Published private(set) var stagedBytes: Int = 0
    /// Pack ids currently downloading via the per-region Downloads page (drives per-row spinners).
    @Published private(set) var downloadingIDs: Set<String> = []
    /// Progress of the next-cycle pre-cache, for the Downloads UI.
    @Published private(set) var precache: Precache = .idle

    /// What the next-cycle pre-cache is doing. `.ready` is the state this feature exists to reach: the
    /// pilot's whole kit is on disk for a cycle that has not started, and the roll will cost nothing.
    enum Precache: Equatable {
        case idle                                       // nothing staged by the publisher (the usual state)
        case off                                        // the pilot turned pre-caching off
        case waiting(String)                            // staged, but the policy says not now
        case running(done: Int, total: Int)
        case ready(cycle: String, packs: Int)
        case partial(cycle: String, have: Int, want: Int)
    }

    private var inFlight: Set<String> = []
    private var warming: Task<Bool, Never>?
    private var bulkTask: Task<Void, Never>?
    private var precacheTask: Task<Void, Never>?
    /// Bumped per bulk run so a finishing run only releases its OWN handle.
    private var bulkGeneration = 0
    private let location = OneShotLocation()

    /// Pack ids the user explicitly downloaded for offline use — **pinned**: exempt from the LRU cap so a
    /// full-country download is never silently evicted. Persisted and keyed to the chart cycle.
    private var pinned: Set<String> = []
    private let pinnedKey = "atc.pinnedCharts"
    private let pinnedCycleKey = "atc.pinnedChartsCycle"

    /// Modest ceiling on the *incidental* on-disk pack cache (route/around-me prefetch + free-pan) for the
    /// current cycle. Pinned offline downloads don't count against it. Old cycles are pruned outright;
    /// within a cycle we LRU-evict non-pinned packs by file date so free-panning can't silently fill the device.
    private let diskBudgetBytes = 600 * 1024 * 1024

    // MARK: Catalog

    /// Fetch the pack catalog once per launch (coalesced across concurrent callers) so opening the
    /// map costs no round-trip. Returns whether a catalog is available.
    /// Currency of the downloadable pack catalog. `.unknown` until the catalog has been fetched.
    var chartProvenance: DataProvenance { catalog?.provenance ?? .unknown }

    /// Re-fetch the catalog from the server, discarding the cached copy. This is what the pilot's
    /// "Check for a new cycle" action calls: `warm()` deliberately fetches only once per launch, so
    /// without this an expired catalog would stay expired for the whole session even after the FAA
    /// published a new one.
    /// Re-fetch the catalog, KEEPING the current one if the fetch fails.
    ///
    /// Nil-ing it first was a cockpit hazard: `warm()` returns false without restoring, so one tap on a
    /// marginal connection left `catalog == nil` for the rest of the offline period — and a nil catalog
    /// means ChartStore draws NO charts even though the packs are sitting on disk, and the expired
    /// banner disappears because provenance falls back to `.unknown`. A pilot who taps "check" while
    /// taxiing must not lose the charts they already have.
    @discardableResult
    func refreshCatalog() async -> Bool {
        let previous = catalog
        catalog = nil
        warming = nil
        if await warm() { return true }
        catalog = previous                       // fetch failed — keep flying on what we had
        if let previous { cycle = previous.cycle }
        return false
    }

    /// What a "check for a new cycle" actually found. The old flow refreshed the catalog and said
    /// NOTHING, so the honest outcomes — "you are already current" and "the publisher has not put out a
    /// newer cycle yet" — were indistinguishable from a broken button.
    enum CycleCheck: Equatable {
        case upToDate(cycle: String)
        /// A newer cycle exists and `packs` of the pilot's installed packs can be replaced from it.
        case newCycle(from: String, to: String, packs: Int)
        case offline
    }

    /// The packs a cycle update should restore: the ones the pilot DELIBERATELY downloaded.
    ///
    /// Deliberately not "every file on disk". The charts directory holds two populations — pinned packs
    /// the pilot chose, and packs that route/around-me prefetch and free panning pulled in incidentally,
    /// which `enforceDiskBudget` is free to evict under a 600 MB LRU. Re-downloading the incidental set
    /// at a new cycle would promote a pack the pilot never asked for into a permanent resident and
    /// defeat that budget. Read the PERSISTED pins, since an in-memory set is dropped on a cycle change.
    func installedPackIDs() -> Set<String> {
        let out = Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
        assert(out.count <= 4096, "pinned pack set out of range")
        return out
    }

    /// Re-fetch the catalog and report what it means for THIS install.
    func checkForNewCycle() async -> CycleCheck {
        let before = cycle
        let installed = installedPackIDs()
        guard await refreshCatalog() else { return .offline }
        guard cycle != before, !cycle.isEmpty else { return .upToDate(cycle: cycle.isEmpty ? before : cycle) }
        let replaceable = (catalog?.entries ?? []).filter { installed.contains($0.id) }.count
        return .newCycle(from: before, to: cycle, packs: replaceable)
    }

    /// Re-download, at the current catalog cycle, every pack the pilot already had. This is the action
    /// the expired banner was missing: refreshing the catalog alone changes the cycle the app READS
    /// from, which without this leaves the pilot with fewer charts than they started with.
    /// Returns false when the update was declined because the connection is metered — every other bulk
    /// path in the app checks this first, and a multi-gigabyte re-download over a cockpit hotspot is
    /// exactly what those checks exist to prevent.
    @discardableResult
    func updateInstalledPacks(_ ids: Set<String>, allowExpensive: Bool = false) async -> Bool {
        // Filter by entitlement BEFORE `addIntent`. Recording intent for a pack the download funnel
        // will refuse would leave the app believing the pilot asked for coverage they cannot have,
        // and `pruneOldCycleFiles` reasons about that intent set.
        let wanted = (catalog?.entries ?? []).filter {
            ids.contains($0.id) && !isCached($0) && EntitlementStore.shared.can($0.capability)
        }
        guard !wanted.isEmpty else { bulk = .idle; return true }
        if !allowExpensive, !(await DownloadPolicy.shared.verdict(.userInitiated)).isAllowed { return false }
        // Record the pilot's INTENT before a single byte moves. loadPinned() clears the pin set on a
        // cycle change, so the first completed download used to rewrite UserDefaults with only that one
        // id — and an update interrupted after 3 of 40 packs left the app believing the pilot had ever
        // wanted 3. pruneOldCycleFiles then deleted the other 37 old-cycle files, which were the only
        // copies they still had. Their coverage must survive a cancelled or crashed update.
        addIntent(ids)                     // intent first; `pinned` follows each pack that lands
        bulkTask?.cancel()
        bulkGeneration &+= 1
        let gen = bulkGeneration
        bulkTask = Task { [weak self] in await self?.runBulkEntries(wanted, generation: gen) }
        return true
    }

    @discardableResult
    func warm() async -> Bool {
        if catalog != nil { return true }
        if let w = warming { return await w.value }
        let task = Task { [weak self] () -> Bool in
            do {
                let (data, resp) = try await NetworkActivity.data(
                    for: URLRequest(url: ChartCatalog.url), "Chart index", .charts)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return self?.adoptCachedCatalog() ?? false }
                let cat = try JSONDecoder().decode(ChartCatalog.self, from: data)
                guard let self else { return false }
                self.adopt(cat)
                self.writeCachedCatalog(data)     // the copy an offline launch will fly on
                return true
            } catch {
                return self?.adoptCachedCatalog() ?? false
            }
        }
        warming = task
        let ok = await task.value
        warming = nil
        return ok
    }

    /// Everything that must follow a catalog becoming current, from either source.
    private func adopt(_ cat: ChartCatalog) {
        catalog = cat
        cycle = cat.cycle
        pruneOldCycleFiles()
        loadPinned()
        refreshCachedBytes()
    }

    /// THE OFFLINE-KIT FIX. The catalog was fetched from the network on EVERY launch and cached nowhere,
    /// while `ChartStore.load` opens with `guard let catalog = library.catalog else { return }` — so a
    /// cold launch with no signal left `catalog == nil` for the whole session and not one downloaded pack
    /// was ever opened. The .mbtiles files were sitting on disk the entire time; the app simply had no
    /// list telling it which bounds they covered. That is backwards for an electronic flight bag: the
    /// pilot downloads their charts at home precisely so they will be there when there is no signal, and
    /// iOS jettisoning a backgrounded app mid-flight is enough to trigger it. They were left with the
    /// bundled z0-7 base and none of their regional coverage.
    ///
    /// Deliberately caches the RAW BYTES rather than re-encoding: `ChartCatalog` is `Decodable` only, so
    /// this needs no round-trip conformance and what is replayed is byte-identical to what the server
    /// served. Provenance is unaffected and stays honest — the cached catalog carries its own cycle, so
    /// the currency banner reports it as exactly as old as it is.
    private func adoptCachedCatalog() -> Bool {
        guard catalog == nil,
              let data = try? Data(contentsOf: cachedCatalogURL),
              let cat = try? JSONDecoder().decode(ChartCatalog.self, from: data) else { return false }
        adopt(cat)
        return true
    }

    private func writeCachedCatalog(_ data: Data) {
        try? data.write(to: cachedCatalogURL, options: .atomic)
    }

    /// Beside the packs it describes, in the same durable Application Support dir — never `.caches`, for
    /// the same reason the packs are not: iOS purges that under storage pressure, which would take the
    /// index and the offline kit with it.
    private var cachedCatalogURL: URL { dir.appendingPathComponent("catalog.json") }

    // MARK: On-disk cache

    /// `Application Support/charts/` — NOT `.cachesDirectory`, which iOS silently PURGES under storage
    /// pressure (a red-hat finding: a pilot's multi-GB offline kit could vanish with no warning, leaving
    /// no base charts in flight with no signal). Mirrors `PlateStore`/`ModelStore`. Excluded from iCloud
    /// backup (large + re-downloadable). Migrates any packs left in the old caches location on first use so
    /// an upgrade never re-downloads what's already on disk. Computed once (lazy) — the migration runs once.
    private lazy var dir: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        var d = base.appendingPathComponent("charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        Self.migrateFromCaches(into: d)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        return d
    }()

    /// Move any `.mbtiles` packs left in the legacy `.cachesDirectory/charts` into the new durable dir,
    /// then remove the old dir. Best-effort per file (a failed move just leaves that pack to re-download).
    private static func migrateFromCaches(into newDir: URL) {
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("charts", isDirectory: true)
        guard old != newDir,
              let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "mbtiles" {            // bounded by disk contents (rule 2)
            let dst = newDir.appendingPathComponent(f.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: f) }
            else { try? FileManager.default.moveItem(at: f, to: dst) }
        }
        try? FileManager.default.removeItem(at: old)                   // clear the now-empty legacy dir
    }

    /// On-disk name carries the AIRAC cycle so a new cycle can't be served from a stale cached file.
    ///
    /// This is the WRITE path and the "is it current" path. For READING, use `readableURL` — see the
    /// note there for why the two must differ.
    func localURL(_ e: ChartCatalog.Entry) -> URL { localURL(e.id, cycle: cycle) }

    /// The on-disk path a pack for `id` takes at an ARBITRARY cycle — the pre-cache writes the NEXT
    /// cycle's file here.
    ///
    /// This is what makes activation free. A staged pack is stored under the name the catalog will ask
    /// for once the cycle rolls, so promotion on the device is not a copy, a move, or a re-download —
    /// `localURL` simply starts resolving to a file that is already there. Nothing has to run at
    /// 0901Z, which matters because nothing reliably does.
    func localURL(_ id: String, cycle: String) -> URL {
        dir.appendingPathComponent("\(id)-\(cycle).mbtiles")
    }

    /// The pack file to actually OPEN: this cycle's if it is there, else the newest older-cycle copy
    /// still on disk.
    ///
    /// ⚠️ WITHOUT THIS, PUBLISHING A NEW CYCLE BLANKS EVERY PILOT'S OFFLINE KIT. `pruneOldCycleFiles`
    /// deliberately KEEPS pinned packs across a rollover and its comment promises they survive "as a
    /// labeled-expired fallback" — but nothing implemented the fallback. `localURL` returns only
    /// `<id>-<currentCycle>.mbtiles`, so the instant a newly published index.json was adopted every
    /// downloaded pack became invisible: the files were on disk, the reader asked for a name that did
    /// not exist yet, and the chart went blank. On a metered or absent connection the multi-gigabyte
    /// re-download is exactly what the pilot cannot do, and it would happen the moment an automated
    /// publish landed — making a cycle roll strictly worse than no automation at all.
    ///
    /// An expired pack is the right thing to draw here. The alternative is a blank chart, and the app
    /// already labels stale data loudly (DataCurrencyBanner, the Downloads expiry row, and
    /// `stalePackCount` below, which offers the re-download). Showing last cycle's chart clearly marked
    /// beats showing nothing silently.
    ///
    /// Returns nil when there is no copy at all, so callers keep their existing "not cached" path.
    func readableURL(_ e: ChartCatalog.Entry) -> URL? {
        let current = localURL(e)
        if FileManager.default.fileExists(atPath: current.path) { return current }
        return newestOlderCyclePack(e.id)
    }

    /// True when the only copy on disk is from an older cycle — the map is drawing it, and the pilot
    /// should be offered a refresh.
    func isServedStale(_ e: ChartCatalog.Entry) -> Bool {
        !FileManager.default.fileExists(atPath: localURL(e).path) && newestOlderCyclePack(e.id) != nil
    }

    /// Newest on-disk pack for this id from ANY cycle other than the current one. Thin disk wrapper —
    /// the choice itself is `chooseOlderCyclePack`, kept pure so it can be unit-tested without a
    /// filesystem (same split as `packID`, which `ChartPackIDTests` covers).
    private func newestOlderCyclePack(_ id: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let candidates = files.map { url -> (name: String, modified: Date) in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (url.lastPathComponent, d ?? .distantPast)
        }
        return Self.chooseOlderCyclePack(id: id, currentCycle: cycle, candidates: candidates)
            .map { dir.appendingPathComponent($0) }
    }

    /// The cycle string out of an on-disk `<id>-<cycle>.mbtiles` name, by the same shape rules as
    /// `packID` — which is to say never by position, because a pack id may itself contain dashes.
    nonisolated static func packCycle(_ name: String) -> String? {
        guard name.hasSuffix(".mbtiles") else { return nil }
        let stem = String(name.dropLast(".mbtiles".count))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        let digits = { (s: Substring, n: Int) in s.count == n && s.allSatisfy(\.isNumber) }
        if parts.count >= 4 {
            let t = Array(parts.suffix(3))
            if digits(t[0], 2), digits(t[1], 2), digits(t[2], 4) { return t.joined(separator: "-") }
        }
        if parts.count >= 2, let last = parts.last, digits(last, 4) { return String(last) }
        return nil
    }

    /// Is this on-disk pack from a cycle that has NOT started yet?
    ///
    /// Only the `MM-DD-YYYY` form can be dated; the legacy `YYNN` form predates the rename and is
    /// always in the past, so it reports false. An unparseable name reports false too — "cannot tell"
    /// must not promote a file into the not-yet-effective class, because that class is excluded from
    /// the fallback and excluding a real old pack would blank the map.
    nonisolated static func isFuturePack(_ name: String, asOf now: Date) -> Bool {
        guard let cyc = packCycle(name), let eff = ChartCatalog.cycleDate(cyc) else { return false }
        return now < eff.addingTimeInterval(9 * 3600 + 60)        // 0901Z on the effective date
    }

    /// Which on-disk file to fall back to for `id` when this cycle's pack is absent.
    ///
    /// Ordered by modification date, NOT by the cycle string. Two cycle shapes coexist on disk —
    /// `MM-DD-YYYY` and the legacy `YYNN` (see `packID`) — and neither sorts lexically into chronological
    /// order, let alone against each other: "05-14-2026" > "01-29-2027" as text. The download date is
    /// the one ordering that is actually true.
    ///
    /// Excludes the current cycle: callers reach here only when that file is missing, and including it
    /// would let a zero-byte or half-written current file win on recency.
    ///
    /// ⚠️ AND IT EXCLUDES CYCLES THAT HAVE NOT STARTED. Pre-caching puts NEXT cycle's pack on disk
    /// days early, under next cycle's filename. "Newest file for this id from any other cycle" matches
    /// it — and because it is the most recently downloaded file on disk it wins every time. A missing
    /// current pack would then be served from a chart that is not in effect yet, labeled as an OLDER
    /// cycle by `isServedStale`, with the currency banner reporting the current cycle's dates. That is
    /// strictly worse than the blank map this fallback exists to prevent: a blank map tells the truth.
    nonisolated static func chooseOlderCyclePack(
        id: String, currentCycle: String, candidates: [(name: String, modified: Date)],
        asOf now: Date = Date()
    ) -> String? {
        let currentName = "\(id)-\(currentCycle).mbtiles"
        return candidates
            .filter { $0.name != currentName && packID($0.name) == id }
            .filter { !isFuturePack($0.name, asOf: now) }         // see the note below
            .max { $0.modified < $1.modified }?
            .name
    }

    /// How many packs the map is currently serving from an older cycle. Drives the Downloads row that
    /// offers the re-download, which is deliberately NOT gated on `isExpired`: on a cycle roll the NEW
    /// catalog is perfectly current, so an expiry-gated control would hide itself at exactly the moment
    /// the pilot needs it.
    var stalePackCount: Int { (catalog?.entries ?? []).filter { isServedStale($0) }.count }

    /// A pack is considered cached once its file is on disk — the download path only leaves a file
    /// there after an integrity check, so presence is a safe signal (no per-call SQLite open).
    func isCached(_ e: ChartCatalog.Entry) -> Bool {
        FileManager.default.fileExists(atPath: localURL(e).path)
    }

    /// Delete cached packs from previous cycles so the pilot never reads an expired chart off disk — but
    /// NEVER a PINNED pack (an explicit offline download). At an AIRAC rollover the pilot often opens the
    /// map while briefly online BEFORE the new cycle is downloaded; the old code then wiped the whole pinned
    /// US kit in the background, and if signal dropped they'd fly with zero charts (a red-hat finding). A
    /// pinned old-cycle pack is kept as a labeled-expired fallback, and `readableURL` now actually
    /// serves it when this cycle's file is absent — the Downloads screen reports it as an older cycle
    /// (`stalePackCount`) and offers the re-download, so it is never silently passed off as current.
    /// (This comment used to claim the reader only ever opened the current-cycle filename. It did,
    /// which is precisely why a cycle roll blanked the map.) Incidental un-pinned prefetch packs are
    /// still pruned to reclaim space.
    private func pruneOldCycleFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let suffix = "-\(cycle).mbtiles"
        // Read the PERSISTED pin ids, not the in-memory `pinned`: prune runs BEFORE loadPinned() (and
        // loadPinned drops the in-memory set on a cycle change), so only UserDefaults still knows which packs
        // the pilot explicitly downloaded. Those must survive the rollover; incidental prefetch is prunable.
        let pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
        for f in files where f.pathExtension == "mbtiles" && !f.lastPathComponent.hasSuffix(suffix) {
            if Self.packID(f.lastPathComponent).map(pinnedIDs.contains) == true { continue }   // keep pilot's downloads
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// The pack id from an on-disk `<id>-<cycle>.mbtiles` filename.
    ///
    /// Two cycle shapes exist on disk, because the naming changed and old files outlive the change: the
    /// current FAA effective date `MM-DD-YYYY`, and an older 4-digit `YYNN`. The date form CONTAINS TWO
    /// DASHES, so the previous rule — everything before the LAST dash — returned "New_York_SEC-05-14"
    /// for every file the app writes today and matched no catalog id at all. That silently broke the one
    /// guarantee `pruneOldCycleFiles` exists to make: unable to recognise a pinned pack, it deleted the
    /// pilot's explicitly-downloaded kit at the next cycle rollover — exactly the cockpit failure its
    /// own comment describes preventing.
    ///
    /// So the cycle is stripped by SHAPE, never by position, and a pack id is free to contain dashes.
    /// A name with no recognisable cycle is not a pack file, and reports nil.
    nonisolated static func packID(_ name: String) -> String? {
        guard name.hasSuffix(".mbtiles") else { return nil }
        let stem = String(name.dropLast(".mbtiles".count))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        let digits = { (s: Substring, n: Int) in s.count == n && s.allSatisfy(\.isNumber) }

        // MM-DD-YYYY (the current form)
        if parts.count >= 4 {
            let t = Array(parts.suffix(3))
            if digits(t[0], 2), digits(t[1], 2), digits(t[2], 4) {
                let id = parts.dropLast(3).joined(separator: "-")
                return id.isEmpty ? nil : id
            }
        }
        // YYNN (the legacy form)
        if parts.count >= 2, let last = parts.last, digits(last, 4) {
            let id = parts.dropLast().joined(separator: "-")
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// Ensure a pack is on disk, downloading it if missing. Integrity-checked (openable + has tile
    /// rows) before it's kept. Returns the on-disk URL, or nil on failure.
    @discardableResult
    func ensureOnDisk(_ e: ChartCatalog.Entry) async -> URL? {
        await ensureOnDisk(e, cycle: cycle, expectStamp: nil)
    }

    /// Download `e` to the file name for `cycle`, if it is not already there.
    ///
    /// `expectStamp` is checked against the pack's own `faa_cycle` metadata when non-nil. The
    /// pre-cache passes it; the ordinary path does not, and the asymmetry is deliberate. A staged
    /// pack is fetched from a path that, by construction, nothing else has verified for this device:
    /// `publish_packs.py` guards the host against publishing last cycle's bytes under a new cycle
    /// number, but a pack pulled days early and then activated silently weeks later gets no second
    /// look. Since `build_chart.sh` stamps the cycle into every pack, the device can hold the
    /// publisher to its claim for the cost of one `metadata` read it is already doing.
    @discardableResult
    func ensureOnDisk(_ e: ChartCatalog.Entry, cycle: String, expectStamp: String?,
                      priority: NetworkActivity.Priority = .normal) async -> URL? {
        let dst = localURL(e.id, cycle: cycle)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }   // verified at write time
        // ENTITLEMENT BACKSTOP. Enforced here as well as at the callers for the same reason the
        // Wi-Fi rule is ("Enforced here too because 'Wi-Fi only' has to be true of every caller,
        // including ones added later"): this is the single funnel every chart download passes
        // through, so a new caller cannot route around the tier check by accident.
        //
        // Note the ordering: the on-disk check comes FIRST. A pack already downloaded keeps working
        // even if the entitlement lapses — only a NEW download is refused. See
        // `EntitlementCurrency.grants` for why revoking content already on the device is the one
        // thing this design will not do.
        guard EntitlementStore.shared.can(e.capability) else { return nil }
        guard let remote = e.remote else { return nil }   // malformed path (L13) → pack simply unavailable
        do {
            let (tmp, resp) = try await NetworkActivity.download(
                from: remote, "Chart pack: \(e.id.replacingOccurrences(of: "_", with: " "))",
                .charts, priority)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                // The caller owns the file `download(from:)` wrote even on a non-200. Returning without
                // removing it leaks a full-size temp per failed attempt, and the retry paths above will
                // hammer the same URL — on a captive-portal Wi-Fi that is an error page per pack, per
                // attempt, filling the device with copies of it. (Same defect, same fix, as
                // NavDataLibrary.run.)
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            guard let r = MBTilesReader(path: dst.path), r.hasTiles else {   // integrity: openable + has tiles
                try? FileManager.default.removeItem(at: dst)
                return nil
            }
            if let want = expectStamp, let got = r.metadata["faa_cycle"], got != want {
                try? FileManager.default.removeItem(at: dst)
                return nil
            }
            _ = r                                                           // reader closes on deinit
            return dst
        } catch { return nil }
    }

    // MARK: Prefetch

    /// Catalog entries for `layer` whose bounds intersect any of `rects`.
    func packsCovering(_ rects: [MKMapRect], layer: ChartLayer) -> [ChartCatalog.Entry] {
        guard let catalog else { return [] }
        return layer.entries(catalog).filter { e in rects.contains { e.mapRect.intersects($0) } }
    }

    /// Background prefetch: download not-yet-cached packs covering `rects` for each raster layer,
    /// de-duped against in-flight downloads and **bounded by `cap` per call** so a wide area can
    /// never mass-download the country. Silently no-ops when offline / catalog unavailable.
    func prefetch(rects: [MKMapRect], layers: [ChartLayer], cap: Int = 8) async {
        guard !rects.isEmpty, await warm() else { return }
        // ⚠️ THIS CHECK WAS MISSING ENTIRELY. `NetPath`'s own comment said it existed "for the
        // BACKGROUND prefetchers", and `updateInstalledPacks` did consult it — but route and
        // around-me prefetch, the two paths that run unprompted on launch and while the pilot pans,
        // went straight to `ensureOnDisk`. Up to 8 packs per call, 30–70 MB each, on whatever link
        // happened to be up. That is the single most expensive thing this app can do without being
        // asked, and it was the one bulk path with no opinion about the connection at all.
        guard await DownloadPolicy.shared.verdict(.background).isAllowed else { return }
        for layer in layers where layer.isRaster {
            var todo = packsCovering(rects, layer: layer).filter { !isCached($0) && !inFlight.contains($0.id) }
            if todo.count > cap { todo = Array(todo.prefix(cap)) }
            for e in todo {
                inFlight.insert(e.id)
                _ = await ensureOnDisk(e, cycle: cycle, expectStamp: nil, priority: .background)
                inFlight.remove(e.id)
            }
        }
        enforceDiskBudget()
    }

    /// Prefetch the packs around a single position (device GPS / Stratux fix) — used on app open so
    /// the charts for where you are are already on disk by the time you open the map.
    func prefetchAround(_ c: Coord, radiusNM: Double = 60, layers: [ChartLayer], cap: Int = 6) async {
        await prefetch(rects: [ChartGeo.rect(around: c, radiusNM: radiusNM)], layers: layers, cap: cap)
    }

    // MARK: Location

    /// The best available fix for startup prefetch: the Stratux fix when connected, else a single
    /// device-GPS fix. Returns nil when no fix is available or location permission is denied.
    func nearestFix(preferring stratux: Coord?) async -> Coord? {
        if let stratux { return stratux }
        return await location.fix()
    }

    // MARK: Disk budget (LRU by file date)

    /// Keep the current-cycle pack cache under `diskBudgetBytes` by deleting the oldest files first.
    /// Deleting a pack a live reader still has open is safe on iOS (the fd stays valid until closed);
    /// the file simply re-downloads next time it's needed.
    private func enforceDiskBudget() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        // Pinned offline downloads are exempt — only the incidental cache is bounded.
        var packs = files.filter { $0.pathExtension == "mbtiles" && !isPinnedFile($0) }
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var total = packs.reduce(0) { $0 + size($1) }
        guard total > diskBudgetBytes else { return }
        packs.sort { date($0) < date($1) }                                  // oldest (least-recently-downloaded) first
        for f in packs {
            if total <= diskBudgetBytes { break }
            let sz = size(f)
            try? FileManager.default.removeItem(at: f)
            total -= sz
        }
        refreshCachedBytes()
    }

    // MARK: Offline "download all US charts"

    /// Total on-disk size of all chart packs (drives the "stored on device" readout).
    func refreshCachedBytes() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            cachedBytes = 0; stagedBytes = 0; return
        }
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let packs = files.filter { $0.pathExtension == "mbtiles" }
        cachedBytes = packs.reduce(0) { $0 + size($1) }
        if let staged = catalog?.next?.cycle {
            stagedBytes = packs
                .filter { Self.packCycle($0.lastPathComponent) == staged }
                .reduce(0) { $0 + size($1) }
        } else {
            stagedBytes = 0
        }
    }

    /// Catalog bytes for the given raster layers (the full download size), and the not-yet-cached remainder.
    func totalBytes(_ layers: [ChartLayer]) -> Int { entries(for: layers).reduce(0) { $0 + $1.bytes } }
    func remainingBytes(_ layers: [ChartLayer]) -> Int { entries(for: layers).filter { !isCached($0) }.reduce(0) { $0 + $1.bytes } }
    func packCount(_ layers: [ChartLayer]) -> Int { entries(for: layers).count }

    private func entries(for layers: [ChartLayer]) -> [ChartCatalog.Entry] {
        guard let catalog else { return [] }
        return layers.filter { $0.isRaster }.flatMap { $0.entries(catalog) }
    }

    /// Start downloading every US pack for the chosen layers (idempotent — skips what's already on disk).
    /// Downloaded packs are **pinned** so the LRU cap never evicts them. No-op while one is already running.
    func startBulkDownload(layers: [ChartLayer], allowMetered: Bool = false) {
        guard bulkTask == nil else { return }
        bulkTask = Task { await self.runBulk(layers: layers, allowMetered: allowMetered) }
    }

    func cancelBulkDownload() {
        bulkTask?.cancel()
        bulkTask = nil
        bulk = .idle
    }

    /// Bulk-download an explicit entry list (the cycle-update path), sharing the bulk progress state.
    private func runBulkEntries(_ list: [ChartCatalog.Entry], generation: Int) async {
        // bulkTask is the mutual-exclusion token for bulk downloading, so EVERY exit must release it —
        // leaking it permanently poisons startBulkDownload's `guard bulkTask == nil` and the
        // "Download all" row becomes a dead button for the rest of the launch. The generation check
        // stops a finishing run from clearing a NEWER run's handle, which would let two bulk downloads
        // proceed at once and leave the Cancel button wired to neither.
        defer { if generation == bulkGeneration { bulkTask = nil; bulk = .idle } }
        var done = 0
        bulk = .running(done: 0, total: list.count)
        for e in list.prefix(4096) {                                          // bounded (rule 2)
            if Task.isCancelled { return }
            _ = await download(e)
            done += 1
            bulk = .running(done: done, total: list.count)
        }
        refreshCachedBytes()
    }

    private func runBulk(layers: [ChartLayer], allowMetered: Bool = false) async {
        guard await warm() else { bulk = .failed("Chart index unavailable"); bulkTask = nil; return }
        let all = entries(for: layers)
        let total = all.count
        var done = 0, added = 0
        bulk = .running(done: 0, total: total)
        for e in all {
            if Task.isCancelled { bulk = .idle; bulkTask = nil; return }
            // RE-CHECKED EVERY PACK, not just at the start. A full-country download is ~2 GB over
            // tens of minutes; an iPad that began on home Wi-Fi and is now in a car on a hotspot has
            // changed the answer, and a promise about data cost that is only evaluated once is not a
            // promise. The probe is a few milliseconds against a pack that takes seconds.
            if !allowMetered {
                let verdict = await DownloadPolicy.shared.verdict(.userInitiated, requires: e.capability)
                if !verdict.isAllowed {
                    bulk = .failed(verdict.explanation ?? "Paused.")
                    bulkTask = nil
                    return
                }
            }
            var ok = isCached(e)
            if !ok, await ensureOnDisk(e) != nil { ok = true; added += 1 }
            if ok { markDownloaded(e.id) }                  // persist each so a mid-download kill keeps its pins
            done += 1
            bulk = .running(done: done, total: total)
            refreshCachedBytes()
        }
        bulk = .finished(added: added)
        bulkTask = nil
    }

    // MARK: Per-region (single-pack) offline download — the Downloads page

    /// Whether a pack was deliberately downloaded for offline use (pinned, LRU-exempt) vs incidental cache.
    func isPinned(_ e: ChartCatalog.Entry) -> Bool { pinned.contains(e.id) }

    /// Download one pack for offline use and pin it (exempt from the LRU cap). Idempotent; safe to call
    /// on an already-cached pack (just pins it). Returns whether the pack is on disk afterwards.
    @discardableResult
    func download(_ e: ChartCatalog.Entry, allowMetered: Bool = false) async -> Bool {
        guard !downloadingIDs.contains(e.id) else { return isCached(e) }
        // A backstop, not the primary gate: the Downloads row asks the policy first so it can offer
        // the pilot an explicit override. Enforced here too because "Wi-Fi only" has to be true of
        // every caller, including ones added later.
        if !allowMetered, !isCached(e),
           !(await DownloadPolicy.shared.verdict(.userInitiated, requires: e.capability)).isAllowed { return false }
        downloadingIDs.insert(e.id)
        defer { downloadingIDs.remove(e.id) }
        var ok = isCached(e)
        if !ok { ok = await ensureOnDisk(e) != nil }
        if ok { markDownloaded(e.id); refreshCachedBytes() }
        return ok
    }

    /// Remove one downloaded pack and unpin it.
    func remove(_ e: ChartCatalog.Entry) {
        try? FileManager.default.removeItem(at: localURL(e))
        // Also the staged copy, if the pre-cache already fetched next cycle's pack: "remove this
        // download" has to mean it, or the pack reappears by itself at the roll.
        if let staged = catalog?.next?.cycle {
            try? FileManager.default.removeItem(at: localURL(e.id, cycle: staged))
        }
        dropIntent(e.id); refreshCachedBytes()
    }

    /// Delete every cached pack (incidental + pinned offline downloads) and clear the pins — the
    /// "remove downloaded charts" action.
    func removeAllCachedCharts() {
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "mbtiles" { try? FileManager.default.removeItem(at: f) }
        }
        pinned.removeAll()
        UserDefaults.standard.set([String](), forKey: pinnedKey)
        UserDefaults.standard.set(cycle, forKey: pinnedCycleKey)
        refreshCachedBytes()
        if case .finished = bulk { bulk = .idle }
    }

    /// True when the current network path is cellular / a personal hotspot (so the UI can confirm before a
    /// ~2 GB bulk download). One-shot: reads the first path update, then tears the monitor down.
    func isExpensiveConnection() async -> Bool {
        let path = await DownloadPolicy.currentPath()
        return path.expensive || !path.wifi
    }

    // MARK: Next-cycle pre-cache

    /// Download the NEXT cycle's packs before it takes effect, so the roll costs the pilot nothing.
    ///
    /// THE PROBLEM. FAA chart cycles roll every 56 days at 0901Z. The moment the publisher's new
    /// index.json goes live, `localURL` starts asking for `<id>-<newCycle>.mbtiles` — a file that does
    /// not exist — and the pilot's entire offline kit has to come down again, several gigabytes of it.
    /// `readableURL` keeps the map alive by serving last cycle's pack in the meantime, loudly labeled
    /// expired, which is the right failure but it is still a failure: the pilot discovers it when they
    /// open the app, which for a rollover that happens overnight means at the airport, on whatever
    /// connection the FBO has, possibly none.
    ///
    /// THE FIX, AND WHY IT IS ALMOST FREE. The publisher stages the new cycle under its own prefix
    /// weeks early (`publish_packs.py --stage-next`) and advertises it in the live manifest's `next`
    /// block. This downloads the staged packs — only the ones the pilot already chose — under the
    /// filename the catalog WILL ask for. Activation is then not an event: no copy, no move, no
    /// re-download, nothing scheduled for 0901Z. `localURL` simply begins resolving to a file that has
    /// been sitting there for a fortnight. Pre-caching 40 packs and pre-caching none differ only in
    /// what the map looks like the morning after.
    ///
    /// Runs under the pilot's two settings (`DownloadPolicy`), re-checked per pack, and never touches
    /// a pack they did not already download — pre-caching is for keeping a kit current, never for
    /// building one.
    @discardableResult
    func precacheNextCycle(now: Date = Date()) async -> Precache {
        guard precacheTask == nil else { return precache }
        guard DownloadPolicy.shared.precacheNextCycle else { precache = .off; return precache }
        guard await warm(), let staged = catalog?.next else { precache = .idle; return precache }
        // An undateable staged block is unusable (we could not refuse to activate it early); one
        // already in force, or one that IS the live cycle, is the ordinary path's business, not ours.
        guard staged.effectiveDate != nil, !staged.isInForce(asOf: now), staged.cycle != cycle else {
            precache = .idle; return precache
        }
        let wanted = installedPackIDs()
        let mine = staged.entries.filter { wanted.contains($0.id) }
        guard !mine.isEmpty else { precache = .idle; return precache }

        let todo = mine.filter {
            !FileManager.default.fileExists(atPath: localURL($0.id, cycle: staged.cycle).path)
        }
        guard !todo.isEmpty else {
            precache = .ready(cycle: staged.cycle, packs: mine.count); return precache
        }

        let need = todo.reduce(0) { $0 + $1.bytes }
        guard hasHeadroom(for: need) else {
            precache = .waiting("Not enough free space to pre-cache \(staged.cycle) "
                                + "(needs \(ByteCountFormatter.string(fromByteCount: Int64(need), countStyle: .file))).")
            return precache
        }
        let verdict = await DownloadPolicy.shared.verdict(.background)
        guard verdict.isAllowed else {
            precache = .waiting(verdict.explanation ?? "Waiting.")
            return precache
        }
        let have = mine.count - todo.count
        precacheTask = Task { [weak self] in await self?.runPrecache(staged, todo: todo, have: have) }
        return precache
    }

    func cancelPrecache() {
        precacheTask?.cancel()
        precacheTask = nil
        precache = .idle
    }

    private func runPrecache(_ staged: ChartCatalog.Staged, todo: [ChartCatalog.Entry], have: Int) async {
        defer { precacheTask = nil }
        var done = 0
        precache = .running(done: 0, total: todo.count)
        for e in todo.prefix(4096) {                                       // bounded (rule 2)
            if Task.isCancelled { precache = .idle; return }
            let verdict = await DownloadPolicy.shared.verdict(.background)
            guard verdict.isAllowed else {                                 // left Wi-Fi mid-run
                precache = .waiting(verdict.explanation ?? "Waiting.")
                return
            }
            // `expectStamp` holds the publisher to its claim — a staged pack carrying the OLD cycle's
            // faa_cycle stamp is the exact artifact `publish_packs.read_pack` refuses to upload, and
            // the one failure that would otherwise surface as a pilot briefing off last cycle's chart
            // with the app calling it current.
            if await ensureOnDisk(e, cycle: staged.cycle, expectStamp: staged.cycle,
                                   priority: .background) != nil { done += 1 }
            precache = .running(done: done, total: todo.count)
        }
        let onDisk = have + done, want = have + todo.count
        precache = onDisk == want
            ? .ready(cycle: staged.cycle, packs: want)
            : .partial(cycle: staged.cycle, have: onDisk, want: want)
        refreshCachedBytes()
    }

    /// The staged cycle the publisher is advertising, if any.
    var stagedCycle: String? { catalog?.next?.cycle }

    /// Delete the staged cycle's packs — the pilot turning pre-caching off and reclaiming the space.
    func removeStagedPacks() {
        guard let staged = catalog?.next?.cycle,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "mbtiles" && Self.packCycle(f.lastPathComponent) == staged {
            try? FileManager.default.removeItem(at: f)
        }
        precache = .idle
        refreshCachedBytes()
    }

    /// Is there room for `bytes` with a reserve left over?
    ///
    /// Pre-caching is a convenience that runs unprompted, so it must never be the reason a device
    /// fills up — a full disk on an EFB takes the logbook, the plates and the track log with it. The
    /// 2 GB reserve is deliberately larger than any single pack. Proceeds when the volume cannot be
    /// queried: that is a missing answer, not a negative one, and `ensureOnDisk` cleans up after a
    /// download that cannot complete.
    private func hasHeadroom(for bytes: Int) -> Bool {
        guard let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return true }
        return Int64(bytes) + Self.precacheReserveBytes < free
    }

    static let precacheReserveBytes: Int64 = 2 * 1024 * 1024 * 1024

    // MARK: Pinned-pack persistence

    /// Is this file one of the pilot's explicit downloads, and therefore exempt from the disk budget?
    ///
    /// ⚠️ CYCLE-AGNOSTIC, AND IT HAS TO BE. This matched only `-<currentCycle>.mbtiles`, which was
    /// right when the reader opened nothing else. It is not any more: `readableURL` deliberately
    /// serves an OLDER-cycle pack when this cycle's is absent, and `pruneOldCycleFiles` deliberately
    /// keeps those files for it. `enforceDiskBudget` asked this function whether they were pinned,
    /// was told no, and was free to delete the very packs the map had fallen back to — turning the
    /// cycle-roll fix into a slower version of the bug it fixed.
    ///
    /// `loadPinned` drops the in-memory pin set on a cycle change, so the persisted ids are consulted
    /// too; those are what survive a rollover and what `pruneOldCycleFiles` already keys off.
    private func isPinnedFile(_ url: URL) -> Bool {
        guard let id = Self.packID(url.lastPathComponent) else { return false }
        if pinned.contains(id) { return true }
        return (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).contains(id)
    }

    /// TWO SETS, ONE STORE, AND THE DIFFERENCE MATTERS.
    ///
    /// `pinned` (in memory) answers "is this pack downloaded at the CURRENT cycle" and drives the UI.
    /// The persisted ids answer "which packs does this pilot want offline" — an INTENT that outlives
    /// any one cycle, and the only record `pruneOldCycleFiles` has of which old-cycle files to keep as
    /// fallbacks and `updateInstalledPacks` has of what to re-download.
    ///
    /// They used to be the same set written through one `savePinned()`, which was survivable only
    /// because the in-memory set was simply EMPTIED on a cycle roll. Pre-caching breaks that: after a
    /// roll some packs genuinely are present at the new cycle, so the in-memory set has to be
    /// repopulated — and the moment it is, a shared writer would shrink the persisted intent to
    /// whatever happened to be on disk. One pack downloaded after a partial pre-cache would drop the
    /// other thirty-odd ids from the intent record, and the next `adopt` would delete their old-cycle
    /// files: the pilot loses the stale-but-readable fallback for every pack the pre-cache missed.
    /// So intent is only ever added to, and only removed when the pilot deletes a pack.
    private func loadPinned() {
        let intent = installedPackIDs()
        if UserDefaults.standard.string(forKey: pinnedCycleKey) == cycle {
            pinned = intent
        } else {
            // A cycle roll. Anything the pre-cache already landed under the NEW cycle's name is
            // present and stays "downloaded" — that is the whole point of pre-caching, and reporting
            // it as absent would offer the pilot a re-download of bytes they already have.
            pinned = intent.filter { FileManager.default.fileExists(atPath: localURL($0, cycle: cycle).path) }
            UserDefaults.standard.set(cycle, forKey: pinnedCycleKey)
        }
    }

    /// Record that `id` is on disk at the current cycle, and that the pilot wants it offline.
    private func markDownloaded(_ id: String) {
        pinned.insert(id)
        addIntent([id])
    }

    /// Union into the persisted intent. Never a replace — see `loadPinned`.
    private func addIntent(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let merged = installedPackIDs().union(ids)
        UserDefaults.standard.set(Array(merged), forKey: pinnedKey)
        UserDefaults.standard.set(cycle, forKey: pinnedCycleKey)
    }

    /// The pilot deleted a pack: drop it from both sets, so prune may reclaim its old-cycle copies.
    private func dropIntent(_ id: String) {
        pinned.remove(id)
        UserDefaults.standard.set(Array(installedPackIDs().subtracting([id])), forKey: pinnedKey)
        UserDefaults.standard.set(cycle, forKey: pinnedCycleKey)
    }
}

// MARK: - Route / location geometry helpers (shared by the map sheet and prefetch)

/// Map-rect helpers used both by the chart map (framing / free-pan) and by background prefetch,
/// so route-corridor and around-me selection use identical geometry.
enum ChartGeo {
    /// Per-leg rects (a pack is selected if it intersects any) — tighter than the whole-route
    /// bounding box on a diagonal route, and non-degenerate for a single-fix route. Mirrors the
    /// selection the chart map uses so prefetch and on-open loading agree on which packs a route needs.
    static func routeRects(_ points: [ResolvedLeg]) -> [MKMapRect] {
        let pts = points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.coord.lat, longitude: $0.coord.lon)) }
        guard let f = pts.first else { return [] }
        let eps: Double = 5_000        // map points — gives a single point some area so intersects() works
        if pts.count == 1 { return [MKMapRect(x: f.x - eps, y: f.y - eps, width: 2 * eps, height: 2 * eps)] }
        return (1..<pts.count).map { i in
            let a = pts[i - 1], b = pts[i]
            return MKMapRect(x: min(a.x, b.x) - eps, y: min(a.y, b.y) - eps,
                             width: abs(a.x - b.x) + 2 * eps, height: abs(a.y - b.y) + 2 * eps)
        }
    }

    /// A square rect of `radiusNM` nautical miles around a coordinate (device / Stratux position).
    static func rect(around c: Coord, radiusNM: Double) -> MKMapRect {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon))
        let d = radiusNM * 1852.0 * MKMapPointsPerMeterAtLatitude(c.lat)     // NM → metres → map points
        return MKMapRect(x: center.x - d, y: center.y - d, width: 2 * d, height: 2 * d)
    }
}

// MARK: - One-shot device location

/// A single device-GPS fix for background prefetch. Not main-actor isolated: `CLLocationManager`
/// delivers its callbacks on the thread that created it (the main thread here), and the project's
/// Swift 5 language mode doesn't enforce actor isolation on the delegate protocol. Requests are
/// coalesced — only one fix is in flight at a time.
///
/// It deliberately **does not raise a permission prompt**: a background launch/foreground prefetch
/// should be silent. It only reads location that's already authorized; the map view
/// (`ChartMapView.Coordinator.requestLocation`) is what asks for permission when the map is opened, so
/// once the pilot has used the map, later launches can prefetch around their position.
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<Coord?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    /// One-shot fix, or nil if location isn't already authorized / no fix arrives. Extra callers while a
    /// request is in flight get nil rather than hijacking the pending continuation.
    func fix() async -> Coord? {
        if cont != nil { return nil }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil                                                 // not yet granted — stay silent
        }
        return await withCheckedContinuation { c in
            cont = c
            manager.requestLocation()
        }
    }

    private func finish(_ coord: Coord?) {
        guard let c = cont else { return }
        cont = nil
        c.resume(returning: coord)
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { finish(nil); return }
        finish(Coord(lat: l.coordinate.latitude, lon: l.coordinate.longitude))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
