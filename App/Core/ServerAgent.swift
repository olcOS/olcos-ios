import CryptoKit
import Foundation
import Security

// MARK: - Server agent client
//
// olcos-agent (gomobile/agent) is a small HTTPS service the app installs on the
// user's own VPS so the server page reads status and runs room actions over a
// pinned, signed connection instead of an SSH login on the hot path. This file
// is the app side: the endpoint record, this phone's device key, request
// signing, route selection, and the client calls; the pinned HTTPS itself is
// AgentHTTPS.swift.
//
// Every request is signed with a P-256 key (Secure Enclave where it exists, a
// software key in the Keychain otherwise) and the agent's self-signed leaf
// certificate is pinned by SHA-256 — the pin only ever arrives over SSH at
// install, never trusted on first use. Anything the agent cannot authenticate
// it answers with an nginx-identical 404, so a wrong clock or a revoked key
// looks exactly like "there is nothing here". On Automatic (Settings → server
// connection) the caller treats any failure as "fall back to SSH"; on an HTTPS
// choice the failure is the answer.

// MARK: Endpoint

/// What the app stores per host to reach its agent. Persisted inside
/// `ServerHost` (synthesized Codable); `version` is the installed agent source
/// version (so a newer app reinstalls), `deviceID` the owner id registered for
/// this phone at install.
struct AgentEndpoint: Codable, Equatable, Hashable, Sendable {
    var port: Int
    var certSHA256: String
    var prefix: String
    var version: String
    var deviceID: String
    /// The base container the agent's cached status scripts target. When the
    /// server is reinstalled under a new container name this no longer matches,
    /// so the app reinstalls the agent rather than trusting stale status.
    var baseContainer: String = ""
}

/// The decoded `GET status` body: the version counter, the server clock, and
/// the cached outputs of the app's named status scripts (reused by the app's
/// existing parsers).
struct AgentStatus: Codable, Equatable, Sendable {
    var version: UInt64
    var at: Int64
    var outputs: [String: String]
}

/// The decoded `GET usage` body (owner only), which the agent reads from the
/// olcrtc containers' logs: per device id a client announced
/// (DeviceIdentity — an invite's are `inv-<tag>-<name>`), the server's unix
/// time of the latest line about it, whether it has an open session seen in
/// the last three minutes, the bytes it sent through the server (`in`) and
/// received (`out`), and how many sessions it opened. Most recently seen first.
struct AgentUsage: Decodable, Equatable, Sendable {
    struct Device: Decodable, Equatable, Sendable {
        var id: String
        var lastSeen: Int64
        var online: Bool
        var bytesIn: Int64
        var bytesOut: Int64
        var sessions: Int

        enum CodingKeys: String, CodingKey {
            case id, online, sessions
            case lastSeen = "last_seen"
            case bytesIn = "in"
            case bytesOut = "out"
        }
    }

    var at: Int64
    var devices: [Device]
}

// MARK: Device key

/// This phone's identity to every one of its agents: one P-256 key, registered
/// as owner on each server the phone installs. Stored once in the Keychain.
struct AgentDeviceKey {
    let deviceID: String
    /// X.509 SubjectPublicKeyInfo DER — the bytes the installer passes to the
    /// agent as `-owner` (base64) and the agent hashes into the device id.
    let spkiDER: Data
    // fileprivate (not private) so the synthesized memberwise initializer stays
    // reachable from AgentDeviceKeyStore's factories in this file.
    fileprivate let signer: @Sendable (Data) throws -> Data

    /// ECDSA signature over `data`, ASN.1/DER encoded. CryptoKit hashes with
    /// SHA-256 before signing, which is what the Go side verifies.
    func sign(_ data: Data) throws -> Data { try signer(data) }

    static func deviceID(forSPKI spki: Data) -> String {
        let digest = SHA256.hash(data: spki)
        return String(Data(digest).olcBase64URLNoPad().prefix(16))
    }
}

enum AgentKeyError: LocalizedError {
    case keychain
    case corrupt
    var errorDescription: String? {
        switch self {
        case .keychain: return L10n.agentKeyErrorKeychain.localized()
        case .corrupt:  return L10n.agentKeyErrorCorrupt.localized()
        }
    }
}

