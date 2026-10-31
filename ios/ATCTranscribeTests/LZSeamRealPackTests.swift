import XCTest
import MapKit
@testable import ATCTranscribe

/// The cell-seam obstacle drop, against the REAL packs on either side of the n33w107 / n33w108 seam.
///
/// The synthetic tests in `LZTileMergeTests` pin the rule. This pins the measurement that found it:
/// at (−107.00452, 32.69898), inside n33w108, the owning pack carries a charted obstacle and
/// n33w107's margin — which never saw that obstacle — does not. Mounted together, the map served
/// the margin. Skips cleanly on a machine without the built packs.
final class LZSeamRealPackTests: XCTestCase {

    private static let out = "/Users/bsusl/CommSight/ATC_Transcriptions/lz/out"
    private let seam = (lon: -107.00452, lat: 32.69898)

    private func store(_ ids: [String]) throws -> LZPackStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lzseam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for id in ids {
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("\(id).lzpack"),
                withDestinationURL: URL(fileURLWithPath: "\(Self.out)/\(id).lzpack"))
        }
        let s = LZPackStore(directory: dir)
        XCTAssertEqual(s.mounted.count, ids.count, "a real pack failed to mount: \(s.rejected)")
        return s
    }

    private func hazard(_ s: LZPackStore) -> UInt8? { read(s, plane: LZPack.planeHazard) }

    private func read(_ s: LZPackStore, plane: Int) -> UInt8? {
        let p = MKMapPoint(CLLocationCoordinate2D(latitude: seam.lat, longitude: seam.lon))
        let side = MKMapSize.world.width / Double(1 << 13)
        let tx = Int(p.x / side), ty = Int(p.y / side)
        let rect = LZPackStore.tileRect(z: 13, x: tx, y: ty)
        let px = Int((p.x - rect.minX) / rect.width * Double(LZPack.side))
        let py = Int((p.y - rect.minY) / rect.height * Double(LZPack.side))
        return s.planes(z: 13, x: tx, y: ty)?.value(plane: plane, x: px, y: py)
    }

    func testTheSeamPixelShowsTheOwningPacksObstacle() throws {
        for id in ["n33w107", "n33w108"] {
            try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(Self.out)/\(id).lzpack"),
                              "no built pack \(id) — this machine has not run the pipeline")
        }
        // What the owner measured — read with nothing else mounted.
        let owner = try XCTUnwrap(hazard(try store(["n33w108"])), "the owner has no data at the seam")
        // Mounted alone, n33w107 must serve NOTHING west of its own edge — that ground is its
        // margin, measured without n33w108's obstacles.
        XCTAssertEqual(read(try store(["n33w107"]), plane: LZPack.planeClass), LZPack.classUnknown,
                       "a pack served its own margin as known ground")

        // Both mounted. `reload()` sorts by filename, so n33w107 mounts FIRST — exactly the order
        // that let its margin overwrite the owner. The owner's obstacle must win.
        XCTAssertEqual(hazard(try store(["n33w107", "n33w108"])), owner,
                       "the seam pixel was served from the neighbour's margin, not its owner")
        XCTAssertGreaterThan(owner, 128, "expected the charted obstacle the audit measured here")
    }
}
