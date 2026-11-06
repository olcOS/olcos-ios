import Foundation
@preconcurrency import Citadel

// MARK: - Jitsi instance probe
//
// Public Jitsi servers come and go, and many block foreign addresses: on
// 2026-10-09, six of the fifteen in the list did not answer from an NL VPS at
// all, including the app's old default. The olcrtc server joins a Jitsi room
// over the XMPP WebSocket, so the add-server wizard asks the VPS itself which
// candidates work before it installs: each must serve its config.js, accept
// the WebSocket handshake for /xmpp-websocket (101 Switching Protocols — a
// site that answers 404 there has no WebSocket endpoint) and let guests in
// (no secure-domain guest login, no token auth). Read-only, all hosts in
// parallel, ~10 s in total.

struct JitsiProbe: Equatable, Sendable {
    enum Access: String, Sendable {
        case open
        /// config.js names an `anonymousdomain`: guests may join a room only
        /// after someone authenticated created it, and the olcrtc server is the
        /// one creating it.
        case guestDomain = "guest-domain"
        /// config.js names a `tokenAuthUrl`: every participant needs a JWT.
        case token
    }

    let host: String
    /// HTTP status of https://<host>/config.js (0 = no answer).
    let configStatus: Int
    /// HTTP status of the WebSocket handshake on /xmpp-websocket.
    let websocketStatus: Int
    let access: Access

    var isUsable: Bool { configStatus == 200 && websocketStatus == 101 && access == .open }
}

extension SSHRunner {

