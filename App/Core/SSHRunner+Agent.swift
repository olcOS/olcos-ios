import CryptoKit
import Foundation

// Install side of the HTTPS server agent (gomobile/agent). Like olcos-bond, the
// app carries the agent's Go sources in the bundle and the server builds them
// once in the Go image the olcrtc install already pulls (no network, generated
// minimal go.mod). Unlike the bond — which is a podman container — the agent
// runs as a root systemd service on the host, so it can drive rootful podman
// and run the app's maintenance scripts. First install and every reinstall go
// over SSH; after that the app talks to the agent directly (AgentClient).
//
// The script prints the endpoint facts the app pins —
//   OLCOS_AGENT_PORT=, OLCOS_AGENT_CERT=, OLCOS_AGENT_PREFIX=, OLCOS_AGENT_DEVICE=
// — or OLCOS_AGENT_ERROR=<reason> with exit 0, exactly like the bond endpoint.

extension SSHRunner {

    static let agentDirectory = "/opt/olcos-agent"

    /// A fresh endpoint's port: high and random, same range as the bond.
    static func randomAgentPort() -> Int { Int.random(in: 20_000...59_999) }

    /// Agent Go sources to upload, relative to the gomobile module root. Test
    /// files are left out — the server build does not need them.
    static let agentSourceFiles = [
        "agent/config.go", "agent/auth.go", "agent/camouflage.go", "agent/certs.go",
        "agent/state.go", "agent/server.go", "agent/install.go", "agent/invites.go",
        "agent/share.go", "agent/usage.go", "agent/configlock_unix.go", "agent/configlock_windows.go",
        "agent/cmd/olcos-agent/main.go",
    ]

    /// A module of its own on the server, so the build needs no network. Same
    /// shape as the bond's generated go.mod.
    static let agentGoMod = "module github.com/openlibrecommunity/olcrtc-ios/gomobile\n\ngo 1.22\n"

    struct AgentEnsureResult: Equatable, Sendable {
        var port: Int?
        var certSHA256: String?
        var prefix: String?
        var deviceID: String?
        var error: String?
    }

    enum AgentInstallError: LocalizedError, Equatable {
        case server(String)
        case missingSources
        case badOutput

        var errorDescription: String? {
            switch self {
            case .server(let reason): return L10n.agentInstallError_fmt.formatted(reason)
            case .missingSources:     return L10n.agentInstallError_fmt.formatted(L10n.installerSourcesMissing.localized())
            case .badOutput:          return L10n.agentInstallError_fmt.formatted(L10n.agentInstallNoEndpoint.localized())
            }
        }
    }

    /// Reads the agent sources from the app bundle (or the source tree in a
    /// development build), in `agentSourceFiles` order.
    static func agentSources() throws -> [(path: String, text: String)] {
        let folder: URL? = Bundle.main.url(forResource: "agent", withExtension: nil)?.deletingLastPathComponent()
            ?? {
                let root = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()  // App/Core/
                    .deletingLastPathComponent()  // App/
                    .deletingLastPathComponent()  // project root
                    .appendingPathComponent("gomobile")
                return FileManager.default.fileExists(atPath: root.appendingPathComponent("agent").path) ? root : nil
            }()
        guard let folder else { throw AgentInstallError.missingSources }
        return try agentSourceFiles.map { path in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else {
                throw AgentInstallError.missingSources
            }
            return (path: path, text: text)
        }
    }

