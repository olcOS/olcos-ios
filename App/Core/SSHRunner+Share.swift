import Foundation

// Server side of device invites (App/Models/DeviceInvite.swift): a busybox
// httpd in its own container serves /opt/olcos-share read-only on one TCP
// port. Each invite is one file named by its token, holding the encrypted
// list as text; there is no index, so a token is the only way to a file.
// The scripts print KEY=VALUE lines (OLCOS_SHARE_*) and report a recoverable
// failure as OLCOS_SHARE_ERROR=<reason> with exit 0 so the reason reaches the app.

extension SSHRunner {

    static let shareContainerName = "olcos-share"
    static let shareDirectory = "/opt/olcos-share"

    /// The port a new share server listens on. High and random, so it is
    /// neither a well-known service port nor the same on every server.
    static func randomSharePort() -> Int { Int.random(in: 20_000...59_999) }

    struct ShareResult: Equatable, Sendable {
        /// The port the share server answers on (an existing server keeps its own).
        var port: Int?
        var written: Set<String> = []
        var deleted: Set<String> = []
        /// The server itself was removed because no list was left.
        var stopped = false
        var error: String?
    }

    enum ShareError: LocalizedError, Equatable {
        case server(String)
        case portBusy

        var errorDescription: String? {
            switch self {
            case .server(let reason): return L10n.inviteErrorServer_fmt.formatted(reason)
            case .portBusy:           return L10n.inviteErrorServer_fmt.formatted(L10n.inviteErrorPortBusy.localized())
            }
        }
    }

    /// Starts the share server when it is missing (on `port`), then writes
    /// each list atomically. Prints OLCOS_SHARE_PORT and one OLCOS_SHARE_OK per
    /// written token.
    static func sharePublishScript(port: Int, lists: [(token: String, served: String)]) -> String {
        var lines = [
            "set -e",
            "D=\(shareDirectory)",
            "mkdir -p \"$D\"",
            "chmod 755 \"$D\"",
            "[ -f \"$D/index.html\" ] || : > \"$D/index.html\"",
            "if ! podman container exists \(shareContainerName) 2>/dev/null; then",
            "  if ! podman run -d --name \(shareContainerName) --restart=always -p \(port):8080 "
                + "-v \"$D:/www:ro,Z\" \(AppConstants.shareServerImage) httpd -f -p 8080 -h /www "
                + ">/dev/null 2>/tmp/olcos-share.err; then",
            "    if grep -qi 'address already in use' /tmp/olcos-share.err; then echo OLCOS_SHARE_ERROR=port_busy; exit 0; fi",
            "    echo \"OLCOS_SHARE_ERROR=$(tail -n 1 /tmp/olcos-share.err | tr -d '\\r')\"; exit 0",
            "  fi",
            "else",
            "  podman start \(shareContainerName) >/dev/null 2>&1 || true",
            "fi",
            "echo \"OLCOS_SHARE_PORT=$(podman port \(shareContainerName) 8080/tcp 2>/dev/null | head -n 1 | sed 's/.*://')\"",
        ]
        for list in lists where InviteLink.isWellFormedToken(list.token) && isServable(list.served) {
            lines.append("printf '%s' '\(list.served)' > \"$D/.tmp-\(list.token)\"")
            lines.append("chmod 644 \"$D/.tmp-\(list.token)\"")
            lines.append("mv -f \"$D/.tmp-\(list.token)\" \"$D/\(list.token)\"")
            lines.append("echo OLCOS_SHARE_OK=\(list.token)")
        }
        return lines.joined(separator: "\n")
    }

    /// Deletes lists; when none is left — another phone with SSH access may
    /// have published its own — the server goes too, so nothing listens for
    /// nothing.
    static func shareDeleteScript(tokens: [String]) -> String {
        var lines = ["D=\(shareDirectory)"]
        for token in tokens where InviteLink.isWellFormedToken(token) {
            lines.append("rm -f \"$D/\(token)\" && echo OLCOS_SHARE_DELETED=\(token)")
        }
        lines.append("if [ -d \"$D\" ] && [ -z \"$(find \"$D\" -maxdepth 1 -type f ! -name index.html ! -name '.tmp-*' 2>/dev/null | head -n 1)\" ]; then")
        lines.append("  podman rm -f \(shareContainerName) >/dev/null 2>&1 || true")
        lines.append("  rm -rf \"$D\"")
        lines.append("  echo OLCOS_SHARE_STOPPED=1")
        lines.append("fi")
        return lines.joined(separator: "\n")
    }

    /// Deep uninstall takes the share server with everything else.
    static let shareUninstallLines = """
    podman rm -f \(shareContainerName) >/dev/null 2>&1 || true
    rm -rf \(shareDirectory) 2>/dev/null || true
    """

    static func parseShareOutput(_ output: String) -> ShareResult {
        var result = ShareResult()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let value = line.value(after: "OLCOS_SHARE_PORT=") {
                result.port = Int(value)
            } else if let value = line.value(after: "OLCOS_SHARE_OK=") {
                result.written.insert(value)
            } else if let value = line.value(after: "OLCOS_SHARE_DELETED=") {
                result.deleted.insert(value)
            } else if line == "OLCOS_SHARE_STOPPED=1" {
                result.stopped = true
            } else if let value = line.value(after: "OLCOS_SHARE_ERROR=") {
                result.error = value.isEmpty ? "unknown" : value
            }
        }
        return result
    }

    /// Uploads `lists`, starting the share server on a random port when the
    /// host has none; a busy port is retried with another one.
    static func publishInvites(host: ServerHost, secret: SSHSecret,
                               lists: [(token: String, served: String)]) async throws -> ShareResult {
        var port = host.sharePort ?? randomSharePort()
        for attempt in 1...3 {
            let output = try await _withConnection(host: host, secret: secret) { client in
                try await _execute(client: client, label: "invite publish",
                                   command: sharePublishScript(port: port, lists: lists))
            }
            let result = parseShareOutput(output)
            if result.error == "port_busy", attempt < 3 {
                port = randomSharePort()
                continue
            }
            if result.error == "port_busy" { throw ShareError.portBusy }
            if let error = result.error { throw ShareError.server(error) }
            guard result.port != nil else { throw ShareError.server("no port") }
            return result
        }
        throw ShareError.portBusy
    }

    static func deleteInvites(host: ServerHost, secret: SSHSecret, tokens: [String]) async throws -> ShareResult {
        let output = try await _withConnection(host: host, secret: secret) { client in
            try await _execute(client: client, label: "invite revoke", command: shareDeleteScript(tokens: tokens))
        }
        return parseShareOutput(output)
    }

    /// The served text goes inside single quotes; only the cipher's own
    /// alphabet may.
    private static func isServable(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=:")
        return !text.isEmpty && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
