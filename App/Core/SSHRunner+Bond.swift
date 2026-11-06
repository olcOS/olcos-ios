import CryptoKit
import Foundation

// Server side of bonding (gomobile/bond, the whole-server connection): the
// olcos-bond program in its own container on the host network. The lanes'
// olcrtc exits on this server dial its public address, so one port carries
// every lane back together; it answers only hellos signed with the server's
// tunnel key (~/.olcrtc_key, mounted read-only, re-read per hello so a rotated
// key needs no restart) and only from this machine.
//
// The app carries the Go sources (the gomobile/bond folder in the bundle) and
// the server builds them once in the Go image the olcrtc install already
// uses; a newer app rebuilds when its sources differ (`bondVersion`). The
// script prints OLCOS_BOND_PORT, or OLCOS_BOND_ERROR=<reason> with exit 0
// like the invite server.

extension SSHRunner {

    static let bondContainerName = "olcos-bond"
    static let bondDirectory = "/opt/olcos-bond"

    /// The files the server needs, relative to the module root. The client
    /// half of the package stays in the app.
    static let bondSourceFiles = ["bond/protocol.go", "bond/stripe.go", "bond/server.go",
                                  "bond/cmd/olcos-bond/main.go"]

    /// A module of its own on the server, so the build needs no network.
    static let bondGoMod = "module github.com/openlibrecommunity/olcrtc-ios/gomobile\n\ngo 1.22\n"

    /// A new endpoint's port: high and random, like the invite server's.
    static func randomBondPort() -> Int { Int.random(in: 20_000...59_999) }

    struct BondResult: Equatable, Sendable {
        var port: Int?
        var error: String?
    }

    enum BondError: LocalizedError, Equatable {
        case server(String)
        case missingSources

        var errorDescription: String? {
            switch self {
            case .server(let reason): return L10n.bondErrorServer_fmt.formatted(reason)
            case .missingSources:     return L10n.bondErrorServer_fmt.formatted(L10n.installerSourcesMissing.localized())
            }
        }
    }

    /// The sources from the app bundle (or the source tree in a development
    /// build), in `bondSourceFiles` order.
    static func bondSources() throws -> [(path: String, text: String)] {
        let folder: URL? = Bundle.main.url(forResource: "bond", withExtension: nil)?.deletingLastPathComponent()
            ?? {
                let root = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()  // App/Core/
                    .deletingLastPathComponent()  // App/
                    .deletingLastPathComponent()  // project root
                    .appendingPathComponent("gomobile")
                return FileManager.default.fileExists(atPath: root.appendingPathComponent("bond").path) ? root : nil
            }()
        guard let folder else { throw BondError.missingSources }
        return try bondSourceFiles.map { path in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else {
                throw BondError.missingSources
            }
            return (path: path, text: text)
        }
    }

