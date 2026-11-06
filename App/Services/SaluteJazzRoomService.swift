import Foundation

// MARK: - SaluteJazzRoomService
//
// Creates a SaluteJazz (Sber) meeting from the phone: one anonymous POST, no
// account, no cookie. The answer is the room reference the core joins with,
// `<code>:<password>` (olcrtc-upstream internal/auth/salutejazz/api.go,
// `createMeeting`, whose body and headers this mirrors so the app and the core
// present the same client to Sber).
//
// The phone mints the room for the same reason it mints Telemost rooms: the
// install sends it to the server over SSH, and the phone keeps a copy for the
// connection it saves. The route follows SSHTransport, like TelemostRoomService:
// through the tunnel when one is live, else direct, with one retry on the
// other path when the first never got an answer.

enum SaluteJazzRoomError: LocalizedError, Equatable {
    case networkUnavailable
    case refused(status: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .networkUnavailable: return L10n.saluteJazzErrNetwork.localized()
        case .refused(let s):     return L10n.saluteJazzErrStatus_fmt.formatted(s)
        case .malformedResponse:  return L10n.saluteJazzErrMalformed.localized()
        }
    }
}

enum SaluteJazzRoomService {

    static let createURL = URL(string: "https://bk.salutejazz.ru/room/create-meeting")!

    private static let origin = "https://salutejazz.ru"
    private static let userAgent =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"

    /// The exact body the official web client sends (and the core repeats).
    static let requestBody = Data(#"{"title":"Видеовстреча","guestEnabled":true,"lobbyEnabled":false,"serverVideoRecordAutoStartEnabled":false,"sipEnabled":false,"moderatorEmails":[],"summarizationEnabled":false,"interpretation":null,"room3dEnabled":false,"room3dScene":"XRLobby"}"#.utf8)

    /// A new room reference, `<code>:<password>`.
    static func createRoom() async throws -> String {
        let available = await SSHTransport.currentRoute()
        do {
            return try await createRoom(route: available)
        } catch SaluteJazzRoomError.networkUnavailable {
            let fallback = SSHTransport.nextRoute(attempt: 2, previous: available, available: available)
            guard fallback != available else { throw SaluteJazzRoomError.networkUnavailable }
            return try await createRoom(route: fallback)
        }
    }

    private static func createRoom(route: SSHTransport.Route) async throws -> String {
        let timeout: TimeInterval = route.isTunnel ? 40 : 20
        var req = URLRequest(url: createURL, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = requestBody
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let urlSession = SOCKSSession.make(mode: route.isTunnel ? .tunnel : .direct, timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }

        await log("SaluteJazz: requesting a new room (route: \(route))")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch let error as URLError {
            await log("SaluteJazz: no answer (route: \(route), URLError \(error.code.rawValue))")
            throw SaluteJazzRoomError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw SaluteJazzRoomError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            await log("SaluteJazz: the service answered HTTP \(http.statusCode)")
            throw SaluteJazzRoomError.refused(status: http.statusCode)
        }
        if route.isTunnel { SOCKSSession.noteTunnelActivity() }
        guard let room = roomReference(from: data) else {
            await log("SaluteJazz: unreadable answer (\(data.count) bytes)")
            throw SaluteJazzRoomError.malformedResponse
        }
        await log("SaluteJazz: new room created")
        return room
    }

    /// PURE. `{"roomId": …, "password": …}` → `<code>:<password>`, or nil for
    /// anything else (a different shape, an interception page).
    static func roomReference(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Matched case-insensitively, as the core's JSON decoder does.
        func value(_ name: String) -> String? {
            object.first { $0.key.lowercased() == name }?.value as? String
        }
        guard let code = value("roomid"), let password = value("password") else { return nil }
        return SaluteJazzRoom.normalized("\(code):\(password)")
    }

    private static func log(_ line: String) async {
        await MainActor.run { LogStore.shared.log(.provisioning, line) }
    }
}
