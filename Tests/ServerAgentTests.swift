import CryptoKit
import XCTest
@testable import olcrtc_ios

// Unit tests for the server-agent client (App/Core/ServerAgent.swift and
// AgentHTTPS.swift). The network paths are integration-only (a real device
// talks to a real agent); what is pinned here is the pure, portable surface:
// the canonical string the Go server also signs, the signing primitive, route
// selection per setting, the HTTP bytes on the wire, the pin format, and the
// Codable records.

final class ServerAgentTests: XCTestCase {

    // The canonical string MUST be byte-identical to the Go agent's. This is
    // the exact vector the Go `TestCanonicalString` pins: body `{"a":1}`, whose
    // SHA-256 is the trailing hex below.
    func testCanonicalMatchesGoVector() {
        let body = Data(#"{"a":1}"#.utf8)
        let got = AgentRequest.canonical(method: "POST", path: "/p/v1/exec",
                                         time: "1700000000", nonce: "nonce123", body: body)
        let want = "POST\n/p/v1/exec\n1700000000\nnonce123\n" +
            "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862"
        XCTAssertEqual(got, want)
    }

    func testCanonicalEmptyBody() {
        let got = AgentRequest.canonical(method: "GET", path: "/p/v1/status",
                                         time: "1", nonce: "n", body: Data())
        let want = "GET\n/p/v1/status\n1\nn\n" +
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(got, want)
    }

    // A software P-256 key's signature verifies with its own public key, and
    // survives the ASN.1/DER round trip the wire format uses — the shape the Go
    // side verifies with ecdsa.VerifyASN1.
    func testSoftwareKeySignatureVerifies() throws {
        let priv = P256.Signing.PrivateKey()
        let msg = Data("canonical-bytes".utf8)
        let sig = try priv.signature(for: msg)
        XCTAssertTrue(priv.publicKey.isValidSignature(sig, for: msg))

        let der = sig.derRepresentation
        let roundTrip = try P256.Signing.ECDSASignature(derRepresentation: der)
        XCTAssertTrue(priv.publicKey.isValidSignature(roundTrip, for: msg))
    }

    func testDeviceIDStableAnd16Chars() {
        let priv = P256.Signing.PrivateKey()
        let spki = priv.publicKey.derRepresentation
        let a = AgentDeviceKey.deviceID(forSPKI: spki)
        let b = AgentDeviceKey.deviceID(forSPKI: spki)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16)
    }

    // Route rule: the tunnel is tried first only when the live session runs
    // through THIS server.
    func testRoutesLiveHere() {
        let here = UUID()
        XCTAssertEqual(
            AgentClient.routes(hostRecordIDs: [here], liveRecordID: here, tunnelUp: true),
            [.tunnel, .direct])
    }

    func testRoutesLiveElsewhere() {
        let here = UUID(), elsewhere = UUID()
        XCTAssertEqual(
            AgentClient.routes(hostRecordIDs: [here], liveRecordID: elsewhere, tunnelUp: true),
            [.direct])
    }

    func testRoutesNoSession() {
        let here = UUID()
        XCTAssertEqual(
            AgentClient.routes(hostRecordIDs: [here], liveRecordID: nil, tunnelUp: true),
            [.direct])
    }

    func testRoutesTunnelDownHere() {
        let here = UUID()
        XCTAssertEqual(
            AgentClient.routes(hostRecordIDs: [here], liveRecordID: here, tunnelUp: false),
            [.direct])
    }

    // Per setting: Automatic keeps the rule above; each HTTPS choice uses its
    // one route (the tunnel through any server, but only while it is up); SSH
    // uses none.
    func testRoutesByServerControl() {
        let here = UUID(), elsewhere = UUID()
        XCTAssertEqual(AgentClient.routes(control: .auto, hostRecordIDs: [here],
                                          liveRecordID: here, tunnelUp: true), [.tunnel, .direct])
        XCTAssertEqual(AgentClient.routes(control: .httpsTunnel, hostRecordIDs: [here],
                                          liveRecordID: elsewhere, tunnelUp: true), [.tunnel])
        XCTAssertEqual(AgentClient.routes(control: .httpsTunnel, hostRecordIDs: [here],
                                          liveRecordID: here, tunnelUp: false), [])
        XCTAssertEqual(AgentClient.routes(control: .httpsDirect, hostRecordIDs: [here],
                                          liveRecordID: here, tunnelUp: true), [.direct])
        XCTAssertEqual(AgentClient.routes(control: .ssh, hostRecordIDs: [here],
                                          liveRecordID: here, tunnelUp: true), [])
    }

    func testOnlyAutomaticFallsBackToSSH() {
        XCTAssertTrue(ServerControl.auto.fallsBackToSSH)
        XCTAssertFalse(ServerControl.httpsTunnel.fallsBackToSSH)
        XCTAssertFalse(ServerControl.httpsDirect.fallsBackToSSH)
        XCTAssertFalse(ServerControl.ssh.fallsBackToSSH)
        XCTAssertTrue(ServerControl.httpsDirect.usesAgent)
        XCTAssertFalse(ServerControl.ssh.usesAgent)
    }

