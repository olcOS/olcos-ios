#!/usr/bin/env python3
"""The licence texts the app bundles (App/Licenses/).

The olcrtc core is Apache-2.0 with a NOTICE, both of which must travel with
the app, verbatim; re-pinning the submodule must refresh the copies. The
generated third-party documents must exist and name the main components.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LICENSES = ROOT / "App" / "Licenses"
CORE = ROOT / "olcrtc-upstream"


class BundledLicences(unittest.TestCase):
    def test_core_files_are_verbatim_copies_of_the_submodule(self):
        if not (CORE / "LICENSE").is_file():
            self.skipTest("olcrtc-upstream is not checked out")
        for bundled, source in (("olcrtc-LICENSE.txt", "LICENSE"),
                                ("olcrtc-NOTICE.txt", "NOTICE"),
                                ("olcrtc-upstream-WTFPL.txt", "docs/upstream-license-wtfpl.txt")):
            self.assertEqual((LICENSES / bundled).read_bytes(), (CORE / source).read_bytes(),
                             f"{bundled}: re-copy it from olcrtc-upstream/{source}")

    def test_third_party_documents_name_the_main_components(self):
        go = (LICENSES / "third-party-go.txt").read_text(encoding="utf-8")
        self.assertTrue(go.startswith("Third-party Go modules in olcOS"))
        for module in ("github.com/xtls/xray-core", "github.com/pion/webrtc/v4",
                       "github.com/Jigsaw-Code/outline-sdk"):
            self.assertIn("\n" + module + " ", go, module)
        self.assertNotIn("No licence file found", go)
        swift = (LICENSES / "third-party-swift.txt").read_text(encoding="utf-8")
        for package in ("orlandos-nl/Citadel", "apple/swift-nio", "apple/swift-crypto"):
            self.assertIn("\n" + package + "\n", swift, package)


if __name__ == "__main__":
    unittest.main(verbosity=2)
