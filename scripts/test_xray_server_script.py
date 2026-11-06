#!/usr/bin/env python3
"""The app's side of olcos-core's server/xray/install.sh, the script the app
uploads to a VPS to set up the Xray server.

The script's own behaviour (fresh install, adopting a deployment, refusals) is
tested offline in olcos-core (scripts/test_xray_server_script.py there). Here
only the bundling: the app must ship the script where SSHRunner looks for it.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class XrayBundlingTests(unittest.TestCase):
    def test_the_app_ships_the_server_scripts_as_a_folder(self):
        # SSHRunner.loadXrayInstallScript looks the installer up as
        # server/xray/install.sh inside the bundle: a folder reference.
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertRegex(project, r"- path: olcos-core/server\n\s+type: folder\n\s+buildPhase: resources")
        swift = (ROOT / "App" / "Core" / "SSHRunner+Xray.swift").read_text(encoding="utf-8")
        self.assertIn('forResource: "install", withExtension: "sh",', swift)
        self.assertIn('subdirectory: "server/xray"', swift)

    def test_the_script_is_in_the_core(self):
        script = ROOT / "olcos-core" / "server" / "xray" / "install.sh"
        if not (ROOT / "olcos-core" / "olcrtc.upstream").is_file():
            self.skipTest("the olcos-core submodule is not checked out")
        self.assertTrue(script.is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
