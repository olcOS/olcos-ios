import XCTest
@testable import olcrtc_ios

// The connect-time bulk leg: only a direct (Xray) connection runs it, its
// sources are 64 KB served uncompressed (a Range cut where needed), and the
// requests never come from a cache.

final class BulkVerifyTests: XCTestCase {

    func testOnlyADirectConnectionRunsTheBulkLeg() {
        let xray = ConnectionDetails.xray(XrayConnection(host: "203.0.113.7", uuid: "u",
                                                          sni: "www.example.com", publicKey: "k",
                                                          shortID: ""))
        let olcrtc = ConnectionDetails.olcrtc(OlcrtcConnection(
            carrier: "telemost", transport: "vp8channel",
            roomID: "room", key: String(repeating: "a", count: 64), clientID: "default"))
        XCTAssertTrue(TunnelManager.needsBulkVerify(xray))
        XCTAssertFalse(TunnelManager.needsBulkVerify(olcrtc))
    }

    func testSourcesAskForSixtyFourKilobytes() throws {
        XCTAssertGreaterThanOrEqual(AppConstants.tunnelBulkVerifySources.count, 2,
                                    "one source down must not fail every Xray connect")
        XCTAssertEqual(AppConstants.tunnelBulkVerifyBytes, 65_536)
        for source in AppConstants.tunnelBulkVerifySources {
            let url = try XCTUnwrap(URL(string: source.url))
            XCTAssertEqual(url.scheme, "https")
            let request = TunnelManager.bulkRequest(url, range: source.range)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), source.range)
            if let range = source.range {
                XCTAssertEqual(range, "bytes=0-65535")
            } else {
                XCTAssertTrue(source.url.contains("bytes=65536"))
            }
        }
    }
}
