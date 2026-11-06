# Build and verification

[Overview](../README.md) · [Contributing](../CONTRIBUTING.md)

## Prerequisites

Use macOS with **full Xcode**, an iOS SDK/runtime appropriate to the iOS 17+
deployment target, XcodeGen and GitHub CLI. Building the core from source also
needs Go, the version `olcos-core/mobile/go.mod` names, not an arbitrary older
compiler. The core's build script installs a matching gomobile tool version.
[Project configuration](../project.yml) · [framework script](../scripts/build-framework.sh) ·
[core Go module](https://github.com/olcOS/olcos-core/blob/main/mobile/go.mod).

These are instructions, **not a record of a successful build**. Record the
exact Xcode, SDK, device/simulator and command when reporting your own result.

## Clone and prepare

```bash
gh repo clone olcOS/olcos-ios -- --recurse-submodules
cd olcos-ios
git submodule update --init --recursive
xcode-select -p
xcodebuild -version
```

If `xcode-select -p` points at standalone Command Line Tools, select your full
Xcode installation before building, for example:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Accept Xcode's license and install the needed iOS platform/runtime through
Xcode if prompted. Install XcodeGen, GitHub CLI and Go with your preferred
package manager; with Homebrew:

```bash
brew install xcodegen gh go
```

### Option A — build the framework from source

```bash
./scripts/build-framework.sh
```

The Go core lives in the `olcos-core` submodule
([olcOS/olcos-core](https://github.com/olcOS/olcos-core)), the same core the
Android app binds. The script calls its `scripts/build-ios.sh`, which binds
the olcrtc client (`olcrtc/`: a release of
[ghostlane-project/olcrtc](https://github.com/ghostlane-project/olcrtc), the
Apache-2.0 continuation of the archived upstream, plus the olcOS commits),
`mobile/tunstack`, `mobile/bond` and the Xray engine (package `olcos`) into one
`App/Mobile.xcframework`. Nothing is patched or copied into the tree for the
build: the olcOS changes are commits in olcos-core.

The server runs the same core. `olcos-core/server/olcrtc-core.patch` is the
olcOS commits as one patch series on top of the upstream commit both sides pin
(`AppConstants.upstreamCorePin`, `OLCRTC_COMMIT` in `olcos-core/olcrtc.upstream`).
The app bundles it with `srv.sh`, and the install and the app's server update
apply it before building the server. Today the series carries the Telemost
framing (each frame one RTP packet, data as interframes, keyframes rare, paced
at what comes back acknowledged), which Telemost's media server needs since
October 2026. A server records the series' SHA-256 in
`<deploy dir>/.olcos-core-patch` once it applied it, and the app compares
that, with the commit, to tell a current core from a stale one.
[Build implementation](../scripts/build-framework.sh) ·
[how olcos-core tracks olcrtc](https://github.com/olcOS/olcos-core/blob/main/docs/olcrtc.md) ·
[wiring checks](../scripts/test_core_patch.py).

The app shows the licence and notice texts of everything it links (Settings →
About → Open-source licences). The core's files in `App/Licenses/olcrtc-*.txt`
are verbatim copies of the submodule's `LICENSE`, `NOTICE` and
`docs/upstream-license-wtfpl.txt`; the Go modules and Swift packages are
generated into `App/Licenses/third-party-*.txt` by
`python3 scripts/gen-third-party-notices.py`. Refresh both whenever the
olcos-core submodule or the Swift packages change; `Tests/test_licenses.py`
fails on a stale core copy.

Rebuild when the olcos-core submodule moves or the build scripts change; an
older binary is not proof that newly referenced generated symbols exist.
[Framework inputs](../scripts/build-framework.sh).

### Option B — fetch a matching released framework

Only if the selected release actually contains `Mobile.xcframework.zip`,
`framework-provenance.json` and `SHA256SUMS`:

```bash
GH_REPO=olcOS/olcos ./scripts/fetch-framework.sh v2.0.2
```

The script needs `gh`, `unzip` and `python3`. It downloads the three assets
through `gh`, verifies the archive against `SHA256SUMS`, and refuses a binary
whose provenance `input_sha256` does not match the fingerprint of your
checkout (the olcos-core commit and the build scripts; local edits in the
submodule never match). Only then does it replace `App/Mobile.xcframework`. Run it
without a tag to use the default from `scripts/cut-release.py --dry-run`;
`./scripts/fetch-framework.sh --cache-key` prints the fingerprint used for
CI caching. Authenticate with `gh auth login` if your environment requires it.
If the release or asset is absent, build from source; do not assume every tag
has a completed or validated release artifact. Inspect release provenance and
match the binary to the source revision you intend to test.
[Fetch script](../scripts/fetch-framework.sh) ·
[release workflow definition](../.github/workflows/release.yml).

## Generate and open

```bash
xcodegen generate --spec project.yml
open olcrtc-ios.xcodeproj
```

`project.yml` is authoritative. Regenerate when it changes or source/resource
membership changes; do not edit generated project/plist output as the fix.
XcodeGen generates one scheme per target: use `olcrtc-ios` to run the app and
`olcrtc-ios-tests` for tests; the embedded extension targets are `olcrtc-tunnel`
(the VPN) and `olcrtc-widgets` (widgets and the iOS 18 Control Centre toggle). [Project specification](../project.yml).

For device installation, configure signing consistently for the app and
extensions, retaining the `<app bundle id>.tunnel` and `<app bundle id>.widgets`
relationships, the required NetworkExtension entitlements and the shared App
Group `group.io.github.hotelk52339.olcrtc-ios` (app, tunnel and widgets). Without
the App Group the widgets still install and switch the tunnel, but cannot show
its state. Signing capability must be verified on the installed build; a
successful unsigned compile does not establish it.
[Provider identifier](../App/Core/VPNController.swift) ·
[app entitlements](../App/Entitlements.plist) · [extension entitlements](../Tunnel/Entitlements.plist) ·
[widget entitlements](../Widgets/Entitlements.plist).

## Simulator build and tests

Select an available iPhone simulator UDID rather than assuming a device model
exists in every Xcode release:

```bash
xcrun simctl list devices available
UDID="<available-iPhone-simulator-UDID>"

xcodebuild build \
  -project olcrtc-ios.xcodeproj \
  -scheme olcrtc-ios \
  -destination "id=$UDID"

xcodebuild test \
  -project olcrtc-ios.xcodeproj \
  -scheme olcrtc-ios-tests \
  -destination "id=$UDID"
```

For a focused regression, append a real test class, for example:

```bash
xcodebuild test \
  -project olcrtc-ios.xcodeproj \
  -scheme olcrtc-ios-tests \
  -destination "id=$UDID" \
  -only-testing:olcrtc-ios-tests/SSHHostKeyVerificationTests
```

Even simulator builds need the initialized olcos-core submodule: the app
bundles the server scripts and Go sources from it. Simulator testing cannot
validate a running iOS packet-tunnel provider or device entitlement behavior.
[Project](../project.yml) · [test class](../Tests/SSHHostKeyVerificationTests.swift).

## Additional checks

Choose checks relevant to your diff; these are available commands rather than
a claim that every platform can execute every check:

**Foundation-only animation regressions on Linux:** with a Swift toolchain
providing XCTest, run `bash scripts/test_firewall_model.sh` (or set `SWIFTC`
to the compiler's absolute path). This compiles the pure firewall state model
and executes its sequence, cancellation, intensity, haptic-policy and
wall-geometry tests.
It does **not** compile SwiftUI, render the hero or replace native Xcode tests.

**Linux server checks:** run the following group on Linux (for example an
Ubuntu runner, VM or container) with Python 3, Bash and GNU command-line tools.
The SSH audit executes Linux server-shell fragments; macOS's default BSD
`sed` is not an equivalent test environment, even though the harness is Python.
Do not classify those platform failures as native iOS test failures.
[SSH audit harness](../scripts/test_ssh_audit_481.py) ·
[server scripts](https://github.com/olcOS/olcos-core/tree/main/server).

```bash
python3 olcos-core/scripts/parity_check.py
python3 scripts/test_ssh_audit_481.py
bash -n olcos-core/server/srv.sh olcos-core/server/add-carrier.sh olcos-core/server/rotate-key.sh
```

The parity check (srv.sh against upstream's `install.sh`) belongs to
olcos-core and runs in its CI; this repository's CI runs it again with the
Linux source tests. It can also run on macOS; that does not make the
shell-executing SSH regressions portable to BSD tooling.
[Parity checker](https://github.com/olcOS/olcos-core/blob/main/scripts/parity_check.py).

**macOS native toolchain checks:**

```bash
# Checks the Go packet adapter and bonding in the core
# (bond's tests run shaped in-process lanes for a few seconds).
(cd olcos-core/mobile && go test ./tunstack ./bond/...)

# Requires SwiftLint.
swiftlint lint
```

The Python tests use local fixtures/mocks and do not prove a live SSH or VPS
deployment. `go test ./tunstack` checks the package; if it reports
`[no test files]`, report that literally, not as packet regression tests passing.
CI's configured checks also include Xcode tests and SwiftLint, with docs-only
path exclusions. A workflow definition or cache hit is not test evidence.
[SSH audit tests](../scripts/test_ssh_audit_481.py) ·
[tunstack](https://github.com/olcOS/olcos-core/tree/main/mobile/tunstack) · [CI](../.github/workflows/ci.yml).

### Native-device evidence

For a VPN-affecting change, verify the installed app's actual permission gate,
consent behavior, start/stop, cleanup, network changes and lock/unlock recovery.
Check IPv4 TCP, DNS-over-TCP behavior, dropped IPv6/UDP and unsupported settings
without interpreting a leak or direct retry as successful forwarding.
Use a test server/account and attach sanitized evidence.
[Provider boundary](../Tunnel/PacketTunnelProvider.swift) ·
[lifecycle controller](../App/Core/VPNController.swift).

For UI changes, capture native screenshots with device/OS/build details and
check RU/EN/FR, accessibility and Reduce Motion. Physical haptics need a
device; conceptual artwork is not a substitute for rendered UI evidence.
[Localization](../App/Localization/L10n.swift) · [interaction policy](../App/Views/SignalWaveform.swift).

### Localization and release tooling

User-facing strings are keyed in `App/Localization/L10n.swift`, with EN/RU
values in `L10nTable.swift` and FR values in `L10nFrench.swift`. Edit them
with the lock-protected helper instead of by hand, and verify the three files
stay aligned:

```bash
python3 scripts/dev/l10n.py add KEY --en "English" --ru "Русский" --fr "Français"
python3 scripts/dev/l10n.py check
```

The release identity comes from `project.yml`; these read-only helpers print
the planned tag and validate the pipeline without tagging or publishing:

```bash
python3 scripts/cut-release.py --dry-run
python3 scripts/test_release_pipeline.py
```

## Package an unsigned IPA

After obtaining the framework (the script regenerates the Xcode project
itself):

```bash
./scripts/package-ipa.sh
```

The output is `olcos-ios-unsigned.ipa`; the script checks that
`olcrtc-tunnel.appex` is embedded. The IPA is **unsigned**, so installing it
requires appropriate signing and is not equivalent to App Store distribution
or verified VPN support. [Packaging script](../scripts/package-ipa.sh).

The olcOS 2.0 release identity is version **2.0**, build **2**, tag **v2.0.2**.
The release owner coordinates versions and publication; do not tag, publish
or change version counters as an incidental build step.

## Troubleshooting

| Failure | Action |
|---|---|
| Missing `olcos-core` files | Run `git submodule update --init --recursive`; verify the checked-out core commit. |
| `Mobile.xcframework` missing | Use Option A or a matching asset from Option B, then regenerate the project. |
| gomobile cannot find Xcode/iOS SDK | Check `xcode-select -p`, full Xcode installation and platform components. |
| Unknown simulator destination | List available devices and replace the placeholder UDID. |
| Parity reports drift | A change for olcos-core: inspect its `server/srv.sh` against upstream's `install.sh` and adopt or explicitly reject upstream changes under the checked markers. Never disable parity as a workaround. |
| VPN permission fails on device | Inspect installed signing/entitlements and iOS permission evidence; do not infer capability from the signing-account label. |
| Network operation fails in otherwise green tests | Isolate the actual device/network/server path; mocks and simulator compilation are not end-to-end proof. |

The underlying diagnostics are implemented in the [framework scripts](../scripts/build-framework.sh),
[parity checker](https://github.com/olcOS/olcos-core/blob/main/scripts/parity_check.py), [project](../project.yml) and
[VPN controller](../App/Core/VPNController.swift).
