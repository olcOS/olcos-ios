<p align="center">
  <img src="docs/assets/app-icon.png" width="96" height="96" alt="olcOS">
</p>

<h1 align="center">olcOS for iPhone and iPad</h1>

<p align="center">
  Source code of the olcOS app for iOS and iPadOS 17+.<br>
  olcOS helps you get around mobile internet whitelists through video calls.
</p>

> [!IMPORTANT]
> **Just want to install the app?** This repository holds the source code. The ready-made file and step-by-step
> iPhone instructions are in the [main olcOS repository](https://github.com/olcOS/olcos/blob/main/README.en.md#iphone-and-ipad)
> and on the [website](https://olcos.github.io/en/#download).

<p align="center">
  <a href="https://github.com/olcOS/olcos/blob/main/README.en.md#iphone-and-ipad"><img src="docs/assets/btn-iphone-en.png" width="219" height="56" alt="Install on iPhone and iPad"></a>&nbsp;
  <a href="https://github.com/olcOS/olcos/blob/main/README.en.md#android"><img src="docs/assets/btn-android-en.png" width="159" height="56" alt="Download for Android"></a>
</p>

<p align="center">
  <a href="https://olcos.github.io/en/">Website</a> ·
  <a href="https://github.com/olcOS/olcos/blob/main/README.en.md">User guide</a> ·
  <a href="https://github.com/olcOS/olcos/blob/main/README.en.md#troubleshooting">Troubleshooting</a> ·
  <a href="https://github.com/olcOS/olcos-android">Android</a> ·
  <a href="README.md">Русский</a>
</p>

<p align="center">
  <img src="docs/assets/screens.png" width="760" alt="olcOS on iPhone: home screen, the whole-server connection and the per-room speed test">
</p>

## What it is

olcOS sends the internet traffic of your iPhone or iPad through your own server. The traffic travels inside an
ordinary video call (WebRTC) on one of the calling services the app supports. The list lives in the app and grows with
updates. When mobile internet only works through a whitelist, an ordinary VPN can't reach its server, while a call to
a whitelisted service gets through. Without whitelists the phone can also connect to the server directly over Xray
(VLESS + REALITY), so the speed isn't limited by the call.

You need an iPhone or iPad with iOS 17 or later. The IPA is about 55 MB and is installed from a computer.

How whitelists work, how to install the app and how to set up a server is explained in the
[main repository](https://github.com/olcOS/olcos/blob/main/README.en.md).

The app is available in English, Russian and French; switch the language in Settings.

## Features

- Connect with a link, QR code, file, subscription or a ready-made list. When a server stops answering, the app moves
  to another one that works.
- Install your own server over SSH. One server can run several protocols, and the Whole server connection bonds
  their rooms into one channel.
- Live speed for each protocol on the home screen, and a connection check that measures every room on its own and
  all of them together.
- If you want, Russian sites such as banks and government services can go directly, outside the tunnel. You can add
  your own list.
- A VPN for the whole device, or a SOCKS5 proxy for apps that support one: Telegram, Potatso, Shadowrocket.
- Widgets for the Home Screen, Lock Screen and Control Center, and a Live Activity with the speed in the Dynamic
  Island.
- Auto-connect on mobile data and on chosen Wi-Fi networks.
- Invites for other devices, including invites that allow server management. olcOS for Android accepts them too.
- Settings for those who know what they change: VP8 video channel frames and packets (30 frames of 64 packets by
  default), DNS, proxy port and login. Xray connections let you change the server, SNI, flow, TLS fingerprint and
  short ID.

## Modes

| | VPN | SOCKS5 proxy |
|---|---|---|
| What goes through the tunnel | the whole device | apps that have the proxy set |
| Needs a paid signature | yes | no |
| Whole server | trial, up to three rooms | all rooms |

With a free Apple ID, iOS does not give the app VPN mode, so only the proxy works. More about modes, routing and VPN
limitations in [docs/setup.md](docs/setup.md).

## Building from source

You need macOS with Xcode 15 or later, XcodeGen, Go and the GitHub CLI.

```bash
gh repo clone olcOS/olcos-ios -- --recurse-submodules
cd olcos-ios
./scripts/build-framework.sh
xcodegen generate --spec project.yml
open olcrtc-ios.xcodeproj
```

The Go core and the server side live in a separate repository, [olcOS/olcos-core](https://github.com/olcOS/olcos-core),
included here as the `olcos-core/` submodule. The Android app uses the same core: the olcrtc client, the tunnel glue,
room bonding, the server agent, the Xray engine and the server install scripts.

Documentation:

- [docs/build.md](docs/build.md): building, tests and release files;
- [docs/architecture.md](docs/architecture.md): how the app works;
- [docs/setup.md](docs/setup.md): modes, server setup and diagnostics;
- [docs/uri.md](docs/uri.md): link and subscription formats;
- [docs/diagnostic-messages.md](docs/diagnostic-messages.md): diagnostic message codes;
- [CONTRIBUTING.md](CONTRIBUTING.md): how to propose changes.

## Bugs and security

Report bugs and questions in the [main repository's issues](https://github.com/olcOS/olcos/issues/new/choose). Attach
the logs (Settings → View all logs → Export all logs) and remove keys, passwords and full links from them first.
Report vulnerabilities privately, see [SECURITY.md](SECURITY.md).

Use the app within the law of your country and the terms of the services your traffic goes through.

## Licenses

olcOS is released under the [MIT](LICENSE) license, Copyright (c) 2026 Hotelk52339. The olcrtc core
([ghostlane-project/olcrtc](https://github.com/ghostlane-project/olcrtc), the continuation of the archived
[openlibrecommunity/olcrtc](https://github.com/openlibrecommunity/olcrtc)) is under [Apache-2.0](https://github.com/olcOS/olcos-core/blob/main/olcrtc/LICENSE)
with a [NOTICE](https://github.com/olcOS/olcos-core/blob/main/olcrtc/NOTICE); the original upstream license is
[WTFPL](https://github.com/olcOS/olcos-core/blob/main/olcrtc/docs/upstream-license-wtfpl.txt). Xray-core is under
[MPL-2.0](https://github.com/XTLS/Xray-core/blob/main/LICENSE).
