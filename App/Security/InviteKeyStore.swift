import Foundation

// MARK: - InviteKeyStore
//
// The key of a device invite (DeviceInvite.swift), on both sides of it: the
// phone that publishes the list keeps it to re-encrypt every update, the
// invited device keeps it to read them. Keyed by the invite's token, which
// both sides know; the key itself never reaches UserDefaults — a stored
// subscription source is the link without its fragment.

enum InviteKeyStore {
    private static let service = "olcos.invite.key"
    /// The agent pairing code an access invite carries (DeviceInvite.agentCode),
    /// on the publishing phone. It grants server access, so it lives here,
    /// keyed by the same token, and never in the saved host list.
    private static let codeService = "olcos.invite.agentcode"

    static func set(_ key: Data, token: String) {
        KeychainHelper.set(key.base64EncodedString(), service: service, account: token)
    }

    static func key(token: String) -> Data? {
        KeychainHelper.get(service: service, account: token).flatMap { Data(base64Encoded: $0) }
    }

    @discardableResult
    static func setAgentCode(_ code: String, token: String) -> Bool {
        KeychainHelper.set(code, service: codeService, account: token)
    }

    /// `.success(nil)` when there is no code; `.failure` when the Keychain
    /// cannot be read now (still locked after a restart).
    static func agentCode(token: String) -> Result<String?, KeychainError> {
        KeychainHelper.getResult(service: codeService, account: token)
    }

    /// Forgets everything the invite kept: its key and its pairing code.
    static func remove(token: String) {
        KeychainHelper.delete(service: service, account: token)
        KeychainHelper.delete(service: codeService, account: token)
    }
}
