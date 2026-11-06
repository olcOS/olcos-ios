# Connection links and subscriptions

[Setup](setup.md) · [Security](../SECURITY.md)

olcOS retains the `olcrtc://` and `olcrtc-sub://` schemes for compatibility;
the product rename does not create a new wire protocol.
[URL registration](../project.yml) · [URI parser](../App/Models/OlcrtcURI.swift).

**Treat all working connection links, QR codes, subscription URLs and payloads
as secrets.** A plain connection URI contains the shared room key.
[Encoder](../App/Models/OlcrtcURI.swift).

## Plain connection URI

```text
olcrtc://<carrier>?<transport>[<params>]@<roomID>#<key>[%<clientID>][$<name>]
```

Angle-bracket names above are placeholders, not literal values.
The app's encoder/parser defines these fields:
[OlcrtcURI](../App/Models/OlcrtcURI.swift).

| Field | Meaning |
|---|---|
| `carrier` | Carrier identifier: `telemost`, `vkcalls`, `salutejazz`, `mtslink`, `wbstream` or `jitsi`. A `vkcalls` room is the call link `https://vk.com/call/join/<id>` (or vk.ru); a `salutejazz` room is `<code>:<password>`; an `mtslink` room is a permanent meeting's link `https://my.mts-link.ru/j/<owner>/<event>`, which may end in an `?ice=tcp` / `udp` / `both` hint (a server config always carries one: the typed hint, else `?ice=both`; the phone keeps what was typed and connects over TCP without a hint). A link such as `…/j/<owner>/<event>/stream-new/<session>` is the same room |
| `transport` | `datachannel`, `vp8channel`, `seichannel` or `videochannel`; parsing a value does not establish runtime support |
| `[params]` | Optional transport-specific `key=value` pairs |
| `roomID` | Room identifier; may be a full room URL |
| `key` | Shared room key; connection validation expects 64 hexadecimal characters |
| `%clientID` | Optional compatible client identifier; absent means `default`, and the encoder omits `%default` |
| `$name` | Optional connection/configuration name, represented by `mimo` in the model |

Runtime constraints, including carrier combinations and VPN's rejection of
`videochannel`, apply after URI parsing.
[Connection validation](../App/Core/TunnelManager.swift) ·
[provider validation](../Tunnel/PacketTunnelProvider.swift).

### Transport parameters

The encoder writes square brackets and comma-separated parameters, for example:

```text
vp8channel[vp8-fps=15,vp8-batch=8]
seichannel[fps=30,batch=10,frag=1200,ack-ms=1]
```

The parser also accepts the server-script angle-bracket form, for example
`vp8channel<vp8-fps=15&vp8-batch=8>`. It rejects mixed bracket syntax, routes
parameter names according to transport, ignores unknown keys and handles
percent-encoded payload delimiters. The examples are syntax illustrations,
not recommended tuning or measured performance.
[Parser and encoder](../App/Models/OlcrtcURI.swift) ·
[payload tests](../Tests/OlcrtcURIPayloadTests.swift).

The URI is not a complete export of local settings, SSH trust or every
credential. SOCKS credentials and provider tokens are separate model/storage
fields; do not assume a URI preserves everything needed for every carrier.
[Connection model](../App/Models/OlcrtcConnection.swift) · [secret store](../App/Security/ConnectionSecretStore.swift).

The key is excluded from ordinary saved connection JSON, but a shared URI
contains it in plaintext. VPN startup also passes the key through system
preferences, so “the URI is the only plaintext location” would be incorrect.
[Connection encoding](../App/Models/OlcrtcConnection.swift) · [VPN configuration](../App/Models/VPNConfig.swift).

## Subscription links

```text
olcrtc-sub://<host>[:port]/<path>[?query]
```

The app replaces the scheme with `https`, preserving the host/path/query:

```text
olcrtc-sub://pool.example.org/sub
https://pool.example.org/sub
```

The payload is the upstream plain-text list format: global `#key: value`
fields, one connection URI per line and per-server `##key: value` fields.
The scheme is an iOS-client convention; the list format is documented by
[upstream](../olcrtc-upstream/docs/sub.md).

The app fetches via HTTPS and shows an import confirmation. `#name` becomes a
group, and entries use `##name` with fallback naming; unknown fields are ignored.
A list may also carry `vless://` lines (see below); `##` fields after one
describe that Xray connection. The import sheet also accepts a plain `https://`
subscription URL and a pasted sub.md body (lines of `olcrtc://` / `vless://`
links with `#`/`##` marker lines) without fetching. Plain `http://` subscription sources are rejected, and the fetcher
implements a DoH fallback while preserving TLS host validation.
[Subscription model](../App/Models/OlcrtcSubscription.swift) ·
[fetcher](../App/Services/SubscriptionFetcher.swift).

