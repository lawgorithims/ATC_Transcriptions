import Foundation

/// The one encoder sync payloads are built with.
///
/// # Why this exists: `JSONEncoder` key order is not stable
///
/// `JSONEncoder` does not guarantee the order it writes keys in, and in practice it varies **between
/// two encodes of the same value in the same process**. Two devices holding an identical flight
/// therefore produce payloads with identical content and different bytes.
///
/// That breaks the merge in a way that is invisible until you look at the network: `SyncMerge` sees
/// `mine != theirs`, both clocks equal, both live — so it falls through to rule 4, picks a side by
/// byte order, and marks it for upload. Every pass. Forever. Every device re-uploads its whole
/// logbook on every sync, burning the pilot's iCloud quota and battery while the stored bytes
/// flip-flop between two encodings of the same flight.
///
/// `.sortedKeys` makes the payload a deterministic function of the value, which is what the merge
/// assumes it is. `SyncCodingTests` pins it.
///
/// ⚠️ Anything that builds a `SyncRecord.payload` must encode through here. A plain `JSONEncoder()`
/// compiles, passes a round-trip test, and reintroduces the loop.
enum SyncCoding {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        // Dates stay at the default `.deferredToDate` (a Double). It is stable, compact, and already
        // what `flights.json` and the note index on disk use — changing it here would make a payload
        // that no existing build can decode.
        return e
    }()

    static let decoder = JSONDecoder()
}
