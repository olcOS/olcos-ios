#!/bin/bash
# The olcOS server installer lives in olcOS/olcos-core (server/install.sh), next
# to the server script and the agent it installs. This stub keeps the old address
# (raw.githubusercontent.com/olcOS/olcos-ios/main/scripts/install.sh) working: it
# runs the installer of the core commit this app is built on, the olcos-core
# submodule (scripts/test_install_stub.py holds the two together), and that
# installer fetches its files from the same commit. Settings are the same
# environment variables. The usual command is
#
#   curl -fsSL https://raw.githubusercontent.com/olcOS/olcos/main/install.sh | sudo bash
set -euo pipefail

CORE_COMMIT="6d078cfc26250cdf4b44d39ccff8993182b47b91"
SOURCE="https://raw.githubusercontent.com/olcOS/olcos-core/$CORE_COMMIT"
URL="$SOURCE/server/install.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP"
# A page that is not a shell script (an error page, a captive portal) must not run as root.
head -n 1 "$TMP" | grep -q '^#!.*\(ba\)\?sh' || { echo "olcOS: the installer could not be fetched from $URL" >&2; exit 1; }
OLCOS_SOURCE="${OLCOS_SOURCE:-$SOURCE}" bash "$TMP" "$@" < /dev/null
