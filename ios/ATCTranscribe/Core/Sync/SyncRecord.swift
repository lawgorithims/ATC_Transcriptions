import Foundation

/// One syncable item, in the shape the local ledger and the cloud transport both speak.
///
/// # Why a payload blob and not a typed model
///
/// The two things being synced have nothing in common: a `LoggedFlight` is a value with a 2,000-point
/// breadcrumb trail, and a `Note` is an index row plus an opaque PencilKit drawing. Making the merge
/// generic over both would mean a protocol with a timestamp requirement, which neither type has (see
/// `SyncLedger` for why the clock lives outside the model). So the merge is deliberately blind to
/// content: it decides *which side wins* from the clock alone, and the stores decode the payload only
/// once a winner is known. That also means the merge is exhaustively testable with `Data("a")`.
struct SyncRecord: Equatable, Sendable {

    /// What a record is. The raw values are persisted in the ledger and used as the CloudKit record
    /// type, so they are API: renaming one orphans every record already in a pilot's iCloud.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case flight
        case note
    }

    let id: String
    let kind: Kind

    /// The single clock last-writer-wins compares. **For a tombstone this is the time of deletion**,
    /// not the time the record was last edited — a delete is a write, and giving it its own separate
    /// timestamp field was the first design here and produced the obvious bug: a tombstone whose
    /// `modifiedAt` was the old edit time always lost to the device that still held the record, so
    /// nothing could ever be deleted twice over.
    let modifiedAt: Date

    /// A deleted record keeps its id and clock and loses its payload. See `SyncLedger` on retention:
    /// a tombstone that is pruned too early resurrects the record from any device that was offline
    /// longer than the window.
    let deleted: Bool

    /// `nil` if and only if `deleted`.
    let payload: Data?

    init(id: String, kind: Kind, modifiedAt: Date, deleted: Bool = false, payload: Data?) {
        assert(!id.isEmpty, "SyncRecord: empty id")
        assert(deleted == (payload == nil),
               "SyncRecord: `deleted` and a nil payload are the same fact and must agree — "
               + "a tombstone carrying a payload would be pushed as live data by one device and as a "
               + "deletion by another")
        self.id = id
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.deleted = deleted
        self.payload = payload
    }

    /// A tombstone for an id that is going away.
    static func tombstone(id: String, kind: Kind, at: Date) -> SyncRecord {
        SyncRecord(id: id, kind: kind, modifiedAt: at, deleted: true, payload: nil)
    }

    /// The composite key. Ids are only unique within a kind (`Note.id` and `LoggedFlight.id` are both
    /// UUID strings and could collide), so nothing keyed on the bare id is safe.
    var key: String { "\(kind.rawValue)/\(id)" }
}
