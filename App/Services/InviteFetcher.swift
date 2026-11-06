import Foundation
import Network

// MARK: - InviteFetcher
//
// Downloads and decrypts the list behind a device invite (DeviceInvite.swift).
// The list is served over plain HTTP from the VPS's address, so this speaks
// HTTP/1.1 over an NWConnection instead of URLSession: App Transport Security
// would refuse the request, and its exceptions cannot name an IP address. TLS
// is not what protects the list — AES-GCM with the key from the link is, and a
// tampered or truncated answer fails to decrypt.
//
// The request carries the token only; the key never leaves the device.

enum InviteFetcher {

    enum FetchError: LocalizedError, Equatable {
        case httpStatus(Int)
        case malformedResponse
        case tooLarge
        case timedOut
        case connection(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return L10n.subInvalidResponse_fmt.formatted(code)
            case .malformedResponse:    return L10n.inviteErrorNotAnInvite.localized()
            case .tooLarge:             return L10n.inviteErrorNotAnInvite.localized()
            case .timedOut:             return L10n.inviteErrorUnreachable.localized()
            case .connection(let why):  return L10n.inviteErrorUnreachableDetail_fmt.formatted(why)
            }
        }
    }

    /// A list is a few kilobytes; anything far bigger is not one.
    static let maxResponseBytes = 1 << 20

    /// The decrypted list behind an invite link (with or without its key; the
    /// key comes from the link when present, else from the Keychain).
    static func fetchList(link: String,
                          timeout: TimeInterval = AppConstants.subscriptionFetchTimeout) async throws -> String {
        guard let endpoint = InviteLink.endpoint(of: link) else { throw InviteError.invalidLink }
        let key: Data
        if let parsed = try? InviteLink.parse(link) {
            key = parsed.key
        } else if let stored = InviteKeyStore.key(token: endpoint.token) {
            key = stored
        } else {
            throw InviteError.missingKey
        }
        let body = try await get(host: endpoint.host, port: endpoint.port,
                                 path: "/" + endpoint.token, timeout: timeout)
        guard let text = String(data: body, encoding: .utf8) else { throw InviteError.notAnInvite }
        return try InviteCipher.open(text, key: key)
    }

    /// One GET over a fresh TCP connection; the body of a 200 answer.
    static func get(host: String, port: Int, path: String, timeout: TimeInterval) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw InviteError.invalidLink
        }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let request = "GET \(path) HTTP/1.1\r\nHost: \(shownHost):\(port)\r\n"
            + "Accept: text/plain\r\nConnection: close\r\nUser-Agent: olcOS\r\n\r\n"
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let response: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await Self.ready(connection)
                try await Self.send(Data(request.utf8), on: connection)
                return try await Self.receiveAll(from: connection)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                throw FetchError.timedOut
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            guard let first = try await group.next() else { throw FetchError.timedOut }
            return first
        }
        return try body(ofResponse: response)
    }

    /// The body of a complete HTTP/1.x response, or why there is none. A
    /// missing list answers 404, which means the invite was revoked.
    static func body(ofResponse data: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: separator),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else {
            throw FetchError.malformedResponse
        }
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ")
        guard let status, status.count >= 2, status[0].hasPrefix("HTTP/1."),
              let code = Int(status[1]) else { throw FetchError.malformedResponse }
        if code == 404 { throw InviteError.revoked }
        guard code == 200 else { throw FetchError.httpStatus(code) }
        var body = data[split.upperBound...]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding", value.lowercased() != "identity" {
                throw FetchError.malformedResponse
            }
            if name == "content-length" {
                guard let length = Int(value), length >= 0, body.count >= length else {
                    throw FetchError.malformedResponse
                }
                body = body.prefix(length)
            }
        }
        return Data(body)
    }

    // MARK: NWConnection, one step at a time

    private static func ready(_ connection: NWConnection) async throws {
        let gate = ContinuationGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.fire() { continuation.resume() }
                case .waiting(let error), .failed(let error):
                    // `.waiting` would retry until the timeout; a refused or
                    // unroutable server is an answer already.
                    if gate.fire() { continuation.resume(throwing: FetchError.connection(error.localizedDescription)) }
                case .cancelled:
                    if gate.fire() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: FetchError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receiveAll(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            let (chunk, complete) = try await receive(from: connection)
            buffer.append(chunk)
            if buffer.count > maxResponseBytes { throw FetchError.tooLarge }
            if complete { return buffer }
        }
    }

    private static func receive(from connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: FetchError.connection(error.localizedDescription))
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }
}
