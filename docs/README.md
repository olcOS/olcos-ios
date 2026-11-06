# olcOS documentation

Start with the [product overview](../README.md) ([English](../README.en.md)), then choose a guide:

| Guide | Audience |
|---|---|
| [Setup and connection modes](setup.md) | Installing, adding a connection, preparing your VPS and understanding routing |
| [Build and verification](build.md) | macOS/Xcode setup, framework generation, tests and release artifacts |
| [Architecture](architecture.md) | Data paths, SSH control plane, lifecycle ownership and trust boundaries |
| [URI and subscription formats](uri.md) | Connection sharing, import behavior and secret handling |
| [Diagnostic messages](diagnostic-messages.md) | Looking up emitted codes and reporting a reproducible failure |
| [Security policy](../SECURITY.md) | Private reporting and security limitations |
| [Contributing](../CONTRIBUTING.md) | Pull requests, style and verification evidence |
| [Technical contract](../AGENTS.md) | Essential constraints for repository changes |

The public product name is **olcOS**, version **3.5 (build 4)**, tag `v3.5`
in [olcOS/olcos](https://github.com/olcOS/olcos/releases). The release before
it was 3.0 (build 3), tag `v3.0.3-beta`.
Internal targets and URI schemes retain their compatible `olcrtc` names; this
is not a separate protocol. [Project](../project.yml) · [URI implementation](../App/Models/OlcrtcURI.swift).

The screenshots in `assets/screens.png` are native app screenshots from a CI
run. The older `assets/olcos-preview.png` (Russian) and
`assets/olcos-preview-en.png` (English) are a **UI concept preview**, not a
native screenshot, benchmark or test result; their HTML source and render
script live in `assets/src/`. `assets/social-preview.png` is the image for the
repository's social preview (Settings → Social preview).

The Go core shared with the
[Android app](https://github.com/olcOS/olcos-android) lives in
[olcOS/olcos-core](https://github.com/olcOS/olcos-core), the `olcos-core/`
submodule here: the olcrtc client with the olcOS commits, the tun2socks glue,
room bonding, the server agent, the Xray engine and the server scripts. The
WebRTC core itself comes from the separate
[ghostlane-project/olcrtc](https://github.com/ghostlane-project/olcrtc)
project. Follow its documentation for protocol/server details, and use this
repository's guides for iOS-specific behavior and limitations. Windows and
macOS clients are plans only.