/// Loads this phone's device key, creating it on first use.
enum AgentDeviceKeyStore {
    static let service = "olcrtc.agent"
    static let account = "devicekey.v1"

    static func loadOrCreate() throws -> AgentDeviceKey {
        if let blob = KeychainHelper.get(service: service, account: account),
           let key = try? fromBlob(blob) {
            return key
        }
        let (key, blob) = try create()
        guard KeychainHelper.set(blob, service: service, account: account) else {
            throw AgentKeyError.keychain
        }
        return key
    }

    /// Creates a Secure Enclave key where the hardware exists, else a software
    /// key (simulator, older devices). The blob is tagged so the loader knows
    /// which representation to rebuild.
    private static func create() throws -> (AgentDeviceKey, String) {
        if SecureEnclave.isAvailable {
            let priv = try SecureEnclave.P256.Signing.PrivateKey()
            let key = makeSE(priv)
            return (key, "se:" + priv.dataRepresentation.base64EncodedString())
        }
        let priv = P256.Signing.PrivateKey()
        let key = makeSW(priv)
        return (key, "sw:" + priv.rawRepresentation.base64EncodedString())
    }

    private static func fromBlob(_ blob: String) throws -> AgentDeviceKey {
        let parts = blob.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let raw = Data(base64Encoded: String(parts[1])) else {
            throw AgentKeyError.corrupt
        }
        switch parts[0] {
        case "se":
            let priv = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: raw)
            return makeSE(priv)
        case "sw":
            let priv = try P256.Signing.PrivateKey(rawRepresentation: raw)
            return makeSW(priv)
        default:
            throw AgentKeyError.corrupt
        }
    }

    private static func makeSE(_ priv: SecureEnclave.P256.Signing.PrivateKey) -> AgentDeviceKey {
        let spki = priv.publicKey.derRepresentation
        return AgentDeviceKey(deviceID: AgentDeviceKey.deviceID(forSPKI: spki), spkiDER: spki) {
            try priv.signature(for: $0).derRepresentation
        }
    }

    private static func makeSW(_ priv: P256.Signing.PrivateKey) -> AgentDeviceKey {
        let spki = priv.publicKey.derRepresentation
        return AgentDeviceKey(deviceID: AgentDeviceKey.deviceID(forSPKI: spki), spkiDER: spki) {
            try priv.signature(for: $0).derRepresentation
        }
    }
}

// MARK: Request canonicalisation

enum AgentRequest {
    /// The exact string both sides sign:
    ///
    ///   METHOD \n path?query \n time \n nonce \n hex(sha256(body))
    ///
    /// `path` is the request URI as sent (path, plus "?"+query when present);
    /// it must equal the Go server's `r.URL.RequestURI()`.
    static func canonical(method: String, path: String, time: String, nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body)
        let hex = bodyHash.map { String(format: "%02x", $0) }.joined()
        return method + "\n" + path + "\n" + time + "\n" + nonce + "\n" + hex
    }

    static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).olcBase64URLNoPad()
    }
}

// MARK: Route selection

enum AgentRoute: Equatable, Sendable {
    case tunnel // through the live session's local SOCKS port (the exit reaches the server's address)
    case direct // straight to the server's address
}

// MARK: Client

enum AgentError: LocalizedError {
    case allRoutesFailed
    case http(Int)
    case decode
    var errorDescription: String? {
        switch self {
        case .allRoutesFailed: return L10n.agentErrorUnreachable.localized()
        case .http(let code):  return L10n.agentErrorHTTP_fmt.formatted(code)
        case .decode:          return L10n.agentErrorDecode.localized()
        }
    }
}

struct AgentClient {
    let host: ServerHost
    let endpoint: AgentEndpoint
    let key: AgentDeviceKey
    /// The routes to try, in order. Injected so the pure selection (the static
    /// `routes(...)` below) stays testable and production builds it from the
    /// live tunnel state and the user's setting.
    let routePlan: [AgentRoute]
    /// Whether the caller reads over SSH when every route fails (Automatic).
    /// Otherwise the failure is the answer, so the user sees it.
    let fallsBackToSSH: Bool

