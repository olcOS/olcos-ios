#!/usr/bin/env python3
"""How the app uses the core from the olcos-core submodule.

olcos-core (olcOS/olcos-core) holds the Go core and the server side: olcrtc as
upstream release plus the olcOS commits, the patch series that carries those
commits to the server (server/olcrtc-core.patch), srv.sh and the agent and
bond sources. Its own CI checks the core, the series and the scripts. These
tests check the app side: the framework is built from that tree, the app pins
the same upstream commit, bundles the same series and server files, uploads
the series on install and update, and a server records the series id so the
app can tell a current core from an old one. Behaviour of the server update
script itself is exercised offline in test_ssh_audit_481.py.

Run: python3 scripts/test_core_patch.py
"""
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "olcos-core"
PATCH = CORE / "server" / "olcrtc-core.patch"


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def upstream_manifest():
    values = {}
    for line in (CORE / "olcrtc.upstream").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


class CoreSubmodule(unittest.TestCase):
    def setUp(self):
        if not (CORE / "olcrtc.upstream").is_file():
            self.skipTest("the olcos-core submodule is not checked out")

    def test_the_app_pins_the_upstream_commit_the_core_is_based_on(self):
        manifest = upstream_manifest()
        constants = read("App/Utilities/AppConstants.swift")
        pin = re.search(r'static let upstreamCorePin = "([0-9a-f]{40})"', constants).group(1)
        self.assertEqual(pin, manifest["OLCRTC_COMMIT"],
                         "AppConstants.upstreamCorePin must equal OLCRTC_COMMIT in olcos-core/olcrtc.upstream")
        repository = re.search(r'static let coreRepositoryURL = "([^"]+)"', constants).group(1)
        self.assertEqual(repository.removesuffix(".git"), manifest["OLCRTC_REPO"])
        srv = (CORE / "server" / "srv.sh").read_text(encoding="utf-8")
        self.assertIn('OLCRTC_PIN="${OLCRTC_PIN:-' + pin + '}"', srv)
        self.assertIn('REPO_URL="' + manifest["OLCRTC_REPO"] + '.git"', srv)

    def test_the_series_is_telemosts_framing_and_only_modifies_existing_files(self):
        text = PATCH.read_text(encoding="utf-8")
        self.assertIn("SinglePacketRelay", text)
        self.assertNotIn("\r", text)
        # The server update restores tracked files before re-applying, and
        # git apply refuses to create a file that already exists.
        self.assertNotIn("\nnew file mode", text)
        self.assertNotIn("\ndeleted file mode", text)

    def test_the_bundled_go_sources_exist_in_the_core(self):
        # The source lists name paths relative to the bundle root, where the
        # bond and agent folders sit (olcos-core/mobile/bond and /agent).
        for swift, folder in (("App/Core/SSHRunner+Bond.swift", "bond"),
                              ("App/Core/SSHRunner+Agent.swift", "agent")):
            names = re.findall(r'"(' + folder + r'/[\w/-]+\.go)"', read(swift))
            self.assertTrue(names, swift)
            for name in names:
                self.assertTrue((CORE / "mobile" / name).is_file(), f"{swift}: {name}")


class AppWiring(unittest.TestCase):
    def test_the_framework_is_built_by_the_core(self):
        build = read("scripts/build-framework.sh")
        self.assertIn('CORE="$ROOT/olcos-core"', build)
        self.assertIn('"$CORE/scripts/build-ios.sh" "$OUT"', build)
        self.assertNotIn("git apply", build)
        fetch = read("scripts/fetch-framework.sh")
        self.assertIn('["git", "-C", str(core_dir), "rev-parse", "HEAD"]', fetch)

    def test_the_app_bundles_the_series_and_the_server_files(self):
        project = read("project.yml")
        for path in ("olcos-core/server/srv.sh", "olcos-core/server/rotate-key.sh",
                     "olcos-core/server/add-carrier.sh", "olcos-core/server/olcrtc-core.patch"):
            self.assertIn(f"- path: {path}\n        buildPhase: resources", project, path)
        for path in ("olcos-core/mobile/bond", "olcos-core/mobile/agent", "olcos-core/server"):
            self.assertIn(f"- path: {path}\n        type: folder\n        buildPhase: resources", project, path)

    def test_the_app_checks_for_the_series_on_the_server(self):
        swift = read("App/Core/SSHRunner.swift")
        self.assertIn('"OLCRTC_CORE_PATCH_ID=\\(corePatchID)"', swift)
        self.assertIn('echo "OLCRTC_CORE_PATCH=$(cat "$DEPLOY_DIR/.olcos-core-patch" 2>/dev/null || true)"', swift)

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

    def test_the_build_needs_no_secret(self):
        for workflow in ("build.yml", "ci.yml", "release.yml"):
            text = read(f".github/workflows/{workflow}")
            self.assertNotIn("CORE_PATCH_B64", text, workflow)
            self.assertIn("submodules: recursive", read(".github/workflows/build.yml"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
