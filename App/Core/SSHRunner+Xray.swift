import Foundation

// Server side of the Xray (VLESS · REALITY) protocol: install or adopt, read
// status, remove. The installer is olcos-core's server/xray/install.sh,
// bundled with the app (project.yml: the olcos-core/server folder) and
// uploaded over the same base64-printf channel as add-carrier.sh. It prints
// KEY=VALUE lines (OLCOS_XRAY_*) and reports a failure as
// OLCOS_XRAY_ERROR=<reason>; an existing olcos-xray-* deployment is adopted
// rather than a second one installed beside it.

/// What the user may override on an Xray install; empty means automatic.
struct XrayInstallOptions: Equatable, Sendable {
    /// REALITY camouflage site, e.g. "www.example.com"; "" = the server picks
    /// the first candidate that passes its checks.
    var target = ""
    /// Listen port as typed; "" = 443.
    var port = ""

    var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPort: String { port.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A bare host name: letters, digits, dots and dashes, with a dot inside.
    var isTargetValid: Bool {
        let t = trimmedTarget
        if t.isEmpty { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return t.contains(".") && !t.hasPrefix(".") && !t.hasSuffix(".")
            && t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var isPortValid: Bool {
        let p = trimmedPort
        if p.isEmpty { return true }
        guard let n = Int(p) else { return false }
        return (1...65535).contains(n)
    }

    var isValid: Bool { isTargetValid && isPortValid }
}

extension SSHRunner {

    struct XrayInstallResult: Equatable, Sendable {
        let uri: String
        let containerName: String
        /// "host:443" the server camouflages as.
        let target: String
        /// The server already ran this deployment; nothing was installed.
        let adopted: Bool
    }

    /// One olcos-xray-* container on a host.
    struct XrayDeployment: Equatable, Sendable, Identifiable {
        let containerName: String
        let status: ContainerStatus
        var id: String { containerName }
    }

    enum XrayInstallError: LocalizedError, Equatable {
        /// The installer's own reason (OLCOS_XRAY_ERROR), or the tail of its log.
        case server(String)

        var errorDescription: String? {
            switch self {
            case .server(let reason): return L10n.xrayInstallFailed_fmt.formatted(reason)
            }
        }
    }

    static let xrayContainerPrefix = "olcos-xray-"
    static let xrayInstallRemotePath = "/tmp/olcos-xray-install.sh"

    /// olcos-core's installer from the app bundle, or from the source tree for
    /// simulator and development builds.
    static func loadXrayInstallScript() throws -> String {
        let url: URL? = Bundle.main.url(forResource: "install", withExtension: "sh",
                                        subdirectory: "server/xray")
            ?? {
                let root = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()   // App/Core/
                    .deletingLastPathComponent()   // App/
                    .deletingLastPathComponent()   // project root
                let candidate = root.appendingPathComponent("olcos-core/server/xray/install.sh")
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }()
        guard let url, let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProvisionError.parseFailed(
                "server/xray/install.sh not found — rebuild the app (xcodegen + clean build)")
        }
        return script
    }

    /// Runs the uploaded installer and always exits 0, so the script's own
    /// OLCOS_XRAY_ERROR line reaches the app instead of a bare exit status.
    /// The link uses the address the user reaches the server by.
    static func xrayInstallCommand(host: ServerHost, options: XrayInstallOptions) -> String {
        var env = ["OLCOS_XRAY_HOST=\(shellSafe(host.host))"]
        if !options.trimmedTarget.isEmpty, options.isTargetValid {
            env.append("OLCOS_XRAY_TARGET=\(shellSafe(options.trimmedTarget))")
        }
        if !options.trimmedPort.isEmpty, options.isPortValid {
            env.append("OLCOS_XRAY_PORT=\(shellSafe(options.trimmedPort))")
        }
        return env.joined(separator: " ") + " bash \(xrayInstallRemotePath); echo \"OLCOS_XRAY_EXIT=$?\""
    }

    static func xrayInstall(host: ServerHost, secret: SSHSecret, options: XrayInstallOptions,
                            onStep: @Sendable @escaping (String) -> Void) async throws -> XrayInstallResult {
        let script = try loadXrayInstallScript()
        let b64 = Data(script.utf8).base64EncodedString()
        onStep(L10n.provisioningXrayInstalling.localized())
        let output = try await _withConnection(host: host, secret: secret) { client in
            _ = try await _execute(client: client, label: "upload xray install.sh",
                                   command: "printf '%s' '\(b64)' | base64 -d > \(xrayInstallRemotePath)")
            return try await _execute(client: client, label: "xray install",
                                      command: xrayInstallCommand(host: host, options: options))
        }
        return try parseXrayInstall(output)
    }

    static func parseXrayInstall(_ output: String) throws -> XrayInstallResult {
        let values = extract(keys: ["OLCOS_XRAY_URI", "OLCOS_XRAY_CONTAINER", "OLCOS_XRAY_TARGET",
                                    "OLCOS_XRAY_ADOPTED", "OLCOS_XRAY_ERROR"], from: output)
        if let reason = values["OLCOS_XRAY_ERROR"], !reason.isEmpty {
            throw XrayInstallError.server(reason)
        }
        guard let uri = values["OLCOS_XRAY_URI"], XrayURI.matches(uri),
              let container = values["OLCOS_XRAY_CONTAINER"],
              isXrayContainerName(container) else {
            // No result and no reason: the last lines say the most.
            let tail = output.split(separator: "\n").suffix(3).joined(separator: " ")
            throw XrayInstallError.server(tail.isEmpty ? "no output" : String(tail.prefix(300)))
        }
        return XrayInstallResult(uri: uri, containerName: container,
                                 target: values["OLCOS_XRAY_TARGET"] ?? "",
                                 adopted: values["OLCOS_XRAY_ADOPTED"] == "1")
    }

    /// One `XRAY=<name>\t<status>` line per olcos-xray-* container.
    static let xrayStatusScript = """
    podman ps -a --filter 'name=olcos-xray-' --format 'XRAY={{.Names}}\t{{.Status}}' 2>/dev/null || true
    """

    static func parseXrayStatus(_ output: String) -> [XrayDeployment] {
        output.split(separator: "\n").compactMap { raw -> XrayDeployment? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("XRAY=") else { return nil }
            let fields = line.dropFirst("XRAY=".count)
                .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(fields[0])
            guard isXrayContainerName(name) else { return nil }
            let status = fields.count > 1 ? String(fields[1]) : ""
            return XrayDeployment(containerName: name, status: ContainerStatus.parse(from: status))
        }
    }

    /// `olcos-xray-<id>` with the id install.sh generates: lowercase letters
    /// and digits only — the name also becomes a path under /opt.
    static func isXrayContainerName(_ name: String) -> Bool {
        guard name.hasPrefix(xrayContainerPrefix) else { return false }
        let id = name.dropFirst(xrayContainerPrefix.count)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return !id.isEmpty && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Removes one deployment: the container and its directory, keys included,
    /// so the link stops working — the confirmation says so.
    static func xrayRemoveScript(containerName: String) -> String {
        guard isXrayContainerName(containerName) else {
            return "echo 'ERROR: not an olcOS Xray container' >&2; exit 1"
        }
        return """
        podman rm -f '\(containerName)' >/dev/null 2>&1 || true
        rm -rf '/opt/\(containerName)'
        echo OLCOS_XRAY_REMOVED=ok
        """
    }

    /// The Xray part of "Remove all protocols" (uninstall and deep uninstall).
    static let xrayUninstallLines = """
    for c in $(podman ps -a --format '{{.Names}}' | grep '^olcos-xray-' 2>/dev/null); do podman rm -f "$c" >/dev/null 2>&1; done
    rm -rf /opt/olcos-xray-* 2>/dev/null || true
    """
}