    init(host: ServerHost, endpoint: AgentEndpoint, key: AgentDeviceKey,
         routePlan: [AgentRoute], fallsBackToSSH: Bool = true) {
        self.host = host
        self.endpoint = endpoint
        self.key = key
        self.routePlan = routePlan
        self.fallsBackToSSH = fallsBackToSSH
    }

    /// The client for `host` as the user set it up, or nil when the app does
    /// not use the agent there: none is installed, Settings say SSH, or this
    /// phone's key cannot be loaded.
    static func live(for host: ServerHost) -> AgentClient? {
        if host.isAgentOnly { return exec(for: host) }
        let control = SettingsStore.shared.serverControl
        guard control.usesAgent, let endpoint = host.agent,
              let key = try? AgentDeviceKeyStore.loadOrCreate() else { return nil }
        let plan = routes(control: control, hostRecordIDs: host.linkedConnectionIDs,
                          liveRecordID: TunnelManager.liveRecordID,
                          tunnelUp: TunnelManager.liveBoundPort != nil)
        return AgentClient(host: host, endpoint: endpoint, key: key,
                           routePlan: plan, fallsBackToSSH: control.fallsBackToSSH)
    }

    /// The client of an invited host (no SSH): the server-connection setting
    /// does not apply, there is nothing to fall back to, and a failure is the
    /// answer the user sees.
    static func exec(for host: ServerHost) -> AgentClient? {
        guard host.isAgentOnly, let endpoint = host.agent,
              let key = try? AgentDeviceKeyStore.loadOrCreate() else { return nil }
        let plan = routes(control: .auto, hostRecordIDs: host.linkedConnectionIDs,
                          liveRecordID: TunnelManager.liveRecordID,
                          tunnelUp: TunnelManager.liveBoundPort != nil)
        return AgentClient(host: host, endpoint: endpoint, key: key,
                           routePlan: plan, fallsBackToSSH: false)
    }

    /// The one unsigned call: registers this phone's key under a usable invite
    /// code: `{code, public_key, name}` in, `{device_id, role}` out. Pinned like
    /// every other call; the agent answers a failure with its camouflage 404.
    /// With `viaTunnel`, the live session's SOCKS port is tried first: its exit
    /// reaches the server's own address when the phone's own network does not.
    static func pair(offer: AgentOffer, key: AgentDeviceKey, name: String,
                     viaTunnel: Bool = false) async throws -> (deviceID: String, role: String) {
        struct Req: Encodable { let code: String; let public_key: String; let name: String }
        struct Res: Decodable { let device_id: String; let role: String }
        let body = try JSONEncoder().encode(Req(code: offer.code, public_key: key.spkiDER.base64EncodedString(), name: name))
        let path = "/\(offer.prefix)/v1/pair"
        let request = AgentHTTPS.request(method: "POST", path: path, host: offer.host, port: offer.port,
                                         headers: [("Content-Type", "application/json")], body: body)
        var routes: [AgentHTTPS.SOCKS?] = [nil]
        if viaTunnel, let port = TunnelManager.liveBoundPort {
            let credentials = TunnelManager.liveSocksCredentials
            routes.insert(AgentHTTPS.SOCKS(port: port, user: credentials?.user, pass: credentials?.pass), at: 0)
        }
        var lastError: Error = AgentError.allRoutesFailed
        for socks in routes {
            let response: AgentHTTPS.Response
            do {
                response = try await AgentHTTPS.send(host: offer.host, port: offer.port, pinHex: offer.certSHA256,
                                                     request: request, socks: socks, timeout: 12)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Nothing came back this way; the next route may reach the agent.
                lastError = error
                continue
            }
            // An answer is final: the code is one-time and is not sent again.
            guard response.status == 200 else { throw AgentError.http(response.status) }
            guard let r = try? JSONDecoder().decode(Res.self, from: response.body) else { throw AgentError.decode }
            return (r.device_id, r.role)
        }
        throw lastError
    }

