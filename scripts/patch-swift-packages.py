#!/usr/bin/env python3
"""Apply the security fix the app's resolved swift-nio-ssh lacks.

Citadel, the app's SSH client, pins its own fork of swift-nio-ssh
(github.com/Wellz26/swift-nio-ssh, 0.3.4..<0.4.0), and no release of that
fork carries the fix for GHSA-998x-vgvp-xwpc (CVE-2026-43798): an ECDSA
signature integer wider than the curve, sent in the server's key-exchange
reply, is copied out of bounds on the stack before anything is verified. A
man in the middle between the phone and the VPS could use it against the
app. The fix is Apple's (apple/swift-nio-ssh 31cdc3c, released in 0.14.1),
applied here to the checkout xcodebuild resolved.

Usage: patch-swift-packages.py <SourcePackages dir>
       (the -clonedSourcePackagesDirPath given to xcodebuild)

Running it twice changes nothing. It fails when the checkout matches neither
the vulnerable code nor the fixed one, so a dependency update gets looked at
instead of being built unpatched.
"""
import sys
from pathlib import Path

MARKER = "ECDSA signature mpint exceeds curve point size"

REPLACEMENTS = [
    (
        "    private init(r: ByteBuffer, s: ByteBuffer, pointSize: Int) {\n",
        "    private init(r: ByteBuffer, s: ByteBuffer, pointSize: Int) throws {\n",
    ),
    (
        "        let rByteView = r.mpIntView\n"
        "        let sByteView = s.mpIntView\n"
        "\n",
        "        let rByteView = r.mpIntView\n"
        "        let sByteView = s.mpIntView\n"
        "\n"
        "        // The r and s components are attacker-controlled and parsed pre-authentication. Neither may be\n"
        "        // wider than the curve's point size: a larger value produces a negative starting offset below and\n"
        "        // an out-of-bounds write into the stack storage.\n"
        "        guard rByteView.count <= pointSize, sByteView.count <= pointSize else {\n"
        f"            throw NIOSSHError.invalidSSHMessage(reason: \"{MARKER}\")\n"
        "        }\n"
        "\n",
    ),
    (
        "        let helper = ECDSASignatureHelper(r: r, s: s, pointSize: Signature.pointSize)\n",
        "        let helper = try ECDSASignatureHelper(r: r, s: s, pointSize: Signature.pointSize)\n",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = (Path(sys.argv[1]) / "checkouts" / "swift-nio-ssh" / "Sources" / "NIOSSH"
            / "Keys And Signatures" / "NIOSSHSignature.swift")
    if not path.is_file():
        print(f"error: {path} not found: resolve the packages first "
              "(xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath ...)", file=sys.stderr)
        return 1
    text = path.read_text()
    if MARKER in text:
        print(f"note: swift-nio-ssh already carries the GHSA-998x-vgvp-xwpc fix ({path})")
        return 0
    for old, new in REPLACEMENTS:
        if text.count(old) != 1:
            print(f"error: {path} does not have the code the GHSA-998x-vgvp-xwpc fix applies to "
                  f"(expected once: {old.strip()!r}). Check the swift-nio-ssh version Citadel "
                  "resolved and update scripts/patch-swift-packages.py.", file=sys.stderr)
            return 1
        text = text.replace(old, new)
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(text)
    print(f"note: applied the GHSA-998x-vgvp-xwpc fix to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
