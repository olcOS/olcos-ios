#!/usr/bin/env python3
"""#481: offline B1/B2/B4 regressions. No SSH, server, real podman/git or build.

Run: python3 scripts/test_ssh_audit_481.py
Fixtures are retained under the system temporary directory for inspection.
"""
# boc #481
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
OLD_KEY = "a" * 64
NEW_KEY = "b" * 64
BASE = "olcrtc-server-audit"
MOCK = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
path = pathlib.Path(os.environ["MOCK_STATE"])
state = json.loads(path.read_text())
containers = state.setdefault("containers", {})
with open(os.environ["MOCK_LOG"], "a") as out:
    out.write(json.dumps(args) + "\n")
if args[0] == "ps":
    print("\n".join(state["all"] if "-a" in args else state["running"]))
elif args[0] == "inspect":
    fmt, name = args[args.index("--format") + 1], args[-1]
    info = containers.get(name, {})
    if "RestartPolicy" in fmt:
        print(info.get("policy", "always"))
    elif "Config.Cmd" in fmt:
        print(info.get("cmd", "./olcrtc server.yaml"))
    elif "ImageName" in fmt:
        print("offline-image")
    elif "State.Running" in fmt:
        print("true" if name in state["running"] else "false")
    else:
        print(os.environ["MOCK_DEPLOY"])
elif args[0] == "restart":
    if args[1] in state.get("fail_restart", []):
        sys.exit(42)
elif args[0] in ("run", "create"):
    if "--name" in args:
        name = args[args.index("--name") + 1]
        if name in state.get("fail_create", []):
            sys.exit(125)
        state["all"].append(name)
        if args[0] == "run":
            state["running"].append(name)
        containers[name] = {"policy": args[args.index("--restart") + 1], "cmd": args[-1]}
        path.write_text(json.dumps(state))
elif args[0] == "rename":
    old, new = args[1], args[2]
    for key in ("all", "running"):
        state[key] = [new if n == old else n for n in state[key]]
    if old in containers:
        containers[new] = containers.pop(old)
    path.write_text(json.dumps(state))
elif args[0] in ("start", "stop"):
    name = args[-1]
    if name in state["running"]:
        state["running"].remove(name)
    if args[0] == "start":
        state["running"].append(name)
    path.write_text(json.dumps(state))
elif args[0] == "rm":
    for name in (a for a in args[1:] if not a.startswith("-")):
        for key in ("all", "running"):
            if name in state[key]:
                state[key].remove(name)
        containers.pop(name, None)
    path.write_text(json.dumps(state))
elif args[0] != "logs":
    raise SystemExit("unexpected mock command: " + repr(args))
"""
GIT_MOCK = r"""#!/usr/bin/env python3
import json, os, sys
with open(os.environ["MOCK_LOG"], "a") as out:
    out.write(json.dumps(["git"] + sys.argv[1:]) + "\n")