    /// Pure route rule. Automatic: the tunnel route is worth trying only when
    /// a live session runs through THIS server (its exit hairpins to the agent
    /// port), then direct; with no such session, direct. Each HTTPS choice uses
    /// its one route (through the tunnel only while a session is up, through
    /// any server); SSH uses none.
    static func routes(control: ServerControl = .auto, hostRecordIDs: [UUID],
                       liveRecordID: UUID?, tunnelUp: Bool) -> [AgentRoute] {
        switch control {
        case .auto:
            if tunnelUp, let live = liveRecordID, hostRecordIDs.contains(live) {
                return [.tunnel, .direct]
            }
            return [.direct]
        case .httpsTunnel:
            return tunnelUp ? [.tunnel] : []
        case .httpsDirect:
            return [.direct]
        case .ssh:
            return []
        }
    }

    // Per-route timeouts (spec §4.2): the tunnel adds a SOCKS hop, direct is
    // a straight dial; a long-poll needs more than either. A usage read may
    // wait up to two seconds for the agent's pass over the container logs.
    private static let tunnelTimeout: TimeInterval = 6
    private static let directTimeout: TimeInterval = 4
    private static let longPollTimeout: TimeInterval = 30
    private static let usageTimeout: TimeInterval = 8
    /// A room start, stop or restart is podman's own work, seconds long (a stop
    /// waits for the container to exit), before the agent answers.
    private static let roomActionTimeout: TimeInterval = 40

    // MARK: Calls

    func status() async throws -> AgentStatus {
        let data = try await send(method: "GET", pathSuffix: "status", body: Data(), longPoll: false)
        guard let status = try? JSONDecoder().decode(AgentStatus.self, from: data) else {
            throw AgentError.decode
        }
        return status
    }

    /// Owner only: who used the tunnel through this server, when, and how much
    /// (AgentUsage). A member gets the agent's 404. Nothing reads this over
    /// SSH: a failure is the caller's to show or to ignore.
    func usage() async throws -> AgentUsage {
        let data = try await send(method: "GET", pathSuffix: "usage", body: Data(), longPoll: false,
                                  timeout: Self.usageTimeout, sshFallback: false)
        guard let usage = try? JSONDecoder().decode(AgentUsage.self, from: data) else {
            throw AgentError.decode
        }
        return usage
    }

    /// Long-poll the event version; returns the (possibly unchanged) version.
    func events(since: UInt64) async throws -> UInt64 {
        let data = try await send(method: "GET", pathSuffix: "events?since=\(since)", body: Data(), longPoll: true)
        struct E: Decodable { let version: UInt64 }
        guard let e = try? JSONDecoder().decode(E.self, from: data) else { throw AgentError.decode }
        return e.version
    }

    func room(_ container: String, action: String) async throws {
        _ = try await send(method: "POST", pathSuffix: "rooms/\(container)/\(action)", body: Data(), longPoll: false,
                           timeout: Self.roomActionTimeout)
    }

    /// Owner only: runs a maintenance script on the server (bash, as root)
    /// and returns its exit status with the merged output. The agent caps the
    /// time at ten minutes and keeps the last 64 KB of output.
    func exec(script: String, timeout: Int) async throws -> (exit: Int, output: String) {
        struct Req: Encodable { let script: String; let timeout: Int }
        let body = try JSONEncoder().encode(Req(script: Data(script.utf8).base64EncodedString(), timeout: timeout))
        let data = try await send(method: "POST", pathSuffix: "exec", body: body, longPoll: true,
                                  timeout: TimeInterval(timeout) + 15)
        struct Res: Decodable { let exit: Int; let output: String }
        guard let r = try? JSONDecoder().decode(Res.self, from: data) else { throw AgentError.decode }
        return (r.exit, r.output)
    }

    func log(_ container: String, lines: Int) async throws -> String {
        let data = try await send(method: "GET", pathSuffix: "rooms/\(container)/log?lines=\(lines)", body: Data(), longPoll: false)
        struct L: Decodable { let log: String }
        guard let l = try? JSONDecoder().decode(L.self, from: data) else { throw AgentError.decode }
        return l.log
    }

    // MARK: Transport

