#!/usr/bin/env bash
# #253: Build App/Mobile.xcframework, the Go core of the app: the olcrtc
# client, tun2socks (tunstack), the bonding client (Bond*) and the Xray engine
# (Olcos*), bound together into ONE xcframework (two separately built gomobile
# frameworks cannot be linked into one binary: duplicate Go runtimes).
#
# The core lives in the olcos-core submodule (olcOS/olcos-core), the same core
# the Android app binds; this script only calls its iOS build:
#
#   git submodule update --init --recursive
#   ./scripts/build-framework.sh
#
# Single source of truth for the framework build — humans, CI (build.yml) and
# the release workflow (release.yml) all call this. Prefer the prebuilt
# download (./scripts/fetch-framework.sh) unless you moved the olcos-core
# submodule or changed the core in it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/olcos-core"
OUT="$ROOT/App/Mobile.xcframework"

if [ ! -f "$CORE/scripts/build-ios.sh" ] || [ ! -f "$CORE/olcrtc/mobile/runtime.go" ]; then
  echo "error: the olcos-core submodule is missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go toolchain not found. Install Go (the version in olcos-core/mobile/go.mod), e.g. 'brew install go'." >&2
  exit 1
fi

rm -rf "$OUT"
"$CORE/scripts/build-ios.sh" "$OUT"

echo "next:  xcodegen generate --spec project.yml   # so Xcode picks up the framework"