Reimporting the same source computes additions, updates and removals using
connection identity, including the key. A changed key can therefore change
node identity; do not promise that every server-side change preserves the
same record or selection. An entry that sets `##id: <stable id>` is matched by
that id alone, so a list that keeps the id while the room or key changes (a
renewed Telemost room, a re-keyed server) updates the saved connection in
place. `##id` is an olcOS extension; other clients ignore it.

`##lanes: <room>,<room>` (also an olcOS extension) lists more rooms of the same
server and carrier. The app joins all of them at once and spreads new
connections over the rooms that are up, so their speeds add up for anything
that opens several connections.

`##with: <carrier>?<transport>@<room>,…` (an olcOS extension) makes the entry a
whole-server connection: the server's other protocols, each lane with its own
carrier, transport and room, joined with the entry's own under its key and
device id. `##bond: <host>:<port>` (an olcOS extension) names the server's bond
endpoint; with it, every connection an app opens is carried over all lanes at
once, so a single download gets the sum of their speeds and survives a lane
dropping out. Without it the lanes take turns per connection. An entry with
`##with` is a different connection from the entry of its first protocol even
without `##id`. Other clients ignore both fields and see the first protocol.

The refresh interval is scheduling metadata, not an always-running iOS
background timer.
[Diff and refresh implementation](../App/Core/ConnectionStore.swift).

Only subscribe to operators you trust: a list update can change the
connections you use. Subscription query parameters may themselves contain
access tokens; remove the entire sensitive URL from public reports.

## Device invite links

```text
olcrtc-sub://<vps>:<port>/<token>?enc=v1#<key>
```

Manage server → Devices creates one per device. The phone that holds the
server's SSH access uploads a subscription list for it to the VPS, where a
busybox httpd container (`olcos-share`, `/opt/olcos-share`) serves the file
`<token>` over plain HTTP on a random high port. The file is
`olcos1:` + base64 of AES-256-GCM (nonce, ciphertext, tag); the key is the
link's fragment (base64url, 32 bytes), which no request carries. Every entry
has `##id: <record id>`, so when the server's connections change (a renewed
Telemost room, a rotated key, an added protocol) the publishing phone uploads
the new list and the invited device updates the same connections on its next
refresh (`#refresh: 30m`, on opening the app, or a pull).

The invited device stores the link without its fragment as the subscription
source and the key in its Keychain. A missing file (HTTP 404) means the invite
was revoked; the device keeps what it has, because only a rotated server key
closes access. The fetch needs the VPS to be reachable directly: on a network
that only lets whitelisted sites through, it waits for another network.

Every `olcrtc://` line of an invite's list carries `%inv-<tag>`, where `<tag>`
is the first 8 lowercase hex digits of SHA-256 of the invite's token (UTF-8);
`vless://` lines are unchanged. A client whose clientID is exactly
`inv-` + 8 lowercase hex digits announces `inv-<tag>-<its own device name>`
(for example `inv-1a2b3c4d-quiet-harbor-42`), so several installs of one
invite never share an identity, and the owner's server agent (`GET usage`)
tells which invite each device came in on. Any other clientID is announced as
before.
[Invite model](../App/Models/DeviceInvite.swift) ·
[fetcher](../App/Services/InviteFetcher.swift) ·
[publisher](../App/Services/InviteSync.swift) ·
[server scripts](../App/Core/SSHRunner+Share.swift).

## VLESS · REALITY link (xray engine)

```text
vless://<uuid>@<host>:<port>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<sni>&fp=chrome&pbk=<pbk>&sid=<sid>&spx=%2F&type=tcp#<name>
```

The common client-link shape for an Xray VLESS server behind REALITY. The app
accepts it from the same paste / QR / share venues as an `olcrtc://` link and
stores it as a separate connection kind; it is carried by the embedded
[olcos-core](../olcos-core) engine, not by the olcrtc core. Only
`security=reality`, `type=tcp` and `encryption=none` are supported; other
variants are rejected with a readable error rather than stored. `pbk` and `sni`
are required; `sid`, `fp` (default `chrome`), `flow` and `spx` (default `/`) are
optional. The UUID is the access credential: it lives in the Keychain, is never
displayed by the editor and is scrubbed from any shared VPN profile copy.
[XrayConnection](../App/Models/XrayConnection.swift).

## Retired SSH full-access link

```text
olcrtc://host/v1/<base64url-encoded-JSON>
```

Older versions could share a server's SSH login and password (or private key)
in this form. It is no longer created or imported: a device invite with
management access moves a server to another phone through its server agent.
An old link that is opened or pasted is recognised by its `olcrtc://host/`
prefix and answered with one line asking for such an invite; nothing is
stored. Such a link still carries a working SSH credential — change that
password or key if one was ever sent.
[RetiredFullAccessLink](../App/Models/RetiredFullAccessLink.swift).
