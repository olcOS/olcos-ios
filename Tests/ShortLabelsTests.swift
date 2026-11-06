import XCTest
@testable import olcrtc_ios

// The whole-server row and the per-room speed check name things in a few
// words, in every language, so no title or state ends in an ellipsis on the
// narrowest phone: a name, a count and a mode, each short and complete.
final class ShortLabelsTests: XCTestCase {

    private let names: [L10n] = [
        .bundleServiceName, .bundleBonded, .bundleBondPending, .bundleBondOff,
        .protoCheckAllTogether, .laneRemoveAction, .protocolChangeRoom,
    ]

    func testTheLabelsAreShortInEveryLanguage() {
        for locale in AppLocale.allCases {
            for name in names {
                let text = name.localized(locale)
                XCTAssertFalse(text.isEmpty, "\(name) is empty in \(locale)")
                XCTAssertLessThanOrEqual(text.count, 22, "\(name) is too long in \(locale): \(text)")
                XCTAssertFalse(text.contains("…"), "\(name) ends in an ellipsis in \(locale): \(text)")
            }
        }
    }

    func testTheRoomCountsAreShortAndKeepTheirNumber() {
        for locale in AppLocale.allCases {
            for count in [L10n.listBundleRooms_fmt, L10n.lanesRoomCount_fmt] {
                let text = count.localized(locale)
                XCTAssertEqual(text.components(separatedBy: "%d").count, 2, "\(count) in \(locale): \(text)")
                XCTAssertLessThanOrEqual(text.count, 14, "\(count) is too long in \(locale): \(text)")
            }
        }
    }

    func testTheWholeServerSubtitleStillNamesTheServer() {
        for locale in AppLocale.allCases {
            let text = L10n.listBundleSubtitle_fmt.localized(locale)
            XCTAssertEqual(text.components(separatedBy: "%@").count, 2, "\(locale): \(text)")
        }
    }
}
