#if canImport(MapLibre)
import Foundation
import MapLibre

/// MapLibre's AMBIENT CACHE — `.mapbox/cache.db` under Application Support, where MapLibre stores every
/// response it fetches over HTTP — switched OFF, from `App.init`, before any map exists.
///
/// Every tile this app draws is already on the device: the loopback `MBTilesHTTPServer` serves the
/// downloaded and bundled MBTiles packs. So the cache could only ever hold a second copy of local data,
/// and it could not even serve that copy back. It keys a tile by its URL, the URL carries the loopback
/// port, and the listener binds a NEW random port on every Map-tab mount, so no mount ever hit a row an
/// earlier one wrote. Measured on the iPad Pro 13-inch simulator (2026-10-24): each mount inserted ~935
/// tiles under its new port, and the 50 MB cap held the last three mounts and nothing older. Every request
/// is its own fsync'd transaction — a rollback journal plus table and index pages — so a replay against a
/// real cache dirtied 61-75 KB of file-backed memory per request for tiles averaging ~2.5 KB, and even a
/// cache HIT cost ~49 KB before any tile moved, because reading a tile rewrites its `accessed` stamp. One
/// relaunch dirtied ~88 MB, 99% of everything the app wrote. iOS files a "disk writes" report against an
/// app past about 1 GB in 24 hours, and an EFB's battery pays for every fsync.
///
/// OFF, not small: the cost is per request, so a 5 MB cap measured the same as the default 50 MB (60.9
/// against 64.5 KB per request); a cap only bounds the file. Zero is MapLibre's own off switch. With no
/// offline packs in the database — this app has never created one — `OfflineDatabase::disabled()` turns
/// every get and put into a no-op before any SQL runs.
enum MapLibreAmbientCache {
    /// The cap MapLibre reads as "disabled".
    static let disabledSize: UInt = 0

    /// Empty the cache an earlier build filled, then cap it at zero. Exactly once, on the main thread,
    /// from `App.init`.
    ///
    /// CLEAR FIRST. A zero cap applied to a FULL cache makes MapLibre trim it, and upstream's eviction
    /// accounting gives up early: a replay of that trim deleted ~8% of the rows and wrote 16-25 MB per pass,
    /// so it would rerun on every launch. Clearing a full cache dirtied ~46 MB once, on the first launch of
    /// this build, and nothing at all on an empty cache, so it is unconditional. Both calls queue, in order,
    /// on MapLibre's database thread, ahead of any tile request.
    ///
    /// NOWHERE LATER. The cap's completion handler is delivered with `dispatch_sync` to the MAIN queue from
    /// that database thread, while `MLNOfflineStorage` pauses the same thread FROM main on
    /// `didEnterBackground` — and a pause blocks its caller until the thread acknowledges it. Background the
    /// app while the setter is in flight and the two threads wait on each other forever. From here the
    /// setter has finished before the first frame is up, and the app declares no background modes, so iOS
    /// never launches it straight into the background.
    static func disable(_ storage: MLNOfflineStorage = .shared) {
        assert(Thread.isMainThread, "MapLibreAmbientCache.disable must run on the main thread")
        assert(!didDisable, "MapLibreAmbientCache.disable must run once, from App.init (see the deadlock note)")
        guard Thread.isMainThread, !didDisable else { return }
        didDisable = true
        storage.clearAmbientCache { error in
            guard let error else { return }
            NSLog("CommSight ambient cache: clearing failed: %@", error.localizedDescription)
        }
        storage.setMaximumAmbientCacheSize(disabledSize) { error in
            guard let error else { return }
            NSLog("CommSight ambient cache: disabling failed, MapLibre will keep caching: %@",
                  error.localizedDescription)
        }
    }

    /// Set by `disable`. Main-thread only, like the call that sets it.
    private(set) static var didDisable = false
}
#endif
