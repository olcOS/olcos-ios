import XCTest
@testable import olcrtc_ios

// Tests for the agent install script builder and its output parser
// (App/Core/SSHRunner+Agent.swift). The script is built as a pure string, so
// its shape is unit-testable without a server; the SSH round trip is
// integration-only.

final class SSHRunnerAgentTests: XCTestCase {

    private func sampleSources() -> [(path: String, text: String)] {
        SSHRunner.agentSourceFiles.map { (path: $0, text: "package agent // \($0)") }
    }

    func testEnsureScriptShape() {
        let script = SSHRunner.agentEnsureScript(
            port: 28431, version: "deadbeef", sources: sampleSources(),
            owner: "QUJDREVG", deviceName: "iPhone", host: "198.51.100.10",
            scripts: ["readiness": "echo PODMAN=yes", "carriers": "echo none", "xray": "echo x"])

        // Built in a network-less container, as a static binary.
        XCTAssertTrue(script.contains("--network none"))
        XCTAssertTrue(script.contains("CGO_ENABLED=0"))
        XCTAssertTrue(script.contains("go build -trimpath -o /work/olcos-agent.new ./agent/cmd/olcos-agent"))
        // systemd unit written and (re)started.
        XCTAssertTrue(script.contains("/etc/systemd/system/olcos-agent.service"))
        XCTAssertTrue(script.contains("ExecStart=/opt/olcos-agent/olcos-agent serve -dir /opt/olcos-agent"))
        XCTAssertTrue(script.contains("systemctl restart olcos-agent"))
        // first-run init vs reinstall; owner key registered; scripts set.
        XCTAssertTrue(script.contains("olcos-agent\" init -dir"))
        XCTAssertTrue(script.contains("add-device -dir \"$D\" -key 'QUJDREVG' -role owner"))
        XCTAssertTrue(script.contains("set-scripts -dir \"$D\" -file"))
        // owner key passed single-quoted (base64 can carry + / =).
        XCTAssertTrue(script.contains("-owner 'QUJDREVG'"))
        // every source file is materialised under src/ with its path.
        for file in SSHRunner.agentSourceFiles {
            XCTAssertTrue(script.contains("> \"$D/src/\(file)\""), "missing source write for \(file)")
        }
        // environment guards and the firewall opening.
        XCTAssertTrue(script.contains("OLCOS_AGENT_ERROR=no_systemd"))
        XCTAssertTrue(script.contains("ufw allow"))
        XCTAssertTrue(script.contains("firewall-cmd"))
    }

    func testParseSuccess() {
        let out = """
        OLCOS_AGENT_PORT=28431
        OLCOS_AGENT_CERT=e63fedd514815e83377509880430ce9bde1673ac8ba4e84f6773a3349425a441
        OLCOS_AGENT_PREFIX=eiteEIkCFQLLMiMKctJEjA
        OLCOS_AGENT_DEVICE=MK8epPHXaye6NMgk
        """
        let r = SSHRunner.parseAgentEnsure(out)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.port, 28431)
        XCTAssertEqual(r.certSHA256, "e63fedd514815e83377509880430ce9bde1673ac8ba4e84f6773a3349425a441")
        XCTAssertEqual(r.prefix, "eiteEIkCFQLLMiMKctJEjA")
        XCTAssertEqual(r.deviceID, "MK8epPHXaye6NMgk")
    }

    func testParseError() {
        let r = SSHRunner.parseAgentEnsure("OLCOS_AGENT_ERROR=build: undefined: foo\n")
        XCTAssertEqual(r.error, "build: undefined: foo")
        XCTAssertNil(r.port)
    }

    func testParseEmptyErrorBecomesUnknown() {
        let r = SSHRunner.parseAgentEnsure("OLCOS_AGENT_ERROR=\n")
        XCTAssertEqual(r.error, "unknown")
    }

    func testStatusScriptsHaveThreeNames() {
        let scripts = SSHRunner.agentStatusScripts(baseContainer: "olcrtc-server-abcd1234")
        XCTAssertEqual(Set(scripts.keys), ["readiness", "carriers", "xray"])
        for (_, body) in scripts { XCTAssertFalse(body.isEmpty) }
    }

    func testVersionChangesWithSource() {
        let a = SSHRunner.agentVersion([(path: "agent/x.go", text: "one")])
        let b = SSHRunner.agentVersion([(path: "agent/x.go", text: "two")])
        let a2 = SSHRunner.agentVersion([(path: "agent/x.go", text: "one")])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a2)
        XCTAssertEqual(a.count, 16) // 8 bytes hex
    }
}

final class ProvisionerAgentUsableTests: XCTestCase {

    private func host(agent: AgentEndpoint?) -> ServerHost {
        var h = ServerHost(label: "VPS", host: "203.0.113.9")
        h.agent = agent
        return h
    }

    private func endpoint(version: String, base: String) -> AgentEndpoint {
        AgentEndpoint(port: 28000, certSHA256: "ab", prefix: "p", version: version,
                      deviceID: "d", baseContainer: base)
    }

    func testNoAgentIsUnusable() {
        XCTAssertFalse(Provisioner.agentUsable(host: host(agent: nil),
                                               containerName: "olcrtc-server-abcd1234", sourceVersion: "v1"))
    }

    func testUsableWhenVersionAndContainerMatch() {
        let h = host(agent: endpoint(version: "v1", base: "olcrtc-server-abcd1234"))
        XCTAssertTrue(Provisioner.agentUsable(host: h,
                                              containerName: "olcrtc-server-abcd1234", sourceVersion: "v1"))
    }

    func testStaleVersionIsUnusable() {
        let h = host(agent: endpoint(version: "old", base: "olcrtc-server-abcd1234"))
        XCTAssertFalse(Provisioner.agentUsable(host: h,
                                               containerName: "olcrtc-server-abcd1234", sourceVersion: "new"))
    }

    func testDifferentBaseContainerIsUnusable() {
        // Server was reinstalled under a new container name → stale status.
        let h = host(agent: endpoint(version: "v1", base: "olcrtc-server-OLD"))
        XCTAssertFalse(Provisioner.agentUsable(host: h,
                                               containerName: "olcrtc-server-NEW", sourceVersion: "v1"))
    }

    func testNilContainerIgnoresContainerGate() {
        let h = host(agent: endpoint(version: "v1", base: "olcrtc-server-abcd1234"))
        XCTAssertTrue(Provisioner.agentUsable(host: h, containerName: nil, sourceVersion: "v1"))
    }

    func testNilVersionIgnoresVersionGate() {
        let h = host(agent: endpoint(version: "whatever", base: "olcrtc-server-abcd1234"))
        XCTAssertTrue(Provisioner.agentUsable(host: h,
                                              containerName: "olcrtc-server-abcd1234", sourceVersion: nil))
    }
}