    /// `sshFallback`: whether the caller reads over SSH when this fails, for
    /// the log line only.
    private func send(method: String, pathSuffix: String, body: Data, longPoll: Bool,
                      timeout: TimeInterval? = nil, sshFallback: Bool = true) async throws -> Data {
        // No route at all: an HTTPS-through-the-tunnel choice with no session up.
        var lastError: Error = AgentError.allRoutesFailed
        if routePlan.isEmpty { lastError = AgentHTTPS.Failure.noTunnel }
        for route in routePlan {
            do {
                return try await attempt(route: route, method: method, pathSuffix: pathSuffix, body: body,
                                         longPoll: longPoll, timeout: timeout)
            } catch is CancellationError {
                throw CancellationError()   // the screen closed: nothing to report
            } catch {
                lastError = error
            }
        }
        // Leave a trace in the log, above all when the caller then falls back
        // to SSH silently. Never the URL: it carries the secret API prefix.
        let tried = routePlan.isEmpty ? "tunnel" : routePlan.map { "\($0)" }.joined(separator: ", ")
        let line = "Agent on \(host.host) did not answer (\(tried): \(Self.reason(lastError)))"
            + (fallsBackToSSH && sshFallback ? "; using SSH" : "")
        Task { @MainActor in LogStore.shared.log(.provisioning, line) }
        throw lastError
    }

    /// A short, secret-free reason: an HTTP status (404 = not authenticated —
    /// a wrong phone clock or a revoked key), the pin, a TLS or network
    /// failure, or a decode fault.
    static func reason(_ error: Error) -> String {
        if let e = error as? AgentError {
            switch e {
            case .http(let code):   return "HTTP \(code)"
            case .decode:           return "unreadable answer"
            case .allRoutesFailed:  return "no route"
            }
        }
        if let e = error as? AgentHTTPS.Failure { return e.reason }
        return String(describing: type(of: error))
    }

    private func attempt(route: AgentRoute, method: String, pathSuffix: String, body: Data, longPoll: Bool,
                         timeout explicit: TimeInterval? = nil) async throws -> Data {
        let fullPath = "/\(endpoint.prefix)/v1/\(pathSuffix)"
        let timeout = explicit ?? (longPoll ? Self.longPollTimeout : (route == .tunnel ? Self.tunnelTimeout : Self.directTimeout))
        var socks: AgentHTTPS.SOCKS?
        if route == .tunnel {
            guard let port = TunnelManager.liveBoundPort else { throw AgentHTTPS.Failure.noTunnel }
            let credentials = TunnelManager.liveSocksCredentials
            socks = AgentHTTPS.SOCKS(port: port, user: credentials?.user, pass: credentials?.pass)
        }
        let headers = try signedHeaders(method: method, fullPath: fullPath, body: body)
        let request = AgentHTTPS.request(method: method, path: fullPath, host: host.host,
                                         port: endpoint.port, headers: headers, body: body)
        let response = try await AgentHTTPS.send(
            host: host.host, port: endpoint.port, pinHex: endpoint.certSHA256,
            request: request, socks: socks, timeout: timeout)
        guard response.status == 200 else { throw AgentError.http(response.status) }
        if route == .tunnel { SOCKSSession.noteTunnelActivity() }
        return response.body
    }

    /// The four headers that authenticate a request (see AgentRequest.canonical).
    private func signedHeaders(method: String, fullPath: String, body: Data) throws -> [(String, String)] {
        let now = String(Int(Date().timeIntervalSince1970))
        let nonce = AgentRequest.randomNonce()
        let canonical = AgentRequest.canonical(method: method, path: fullPath, time: now, nonce: nonce, body: body)
        let signature = try key.sign(Data(canonical.utf8))
        return [("X-Olc-Device", key.deviceID), ("X-Olc-Time", now),
                ("X-Olc-Nonce", nonce), ("X-Olc-Sig", signature.olcBase64URLNoPad())]
    }
}

// MARK: - base64url helper

extension Data {
    /// Unpadded base64url (RFC 4648 §5), matching Go's base64.RawURLEncoding.
    func olcBase64URLNoPad() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
