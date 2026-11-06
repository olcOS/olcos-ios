#!/usr/bin/env python3
"""Wiring of the optional core patch series and of the server restart policy.

scripts/olcrtc-core.patch is olcOS's series on top of the pinned olcrtc core
(today Telemost's single-packet framing). Every place that builds the core
applies it: the framework build, CI, srv.sh and the app's server update, and a
server records the series' id next to the core so the app can tell a patched
core from the bare pin. Each step skips an absent series, and the app removes
a stale copy an older version left on the server. Behaviour of the server
update script itself is exercised offline in test_ssh_audit_481.py.

Run: python3 scripts/test_core_patch.py
"""
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "scripts" / "olcrtc-core.patch"
UPSTREAM = ROOT / "olcrtc-upstream"


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


class CorePatchSeries(unittest.TestCase):
    def test_a_present_series_applies_to_the_pin_and_only_modifies_existing_files(self):
        if not PATCH.is_file():
            self.skipTest("no patch series: the core ships unpatched")
        text = PATCH.read_text(encoding="utf-8")
        # The server update restores tracked files before re-applying, and
        # git apply refuses to create a file that already exists.
        self.assertNotIn("\nnew file mode", text)
        self.assertNotIn("\ndeleted file mode", text)
        if not (UPSTREAM / "go.mod").exists():
            self.skipTest("olcrtc-upstream is not checked out")
        result = subprocess.run(["git", "-C", str(UPSTREAM), "apply", "--check", str(PATCH)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_framework_build_applies_only_a_present_series_and_restores_it(self):
        build = read("scripts/build-framework.sh")
        self.assertIn('CORE_PATCH="$ROOT/scripts/olcrtc-core.patch"', build)
        guarded = build.index('if [ -s "$CORE_PATCH" ]; then\n  git -C "$UPSTREAM" apply "$CORE_PATCH"')
        self.assertLess(guarded, build.index("gomobile bind"))
        self.assertIn("trap 'rm -f \"${SHIM_DSTS[@]}\"; restore_patched' EXIT", build)
        fetch = read("scripts/fetch-framework.sh")
        self.assertIn('[root / "scripts/olcrtc-core.patch"] if p.is_file()', fetch)

    def test_ci_tests_the_core_with_a_present_series(self):
        workflow = read(".github/workflows/build.yml")
        apply_at = workflow.index(
            "if [ -s scripts/olcrtc-core.patch ]; then git -C olcrtc-upstream apply ../scripts/olcrtc-core.patch; fi")
        self.assertLess(apply_at, workflow.index("(cd olcrtc-upstream && go test"))

    def test_server_install_applies_a_present_series_between_checkout_and_build(self):
        srv = read("scripts/srv.sh")
        checkout = srv.index('git -C "$WORK_DIR" checkout -q FETCH_HEAD')
        guard = srv.index('if [ -s "${OLCRTC_CORE_PATCH:-}" ]; then')
        apply_at = srv.index('git -C "$WORK_DIR" apply "$OLCRTC_CORE_PATCH"')
        record = srv.index('printf \'%s\\n\' "${OLCRTC_CORE_PATCH_ID:-}" > "$WORK_DIR/.olcos-core-patch"')
        build = srv.index("go build -trimpath")
        self.assertLess(checkout, guard)
        self.assertLess(guard, apply_at)
        self.assertLess(apply_at, record)
        self.assertLess(record, build)

    def test_the_series_is_telemosts_framing_and_the_app_checks_for_it(self):
        # The series itself is olcOS's own work: it is not committed, CI
        # materializes it from a secret (see build.yml). Check its content only
        # when it is present; the app-side wiring is checked either way.
        if PATCH.is_file():
            text = PATCH.read_text(encoding="utf-8")
            self.assertIn("SinglePacketRelay", text)
            self.assertNotIn("\r", text)
        swift = read("App/Core/SSHRunner.swift")
        self.assertIn('"OLCRTC_CORE_PATCH_ID=\\(corePatchID)"', swift)
        self.assertIn('echo "OLCRTC_CORE_PATCH=$(cat "$DEPLOY_DIR/.olcos-core-patch" 2>/dev/null || true)"', swift)

    def test_server_install_fetches_the_pin_from_the_fork(self):
        srv = read("scripts/srv.sh")
        self.assertIn('REPO_URL="https://github.com/ghostlane-project/olcrtc.git"', srv)
        pin = read("App/Utilities/AppConstants.swift").split('static let upstreamCorePin = "', 1)[1][:40]
        self.assertIn('OLCRTC_PIN="${OLCRTC_PIN:-' + pin + '}"', srv)
        # The gitlink as staged (`ls-files -s`: mode, sha, stage, path), so the
        # check holds before a commit as well as on a CI checkout.
        link = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s", "olcrtc-upstream"],
                              capture_output=True, text=True).stdout.split()
        if len(link) >= 2:
            self.assertEqual(link[1], pin, "the server pin must equal the submodule pin")

    def test_app_uploads_a_present_series_or_removes_a_stale_one(self):
        swift = read("App/Core/SSHRunner.swift")
        self.assertIn('static let corePatch = "/tmp/olcrtc-ios-core.patch"', swift)
        self.assertIn('"OLCRTC_CORE_PATCH=\\(RemotePaths.corePatch)"', swift)
        upload = swift.split("static func corePatchUploadCommand()", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn('loadBundledScript(named: "olcrtc-core", ext: "patch")', upload)
        self.assertIn('return "rm -f \\(RemotePaths.corePatch)"', upload)
        for function in ("private static func uploadScript(", "static func update(host:"):
            body = swift.split(function, 1)[1].split("\n    }\n", 1)[0]
            self.assertIn("corePatchUploadCommand()", body, function)
        script = swift.split("static func updateScript(", 1)[1].split('"""#', 1)[0]
        steps = [script.index(step) for step in (
            'reset -q --hard', 'remote set-url origin \\#(AppConstants.coreRepositoryURL)',
            'checkout -q FETCH_HEAD', 'if [ -s \\#(RemotePaths.corePatch) ]; then',
            'apply \\#(RemotePaths.corePatch)', 'go build -trimpath')]
        self.assertEqual(steps, sorted(steps))

    def test_the_app_bundles_the_series(self):
        # The app always carries the Telemost series, so project.yml always
        # bundles it. The file is committed in the private source of truth and
        # materialized from a secret in the public CI snapshot (build.yml), so
        # its presence on disk is not coupled to the bundle line.
        self.assertIn("- path: scripts/olcrtc-core.patch", read("project.yml"))


class RestartPolicy(unittest.TestCase):
    def test_new_containers_come_back_after_a_reboot(self):
        # podman-restart.service starts only restart-policy=always containers.
        for relative in ("scripts/srv.sh", "scripts/add-carrier.sh"):
            executable = [line for line in read(relative).splitlines()
                          if not line.lstrip().startswith("#")]
            self.assertIn("    --restart always \\", executable, relative)
            self.assertFalse(any("unless-stopped" in line for line in executable), relative)
        self.assertIn("systemctl enable podman-restart.service", read("scripts/srv.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