"""


def yaml(provider, key=OLD_KEY):
    return (f'mode: srv\nauth:\n  provider: "{provider}"\nroom:\n  id: "audit-room"\n'
            f'crypto:\n  key: "{key}"\nnet:\n  transport: "datachannel"\n'
            '  dns: "77.88.8.8:53"\n')


class SSHScriptAudit481Tests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="olcrtc-ssh-481-"))
        self.deploy = self.directory / "deploy"
        self.deploy.mkdir()
        (self.deploy / ".git").mkdir()
        (self.deploy / "server.yaml").write_text(yaml("wbstream"))
        (self.deploy / "olcrtc").write_text("#!/bin/sh\nexit 0\n")
        (self.deploy / "olcrtc").chmod(0o700)
        self.home = self.directory / "home"
        self.home.mkdir()
        (self.home / ".olcrtc_key").write_text(OLD_KEY)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name, script in {
            "podman": MOCK, "git": GIT_MOCK,
            "sleep": "#!/bin/sh\nexit 0\n", "systemctl": "#!/bin/sh\nexit 0\n",
            "openssl": f"#!/bin/sh\nprintf '%s\\n' '{NEW_KEY}'\n",
        }.items():
            executable = self.bin / name
            executable.write_text(script)
            executable.chmod(0o700)
        self.state = self.directory / "state.json"
        self.log = self.directory / "commands.jsonl"
        self.set_state([BASE], [BASE])
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        HOME=str(self.home), MOCK_STATE=str(self.state),
                        MOCK_LOG=str(self.log), MOCK_DEPLOY=str(self.deploy),
                        OLCRTC_BASE_CONTAINER=BASE, OLCRTC_CONTAINER=BASE,
                        OLCRTC_CARRIER="jitsi", OLCRTC_TRANSPORT="datachannel",
                        OLCRTC_ROOM_ID="https://meet.example/audit")

    def set_state(self, all_names, running, fail_restart=None, containers=None,
                  fail_create=None):
        self.state.write_text(json.dumps({"all": all_names, "running": running,
                                         "fail_restart": fail_restart or [],
                                         "containers": containers or {},
                                         "fail_create": fail_create or []}))

    def read_state(self):
        return json.loads(self.state.read_text())

    def update_script(self, patch_path=None):
        source = (ROOT / "App/Core/SSHRunner.swift").read_text(encoding="utf-8")
        body = source.split("static func updateScript(", 1)[1].split('return #"""', 1)[1]
        body = body.split('"""#', 1)[0]
        patch = patch_path or (self.directory / "absent-core.patch")
        for name, value in {"target": BASE, "containerNamePrefix": "olcrtc-server-",
                            "AppConstants.upstreamCorePin": "offline-pin",
                            "AppConstants.coreRepositoryURL": "https://fork.invalid/olcrtc.git",
                            "AppConstants.serverGoImage": "offline-image",
                            "RemotePaths.corePatch": patch.as_posix(),
                            "corePatchID": "0" * 64}.items():
            body = body.replace("\\#(" + name + ")", value)
        self.assertNotIn("\\#(", body)
        script = self.directory / "update.sh"
        script.write_text(body)
        return script

    def run_script(self, script):
        return subprocess.run(["bash", str(script)], env=self.env, text=True,
                              capture_output=True, timeout=10)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_update_restarts_running_sibling_but_not_stopped_or_unrelated(self):
        script = self.update_script()
        live, stopped, other = BASE + "-telemost", BASE + "-jitsi", "other-server"
        self.set_state([BASE, live, stopped, other], [BASE, live, other])
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        restarts = [cmd[1] for cmd in self.commands() if cmd[0] == "restart"]
        self.assertEqual(restarts, [BASE, live])
        self.assertIn("OLCRTC_UPDATED=ok", result.stdout)

    def update_steps(self, patch_path=None):
        result = self.run_script(self.update_script(patch_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        return [" ".join(cmd) for cmd in self.commands()
                if cmd[0] == "git" or cmd[:2] == ["run", "--rm"]]

    def test_update_moves_the_checkout_to_the_fork_before_fetching_the_pin(self):
        steps = self.update_steps()
        deploy = str(self.deploy)
        self.assertEqual(steps[:4], [
            f"git -C {deploy} reset -q --hard",
            f"git -C {deploy} remote set-url origin https://fork.invalid/olcrtc.git",
            f"git -C {deploy} fetch --depth 1 origin offline-pin",
            f"git -C {deploy} checkout -q FETCH_HEAD",
        ])
        # No series uploaded: nothing is applied, the build follows the checkout.
        self.assertTrue(steps[4].startswith("run --rm"), steps)

    def test_update_applies_an_uploaded_core_patch_between_checkout_and_build(self):
        patch = self.directory / "core.patch"
        patch.write_text("diff --git a/x b/x\n")
        steps = self.update_steps(patch)
        deploy = str(self.deploy)
        self.assertEqual(steps[3], f"git -C {deploy} checkout -q FETCH_HEAD")
        self.assertTrue(steps[4].startswith(f"git -C {deploy} apply "), steps)
        self.assertTrue(steps[4].endswith("/core.patch"), steps)
        self.assertTrue(steps[5].startswith("run --rm"), steps)
        # The server records the series it applied, for the app's core check.
        self.assertEqual((self.deploy / ".olcos-core-patch").read_text(), "0" * 64 + "\n")

    def test_update_without_a_series_forgets_a_recorded_one(self):
        (self.deploy / ".olcos-core-patch").write_text("f" * 64 + "\n")
        self.update_steps()
        self.assertFalse((self.deploy / ".olcos-core-patch").exists())

    def test_update_recreates_unless_stopped_containers_with_always(self):
        live, stopped = BASE + "-telemost", BASE + "-jitsi"
        commands = {BASE: "./olcrtc server.yaml", live: "./olcrtc server-telemost.yaml",
                    stopped: "./olcrtc server-jitsi.yaml"}
        self.set_state([BASE, live, stopped], [BASE, live], containers={
            name: {"policy": "unless-stopped", "cmd": cmd} for name, cmd in commands.items()})
        result = self.run_script(self.update_script())
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(sorted(state["all"]), sorted(commands))
        self.assertEqual(sorted(state["running"]), sorted([BASE, live]),
                         "a stopped sibling stays stopped")
        for name, cmd in commands.items():
            self.assertEqual(state["containers"][name], {"policy": "always", "cmd": cmd})
        created = [cmd for cmd in self.commands() if cmd[0] == "create"]
        self.assertEqual(len(created), 3)
        for cmd in created:
            self.assertEqual(cmd[cmd.index("-v") + 1], f"{self.deploy}:/app:Z")
            self.assertIn("offline-image", cmd)
        self.assertEqual([cmd[1] for cmd in self.commands() if cmd[0] == "restart"],
                         [BASE, live])

    def test_update_leaves_unknown_containers_and_always_policies_alone(self):
        other = BASE + "-custom"
        self.set_state([BASE, other], [BASE, other], containers={
            BASE: {"policy": "always", "cmd": "./olcrtc server.yaml"},
            other: {"policy": "unless-stopped", "cmd": "/usr/bin/something"}})
        result = self.run_script(self.update_script())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(cmd[0] in ("rename", "create", "rm") for cmd in self.commands()))
        self.assertIn(f"WARN: {other} runs '/usr/bin/something'", result.stdout)

    def test_update_puts_a_container_back_when_it_cannot_be_recreated(self):
        self.set_state([BASE], [BASE], fail_create=[BASE], containers={
            BASE: {"policy": "unless-stopped", "cmd": "./olcrtc server.yaml"}})
        result = self.run_script(self.update_script())
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(state["all"], [BASE])
        self.assertEqual(state["running"], [BASE])
        self.assertEqual(state["containers"][BASE]["policy"], "unless-stopped")
        self.assertIn(f"WARN: {BASE} could not be recreated", result.stdout)

    def assert_collision_preserved(self, existing_file, existing_container):
        sibling = self.deploy / "server-jitsi.yaml"
        original = yaml("telemost")
        if existing_file:
            sibling.write_text(original)
        if existing_container:
            self.set_state([BASE, BASE + "-jitsi"], [BASE, BASE + "-jitsi"])
        primary = (self.deploy / "server.yaml").read_bytes()
        result = self.run_script(ROOT / "scripts/add-carrier.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists; no changes made", result.stderr)
        self.assertFalse(any(cmd[0] in ("rm", "run", "restart") for cmd in self.commands()))
        self.assertEqual((self.deploy / "server.yaml").read_bytes(), primary)
        self.assertEqual((self.home / ".olcrtc_key").read_text(), OLD_KEY)
        if existing_file:
            self.assertEqual(sibling.read_text(), original)
        else:
            self.assertFalse(sibling.exists())

    def test_add_preserves_reconfigured_sibling(self):
        self.assert_collision_preserved(True, True)

    def test_add_preserves_orphan_yaml(self):
        self.assert_collision_preserved(True, False)

    def test_add_preserves_container_with_missing_yaml(self):
        self.assert_collision_preserved(False, True)

    def test_add_preserves_dangling_symlink(self):
        sibling = self.deploy / "server-jitsi.yaml"
        sibling.symlink_to(self.deploy / "missing")
        result = self.run_script(ROOT / "scripts/add-carrier.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(sibling.is_symlink())
        self.assertFalse((self.deploy / "missing").exists())
        self.assertFalse(any(cmd[0] in ("rm", "run") for cmd in self.commands()))

    def test_add_empty_slot_still_succeeds(self):
        result = self.run_script(ROOT / "scripts/add-carrier.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OLCRTC_CARRIER_ADDED=ok", result.stdout)
        self.assertIn(f"OLCRTC_CONTAINER={BASE}-jitsi", result.stdout)
        self.assertIn(OLD_KEY, (self.deploy / "server-jitsi.yaml").read_text())

    def test_rotate_failed_primary_restart_reports_new_key_and_continues_siblings(self):
        live, stopped = BASE + "-telemost", BASE + "-jitsi"
        (self.deploy / "server-telemost.yaml").write_text(yaml("telemost"))
        (self.deploy / "server-jitsi.yaml").write_text(yaml("jitsi"))
        self.set_state([BASE, live, stopped], [BASE, live], [BASE, live])
        result = self.run_script(ROOT / "scripts/rotate-key.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"[!] {BASE} restart failed", result.stdout)
        self.assertIn(f"OLCRTC_URI=olcrtc://wbstream?datachannel@audit-room#{NEW_KEY}",
                      result.stdout)
        self.assertIn(f"OLCRTC_SIBLING_URI={live}|", result.stdout)
        self.assertIn(f"OLCRTC_SIBLING_URI={stopped}|", result.stdout)
        for config in self.deploy.glob("server*.yaml"):
            self.assertIn(NEW_KEY, config.read_text())
            self.assertNotIn(OLD_KEY, config.read_text())
        self.assertEqual((self.home / ".olcrtc_key").read_text().strip(), NEW_KEY)
        self.assertEqual([cmd[1] for cmd in self.commands() if cmd[0] == "restart"],
                         [BASE, live])

    def test_copied_srv_blocks_remain_verbatim(self):
        lines = {line.strip() for line in (ROOT / "scripts/srv.sh").read_text().splitlines()}
        for name in ("add-carrier", "rotate-key"):
            in_block, count = False, 0
            for raw in (ROOT / f"scripts/{name}.sh").read_text().splitlines():
                line = raw.strip()
                if line.startswith("# boc srv.sh"):
                    self.assertFalse(in_block)
                    in_block = True
                elif line.startswith("# eoc srv.sh"):
                    self.assertTrue(in_block)
                    in_block = False
                elif in_block and line and not line.startswith("#"):
                    self.assertIn(line, lines, f"{name}: {line}")
                    count += 1
            self.assertFalse(in_block)
            self.assertGreater(count, 80)

    def test_host_identity_gate_precedes_authentication_and_uses_original_endpoint(self):
        source = (ROOT / "App/Core/SSHRunner.swift").read_text()
        connect = source.split("private static func connect(host:", 1)[1]
        connect = connect.split('preconditionFailure("unreachable:', 1)[0]
        active = "\n".join(line for line in connect.splitlines()
                           if not line.lstrip().startswith("//"))
        self.assertNotIn(".acceptAnything()", active)
        self.assertLess(active.index("trustStore.prepare("),
                        active.index("authenticationMethod(username:"))
        self.assertIn("host: host.host, port: host.port, legacyPin: host.sshHostKeyPin", active)
        self.assertIn("let hostKeyValidator = SSHAutomaticHostKeyValidator(", active)
        self.assertIn("hostKeyValidator: .custom(hostKeyValidator)", active)
        self.assertIn("context: trustContext, store: trustStore", active)
        self.assertLess(active.index("trustStore.prepare("), active.index("let dialHost"))
        self.assertNotIn("prepare(host: dialHost", active)
        self.assertIn("reconnect: .never", active)
        self.assertLess(active.index("hostKeyValidator.rejection ?? (error as? SSHHostKeyError)"),
                        active.index("if attempt < 2"))

    def test_first_use_has_no_manual_fingerprint_or_acknowledgment(self):
        source = (ROOT / "App/Views/AddServerHostView.swift").read_text()
        self.assertNotIn("TextEditor(text: $hostKeyFingerprint)", source)
        self.assertNotIn("acknowledgedHostKeyPin", source)
        self.assertNotIn("verifiedHostKeyPin", source)
        self.assertNotIn("independentlyVerified:", source)
        validator = (ROOT / "App/Core/SSHHostKeyVerification.swift").read_text()
        self.assertIn("try store.validate(presented: presented, for: context)", validator)
        self.assertNotIn("@MainActor", validator)
        store = (ROOT / "App/Core/SSHHostKeyTrustStore.swift").read_text()
        self.assertIn("if entry.fingerprints.isEmpty", store)
        self.assertIn("entry.fingerprints = [presented]", store)
        self.assertIn("!entry.fingerprints.contains(presented)", store)
        self.assertIn("throw SSHHostKeyError.mismatch", store)
        self.assertIn("entry.generation == context.generation", store)
        self.assertIn("fresh.ignoresLegacy = true", store)
        self.assertIn("Self.lock.lock()", store)
        self.assertIn("flock(descriptor, LOCK_EX | LOCK_NB)", store)
        self.assertIn("data.write(to: fileURL, options: .atomic)", store)
        self.assertIn("throw SSHHostKeyError.trustStoreUnavailable", store)
        self.assertNotIn("@MainActor", store)
        self.assertIn("static let statusDidChange = Notification.Name(", store)
        self.assertIn("func hasMismatch(host: String, port: Int) -> Bool", store)
        self.assertIn("setMismatchLocked(endpoint: context.endpoint, present: true)", store)
        self.assertIn("setMismatchLocked(endpoint: pin.endpoint, present: true)", store)
        self.assertIn("transaction(onCommit:", store)
        self.assertLess(store.index("try data.write(to: fileURL, options: .atomic)"),
                        store.index("onCommit?()"))
        self.assertIn("DispatchQueue.main.async", store)
        renewal = (ROOT / "App/Services/TelemostRenewalCoordinator.swift").read_text()
        self.assertNotIn("SSHHostKeyVerification.requirePin", renewal)
        self.assertIn("SSHHostKeyTrustStore.shared.prepare(host: host.host, port: host.port,", renewal)


if __name__ == "__main__":
    unittest.main(verbosity=2)
# eoc #481