    /// A digest of the sources: a newer app rebuilds the server binary.
    static func agentVersion(_ sources: [(path: String, text: String)]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(agentGoMod.utf8))
        for source in sources {
            hasher.update(data: Data(source.path.utf8))
            hasher.update(data: Data(source.text.utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The status scripts the agent caches and serves. Keys match the app's
    /// existing parsers: `readiness` → parseReadiness/parseVPSStats, `carriers`
    /// → parseCarrierList, `xray` → parseXrayStatus.
    static func agentStatusScripts(baseContainer: String) -> [String: String] {
        [
            "readiness": readinessScript(containerName: baseContainer),
            "carriers":  carrierListScript(baseContainerName: baseContainer),
            "xray":      xrayStatusScript,
        ]
    }

    /// Builds the agent when its version differs, initialises it on first run
    /// (certificate, port, API prefix, this phone as owner) or re-registers the
    /// owner key and reads the existing endpoint back on a reinstall, installs
    /// the systemd unit, opens the port best-effort, and waits for it to listen.
    /// `owner` is this phone's public key as standard-base64 SPKI DER; `host` is
    /// the server address for the certificate SAN.
    static func agentEnsureScript(port: Int, version: String,
                                  sources: [(path: String, text: String)],
                                  owner: String, deviceName: String, host: String,
                                  scripts: [String: String]) -> String {
        let image = AppConstants.serverGoImage
        let D = agentDirectory
        let scriptsB64 = ((try? JSONEncoder().encode(scripts)) ?? Data("{}".utf8)).base64EncodedString()
        let name = shellSafe(deviceName.isEmpty ? "device" : deviceName)
        let safeHost = shellSafe(host)

        var lines = [
            "set -e",
            "D=\(D)",
            "command -v systemctl >/dev/null 2>&1 || { echo OLCOS_AGENT_ERROR=no_systemd; exit 0; }",
            "command -v podman >/dev/null 2>&1 || { echo OLCOS_AGENT_ERROR=no_podman; exit 0; }",
            "mkdir -p \"$D\"",
            "if [ ! -x \"$D/olcos-agent\" ] || [ \"$(cat \"$D/version\" 2>/dev/null)\" != \"\(version)\" ]; then",
            "  rm -rf \"$D/src\"",
            "  mkdir -p \"$D/src/agent/cmd/olcos-agent\" \"$D/cache\"",
            "  printf '%s' '\(Data(agentGoMod.utf8).base64EncodedString())' | base64 -d > \"$D/src/go.mod\"",
        ]
        for source in sources {
            lines.append("  printf '%s' '\(Data(source.text.utf8).base64EncodedString())' | base64 -d > \"$D/src/\(source.path)\"")
        }
        lines += [
            "  podman rm -f olcos-agent-build >/dev/null 2>&1 || true",
            "  if ! podman run --rm --name olcos-agent-build --network none -v \"$D:/work:Z\" -w /work/src "
                + "-e GOCACHE=/work/cache -e CGO_ENABLED=0 -e GOTOOLCHAIN=local \(image) "
                + "go build -trimpath -o /work/olcos-agent.new ./agent/cmd/olcos-agent >/tmp/olcos-agent-build.log 2>&1; then",
            "    echo \"OLCOS_AGENT_ERROR=build: $(tail -n 1 /tmp/olcos-agent-build.log | tr -d '\\r')\"; exit 0",
            "  fi",
            "  mv -f \"$D/olcos-agent.new\" \"$D/olcos-agent\"",
            "  echo \"\(version)\" > \"$D/version\"",
            "fi",
            // First install: generate everything and register this phone as owner.
            // Reinstall: keep the certificate/devices, just ensure the owner key
            // is present and read the endpoint back.
            "if [ ! -s \"$D/config.json\" ]; then",
            "  FACTS=$(\"$D/olcos-agent\" init -dir \"$D\" -port \(port) -host '\(safeHost)' -owner '\(owner)' -name '\(name)' 2>/tmp/olcos-agent-init.err) || "
                + "{ echo \"OLCOS_AGENT_ERROR=init: $(tail -n 1 /tmp/olcos-agent-init.err | tr -d '\\r')\"; exit 0; }",
            "else",
            "  \"$D/olcos-agent\" add-device -dir \"$D\" -key '\(owner)' -role owner -name '\(name)' >/dev/null 2>&1 || true",
            "  FACTS=$(\"$D/olcos-agent\" show -dir \"$D\" 2>/tmp/olcos-agent-show.err) || "
                + "{ echo \"OLCOS_AGENT_ERROR=show: $(tail -n 1 /tmp/olcos-agent-show.err | tr -d '\\r')\"; exit 0; }",
            "fi",
            "PORT=$(printf '%s\\n' \"$FACTS\" | sed -n 's/^OLCOS_AGENT_PORT=//p' | head -n1)",
            "[ -n \"$PORT\" ] || { echo OLCOS_AGENT_ERROR=no_port; exit 0; }",
            // Status scripts (idempotent, every run so a newer app updates them).
            "printf '%s' '\(scriptsB64)' | base64 -d > \"$D/scripts.json\"",
            "\"$D/olcos-agent\" set-scripts -dir \"$D\" -file \"$D/scripts.json\" >/dev/null 2>&1 || true",
            "rm -f \"$D/scripts.json\"",
            // systemd unit (root, always restart).
            "cat > /etc/systemd/system/olcos-agent.service <<'UNIT'",
            "[Unit]",
            "Description=olcOS server agent",
            "After=network-online.target",
            "Wants=network-online.target",
            "[Service]",
            "Type=simple",
            "ExecStart=\(D)/olcos-agent serve -dir \(D)",
            "Restart=always",
            "RestartSec=2",
            "[Install]",
            "WantedBy=multi-user.target",
            "UNIT",
            "systemctl daemon-reload >/dev/null 2>&1 || true",
            "systemctl enable olcos-agent >/dev/null 2>&1 || true",
            "systemctl restart olcos-agent >/dev/null 2>&1 || { echo \"OLCOS_AGENT_ERROR=service: $(systemctl is-active olcos-agent 2>&1 | tr -d '\\r')\"; exit 0; }",
            // Open the port best-effort (whitelist windows cut direct traffic anyway).
            "if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then ufw allow \"$PORT\"/tcp >/dev/null 2>&1 || true; fi",
            "if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --add-port=\"$PORT\"/tcp >/dev/null 2>&1 || true; firewall-cmd --permanent --add-port=\"$PORT\"/tcp >/dev/null 2>&1 || true; fi",
            // Readiness: wait for the port to listen (ss/netstat), else accept an active service.
            "LISTEN=\"\"",
            "for i in $(seq 1 15); do",
            "  if ss -ltnH 2>/dev/null | grep -q \":$PORT \" || netstat -ltn 2>/dev/null | grep -q \":$PORT \"; then LISTEN=1; break; fi",
            "  sleep 1",
            "done",
            "if [ -z \"$LISTEN\" ]; then if systemctl is-active --quiet olcos-agent; then LISTEN=1; fi; fi",
            "[ -n \"$LISTEN\" ] || { echo \"OLCOS_AGENT_ERROR=not_listening: $(systemctl is-active olcos-agent 2>&1 | tr -d '\\r')\"; exit 0; }",
            // Success: hand the endpoint facts back to the app.
            "printf '%s\\n' \"$FACTS\"",
        ]
        return lines.joined(separator: "\n")
    }

    /// Remove the agent (uninstall / deep uninstall).
    static let agentUninstallLines = """
    systemctl disable --now olcos-agent >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/olcos-agent.service 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    podman rm -f olcos-agent-build >/dev/null 2>&1 || true
    rm -rf \(agentDirectory) 2>/dev/null || true
    """

    // MARK: Pairing codes for invited devices

    struct AgentInviteResult: Equatable, Sendable {
        var code: String
        var role: String
        var expires: Int64?
    }

    /// Mints a one-time pairing code on the installed agent (`olcos-agent
    /// invite`); the code rides in the invited device's encrypted list.
    static func agentInviteScript(role: String, name: String, days: Int = 30) -> String {
        let D = agentDirectory
        let safeRole = role == "owner" ? "owner" : "member"
        let safeName = shellSafe(name.isEmpty ? "device" : name)
        return """
        set -e
        [ -x \(D)/olcos-agent ] && [ -s \(D)/config.json ] || { echo OLCOS_AGENT_ERROR=not_installed; exit 0; }
        \(D)/olcos-agent invite -dir \(D) -role \(safeRole) -name '\(safeName)' -days \(max(1, days)) 2>/tmp/olcos-agent-invite.err || { echo "OLCOS_AGENT_ERROR=invite: $(tail -n 1 /tmp/olcos-agent-invite.err | tr -d '\\r')"; exit 0; }
        """
    }

    static func parseAgentInvite(_ output: String) throws -> AgentInviteResult {
        var code: String?
        var role = "member"
        var expires: Int64?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = value(line, "OLCOS_AGENT_INVITE=") { code = v }
            else if let v = value(line, "OLCOS_AGENT_INVITE_ROLE=") { role = v }
            else if let v = value(line, "OLCOS_AGENT_INVITE_EXPIRES=") { expires = Int64(v) }
            else if let v = value(line, "OLCOS_AGENT_ERROR=") { throw AgentInstallError.server(v.isEmpty ? "unknown" : v) }
        }
        guard let code, !code.isEmpty else { throw AgentInstallError.badOutput }
        return AgentInviteResult(code: code, role: role, expires: expires)
    }

    /// Burns a pairing code and revokes the device that redeemed it, when the
    /// owner revokes the device invite that carried it. Best effort: a missing
    /// agent is not an error (the invite's list is already gone).
    static func agentRevokeInviteScript(code: String) -> String {
        let D = agentDirectory
        let safeCode = shellSafe(code)
        return """
        [ -x \(D)/olcos-agent ] && [ -s \(D)/config.json ] || { echo OLCOS_AGENT_REVOKED=-; exit 0; }
        \(D)/olcos-agent revoke-invite -dir \(D) -code '\(safeCode)' 2>/dev/null || echo OLCOS_AGENT_REVOKED=-
        """
    }

    static func agentRevokeInvite(host: ServerHost, secret: SSHSecret, code: String) async throws -> String {
        let output = try await _withConnection(host: host, secret: secret) { client in
            try await _execute(client: client, label: "agent revoke",
                               command: agentRevokeInviteScript(code: code))
        }
        for raw in output.split(whereSeparator: \.isNewline) {
            if let v = value(raw.trimmingCharacters(in: .whitespaces), "OLCOS_AGENT_REVOKED=") { return v }
        }
        return "-"
    }

    static func agentInvite(host: ServerHost, secret: SSHSecret, role: String, name: String) async throws -> AgentInviteResult {
        let output = try await _withConnection(host: host, secret: secret) { client in
            try await _execute(client: client, label: "agent invite",
                               command: agentInviteScript(role: role, name: name))
        }
        return try parseAgentInvite(output)
    }

    static func parseAgentEnsure(_ output: String) -> AgentEnsureResult {
        var result = AgentEnsureResult()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = value(line, "OLCOS_AGENT_PORT=") { result.port = Int(v) }
            else if let v = value(line, "OLCOS_AGENT_CERT=") { result.certSHA256 = v }
            else if let v = value(line, "OLCOS_AGENT_PREFIX=") { result.prefix = v }
            else if let v = value(line, "OLCOS_AGENT_DEVICE=") { result.deviceID = v }
            else if let v = value(line, "OLCOS_AGENT_ERROR=") { result.error = v.isEmpty ? "unknown" : v }
        }
        return result
    }

    private static func value(_ line: String, _ key: String) -> String? {
        line.hasPrefix(key) ? String(line.dropFirst(key.count)) : nil
    }
}