    // The bytes the agent's Go server reads: one HTTP/1.1 request, Host with
    // the port (an IPv6 literal in brackets), a length on POST even when empty,
    // the connection closed after the answer.
    func testRequestBytes() {
        let get = AgentHTTPS.request(method: "GET", path: "/p/v1/status", host: "203.0.113.9", port: 30000,
                                     headers: [("X-Olc-Time", "1")], body: Data())
        XCTAssertEqual(String(decoding: get, as: UTF8.self),
                       "GET /p/v1/status HTTP/1.1\r\nHost: 203.0.113.9:30000\r\nX-Olc-Time: 1\r\n"
                       + "Connection: close\r\n\r\n")
        let post = AgentHTTPS.request(method: "POST", path: "/p/v1/rooms/c/start", host: "2001:db8::1", port: 443,
                                      headers: [], body: Data())
        XCTAssertEqual(String(decoding: post, as: UTF8.self),
                       "POST /p/v1/rooms/c/start HTTP/1.1\r\nHost: [2001:db8::1]:443\r\nContent-Length: 0\r\n"
                       + "Connection: close\r\n\r\n")
    }

    func testResponseWithLength() {
        let full = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}".utf8)
        XCTAssertEqual(try AgentHTTPS.response(in: full, atEnd: false),
                       AgentHTTPS.Response(status: 200, body: Data(#"{"a":1}"#.utf8)))
        XCTAssertNil(try AgentHTTPS.response(in: full.dropLast(2), atEnd: false))   // more to come
        XCTAssertThrowsError(try AgentHTTPS.response(in: full.dropLast(2), atEnd: true))   // cut short
    }

    func testResponseChunked() {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(try AgentHTTPS.response(in: raw, atEnd: false)?.body, Data("hello world".utf8))
        let cut = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n wo".utf8)
        XCTAssertNil(try AgentHTTPS.response(in: cut, atEnd: false))
        XCTAssertThrowsError(try AgentHTTPS.response(in: cut, atEnd: true))
    }

    // No length and not chunked (the nginx-like 404): the body ends at close.
    func testResponseUntilClose() {
        let raw = Data("HTTP/1.0 404 Not Found\r\nServer: nginx\r\n\r\n<html>".utf8)
        XCTAssertNil(try AgentHTTPS.response(in: raw, atEnd: false))
        XCTAssertEqual(try AgentHTTPS.response(in: raw, atEnd: true),
                       AgentHTTPS.Response(status: 404, body: Data("<html>".utf8)))
    }

    func testResponseGarbageThrows() {
        XCTAssertThrowsError(try AgentHTTPS.response(in: Data("SSH-2.0-OpenSSH\r\n\r\n".utf8), atEnd: false))
        XCTAssertThrowsError(try AgentHTTPS.response(
            in: Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8), atEnd: false))
    }

    // The pin is the lowercase hex SHA-256 of the DER, as the Go side prints it.
    func testPinFormat() {
        XCTAssertEqual(AgentHTTPS.pin(ofDER: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEndpointCodableRoundTrip() throws {
        let e = AgentEndpoint(port: 28431, certSHA256: "abc123", prefix: "someprefix22charslong0", version: "deadbeef", deviceID: "0123456789abcdef")
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(AgentEndpoint.self, from: data)
        XCTAssertEqual(e, back)
    }

    // A host saved before the agent existed (no "agent" key) still decodes, and
    // its agent is nil — so the app knows to install it.
    func testServerHostWithoutAgentDecodes() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","label":"My VPS","host":"203.0.113.9","port":22,"username":"root"}
        """.utf8)
        let host = try JSONDecoder().decode(ServerHost.self, from: json)
        XCTAssertNil(host.agent)
        XCTAssertEqual(host.host, "203.0.113.9")
    }

    func testServerHostWithAgentRoundTrips() throws {
        var host = ServerHost(label: "My VPS", host: "203.0.113.9")
        host.agent = AgentEndpoint(port: 30000, certSHA256: "ff", prefix: "p", version: "v1", deviceID: "d")
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(ServerHost.self, from: data)
        XCTAssertEqual(back.agent, host.agent)
    }

    func testBase64URLNoPadMatchesGoRawURLEncoding() {
        // 0xFB 0xFF 0xBF -> standard "+/+/..." bytes exercise the - and _ swap.
        XCTAssertEqual(Data([0xFB, 0xFF, 0xBF]).olcBase64URLNoPad(), "-_-_")
        // 16 bytes -> 22 chars, no padding (the API prefix length)
        XCTAssertEqual(Data(repeating: 0, count: 16).olcBase64URLNoPad().count, 22)
    }
}
