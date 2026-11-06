#!/usr/bin/env bash
# #253: Build App/Mobile.xcframework with gomobile — the olcrtc core's mobile
# package (ghostlane-project/olcrtc, which continues the archived upstream),
# the local tun2socks glue (gomobile/tunstack, #vpn), the bonding client
# (gomobile/bond, binds as Bond*) and the olcos-core Xray
# engine (package olcos, binds as Olcos*), bound TOGETHER from the gomobile/
# wrapper module into ONE xcframework (two separately built gomobile
# frameworks cannot be linked into one binary: duplicate Go runtimes).
#
# olcos-core is the second submodule (olcos-core/), consumed through a replace
# directive in gomobile/go.mod: `git submodule update --init --recursive`.
#
# Single source of truth for the framework build — humans, CI (ci.yml) and the
# release workflow (release.yml) all call this. Prefer the prebuilt download
# (./scripts/fetch-framework.sh) unless you are building against a moved submodule
# pin or changing olcrtc-upstream/mobile/*.go, scripts/mobile-shim/*,
# scripts/olcrtc-core.patch or gomobile/tunstack/*.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/olcrtc-upstream"
CORE="$ROOT/olcos-core"
OUT="$ROOT/App/Mobile.xcframework"
CORE_PATCH="$ROOT/scripts/olcrtc-core.patch"

# #442: upstream master split mobile.go into runtime.go/config.go/probe.go/… —
# guard on runtime.go, the entry point of the new instance API.
if [ ! -f "$UPSTREAM/mobile/runtime.go" ]; then
  echo "error: $UPSTREAM/mobile/runtime.go missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

if [ ! -f "$CORE/go.mod" ]; then
  echo "error: $CORE/go.mod missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go toolchain not found. Install Go (the version pinned in gomobile/go.mod), e.g. 'brew install go'." >&2
  exit 1
fi

# gomobile installs into $(go env GOPATH)/bin, which isn't on PATH by default.
export PATH="$PATH:$(go env GOPATH)/bin"

# #vpn: resolve the wrapper module's deps and (re)generate gomobile/go.sum —
# it is not committed, and both `go list -m` and the bind below need it.
(cd "$ROOT/gomobile" && go mod tidy)

# #442: pin the gomobile CLI to the x/mobile version the wrapper module requires
# (gomobile/go.mod keeps it in lockstep with olcrtc-upstream/go.mod), so the
# code generator and the bound runtime (golang.org/x/mobile/bind) cannot drift
# (installing @latest risks a generator/runtime mismatch).
GOMOBILE_VER="$(cd "$ROOT/gomobile" && go list -m -f '{{.Version}}' golang.org/x/mobile)"
echo "note: installing golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VER} ..."
go install "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VER}"
gomobile init

# Build-time shims copied into the submodule for the duration of the bind and
# trap-removed afterwards, so the submodule stays clean even if the bind fails.
# The core (ghostlane-project/olcrtc) already provides SetLogWriter,
# FreeOSMemory, constrained smux buffers on phones and the utun filter, so only
# two small differences remain:
#   logflags      pins the stdlib log prefix to time-only ("15:04:05 "), the
#                 line shape LogStore and WedgeDetector were built against.
#   protect_ipsec adds "ipsec" to pion's tunnel-interface filter (the core
#                 lists tun/utun/ppp/pptp).
SHIM_DSTS=(
  "$UPSTREAM/mobile/zz_olcos_logflags.go"
  "$UPSTREAM/internal/protect/zz_olcos_ipsec.go"
)

# scripts/olcrtc-core.patch, when present, is olcOS's patch series for the
# pinned core — the same file srv.sh and the app's server update apply, so the
# framework and the server run the same code. Today it carries Telemost's
# single-packet framing. It only modifies tracked files, so restoring the
# files it touches undoes it.
PATCHED_FILES=()
if [ -s "$CORE_PATCH" ]; then
  while IFS=$'\t' read -r _ _ path; do
    PATCHED_FILES+=("$path")
  done < <(git -C "$UPSTREAM" apply --numstat "$CORE_PATCH")
fi
restore_patched() {
  if [ "${#PATCHED_FILES[@]}" -gt 0 ]; then
    git -C "$UPSTREAM" checkout -- "${PATCHED_FILES[@]}"
  fi
}
trap 'rm -f "${SHIM_DSTS[@]}"; restore_patched' EXIT

# Self-heal: if a previous run died before its trap could fire (e.g. SIGKILL),
# the files the series touches may still carry it — restore them first so the
# series below applies again and reruns stay idempotent.
restore_patched
if [ -s "$CORE_PATCH" ]; then
  git -C "$UPSTREAM" apply "$CORE_PATCH"
fi

cp "$ROOT/scripts/mobile-shim/logflags.go"      "${SHIM_DSTS[0]}"
cp "$ROOT/scripts/mobile-shim/protect_ipsec.go" "${SHIM_DSTS[1]}"

echo "note: gomobile bind -target=ios -> $OUT (~5 min on first run) ..."
cd "$ROOT/gomobile"
# -trimpath/-ldflags strip build paths and symbols (smaller framework, no
# host paths in the binary); -checklinkname=0 is required by xray-core's
# dependencies that use go:linkname.
gomobile bind -target=ios -trimpath -ldflags='-s -w -buildid= -checklinkname=0' -o "$OUT" \
  github.com/openlibrecommunity/olcrtc/mobile ./tunstack ./bond github.com/Hotelk52339/olcos-core/olcos

echo "done:  $OUT"
echo "next:  xcodegen generate --spec project.yml   # so Xcode picks up the framework"
