#!/usr/bin/env python3
"""scripts/install.sh, kept for the old install address, runs the server
installer of the olcos-core commit the app is built on.

Run: python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class InstallStub(unittest.TestCase):
    def test_it_runs_the_installer_of_the_core_the_app_is_built_on(self):
        stub = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        pinned = re.search(r'^CORE_COMMIT="([0-9a-f]{40})"$', stub, re.M)
        self.assertIsNotNone(pinned, "CORE_COMMIT must be a full commit id")
        tree = subprocess.run(["git", "-C", str(ROOT), "ls-tree", "HEAD", "olcos-core"],
                              capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(tree[:2], ["160000", "commit"])
        self.assertEqual(pinned.group(1), tree[2], "bump CORE_COMMIT with the olcos-core submodule")

    def test_it_fetches_from_that_commit_and_checks_what_it_got(self):
        stub = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn('SOURCE="https://raw.githubusercontent.com/olcOS/olcos-core/$CORE_COMMIT"', stub)
        self.assertIn('URL="$SOURCE/server/install.sh"', stub)
        self.assertIn('OLCOS_SOURCE="${OLCOS_SOURCE:-$SOURCE}" bash "$TMP"', stub)
        self.assertIn("head -n 1 \"$TMP\" | grep -q", stub)


if __name__ == "__main__":
    unittest.main(verbosity=2)
