import XCTest
@testable import olcrtc_ios

// The secrets around device invites: an access invite's pairing code lives in
// the Keychain, not in the saved host list (ServerHostStore, InviteKeyStore),
// and a pairing code that got its final answer is not offered again on every
// refresh of the list (InvitedServerPairing). The agent calls themselves are
// integration-only.

@MainActor
final class InviteSecretsTests: XCTestCase {

    private let hostsKey = "olcrtc_server_hosts"
    private var suites: [String] = []
    private var tokens: [String] = []

    override func tearDown() {
        for token in tokens { InviteKeyStore.remove(token: token) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func freshDefaults() throws -> UserDefaults {
        let suite = "InviteSecretsTests.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func savedList(_ defaults: UserDefaults) -> String {
        String(decoding: defaults.data(forKey: hostsKey) ?? Data(), as: UTF8.self)
    }

    // MARK: The pairing code lives in the Keychain

    func testALegacyPairingCodeMovesToTheKeychain() throws {
        let defaults = try freshDefaults()
        let token = InviteLink.makeToken()
        tokens.append(token)
        // A list an older build saved, with the code in the preferences.
        var invite = DeviceInvite(name: "iPad", token: token)
        invite.agentCode = "c0de_legacy-Z"
        invite.agentRole = "member"
        var host = ServerHost(label: "ams", host: "203.0.113.7")
        host.invites = [invite]
        defaults.set(try JSONEncoder().encode([host]), forKey: hostsKey)

        let store = ServerHostStore(defaults: defaults)

        XCTAssertEqual(try InviteKeyStore.agentCode(token: token).get(), "c0de_legacy-Z")
        let saved = savedList(defaults)
        XCTAssertFalse(saved.contains("c0de_legacy-Z"), "the code must leave the preferences")
        XCTAssertTrue(saved.contains(token), "the invite itself stays in the list")
        let loaded = try XCTUnwrap(store.hosts.first?.invites?.first)
        XCTAssertEqual(try InviteSync.accessCode(of: loaded).get(), "c0de_legacy-Z")

        // The next launch reads it back from the Keychain.
        let again = ServerHostStore(defaults: defaults)
        let reread = try XCTUnwrap(again.hosts.first?.invites?.first)
        XCTAssertEqual(reread.agentCode, "c0de_legacy-Z")
        XCTAssertEqual(reread.agentRole, "member")
        XCTAssertFalse(savedList(defaults).contains("c0de_legacy-Z"))
    }

    func testAFreshPairingCodeNeverReachesThePreferences() throws {
        let defaults = try freshDefaults()
        let store = ServerHostStore(defaults: defaults)
        let host = ServerHost(label: "ams", host: "203.0.113.7")
        store.hosts.append(host)
        var invite = DeviceInvite(name: "Phone")
        tokens.append(invite.token)
        invite.agentCode = "c0de_fresh-Z"
        invite.agentRole = "owner"

        store.setInvites([invite], sharePort: 38471, forHost: host.id)

        XCTAssertEqual(try InviteKeyStore.agentCode(token: invite.token).get(), "c0de_fresh-Z")
        XCTAssertFalse(savedList(defaults).contains("c0de_fresh-Z"))
        // The invite in memory still carries it for the publisher.
        XCTAssertEqual(store.hosts.first?.invites?.first?.agentCode, "c0de_fresh-Z")

        // An invite that gives connections only has no code to look for.
        let plain = DeviceInvite(name: "TV")
        XCTAssertNil(try InviteSync.accessCode(of: plain).get())

        // Forgetting the invite forgets its code.
        InviteKeyStore.remove(token: invite.token)
        XCTAssertNil(try InviteKeyStore.agentCode(token: invite.token).get())
    }

    // MARK: A code that got its answer is not offered again

    private let source = "olcrtc-sub://203.0.113.7:38471/0123456789abcdef0123456789abcdef?enc=v1"

    private func offer(code: String) -> AgentOffer {
        AgentOffer(host: "203.0.113.7", port: 25113, certSHA256: String(repeating: "ab", count: 32),
                   prefix: "abcdefghijklmnopqrstuv", code: code, role: "member")
    }

    func testASettledCodeIsRememberedAsAHashPerList() throws {
        let defaults = try freshDefaults()
        XCTAssertFalse(InvitedServerPairing.isSettled(code: "c0de_spent-Z", source: source, defaults: defaults))
        InvitedServerPairing.noteSettled(code: "c0de_spent-Z", source: source, defaults: defaults)
        XCTAssertTrue(InvitedServerPairing.isSettled(code: "c0de_spent-Z", source: source, defaults: defaults))
        XCTAssertFalse(InvitedServerPairing.isSettled(code: "c0de_other-Z", source: source, defaults: defaults))
        XCTAssertFalse(InvitedServerPairing.isSettled(
            code: "c0de_spent-Z", source: "olcrtc-sub://203.0.113.8:1/" + String(repeating: "f", count: 32) + "?enc=v1",
            defaults: defaults))
        let stored = defaults.stringArray(forKey: InvitedServerPairing.settledKey) ?? []
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(stored.joined().contains("c0de_spent-Z"), "only hashes are kept")
        XCTAssertTrue(stored.allSatisfy { $0.count == 64 })

        // The list keeps the newest codes only.
        let limit = InvitedServerPairing.settledLimit
        for i in 0..<(limit + 5) {
            InvitedServerPairing.noteSettled(code: "c\(i)_Z", source: source, defaults: defaults)
        }
        XCTAssertEqual(defaults.stringArray(forKey: InvitedServerPairing.settledKey)?.count, limit)
        XCTAssertTrue(InvitedServerPairing.isSettled(code: "c\(limit + 4)_Z", source: source, defaults: defaults))
        XCTAssertFalse(InvitedServerPairing.isSettled(code: "c0_Z", source: source, defaults: defaults))
    }

    func testARefreshedListDoesNotOfferASettledCodeAgain() throws {
        let defaults = try freshDefaults()
        let hosts = ServerHostStore(defaults: defaults)
        let before = InvitedServerPairing.pendingOffers()
        defer { InvitedServerPairing.savePending(before) }
        InvitedServerPairing.forgetPending(source: source)

        InvitedServerPairing.noteSettled(code: "c0de_refused-Z", source: source, defaults: defaults)
        InvitedServerPairing.noteRefreshed(offer: offer(code: "c0de_refused-Z"), listName: "ams",
                                           source: source, hosts: hosts, defaults: defaults)
        XCTAssertFalse(InvitedServerPairing.pendingOffers().contains { $0.source == source },
                       "a refused code must not wait for the next session again")

        // A code that never got an answer still waits for one.
        InvitedServerPairing.noteRefreshed(offer: offer(code: "c0de_new-Z"), listName: "ams",
                                           source: source, hosts: hosts, defaults: defaults)
        XCTAssertEqual(InvitedServerPairing.pendingOffers().first { $0.source == source }?.code, "c0de_new-Z")
    }
}
