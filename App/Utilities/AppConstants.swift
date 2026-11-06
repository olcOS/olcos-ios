import Foundation

// MARK: - AppConstants
//
// Centralised compile-time constants — endpoints, presets, fixed sizes.
// Pure values only: no state, no logic. Anything user-tunable lives in
// SettingsStore instead.
//
// The goal is to keep "what URL do we ping for X?" out of the view and
// service files so that swapping providers is a single-file change.

enum AppConstants {

    // #442: the olcrtc wire protocol (record layer, handshake, frame formats)
    // is NOT backward-compatible across upstream's #140 overhaul, and there is
    // no version negotiation — a client and server built from different commits
    // fail right after the handshake. The shipped Mobile.xcframework is built
    // from olcos-core's olcrtc/ tree: the upstream release named in
    // olcos-core/olcrtc.upstream (OLCRTC_COMMIT) plus olcos-core's patch
    // series, so the server MUST be built from the SAME commit and series.
    // srv.sh used to `git clone --branch master`, which silently tracked
    // upstream's moving tip and broke every install once master diverged (it
    // also flipped the `data:` config key to a fatal one).
    // This SHA is emitted as `OLCRTC_PIN` by `SSHRunner.installEnv` and pins the
    // server build. Keep it EQUAL to OLCRTC_COMMIT in olcos-core/olcrtc.upstream
    // (scripts/test_core_patch.py checks it): moving the olcos-core submodule
    // to a core on another upstream release means bumping this pin with it.
    // #442: migrated to upstream master (f616f57) — the #140 overhaul (new
    // OLC2/HKDF record layer, handshake v3, OLVC v5 frames, instance mobile API)
    // is a hard flag day: a server built from a different commit fails every
    // tunnel right after the handshake. Old 42ae4e0 servers MUST be reinstalled.
    // Upstream was archived on 2026-09-30; the core now comes from
    // ghostlane-project/olcrtc (Apache-2.0), which continues it on the same wire
    // format and negotiates its additions, so 54bd269 servers keep working with
    // this app until they run Update. `coreRepositoryURL` is where both the
    // install and the update fetch this commit from.
    static let upstreamCorePin = "0955ba7f2041d1480524292c4af4135a192fe267"
    static let coreRepositoryURL = "https://github.com/ghostlane-project/olcrtc.git"

    /// Go builder/toolchain image the server core is built (and rebuilt) in.
    /// Single source of truth for every Swift-side reference — the readiness
    /// probe (`podman image exists`), the Update Binary rebuild container, and
    /// deep uninstall's `podman rmi`. MUST stay equal to `IMAGE_NAME` in
    /// `olcos-core/server/srv.sh` (== upstream install.sh) — a drift would leave the
    /// readiness probe reporting `.noImage` forever after an upstream tag bump
    /// and deep uninstall stranding the old image. Guarded by
    /// `ServerScriptParityTests.testGoImageMatchesSrvShImageName`.
    static let serverGoImage = "docker.io/library/golang:1.26-alpine3.22"

    /// Image of the small web server that hands out device invites
    /// (SSHRunner+Share): busybox httpd, ~5 MB, pinned like the Go image.
    static let shareServerImage = "docker.io/library/busybox:1.37.0"

    /// URLs probed by `TunnelManager.verifyTunnel()` to confirm end-to-end
    /// traffic. Tried in order; the probe succeeds as soon as any returns 200.
    /// Fallbacks matter — `api.ipify.org` and `ipinfo.io` have both been
    /// observed to be blocked from some Russian carriers, leaving the
    /// probe permanently failing with only two entries. `ifconfig.me` is a
    /// third independent provider already trusted by `ipCheckServices`.
    static let tunnelVerifyURLs: [String] = [
        "https://api.ipify.org",
        "https://ipinfo.io/ip",
        "https://ifconfig.me/ip",
    ]

    /// The connect-time bulk leg for a DIRECT (Xray) connection. DPI on
    /// Russian networks lets a TLS connection to a foreign address carry its
    /// first 16–20 KB and then freezes it, so a tiny HTTP 200 alone can pass on
    /// a path that cannot load a page. 64 KB must arrive whole from either
    /// source. Both are served uncompressed — gzip would shrink the bytes that
    /// actually cross the tunnel — and the OVH file is cut with a Range request.
    static let tunnelBulkVerifySources: [(url: String, range: String?)] = [
        ("https://speed.cloudflare.com/__down?bytes=65536", nil),
        ("https://proof.ovh.net/files/1Mb.dat", "bytes=0-65535"),
    ]
    static let tunnelBulkVerifyBytes = 65_536
    static let tunnelBulkVerifyTimeout: TimeInterval = 10

