import XCTest
@testable import ATCTranscribe

final class TempNavProbeTests: XCTestCase {
    func testNearbyLA() {
        let bb = BBox(minLat: 33.7, minLon: -118.6, maxLat: 34.2, maxLon: -117.9)
        let pts = NavDatabase.nearby(bb, types: [0, 1], limit: 160)
        print("PROBE nearby=\(pts.count)")
        print("PROBE idents=\(pts.prefix(14).map { $0.ident })")
        print("PROBE symbolsAvailable=\(AirportSymbolData.isAvailable) count=\(AirportSymbolData.count)")
        for id in ["KLAX", "KSMO", "KHHR", "KTOA", "KCPM"] {
            let sig0 = AirportSymbolData.spec(id, category: nil).signature
            print("PROBE roundtrip \(id) ok=\(AirportSymbol.Spec(signature: sig0) != nil)")
            let s = AirportSymbolData.spec(id, category: nil)
            print("PROBE \(id) sig=\(s.signature) towered=\(s.towered) shape=\(s.shape) axes=\(s.runwayAxesDeg)")
        }
    }
}
