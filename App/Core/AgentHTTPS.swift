import CryptoKit
import Foundation
import Network
import Security

// MARK: - HTTPS to the server agent over Network.framework
//
// The agent's certificate is self-signed and pinned by the SHA-256 of its DER.
// URLSession cannot take it: with App Transport Security on, iOS refuses a
// certificate the system does not trust whatever a pinning delegate answers,
// and an ATS exception cannot name an IP address. Network.framework is outside
// ATS, so here the TLS handshake asks the pin check below and nothing else.
//
// One request per connection (`Connection: close`). The tunnel route dials
// through the live session's local SOCKS5 listener, with its credentials.

enum AgentHTTPS {

    enum Failure: LocalizedError, Equatable {
        /// The server's certificate is not the pinned one.
        case pin
        case timeout
        /// The tunnel route was asked for while no session is up.
        case noTunnel
        case network(String)
        case badResponse
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .pin:      return L10n.agentErrorPin.localized()
            case .noTunnel: return L10n.agentErrorNoTunnel.localized()
            default:        return L10n.agentErrorUnreachable.localized()
            }
        }

        /// Short and secret-free, for the log line.
        var reason: String {
            switch self {
            case .pin:               return "certificate does not match the pin"
            case .timeout:           return "timed out"
            case .noTunnel:          return "no tunnel"
            case .network(let what): return what
            case .badResponse:       return "unreadable answer"
            case .tooLarge:          return "answer too large"
            }
        }
    }

    struct Response: Equatable {
        let status: Int
        let body: Data
    }

    /// The live session's local SOCKS5 listener, for the tunnel route.
    struct SOCKS: Equatable {
        let port: Int
        let user: String?
        let pass: String?
    }

    /// The agent answers small JSON documents; anything past this is not it.
    static let maxResponse = 4 << 20

    // MARK: Wire format

    /// One HTTP/1.1 request, closed after the answer.
    static func request(method: String, path: String, host: String, port: Int,
                        headers: [(String, String)], body: Data) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host.contains(":") ? "[\(host)]" : host):\(port)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if method != "GET" || !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// The response in `data`, or nil while more is to come. `atEnd`: the
    /// server has closed, so a body without a length ends here and a short one
    /// is an error.
    static func response(in data: Data, atEnd: Bool) throws -> Response? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            if atEnd { throw Failure.badResponse }
            return nil
        }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."),
              let status = Int(statusLine[1]) else { throw Failure.badResponse }
        var length: Int?
        var chunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        let body = Data(data[headEnd.upperBound...])
        if chunked {
            if let decoded = try dechunk(body) { return Response(status: status, body: decoded) }
        } else if let length {
            if body.count >= length { return Response(status: status, body: body.prefix(length)) }
        } else if atEnd {
            return Response(status: status, body: body)
        }
        if atEnd { throw Failure.badResponse }
        return nil
    }

    /// A chunked body decoded, or nil while its last chunk has not arrived.
    static func dechunk(_ data: Data) throws -> Data? {
        let crlf = Data("\r\n".utf8)
        var out = Data()
        var at = data.startIndex
        while let lineEnd = data.range(of: crlf, in: at..<data.endIndex) {
            let line = String(decoding: data[at..<lineEnd.lowerBound], as: UTF8.self)
            let hex = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw Failure.badResponse
            }
            if size == 0 { return out }
            let start = lineEnd.upperBound
            // `size` comes from the peer's hex: compare what is left against
            // it without ever forming `size + 2`.
            let remaining = data.distance(from: start, to: data.endIndex)
            guard remaining >= 2, remaining - 2 >= size else { return nil }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            at = data.index(end, offsetBy: 2)
        }
        return nil
    }

    /// Lowercase hex SHA-256 of a certificate's DER: the agent's pin format.
    static func pin(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sending

    /// Sends `request` to host:port over TLS that trusts exactly the pinned
    /// certificate, through `socks` when given, and returns the answer.
    static func send(host: String, port: Int, pinHex: String, request: Data,
                     socks: SOCKS?, timeout: TimeInterval) async throws -> Response {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw Failure.network("bad port")
        }
        let exchange = AgentExchange(pinHex: pinHex.lowercased(), request: request)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: exchange.parameters(socks: socks))
        return try await withTaskCancellationHandler {
            try await exchange.run(connection, timeout: timeout)
        } onCancel: {
            connection.cancel()
        }
    }
}

/// One request's state. Every callback (the connection's, the TLS verify
/// block's and the deadline's) runs on `queue`, so nothing here needs a lock.
private final class AgentExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "olcos.agent.https")
    private let pinHex: String
    private let request: Data
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<AgentHTTPS.Response, Error>?
    private var received = Data()
    private var pinRefused = false

    init(pinHex: String, request: Data) {
        self.pinHex = pinHex
        self.request = request
    }

    func parameters(socks: AgentHTTPS.SOCKS?) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        sec_protocol_options_set_verify_block(options, { [weak self] _, trust, complete in
            guard let self else { complete(false); return }
            let ok = self.trusts(sec_trust_copy_ref(trust).takeRetainedValue())
            if !ok { self.pinRefused = true }
            complete(ok)
        }, queue)
        let parameters = NWParameters(tls: tls)
        if let socks, let port = NWEndpoint.Port(rawValue: UInt16(clamping: socks.port)) {
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))
            if let user = socks.user, let pass = socks.pass {
                proxy.applyCredential(username: user, password: pass)
            }
            let context = NWParameters.PrivacyContext(description: "olcOS server agent")
            context.proxyConfigurations = [proxy]
            parameters.setPrivacyContext(context)
        }
        return parameters
    }

    /// The leaf certificate is the pinned one. The chain is never evaluated:
    /// the certificate is self-signed, and the pin is the whole of its trust.
    private func trusts(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        return AgentHTTPS.pin(ofDER: SecCertificateCopyData(leaf) as Data) == pinHex
    }

    func run(_ connection: NWConnection, timeout: TimeInterval) async throws -> AgentHTTPS.Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(AgentHTTPS.Failure.timeout))
                }
            }
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection?.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(self.failure(error)))
                } else {
                    self.receive()
                }
            })
        case .failed(let error), .waiting(let error):
            // `.waiting` would wait for the network to change; a request with
            // a deadline has nothing to wait for.
            finish(.failure(failure(error)))
        case .cancelled:
            finish(.failure(CancellationError()))
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            do {
                if self.received.count > AgentHTTPS.maxResponse { throw AgentHTTPS.Failure.tooLarge }
                if let response = try AgentHTTPS.response(in: self.received, atEnd: isComplete) {
                    self.finish(.success(response))
                } else if let error {
                    self.finish(.failure(self.failure(error)))
                } else {
                    self.receive()
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func failure(_ error: NWError) -> Error {
        if pinRefused { return AgentHTTPS.Failure.pin }
        switch error {
        case .posix(let code): return AgentHTTPS.Failure.network("POSIX \(code.rawValue)")
        case .tls(let status): return AgentHTTPS.Failure.network("TLS \(status)")
        case .dns(let code):   return AgentHTTPS.Failure.network("DNS \(code)")
        default:               return AgentHTTPS.Failure.network("\(error)")
        }
    }

    private func finish(_ result: Result<AgentHTTPS.Response, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        continuation.resume(with: result)
    }
}