    /// Endpoint probed by `TunnelManager.ping` (#234) to measure per-connection
    /// latency through an isolated MobilePing client. The classic connectivity
    /// "204 No Content" endpoint is ideal for an RTT probe: it returns an empty
    /// body, so the measured time reflects the round trip rather than payload
    /// transfer. Google is reachable from the RU carriers we target.
    static let pingProbeURL = "https://www.google.com/generate_204"

    /// Quick-pick DNS presets shown in Settings → DNS. `IP:port` strings
    /// passed verbatim to the Go runtime and to the server install script.
    /// Cloudflare is the default (`SettingsStore.Defaults.dnsServer`); Yandex
    /// stays as a preset for networks where public resolvers are intercepted.
    static let dnsPresets: [(label: String, value: String)] = [
        ("Cloudflare", "1.1.1.1:53"),
        ("Yandex",     "77.88.8.8:53"),
        ("Google",     "8.8.8.8:53"),
    ]

    /// Russian-carrier DNS presets — useful when the device is on cellular and
    /// the ISP intercepts requests to public resolvers (8.8.8.8 etc.). These
    /// resolve only from inside the carrier's network. Labels are L10n keys
    /// so carrier names follow the user's selected language.
    static let ruCarrierDnsPresets: [(label: L10n, value: String)] = [
        (.dnsLabelMts,     "213.87.0.1:53"),
        (.dnsLabelBeeline, "213.234.192.8:53"),
        (.dnsLabelMegafon, "83.149.32.66:53"),
        (.dnsLabelTele2,   "89.104.103.1:53"),
        (.dnsLabelYota,    "83.149.32.66:53"),   // MVNO on MegaFon, shares its DNS
    ]

    /// Public IP-echo services `IPChecker` can query (#286). The user picks which
    /// are active in Settings (persisted in `SettingsStore.enabledIPSources`,
    /// keyed by `label`), so this is the *catalogue* — querying all ten every
    /// time is slow and redundant once sources agree (#216 collapses them).
    /// Every entry returns a **bare IP over HTTPS** with a curl UA (verified
    /// 2026-06); JSON-only endpoints (e.g. `api.2ip.io`) are intentionally out.
    /// The RU / ru-zone block stays reachable when public resolvers are blocked
    /// from Russian carriers — `icanhazip.com` is in the catalogue but off by
    /// default (corporate Falcon MITM strips its certificate in some networks).
    static let ipCheckServices: [(label: String, url: String)] = [
        // International
        ("api.ipify.org",         "https://api.ipify.org"),
        ("ipinfo.io",             "https://ipinfo.io/ip"),
        ("ifconfig.me",           "https://ifconfig.me/ip"),
        ("icanhazip.com",         "https://icanhazip.com"),
        ("ident.me",              "https://ident.me"),
        ("ipapi.co",              "https://ipapi.co/ip"),
        ("checkip.amazonaws.com", "https://checkip.amazonaws.com"),
        // Russian / ru-zone
        ("2ip.ru",                "https://2ip.ru"),
        ("2ip.io",                "https://2ip.io"),
        ("ip.beget.ru",           "https://ip.beget.ru"),
    ]

    /// Labels of `ipCheckServices` enabled out of the box — a fast, balanced
    /// subset (three international + one RU) rather than all ten. The rest are
    /// opt-in via Settings. Used as the fallback when the user's enabled set is
    /// missing (first launch / migration) or empty.
    static let defaultEnabledIPCheckLabels: Set<String> = [
        "api.ipify.org", "ipinfo.io", "ifconfig.me", "2ip.ru",
    ]

    /// Speed-test configuration (#285).
    enum SpeedTest {
        static let pingSamples = 4             // first sample is discarded as warmup

        // Mode-aware payloads + timeouts. The tunnel (vp8channel ≈ <1 Mbps)
        // can't move 5 MB inside 60s, so it gets smaller transfers + more time.
        static let downloadBytesDirect = 5_000_000
        static let downloadBytesTunnel = 1_000_000
        static let uploadBytesDirect   = 2_000_000
        static let uploadBytesTunnel   =   500_000
        static let pingTimeoutDirect: TimeInterval = 5
        static let pingTimeoutTunnel: TimeInterval = 10
        static let xferTimeoutDirect: TimeInterval = 60
        static let xferTimeoutTunnel: TimeInterval = 90

