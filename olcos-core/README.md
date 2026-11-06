# olcos-core

Shared Go core for olcOS clients: one `Engine` contract, two transports.

| Engine | Transport | Status |
|---|---|---|
| `olcrtc` | WebRTC data channels over Jitsi/Telemost carriers | wrapper stub (runtime hookup in M3) |
| `xray` | VLESS + REALITY + XTLS-Vision (xray-core) | working: embedded xray-core, SOCKS variant, traffic counters |

## Layout

```
engine/          Engine, Session, Host, Profile contracts + registry
engine/olcrtc/   olcrtc engine (wraps upstream mobile + tunstack)
engine/xray/     Xray engine: config renderers, trimmed distro, embedded runtime
cmd/olcos-cli/   desktop harness: start a share link, print SOCKS addr + counters
profile/         vless:// (#716), olcrtc://, subscription parsing/export
olcos/           gobind-facing API (binds as Olcos*): Runtime, Invoke(method, json)
server/xray/     Podman install/uninstall scripts for the REALITY server
docs/HANDOFF.md  full context, architecture, plan, research citations (RU)
docs/research/   research notes with source URLs
```

## Build and test

```
gofmt -l .
go vet ./...
go test ./...
bash -n server/xray/*.sh
```

Go 1.27 or newer. The only direct dependency is `github.com/xtls/xray-core`
(MPL-2.0), registered through the trimmed list in `engine/xray/distro.go`.

End-to-end check against a running server:

```
go build -trimpath -ldflags='-s -w' -o /tmp/olcos-cli ./cmd/olcos-cli
OLCOS_URI='vless://...' /tmp/olcos-cli -duration 30s
curl --socks5-hostname 127.0.0.1:<port> https://ifconfig.me/ip
```

## Server

```
OLCOS_XRAY_TARGET=www.example.com OLCOS_XRAY_ALLOW_NOSNI=1 OLCOS_XRAY_BBR=1 \
  server/xray/install.sh
```

The script pins `ghcr.io/xtls/xray-core:26.3.27`, probes the target with
`xray tls ping` (TLS 1.3, H2, chain < 8192 bytes), generates the keys in
one-shot containers and prints the `vless://` share link.

## Private

This repository is private by the owner's decision until further notice.
See [AGENTS.md](AGENTS.md) for the contribution and publication rules.
