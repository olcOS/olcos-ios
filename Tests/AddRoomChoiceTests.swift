import XCTest
@testable import olcrtc_ios

/// "Add a service or a room": which services the sheet lists, how many rooms
/// each has and what one more needs — which depends on the accounts the app
/// holds (Yandex, VK, MTS Link), not only on the service. WB Stream is not
/// offered any more, so it is not listed.
final class AddRoomChoiceTests: XCTestCase {
    func testEveryCallServiceIsListedThoseThatNeedNothingFirst() {
        let choices = AddRoomChoice.make(rooms: [:], yandexSignedIn: false, vkSignedIn: false)
        XCTAssertEqual(choices.map(\.carrier),
                       ["jitsi", "salutejazz", "telemost", "vkcalls", "mtslink"])
        // MTS Link needs nothing here: its room is made on the spot - the
        // replay, or the sign-in sheet where the owner signs in, creates the
        // meeting or pastes its link (MTSLinkRoomMaker).
        XCTAssertEqual(choices.map(\.need),
                       [.nothing, .nothing, .yandexSignIn, .callLink, .nothing])
        XCTAssertTrue(choices.allSatisfy { $0.rooms == 0 && !$0.isFull })
    }

    func testWBStreamIsNotOffered() {
        let choices = AddRoomChoice.make(rooms: ["wbstream": 1], yandexSignedIn: true, vkSignedIn: true)
        XCTAssertFalse(choices.contains { $0.carrier == "wbstream" })
    }

    func testTelemostNeedsNothingOnceSignedIn() {
        let telemost = AddRoomChoice.make(rooms: [:], yandexSignedIn: true, vkSignedIn: false)
            .first { $0.carrier == "telemost" }
        XCTAssertEqual(telemost?.need, .nothing)
    }

    func testVKNeedsNothingOnceSignedIn() {
        let signedIn = AddRoomChoice.make(rooms: [:], yandexSignedIn: false, vkSignedIn: true)
        XCTAssertEqual(signedIn.first { $0.carrier == "vkcalls" }?.need, .nothing)
        let signedOut = AddRoomChoice.make(rooms: [:], yandexSignedIn: false, vkSignedIn: false)
        XCTAssertEqual(signedOut.first { $0.carrier == "vkcalls" }?.need, .callLink)
    }

    /// MTS Link asks for nothing on this sheet: its room is made on the spot,
    /// by the replay or, with nothing learned yet, in the create-mode sheet.
    func testMTSLinkIsAlwaysOffered() {
        let need = AddRoomChoice.make(rooms: [:], yandexSignedIn: false, vkSignedIn: false)
            .first { $0.carrier == "mtslink" }?.need
        XCTAssertEqual(need, AddRoomChoice.Need.nothing)
    }

    /// MTS Link keeps ONE room per server (no lanes): its row is full after
    /// the first and says so, while the lane carriers take `maxRooms` each.
    func testMTSLinkTakesOneRoomAndFillsUp() {
        let mts = AddRoomChoice.make(rooms: ["mtslink": 1], yandexSignedIn: false, vkSignedIn: false)
            .first { $0.carrier == "mtslink" }
        XCTAssertEqual(mts?.roomCap, 1)
        XCTAssertEqual(mts?.isFull, true)
        let jitsi = AddRoomChoice.make(rooms: ["jitsi": 1], yandexSignedIn: false, vkSignedIn: false)
            .first { $0.carrier == "jitsi" }
        XCTAssertEqual(jitsi?.roomCap, CarrierTransportMatrix.maxRooms)
        XCTAssertEqual(jitsi?.isFull, false)
    }

    func testRoomCountsAndTheCap() {
        let choices = AddRoomChoice.make(rooms: ["jitsi": CarrierTransportMatrix.maxRooms, "salutejazz": 1],
                                         yandexSignedIn: false, vkSignedIn: false)
        let jitsi = choices.first { $0.carrier == "jitsi" }
        let salute = choices.first { $0.carrier == "salutejazz" }
        XCTAssertEqual(jitsi?.isFull, true)
        XCTAssertEqual(salute?.rooms, 1)
        XCTAssertEqual(salute?.isFull, false)
    }
}