        // User-selectable providers. Cloudflare is parametric (anycast, low RTT,
        // `/__down`+`/__up`+trace, no API key); OVH serves fixed-size files
        // (download + HEAD ping; no upload sink — #291 measures UL against the
        // Cloudflare fallback) and is the non-Cloudflare fallback when Cloudflare
        // is slow/blocked. Both verified to serve real bytes over HTTPS (2026-06).
        //
        // #292: Hetzner is a major global hosting provider (like OVH) with a
        // long-standing public speedtest mirror network (ash-speed.hetzner.com
        // et al.), verified 2026-06 to serve `100MB.bin` over HTTPS with a
        // correct Content-Length (104857600), Accept-Ranges, no redirects, and
        // a stable ETag dating back to 2021. No 1Mb/10Mb-sized files are
        // published, so the same 100MB file is used for both modes; on the
        // tunnel it will typically time out and report download as n/a, same
        // as any other failed sample (#285 tolerates this). No upload sink, so
        // UL falls back to Cloudflare like OVH (#291).
        //
        // A Yandex endpoint was researched but no public, HTTPS-stable,
        // appropriately-sized (~1-10 MB) fixed-file or parametric speedtest
        // host could be found: storage.yandexcloud.net/speedtest-* buckets
        // 404, speedtest.yandex.net is 503, and mirror.yandex.ru (RU Linux
        // mirror, otherwise healthy) only has version-pinned ISOs (100s of MB,
        // filenames change on every release). Left out for now.
        static let providers: [SpeedTestProvider] = [
            SpeedTestProvider(id: "cloudflare", label: "speed.cloudflare.com",
                              host: "speed.cloudflare.com", parametric: true, supportsUpload: true,
                              fixedSmallURL: nil, fixedLargeURL: nil),
            SpeedTestProvider(id: "ovh", label: "proof.ovh.net (OVH)",
                              host: "proof.ovh.net", parametric: false, supportsUpload: false,
                              fixedSmallURL: "https://proof.ovh.net/files/1Mb.dat",
                              fixedLargeURL: "https://proof.ovh.net/files/10Mb.dat"),
            // #292: global hosting provider fixed-file fallback (no upload sink).
            SpeedTestProvider(id: "hetzner", label: "ash-speed.hetzner.com (Hetzner)",
                              host: "ash-speed.hetzner.com", parametric: false, supportsUpload: false,
                              fixedSmallURL: "https://ash-speed.hetzner.com/100MB.bin",
                              fixedLargeURL: "https://ash-speed.hetzner.com/100MB.bin"),
        ]
        static let defaultProviderID = "cloudflare"
        static func provider(id: String) -> SpeedTestProvider {
            providers.first { $0.id == id } ?? providers[0]
        }

        // #291: provider for the *upload* leg when the selected one has no upload
        // sink (OVH is fixed-file download-only). Cloudflare's parametric /__up is
        // the universal upload target, so UL is measured instead of left blank.
        static let uploadFallbackProviderID = "cloudflare"
        static func uploadProvider(for provider: SpeedTestProvider) -> SpeedTestProvider {
            provider.supportsUpload ? provider : self.provider(id: uploadFallbackProviderID)
        }
    }

    /// DNS-over-HTTPS resolver endpoints used by `SubscriptionFetcher` as a
    /// fallback when system DNS is hijacked (common from RU networks). Tried
    /// in order; first one to return an A record wins. Both speak the JSON
    /// API (`Accept: application/dns-json`), so any provider that supports it
    /// is a drop-in. Avoid resolvers that require POST + DNS wire format.
    /// Google answers the JSON API at `/resolve` only: its `/dns-query` takes
    /// the wire format and returns 400 to these requests.
    static let dohEndpoints: [String] = [
        "https://1.1.1.1/dns-query",
        // was: "https://8.8.8.8/dns-query", which never answered a JSON query.
        "https://8.8.8.8/resolve",
    ]

    /// Uniform request timeout for `SubscriptionFetcher`. Replaces the prior
    /// 30 s direct / 10 s DoH split — same budget for both keeps the worst-case
    /// wall time predictable (max ≈ 2 × timeout: one direct attempt + one
    /// DoH-then-IP attempt). 15 s is long enough for slow mobile + DoH round
    /// trips and short enough to fail fast on truly broken hosts.
    static let subscriptionFetchTimeout: TimeInterval = 15

    /// Largest subscription body `SubscriptionFetcher` accepts. Real lists are
    /// a few dozen kilobytes; the cap keeps a hostile link from filling memory.
    /// Same 1 MiB limit as olcOS for Android.
    static let subscriptionMaxBytes = 1 << 20

    /// Default Jitsi server base URL sent as `OLCRTC_JITSI_URL` during install.
    /// The server prefixes short room names with this base and uses it for the
    /// auto-generated room when no room is given. Keep in sync with the
    /// `${OLCRTC_JITSI_URL:-...}` default in `olcos-core/server/srv.sh`. The wizard
    /// replaces it with the first instance its VPS probe finds working; this is
    /// only the starting value. On 2026-10-09 meet.egovm.ru was the one public
    /// instance that carried a real tunnel from an NL VPS (meet.mamba.group, the
    /// previous default, answered the probe but passed no data).
    static let defaultJitsiBaseURL = "https://meet.egovm.ru"
}