    /// A host is passed to the shell only if it is a plain DNS name.
    static func isProbeableJitsiHost(_ host: String) -> Bool {
        host.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#,
                   options: .regularExpression) != nil
    }

    /// Prints `OLCOS_JITSI <host> <config status> <websocket status> <access>`
    /// per host and `OLCOS_JITSI_DONE` at the end, or `OLCOS_JITSI_ERROR=curl`
    /// when the VPS has no curl. Always exits 0.
    static func jitsiProbeScript(hosts: [String]) -> String {
        let list = hosts.filter(isProbeableJitsiHost).joined(separator: " ")
        return #"""
        command -v curl >/dev/null 2>&1 || { echo "OLCOS_JITSI_ERROR=curl"; exit 0; }
        probe() {
          h=$1
          tmp=$(mktemp)
          cfg=$(curl -s -m 6 -o "$tmp" -w '%{http_code}' "https://$h/config.js" 2>/dev/null)
          ws=$(curl -s -o /dev/null -m 6 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
            -H 'Sec-WebSocket-Protocol: xmpp' -H "Origin: https://$h" \
            -w '%{http_code}' "https://$h/xmpp-websocket" 2>/dev/null)
          access=open
          grep -Eq '^[[:space:]]*anonymousdomain[[:space:]]*:' "$tmp" && access=guest-domain
          grep -Eq '^[[:space:]]*tokenAuthUrl[[:space:]]*:' "$tmp" && access=token
          rm -f "$tmp"
          echo "OLCOS_JITSI $h ${cfg:-0} ${ws:-0} $access"
        }
        for h in \#(list); do probe "$h" & done
        wait
        echo "OLCOS_JITSI_DONE"
        exit 0
        """#
    }

    static func parseJitsiProbes(_ output: String) -> [JitsiProbe] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 5, parts[0] == "OLCOS_JITSI",
                  let config = Int(parts[2]), let websocket = Int(parts[3]),
                  let access = JitsiProbe.Access(rawValue: parts[4]) else { return nil }
            return JitsiProbe(host: parts[1], configStatus: config,
                              websocketStatus: websocket, access: access)
        }
    }

    /// The first usable host in the caller's order of preference.
    static func bestJitsiHost(_ probes: [JitsiProbe], order: [String]) -> String? {
        let usable = Set(probes.filter(\.isUsable).map(\.host))
        return order.first { usable.contains($0) }
    }

    /// Runs the probe on the VPS over one SSH session.
    static func probeJitsi(host: ServerHost, secret: SSHSecret,
                           candidates: [String]) async throws -> [JitsiProbe] {
        let output = try await _withConnection(host: host, secret: secret) { client in
            try await _execute(client: client, label: "jitsi probe",
                               command: jitsiProbeScript(hosts: candidates))
        }
        if output.contains("OLCOS_JITSI_ERROR=curl") {
            throw ProvisionError.parseFailed(L10n.addFlowJitsiNoCurl.localized())
        }
        return parseJitsiProbes(output)
    }
}

// MARK: - Real tunnel check
//
// Passing the probe does not mean data flows: on 2026-10-09 meet.mamba.group,
// meet.mirox.chat and m.catonmoon.com let both sides in and carried nothing.
// Once a server is installed, its own core binary settles it: a throwaway
// server and client of that binary meet in a fresh room on the instance, with
// a fresh key, and the client fetches through its SOCKS port. The running
// containers are not touched; the two processes and their temp directory are
// gone when the check ends. Each check runs two core processes (~40 MB each),
// so at most three run at once.

struct JitsiTunnelCheck: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// A 2 MB download came through, at this many bytes per second.
        case works(bytesPerSecond: Int)
        /// The first request came through, the 2 MB download did not finish.
        case stalls
        /// Both sides joined the room and nothing came through.
        case noData
        /// No config.js or no WebSocket endpoint from the server.
        case unreachable
        /// Guests need an account or a token.
        case needsLogin
        /// The probe passed, but the server could not run a tunnel check
        /// (no core binary, no curl, or the test port was taken).
        case answers

        var works: Bool {
            if case .works = self { return true }
            return false
        }
    }

    let host: String
    let verdict: Verdict
}

extension SSHRunner {

    static let jitsiTunnelCheckBasePort = 18870
    static let jitsiTunnelCheckParallel = 3

    /// One throwaway server and client of the installed core in a fresh room on
    /// `instance`. Prints `OLCOS_JITSI_TUNNEL <host> works <bytes/s>`, `... stalls 0`
    /// or `... nodata 0`, or an `OLCOS_JITSI_TUNNEL_ERROR=` line when it cannot
    /// run. Always exits 0. Any container of the install will do: they all mount
    /// the same deploy directory.
    static func jitsiTunnelScript(containerName: String, instance: String,
                                  transport: String, port: Int) -> String {
        let cname = shellSafe(containerName)
        let host = isProbeableJitsiHost(instance) ? instance : ""
        let transport = shellSafe(transport)
        return #"""
        H="\#(host)"
        PORT=\#(port)
        [ -n "$H" ] || { echo "OLCOS_JITSI_TUNNEL_ERROR=host"; exit 0; }
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "\#(cname)" 2>/dev/null)
        BIN="$DEPLOY_DIR/olcrtc"
        { [ -n "$DEPLOY_DIR" ] && [ -x "$BIN" ]; } || { echo "OLCOS_JITSI_TUNNEL_ERROR=binary"; exit 0; }
        command -v curl >/dev/null 2>&1 || { echo "OLCOS_JITSI_TUNNEL_ERROR=curl"; exit 0; }
        if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q .; then
            echo "OLCOS_JITSI_TUNNEL_ERROR=port"; exit 0
        fi
        DNS=$(sed -n 's/^  dns: "\(.*\)"$/\1/p' "$DEPLOY_DIR/server.yaml" 2>/dev/null | head -1)
        [ -n "$DNS" ] || DNS="1.1.1.1:53"
        hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
        D=$(mktemp -d /tmp/olcos-jitsi-check-XXXXXX)
        KEY=$(hex 32)
        ROOM="https://$H/olcos-check-$(hex 6)"
        for ROLE in srv cnc; do
          {
            echo "mode: $ROLE"
            echo "auth:"; echo "  provider: \"jitsi\""
            echo "room:"; echo "  id: \"$ROOM\""
            echo "crypto:"; echo "  key: \"$KEY\""
            echo "net:"; echo "  transport: \"\#(transport)\""; echo "  dns: \"$DNS\""
            if [ "$ROLE" = cnc ]; then
              echo "socks:"; echo "  host: \"127.0.0.1\""; echo "  port: $PORT"; echo "  user: \"\""; echo "  pass: \"\""
            fi
            echo "debug: false"
          } > "$D/$ROLE.yaml"
        done
        "$BIN" "$D/srv.yaml" >/dev/null 2>&1 & SPID=$!
        sleep 6
        "$BIN" "$D/cnc.yaml" >/dev/null 2>&1 & CPID=$!
        VERDICT=nodata; SPEED=0
        i=0
        while [ $i -lt 6 ]; do
          i=$((i + 1)); sleep 4
          kill -0 $CPID 2>/dev/null || break
          if curl -s -m 8 --socks5-hostname "127.0.0.1:$PORT" -o /dev/null "https://speed.cloudflare.com/__down?bytes=1000"; then
            VERDICT=stalls
            S=$(curl -s -m 30 --socks5-hostname "127.0.0.1:$PORT" -o /dev/null -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=2000000") && { VERDICT=works; SPEED=${S%.*}; }
            break
          fi
        done
        kill $CPID $SPID 2>/dev/null; sleep 1; kill -9 $CPID $SPID 2>/dev/null
        rm -rf "$D"
        echo "OLCOS_JITSI_TUNNEL $H $VERDICT ${SPEED:-0}"
        exit 0
        """#
    }

    /// PURE. The verdict `jitsiTunnelScript` printed for `host`; nil when the
    /// script could not run the check.
    static func parseJitsiTunnel(_ output: String, host: String) -> JitsiTunnelCheck.Verdict? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 4, parts[0] == "OLCOS_JITSI_TUNNEL", parts[1] == host else { continue }
            switch parts[2] {
            case "works":  return .works(bytesPerSecond: Int(parts[3]) ?? 0)
            case "stalls": return .stalls
            case "nodata": return .noData
            default:       return nil
            }
        }
        return nil
    }

    /// PURE. What the quick probe alone says about a host; nil when it passed
    /// and only a tunnel check can tell more.
    static func probeVerdict(_ probe: JitsiProbe?) -> JitsiTunnelCheck.Verdict? {
        guard let probe else { return .unreachable }
        if probe.isUsable { return nil }
        if probe.configStatus == 200, probe.websocketStatus == 101 { return .needsLogin }
        return .unreachable
    }

    /// Probes every candidate from the server, then runs a tunnel check on each
    /// one that passed, in `candidates` order, three at a time. Every verdict is
    /// handed to `onResult` as soon as it is known. One SSH connection.
    static func checkJitsiInstances(host: ServerHost, secret: SSHSecret, containerName: String,
                                    candidates: [String], transport: String,
                                    onResult: @escaping @MainActor (JitsiTunnelCheck) -> Void) async throws {
        try await _withConnection(host: host, secret: secret) { client in
            let output = try await _execute(client: client, label: "jitsi probe",
                                            command: jitsiProbeScript(hosts: candidates))
            if output.contains("OLCOS_JITSI_ERROR=curl") {
                throw ProvisionError.parseFailed(L10n.addFlowJitsiNoCurl.localized())
            }
            let probes = parseJitsiProbes(output)
            var passed: [String] = []
            for candidate in candidates {
                if let verdict = probeVerdict(probes.first { $0.host == candidate }) {
                    await onResult(JitsiTunnelCheck(host: candidate, verdict: verdict))
                } else {
                    passed.append(candidate)
                }
            }
            try await withThrowingTaskGroup(of: JitsiTunnelCheck.self) { group in
                var next = 0
                while next < min(jitsiTunnelCheckParallel, passed.count) {
                    let (instance, port) = (passed[next], jitsiTunnelCheckBasePort + next)
                    group.addTask {
                        try await Self.tunnelCheck(client: client, containerName: containerName,
                                                   instance: instance, transport: transport, port: port)
                    }
                    next += 1
                }
                while let result = try await group.next() {
                    await onResult(result)
                    if next < passed.count {
                        let (instance, port) = (passed[next], jitsiTunnelCheckBasePort + next)
                        group.addTask {
                            try await Self.tunnelCheck(client: client, containerName: containerName,
                                                       instance: instance, transport: transport, port: port)
                        }
                        next += 1
                    }
                }
            }
        }
    }

    private static func tunnelCheck(client: ServerLink, containerName: String, instance: String,
                                    transport: String, port: Int) async throws -> JitsiTunnelCheck {
        let output = try await _execute(client: client, label: "jitsi tunnel check \(instance)",
                                        command: jitsiTunnelScript(containerName: containerName,
                                                                   instance: instance,
                                                                   transport: transport, port: port))
        return JitsiTunnelCheck(host: instance, verdict: parseJitsiTunnel(output, host: instance) ?? .answers)
    }
}
