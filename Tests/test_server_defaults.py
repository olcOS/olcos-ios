#!/usr/bin/env python3
"""Defaults the app and scripts/srv.sh must agree on.

The app always passes OLCRTC_JITSI_URL, but srv.sh keeps its own default for
a standalone run, and the two must name the same Jitsi instance.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


class ServerDefaults(unittest.TestCase):
    def test_jitsi_default_matches_the_app(self):
        app = re.search(r'static let defaultJitsiBaseURL = "([^"]+)"',
                        read("App/Utilities/AppConstants.swift")).group(1)
        srv = re.search(r'JITSI_BASE="\$\{OLCRTC_JITSI_URL:-([^}]+)\}"', read("scripts/srv.sh")).group(1)
        self.assertEqual(app, srv)


if __name__ == "__main__":
    unittest.main(verbosity=2)
