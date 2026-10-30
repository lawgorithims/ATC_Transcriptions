import Foundation
#if canImport(CloudKit)
import CloudKit

/// `CloudSyncTransport` over the pilot's own private CloudKit database.
///
/// Compiled in every build — `canImport(CloudKit)`, not `Features.cloudSync` — so the compiler checks
/// it whether or not sync is switched on. Only `CKContainer` instantiation sits behind the feature
/// gate, because asking for a container the binary is not entitled to reach fails at runtime.
///
/// # Why tombstones are soft deletes here
///
/// The obvious mapping is "a deleted record is a CloudKit delete". It does not work: CloudKit reports
/// a deletion as a bare record id with **no timestamp**, and the merge resolves deletions by comparing
/// clocks — a tombstone with no clock cannot beat an edit, or lose to one. So a deletion is stored as
/// a real record carrying `deleted = 1`, no payload, and the time it happened. It costs a few dozen
/// bytes in the pilot's own iCloud and it is the only shape the merge can reason about.
///
/// A *hard* deletion arriving from the server is therefore something else — a zone reset, or the pilot
/// turning iCloud Drive off and on. Those are deliberately ignored rather than applied: a deletion
/// this app cannot date is a deletion it cannot order against local edits, and the safe direction for
/// a logbook is to keep the data and let the next real tombstone decide.
actor CloudKitTransport: CloudSyncTransport {

    /// One custom zone, because the default zone does not support `fetchRecordZoneChanges` and so has
    /// no change tokens — without them every sync is a full download of every flight.
    static let zoneName = "CommSight"

    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private var database: CKDatabase { container.privateCloudDatabase }

    /// Set once the zone is known to exist, so the check costs one round trip per launch rather than
    /// one per sync.
    private var zoneReady = false

    init(containerID: String = Features.cloudSyncContainerID) {
        container = CKContainer(identifier: containerID)
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: Fetch

    func fetchChanges(since token: Data?) async throws -> CloudSyncChanges {
        try await ensureZone()
        do {
            return try await fetch(token: Self.decodeToken(token))
        } catch let error as CKError where error.code == .changeTokenExpired {
            // The server has forgotten our cursor, so start over. Safe precisely because of
            // `SyncMerge` rule 1: a full re-fetch is a superset of a delta, and nothing local is
            // deleted for being absent from it.
            return try await fetch(token: nil)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The pilot wiped iCloud data for the app. Treat it as an empty cloud: everything local is
            // then "ours to upload" and the library is rebuilt rather than deleted.
            zoneReady = false
            try await ensureZone()
            return CloudSyncChanges(records: [], token: nil)
        }
    }

    private func fetch(token: CKServerChangeToken?) async throws -> CloudSyncChanges {
        var records: [SyncRecord] = []
        var newToken: CKServerChangeToken?
        var more = true
        var cursor = token

        while more {
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = cursor
            let (changes, moreComing, tokenAfter) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<([SyncRecord], Bool, CKServerChangeToken?), Error>) in
                let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                           configurationsByRecordZoneID: [zoneID: config])
                var batch: [SyncRecord] = []
                var batchToken: CKServerChangeToken?
                var batchMore = false

                op.recordWasChangedBlock = { _, result in
                    if case let .success(record) = result, let mapped = Self.syncRecord(from: record) {
                        batch.append(mapped)
                    }
                }
                // Deliberately NOT wired: see the note on soft deletes above. A dateless deletion
                // cannot be ordered against a local edit, so it is not applied.
                op.recordWithIDWasDeletedBlock = { _, _ in }

                op.recordZoneChangeTokensUpdatedBlock = { _, t, _ in batchToken = t }
                op.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case let .success((t, _, moreComing)):
                        batchToken = t
                        batchMore = moreComing
                    case let .failure(error):
                        cont.resume(throwing: error)
                        return
                    }
                }
                op.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:  cont.resume(returning: (batch, batchMore, batchToken))
                    case let .failure(error): cont.resume(throwing: error)
                    }
                }
                database.add(op)
            }
            records += changes
            newToken = tokenAfter ?? newToken
            cursor = tokenAfter
            more = moreComing && tokenAfter != nil
        }
        return CloudSyncChanges(records: records, token: Self.encodeToken(newToken))
    }

    // MARK: Push

    func push(_ records: [SyncRecord]) async throws {
        guard !records.isEmpty else { return }
        try await ensureZone()

        // 400 is CloudKit's documented per-operation ceiling; batch well under it so one oversized
        // flight cannot push a batch over the 2 MB request limit on its own.
        for chunk in stride(from: 0, to: records.count, by: 100).map({
            Array(records[$0..<min($0 + 100, records.count)])
        }) {
            let assets = AssetScratch()
            defer { assets.cleanUp() }
            let ckRecords = chunk.map { ckRecord(from: $0, assets: assets) }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let op = CKModifyRecordsOperation(recordsToSave: ckRecords, recordIDsToDelete: nil)
                // This device's merge already decided these records win, so overwrite the server copy
                // rather than failing on a changed-tag conflict and stalling the queue.
                op.savePolicy = .allKeys
                op.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: cont.resume()
                    case let .failure(error): cont.resume(throwing: error)
                    }
                }
                database.add(op)
            }
        }
    }

    // MARK: Zone

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            op.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case let .failure(error):
                    // Already there is the normal case after the first launch.
                    if let ck = error as? CKError, ck.code == .serverRecordChanged { cont.resume() }
                    else { cont.resume(throwing: error) }
                }
            }
            database.add(op)
        }
        zoneReady = true
    }

    // MARK: Record mapping

    private enum Field {
        static let kind = "kind"
        static let modifiedAt = "modifiedAt"
        static let deleted = "deleted"
        static let payload = "payload"
        static let asset = "payloadAsset"
    }

    /// Inline up to this size; above it the payload travels as a `CKAsset`. A `CKRecord` must stay
    /// under 1 MB in total, and a note carries its ink, so the ceiling is real rather than theoretical.
    private static let inlineLimit = 512 * 1024

    private func ckRecord(from record: SyncRecord, assets: AssetScratch) -> CKRecord {
        let id = CKRecord.ID(recordName: record.key, zoneID: zoneID)
        let ck = CKRecord(recordType: record.kind.rawValue, recordID: id)
        ck[Field.kind] = record.kind.rawValue as CKRecordValue
        ck[Field.modifiedAt] = record.modifiedAt as CKRecordValue
        ck[Field.deleted] = (record.deleted ? 1 : 0) as CKRecordValue
        if let payload = record.payload {
            if payload.count > Self.inlineLimit, let url = assets.write(payload) {
                ck[Field.asset] = CKAsset(fileURL: url)
            } else {
                ck[Field.payload] = payload as CKRecordValue
            }
        }
        return ck
    }

    private static func syncRecord(from ck: CKRecord) -> SyncRecord? {
        guard let kind = SyncRecord.Kind(rawValue: ck.recordType),
              let modifiedAt = ck[Field.modifiedAt] as? Date else { return nil }
        let deleted = (ck[Field.deleted] as? Int ?? 0) == 1
        // `recordName` is the composite `kind/id`; the local side keys on the bare id.
        let name = ck.recordID.recordName
        let id = name.hasPrefix("\(kind.rawValue)/")
            ? String(name.dropFirst(kind.rawValue.count + 1))
            : name
        guard !id.isEmpty else { return nil }

        if deleted { return .tombstone(id: id, kind: kind, at: modifiedAt) }

        let payload: Data? = (ck[Field.payload] as? Data)
            ?? (ck[Field.asset] as? CKAsset).flatMap { $0.fileURL.flatMap { try? Data(contentsOf: $0) } }
        // A live record whose payload did not arrive is dropped rather than turned into a tombstone —
        // the alternative deletes a pilot's flight because an asset download failed.
        guard let payload else { return nil }
        return SyncRecord(id: id, kind: kind, modifiedAt: modifiedAt, payload: payload)
    }

    private static func encodeToken(_ token: CKServerChangeToken?) -> Data? {
        guard let token else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeToken(_ data: Data?) -> CKServerChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

/// Temp files for `CKAsset` payloads, deleted once the operation is done. `CKAsset` requires a file
/// URL that outlives the request, so the data cannot simply be handed over inline.
private final class AssetScratch {
    private var urls: [URL] = []

    func write(_ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString).bin")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        urls.append(url)
        return url
    }

    func cleanUp() {
        for u in urls { try? FileManager.default.removeItem(at: u) }
        urls = []
    }
}
#endif