    /// What the server should run: a digest of the sources.
    static func bondVersion(_ sources: [(path: String, text: String)]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(bondGoMod.utf8))
        for source in sources {
            hasher.update(data: Data(source.path.utf8))
            hasher.update(data: Data(source.text.utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the endpoint when its version differs, starts it on `port` when
    /// it is not running (an existing one keeps its own), and waits for it to
    /// listen.
    static func bondEnsureScript(port: Int, version: String,
                                 sources: [(path: String, text: String)], dns: String) -> String {
        let image = AppConstants.serverGoImage
        var lines = [
            "set -e",
            "D=\(bondDirectory)",
            "KEY=\"$HOME/.olcrtc_key\"",
            "if [ ! -s \"$KEY\" ]; then echo OLCOS_BOND_ERROR=no_key; exit 0; fi",
            "mkdir -p \"$D\"",
            "if [ ! -x \"$D/olcos-bond\" ] || [ \"$(cat \"$D/version\" 2>/dev/null)\" != \"\(version)\" ]; then",
            "  rm -rf \"$D/src\"",
            "  mkdir -p \"$D/src/bond/cmd/olcos-bond\" \"$D/cache\"",
            "  printf '%s' '\(Data(bondGoMod.utf8).base64EncodedString())' | base64 -d > \"$D/src/go.mod\"",
        ]
        for source in sources {
            lines.append("  printf '%s' '\(Data(source.text.utf8).base64EncodedString())' | base64 -d > \"$D/src/\(source.path)\"")
        }
        lines += [
            "  podman rm -f olcos-bond-build >/dev/null 2>&1 || true",
            "  if ! podman run --rm --name olcos-bond-build --network none -v \"$D:/work:Z\" -w /work/src "
                + "-e GOCACHE=/work/cache -e CGO_ENABLED=0 -e GOTOOLCHAIN=local \(image) "
                + "go build -trimpath -o /work/olcos-bond.new ./bond/cmd/olcos-bond >/tmp/olcos-bond-build.log 2>&1; then",
            "    echo \"OLCOS_BOND_ERROR=build: $(tail -n 1 /tmp/olcos-bond-build.log | tr -d '\\r')\"; exit 0",
            "  fi",
            "  mv -f \"$D/olcos-bond.new\" \"$D/olcos-bond\"",
            "  echo \"\(version)\" > \"$D/version\"",
            "  podman rm -f \(bondContainerName) >/dev/null 2>&1 || true",
            "fi",
            "PORT=$(cat \"$D/port\" 2>/dev/null || true)",
            "[ -n \"$PORT\" ] || PORT=\(port)",
            "if ! podman container exists \(bondContainerName) 2>/dev/null; then",
            "  if ! podman run -d --name \(bondContainerName) --restart=always --network host "
                + "-v \"$D:/app:ro,Z\" -v \"$KEY:/key:ro,Z\" \(image) "
                + "/app/olcos-bond -listen \":$PORT\" -key /key -dns \"\(shellSafe(dns))\" >/dev/null 2>/tmp/olcos-bond.err; then",
            "    echo \"OLCOS_BOND_ERROR=$(tail -n 1 /tmp/olcos-bond.err | tr -d '\\r')\"; exit 0",
            "  fi",
            "  echo \"$PORT\" > \"$D/port\"",
            "else",
            "  podman start \(bondContainerName) >/dev/null 2>&1 || true",
            "fi",
            "for i in 1 2 3 4 5 6 7 8 9 10; do",
            "  if podman logs \(bondContainerName) 2>&1 | grep -q 'bond: listening'; then echo \"OLCOS_BOND_PORT=$PORT\"; exit 0; fi",
            "  sleep 1",
            "done",
            "if podman logs \(bondContainerName) 2>&1 | grep -qi 'address already in use'; then",
            "  podman rm -f \(bondContainerName) >/dev/null 2>&1 || true",
            "  rm -f \"$D/port\"",
            "  echo OLCOS_BOND_ERROR=port_busy; exit 0",
            "fi",
            "echo \"OLCOS_BOND_ERROR=$(podman logs --tail 1 \(bondContainerName) 2>&1 | tr -d '\\r')\"",
        ]
        return lines.joined(separator: "\n")
    }

    /// Uninstall and deep uninstall take the endpoint with the protocols: it
    /// mounts the key they delete.
    static let bondUninstallLines = """
    podman rm -f \(bondContainerName) >/dev/null 2>&1 || true
    rm -rf \(bondDirectory) 2>/dev/null || true
    """

    static func parseBondOutput(_ output: String) -> BondResult {
        var result = BondResult()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("OLCOS_BOND_PORT=") {
                result.port = Int(line.dropFirst("OLCOS_BOND_PORT=".count))
            } else if line.hasPrefix("OLCOS_BOND_ERROR=") {
                let reason = String(line.dropFirst("OLCOS_BOND_ERROR=".count))
                result.error = reason.isEmpty ? "unknown" : reason
            }
        }
        return result
    }

    /// Makes sure the host runs the endpoint of this app's version; its port
    /// and version. A busy port is retried with another one.
    static func ensureBond(host: ServerHost, secret: SSHSecret) async throws -> (port: Int, version: String) {
        let sources = try bondSources()
        let version = bondVersion(sources)
        let dns = DNSChoice.forServer(SettingsStore.shared.dnsServer)
        var port = host.bondPort ?? randomBondPort()
        for attempt in 1...3 {
            let script = bondEnsureScript(port: port, version: version, sources: sources, dns: dns)
            let output = try await _withConnection(host: host, secret: secret) { client in
                try await _execute(client: client, label: "bond endpoint", command: script)
            }
            let result = parseBondOutput(output)
            if result.error == "port_busy", attempt < 3 {
                port = randomBondPort()
                continue
            }
            if let error = result.error { throw BondError.server(error) }
            guard let bound = result.port else { throw BondError.server("no port") }
            return (bound, version)
        }
        throw BondError.server("port_busy")
    }
}
