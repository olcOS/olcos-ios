import Foundation

// MARK: - L10nTable
//
// Per-language translation dictionaries. Every key in `L10n` must appear in
// every dictionary — the unit test in `L10nTests.swift` enforces this.
//
// Missing translations fall back to English; missing in English too falls back
// to the case's raw name (which makes the gap visible without crashing).

enum L10nTable {

    static func value(for key: L10n, in locale: AppLocale) -> String {
        switch locale {
        case .english: return english[key] ?? key.rawValue
        case .russian: return russian[key] ?? english[key] ?? key.rawValue
        // #488: Resolve the independent, complete French dictionary.
        case .french: return french[key] ?? english[key] ?? key.rawValue
        }
    }

    // MARK: English (canonical / fallback)

    static let english: [L10n: String] = [
        .vpnAutomaticFallbackSummary: "The proxy fallback is on", // #488: Compact automatic-fallback disclosure label.
        // boc #488: Automatic-mode explanations requested by #487.
        .tunnelModeAutomatic: "Automatic (recommended)",
        .tunnelModeAutomaticHint: "System VPN when iOS allows it; otherwise a proxy for chosen apps, and the app says why.",
        .tunnelModeVPNHint: "System VPN only: the whole device goes through the tunnel. Needs an app signed with the Network Extension capability; an Apple Developer subscription alone does not enable it.",
        .tunnelModeProxyHint: "A proxy for chosen apps: only apps set to use it, such as Telegram, go through the tunnel.",
        .vpnAutomaticFallback_fmt: "Using the proxy because this installed app could not obtain VPN permission or capability: %@. This is not a system-wide VPN; set compatible apps to use the local proxy. You can retry VPN by choosing VPN in Settings.",
        // eoc #488

        // Common
        .ok:                "OK",
        .cancel:            "Cancel",
        .save:              "Save",
        .close:             "Close",
        .done:              "Done",
        .error:             "Error",
        .edit:              "Edit",
        .okPrompt:          "Result",   // #457 was: "Done" — this titles failures too

        // Tabs
        // #457 was: "Manage VPS" — the app called one place three names ("Manage
        // VPS" here, "VPS list" as the screen title, "the Servers tab" inside
        // `healthActionOnServersTab_fmt`), so a suggested fix pointed at a tab
        // that did not exist under that name. One noun: server.
        .tabServers:        "Connections",
        .tabSettings:       "Settings",
        .autoDetectedContainer_fmt: "Found an existing install: %@",

        // Tunnel mode (#vpn)
        .tunnelModeProxy:           "Proxy",
        .tunnelModeVPN:             "VPN",
        .configModeSectionHeader:   "Tunnel mode",
        .configVPNUnavailableFooter: "VPN mode is unavailable on this install:",
        // #461 was: "videochannel" — the raw id. Every picker names it "Video".
        .vpnVideochannelUnsupported: "The Video transport is not supported in VPN mode. Switch the connection to another transport, or use proxy mode.",
        .vpnDisconnected:           "VPN tunnel disconnected",
        .vpnSettingsEntryName:      "olcOS",
        .vpnCapabilityUnavailable_fmt: "The system rejected the VPN configuration (%@). This happens when VPN access was declined, or when the app was signed with a free Apple ID — the Network Extension entitlement requires a paid Apple Developer team. Proxy mode still works.",

        .settingsRefreshOnEntryToggle:  "Check on opening",
        .settingsRefreshOnEntryExplainer: "When the app opens, it checks which connections work.",
        .failoverSwitching_fmt:      "Protocol %@ is failing — switching to %@",
        .failoverAllFailed:          "All protocols on this server failed",
        // #454/#459: the health card is now the "This session" block of the
        // Diagnostics card, so it no longer has a title, a throughput row or a
        // refresh glyph of its own.
        .healthExitLabel:            "Exit",
        // #460 was: `.healthLatencyLabel` ("Latency") — see `diagResponseLabel`.
        .healthLatencyMs_fmt:        "%d ms",
        // #455: premium redesign editorial additions
        // #461 was: "Telemost … (vp8channel only) … datachannel … WBStream" —
        // three raw ids and a carrier spelled unlike its own label, in the
        // footer under the picker that shows all four as words.
        // #470 was: "(VP8 only)" — the matrix enables Video for Telemost too (the chip right below was tappable).
        // #460 was: `.configReliabilityHeader` ("Reliability") — its section
        // held only the auto-switch toggle, which moved to Connections.
        .unitSeconds:                "s",
        .sshTestInvalidPort:         "Invalid port",
        .logLevelOff:                "Off",
        .logLevelErrors:             "Errors only",
        .logLevelNormal:             "Normal",
        .logLevelDebug:              "Debug",
        .logLevelVerbose:            "Verbose (all)",
        // #455: reset-to-defaults
        .resetSettingsAction:        "Reset all settings",
        .resetSettingsFooter:        "Restores every setting to its default, including the tunnel mode. Your connections and servers are kept.",
        .resetSettingsConfirmTitle:  "Reset all settings?",
        .resetSettingsConfirmBody:   "Every setting returns to its default, including the tunnel mode. Connections and servers are not affected.",

        // Routing
        .routingHeader:     "Routing",
        .routingAllTunnel:  "All through tunnel",
        .routingViaTunnel:  "via tunnel",
        .routingDirect:     "direct",

        // Connection state
        .stateDisconnected: "Disconnected",
        .stateConnecting:   "Connecting…",
        .stateConnected:    "Connected",
        .stateConnectFailed: "Connection failed",
        .stateWaitingForNetwork: "Waiting for network…",
        .stateReconnecting: "Reconnecting…",
        .stateErrorPrefix_fmt: "Error: %@",

        // ConnectionsView
        // #303 was: "Tap + to add a connection manually. If you have a VPS, go to the Servers tab to install and link automatically."
        .actionConnect:              "Connect",
        .actionRetry:                "Retry",
        .shareAction:                "Share",
        .copyURIAction:              "Copy URI",
        .shareConnectionTitle:       "Share connection",
        .shareConnectionExplanation: "Share this URI to let others connect through your server. It contains the service, room ID, and encryption key — your server SSH credentials are not included.",
        .shareConnectionURIHeader:   "Connection URI",
        .copiedURI_fmt:              "📋 URI copied: %@",
        .fullAccessLinkRetired:      "Links with full SSH access are no longer supported — ask for an invite with management access.",

        // AddConnectionView
        .newConnectionTitle:         "New connection",
        .editConnectionTitle:        "Edit connection",
        .nameField:                  "Label",
        .namePlaceholder:            "My server",
        // #344 was: "Servers" — the Connections tab lists *connections*, not
        // servers (display-only; the persisted raw group value stays "Servers"
        // and is mapped via ConnectionRecord.displayGroupName).
        .groupDefault:               "Connections",
        .importByURI:                "Import from URI",
        .scanQRAction:               "Scan QR",
        .pasteURIAction:             "Paste URI",
        // #458 was: "Tap Paste …" — the button above reads "Paste URI"; a hint may
        // only use a control's OWN name (audit: every named control must exist).
        .importHint:                 "An olcrtc:// link fills the fields below. A subscription link or list opens the import.", // #381 was: "If you have a URI from the server — paste it here and tap «Parse». The fields below will be filled in automatically." — buttons are Scan QR / Paste (Paste also imports subscriptions since #361), there is no "Parse" button.
        .clientIDFooter:             "Leave 'default' — each device then announces its own id, so one link works on several devices at once. Change it only if the server operator asked for a specific value.",
        .keyPlaceholder:             "64 hex characters",
        .roomIDLabel:                "Room ID",
        .clientIDLabel:              "Client ID",
        .keyHexLabel:                "Key (hex)",
        .vp8ParamsHeader:            "VP8 parameters",
        .socksAuthHeader:            "SOCKS5 authentication",
        .socksAuthFooter:            "Username and password that apps must supply to use the local SOCKS5 proxy. Only needed if other apps on this device should be restricted from using the tunnel.",
        .socksUserLabel:             "User",
        .socksPassLabel:             "SOCKS password",
        .socksUserPlaceholder:       "empty = no auth",
        .vp8FpsLabel:                "FPS",
        .vp8BatchLabel:              "Batch size",
        .globalDefault_fmt:          "global (%d)",
        .overrideHint:               "Overrides global settings for this connection only. «×» resets to global.",
        // #365: per-connection seichannel params
        .seiParamsHeader:            "SEI parameters",
        .seiFpsLabel:                "FPS",
        .seiBatchLabel:              "Batch size",
        .seiFragLabel:               "Fragment size",
        .seiAckLabel:                "ACK timeout (ms)",
        // #461 was: "seichannel" — the id; the picker calls this one "SEI".
        .seiParamsHint:              "Tuning for the SEI channel. Sent only when the transport is SEI; stored either way.",

        // ServersView
        // #457 was: "VPS list" — the screen title disagreed with its own tab and
        // with the copy that points at it. Same noun everywhere.
        .serversTitle:               "My servers",
        .emptyNoServers:             "No servers",
        .emptyNoServersHint:         "Add a server over SSH and the app installs a protocol on it. Each protocol becomes a connection you can use or share.",
        .newServerTitle:             "New server",
        .editServerTitle:            "Edit",
        .sshAccessHeader:            "SSH access",
        .hostField:                  "Host",
        .portField:                  "Port",
        .loginField:                 "Login",
        .passwordField:              "Password",
        .actionInstall:              "Install",
        .actionUninstall:            "Remove all protocols from the server",
        // #471 was: "Update binary (fetch pinned build + rebuild)" — three build
        // steps to a reader who runs none of them. Name the software and the place.
        .actionUpdate:               "Update olcOS server side",
        .actionReboot:               "Reboot",
        .actionChangeRoomTransport:  "Change room / transport",
        .actionDone:                 "Done",
        .actionRemoveFromList:       "Remove server from the app",
        .removeHostConfirmTitle_fmt: "Remove %@?",
        // #458/#471: a hint may only name a control that exists — the menu item
        // is `actionUninstall`, now "Remove all protocols from the server".
        .removeHostConfirmMessage:   "The server is removed from this device's list. Nothing on the machine itself is touched — use «Remove all protocols from the server» first if you want to wipe it. Its SSH password is removed from the Keychain.",
        // #471 was: "Remove container from server?" / "Every olcrtc container …
        // Podman, the golang image (~300 MB) and the Go module cache stay." /
        // "Removes container, Go cache (~300 MB) … Podman and image stay." The
        // three lines below now agree with each other and with the scripts:
        // uninstall keeps the build cache, deep uninstall takes it, neither
        // touches the image (ServersView passes removeImage: false) — and the
        // saved connections go with the protocols, so the body says so.
        .uninstallConfirmTitle:      "Remove all protocols from the server?",
        .uninstallConfirmBody:       "Removes every protocol from this server, with its key, and the connections saved for it are removed from this app. The tools stay, so a reinstall takes about a minute.",
        .deepUninstallConfirmBody:   "Removes every protocol, the key and the build cache (~300 MB). Nothing else on the server changes.",
        .rebootConfirmTitle:         "Reboot server?",
        // #470 was: "…will restart automatically…" — nothing enables podman-restart.service; `--restart unless-stopped` alone does not survive a reboot.
        // #471 was: "the olcrtc container may need to be started again" — the card's own verb is "Start server".
        .rebootConfirmBody:          "This reboots the whole server. Once it is back online, check its card — it may need to be started again.",

        // #303: Recover connection from server
        .actionRecoverConnection:    "Recover connection",
        .recoverConfirmTitle:        "Recover connection from this server?",
        .recoverConfirmBody:         "Reads the service, room, transport and encryption key already deployed on this server (read-only) and adds them as a new connection here.",
        .recoverConfirmAction:       "Recover",
        .provisioningRecovering:     "Reading server config…",
        .recoverResultSuccess_fmt:   "Recovered %@/%@ — connection added",
        .recoverErrorMissingYAML:    "Server config not found — the deployed server.yaml could not be read.",
        .recoverErrorMissingField_fmt: "Server config is missing '%@'",

        // #314: generate-new-key fallback (server.yaml unreadable/unparseable)
        .rotateKeyConfirmTitle:      "Server config unreadable — generate a new key?",
        .rotateKeyConfirmBody:       "The deployed server.yaml could not be read, so the existing connection cannot be recovered. This generates a new encryption key on the server, repairs its config, restarts it, and adds the resulting connection here. Warning: all other devices using this server will lose access until they import the new connection.",
        .rotateKeyConfirmAction:     "Generate new key",
        .provisioningRotatingKey:    "Generating new server key…",
        .rotateKeyResultSuccess:     "New key active. Any link you shared before has stopped working.",
        .rotateKeyResultAdded_fmt:   "New key generated — %@/%@ connection added",
        .rotateKeyFailedNoURI:       "Key rotation finished but the server did not print a URI — check the provisioning log.",

        // Protocol status on the server
        // #471 was: "Container running/stopped/not found" — one container is one
        // protocol, and the word never reached anyone who could act on it.
        .containerRunning_fmt:       "Protocol running: %@",
        .containerStopped_fmt:       "Protocol stopped: %@",
        .containerNotFound:          "Nothing installed on the server",
        .containerNotFoundShort:     "not found",
        // #458 was: "… — tap «Install»." This fires from `startContainer` /
        // `stop` / `recoverConnection` / `rotateKey` / `addCarrier`, and in
        // exactly those states the card's button is «Check server» or «Retry» —
        // Install is not on the screen. State the fact; the card's own primary
        // action already offers the right next step for the state it is in.
        // #471 was: "No olcrtc container is installed on this server yet."
        .containerNotInstalled:      "Nothing is installed on this server yet.",
        .readinessNoPodman:              "Ready to install — nothing set up yet, full setup ~5–7 min",
        .readinessNoImage:               "Ready to install — the first install downloads about 300 MB (~3–5 min)",
        .readinessImageReady:            "Ready to install — everything is downloaded, ~1–2 min",
        .readinessContainerStopped_fmt:  "Stopped: %@",
        .readinessContainerRunning_fmt:  "Running: %@",

        // VPS status card (#258/#261)
        .vpsTitleUnknown:         "Not checked",
        .vpsTitleReady:           "Ready to install",
        .vpsTitlePodmanReady:     "Tools installed",
        .vpsTitleStopped:         "Stopped",
        .vpsTitleRunning:         "Running",
        .vpsSubUnknown:           "No test has been run on this server.",
        .vpsSubNoPodman:          "Nothing set up yet — full setup takes 5–7 min",
        .vpsSubNoImage:           "The first install downloads about 300 MB",
        .vpsSubImageReady:        "Everything is downloaded — install takes 1–2 min",
        .vpsSubStopped:           "Installed, not running",
        .vpsSubRunning:           "The server is running. Nothing has gone through it yet.",
        .vpsVerbChecking:         "Checking",
        .vpsVerbInstalling:       "Installing",
        .vpsVerbStarting:         "Starting",
        .vpsVerbStopping:         "Stopping",
        .vpsVerbReconfiguring:    "Reconfiguring",
        .vpsVerbUpdating:         "Updating",
        // #470 was: "Uninstalling" — the card headline for the "Remove container from server" op.
        .vpsVerbUninstalling:     "Removing",
        .vpsVerbDeepUninstalling: "Deep uninstalling",
        .vpsVerbRebooting:        "Rebooting",
        .vpsConnecting:           "Connecting…",
        .vpsCheckServer:          "Check server",
        .vpsWorking:              "Working…",
        .vpsOpFailed_fmt:         "%@ failed",

        // ContainerLogsView
        // #339 was: emptyLogsTitle + emptyLogsHint_fmt (ContainerLogsView sheet, deleted)
        .closeAction:                "Close",

        // LogsView
        .logsTitle:                  "Logs",
        .logsSearchPlaceholder:      "Search",
        .emptyLogsGeneric:           "Empty",
        // #316 was: `emptyLogsGenericHint`, "Run an operation in the Connections
        // or Manage VPS tab" — deleted in #457 with the Logs tab itself; a
        // pushed log names its own subject and never points at a tab.
        .noSearchResults:            "Nothing found",
        .noSearchResultsHint_fmt:    "No matches for «%@».",
        .categoryConnection:         "Connection",
        .categoryDiagnostics:        "Diagnostics",
        .categoryProvisioning:       "Server",
        .categoryContainerLogs:      "Protocol",

        // #294: per-source Logs tabs
        // #316 was: lowercase fragments shown under the tab title — now they
        // open the empty-state hint, so they read as sentences.
        .logsTabDescConnection:      "Connection logs",
        .logsTabDescDiagnostics:     "IP and speed test logs",
        .logsTabDescVPS:             "Server operation logs",
        .logsTabDescContainer:       "Protocol logs from the server",
        .logsFileNameLabel_fmt:      "File: %@",
        .logsContainerSelectServer:  "Server",
        .logsContainerNoServers:     "No servers configured",

        // #295: per-server container log files
        .duplicateServerNameError:   "A server with this name already exists",

        // #296: Container tab always-present load button
        // #338 was: logsDownloadFromServer ("Download logs from server")
        .logsCheckServer:            "Check server",
        .logsContainerEmptyHint:     "Nothing loaded yet. Tap Fetch to pull the newest lines from this server.",
        // #316: single-stack Logs tab — segmented-control short labels + line count
        .logsSegConnection:          "Conn",
        .logsSegDiagnostics:         "Diag",
        .logsSegVPS:                 "Server",
        .logsSegContainer:           "Protocol",
        .logsLineCount_fmt:          "%d lines",
        .logsPeerCount_fmt:          "👥 %d peers",
        // #338: inline container fetch — source card + monotonic phases
        .logsFetchAction:            "Fetch",
        .logsFetchFromHost_fmt:      "Fetch from %@",
        .logsPhaseConnecting:        "Connecting…",
        .logsPhaseCommand_fmt:       "Reading the newest %d lines from %@…",
        .logsPhaseReceiving:         "Receiving output…",
        // #332: rendered-line cap notice
        .logsRenderTruncated_fmt:    "Showing the newest %d lines — Share or Copy all exports the full history.",
        .logsShareThisAction:        "Share this log",
        .logsExportAllAction:        "Export all logs",
        .earlyRestartWedgeLabel:     "Auto-restart a stuck session",
        .wedgeRestartLog:            "⚠ Session appears wedged — restarting early",
        .wedgeRestartReason:         "stuck session",

        // SettingsView
        .settingsTitle:              "Settings",
        .sectionSOCKS5:              "SOCKS5",
        .sectionDNS:                 "DNS",
        // #460 (finding 12, verifier pass) was: "vp8channel" — the raw
        // transport id. Every picker in the app names this transport "VP8"
        // (`transportVp8channel`), so a Settings header spelling it the
        // internal way was the last place that id surfaced in the UI.
        // #460 was: `.sectionConnection` ("Connection") over eight rows and at
        // least four subjects. One header per subject now, so a footer under
        // any of them can only mean the row above it.
        .settingsSectionStart:       "Starting a connection",
        .settingsSectionSpeedTest:   "Speed test",
        .sectionLogs:                "Logs",
        .sectionIPSources:           "IP-check sources",
        .ipSourcesFooter:            "Services queried by the IP check. The RU-zone options stay reachable when public resolvers are blocked. If none are selected, the defaults are used.",
        .sectionSpeedProvider:       "Speed-test provider",
        // #460 (verifier pass) was: "…if Cloudflare is slow" — it named one
        // provider by brand, so it read as false advice to anyone who had
        // already switched away from it.
        .speedProviderFooter:        "Server the speed test runs against. Switch if the one selected is slow or blocked on your network.",
        .speedAllFailed:             "All measurements failed",
        // #458 was: "…Reconfigure the server to datachannel…" — capital-R
        // "Reconfigure" reads as a control name, and no control carries it; the
        // item is `actionChangeRoomTransport`, on the server card.
        // #461 was: "(vp8channel/sei/video)" and "to datachannel" — raw ids in
        // advice about a picker that spells all four out.
        .speedSlowJitsiHint:         "Speed depends on the Jitsi server and the transport. Try another transport or another Jitsi server: “Change room / transport” in My servers.",
        .settingsPortLabel:          "Port",
        .checkPortAction:            "Check port",
        .randomPortAction:           "Random",
        .portFree:                   "free",
        .portBusy:                   "busy",
        .logPortFree_fmt:            "✓ Port %d free",
        .logPortBusyOther_fmt:       "✗ Port %d busy",
        .logPortBusyOlcrtc_fmt:      "✓ Port %d in use by olcOS tunnel",
        .socksPortChangeNote:        "Port change takes effect on the next connection.",
        .dnsFreeFormPlaceholder:     "IP:port",
        .dnsFooter:                  "Usually there is no need to change it: when the chosen resolver stays silent, olcOS moves to another one, then to the phone's own. A new choice applies from the next connection, and often it is the reconnect that helps. Used by the tunnel and when installing servers; format IP:port. Mobile operator presets work only inside their network.",
        // #460 (finding 12) was: `.vp8Footer` — "MobileSetVP8Options only
        // applies when transport=vp8channel…". A gomobile symbol and a config
        // literal in a Settings footer.
        // #460 (verifier pass) also was: the raw ids "vp8channel" and
        // "wbstream" in the replacement sentence. `CarrierTransportMatrix`
        // displays those two as "VP8" and "WB Stream" in every picker, so
        // the note now uses the words the user was shown when they chose.
        // #461: "Telemost" -> "Yandex Telemost", to match the carrier label.
        .vp8Note:                    "Apply only to the VP8 transport. More frames and bigger batches move more data per second. The defaults (30 and 64) are tested.",
        .startTimeoutLabel:          "Ready timeout",
        .startTimeoutNote:           "How long to wait for a connection to come up before giving up and reporting a failure.",
        .autoConnectOnLaunchLabel:   "Auto-connect on launch",
        .autoConnectOnLaunchNote:    "Connects to the chosen server as soon as the app opens.",
        .autoRemoveConnectionOnUninstallLabel: "Remove its connections when a server is removed",
        .autoRemoveOnUninstallNote:  "When you remove the protocols from a server in My servers, the connections it created leave the list too.",
        .tunnelCheckLabel:           "Tunnel check",
        .keepAliveOff:               "off",
        .backgroundAudioLabel:       "Background work (audio)",
        .backgroundAudioNote:        "Keeps the tunnel alive while the app is in the background by playing a silent audio track. Uses more battery. The proxy stops when the app is swiped away.",
        .earlyRestartWedgeNote:      "Restarts the session as soon as it stops passing traffic, without waiting for it to drop. Off by default.",
        .localSocksAuthLabel:        "Require proxy authentication",
        .logLevelLabel:              "Log level",
        .logLevelNote:               "How much detail is recorded. Higher levels help when you are chasing a problem, and fill the log faster.",
        // #460 (verifier pass) was: "…every N seconds" — an algebra variable
        // for the number in the field this note now sits directly under.
        // #471 was: "…an end-to-end probe through SOCKS5…" — the tunnel is the
        // thing the reader of this footer can actually act on.
        .footerKeepAlive:            "Sends an end-to-end probe through the tunnel at the interval set here. On failure the tunnel reconnects automatically. Set to 0 to disable.",
        .footerLogBuffer:            "Maximum number of lines kept in memory per log category.",
        .logBufferLabel:             "Log buffer",
        // #460 (finding 12 class, verifier pass) was: "Container logs (tail)"
        // — `tail` is the shell command this ends up running, not something
        // the label needs to say; the note under it already explains it.
        // #471 was: "Container log lines" — same rule, one noun on: server.
        .containerLogsTailLabel:     "Server log lines",
        .containerLogsTailNote:      "How many of the newest lines to pull from the server's log.",
        .clearAllLogsAction:         "Clear all logs",
        .copyAllAction:              "Copy all",
        .clearCategoryAction:        "Clear this category",
        // #460 (finding 18) was: `.fontFooter` — "Applied app-wide (via SwiftUI
        // dynamicTypeSize)". A framework API named in a Settings footer.
        .languageLabel:              "Language",
        .themeLabel:                 "Theme",

        // #340/#299: appearance scheme picker. #457 was: this comment still
        // listed a fourth "Gray" scheme, deleted in #456.
        .appearanceSystem:           "System",
        .appearanceLight:            "Light",
        .appearanceDark:             "Dark",
        // #342: fixed-footprint hero footer

        // InstallOptionsView
        .installTitle:               "Install olcOS",
        .reconfigureTitle:           "Change room / transport",
        // #470 was: "…restarted with the new -carrier/-id/-transport flags…" — reconfigureScript seds server.yaml; the command line never changes.
        // #471 was: "Rewrites the protocol's server config (carrier, room, transport) and restarts its container." — that is what runs, not what happens.
        .reconfigureInfoFooter:      "Restarts this protocol with the new settings. No reinstall.",
        .reconfigureTransportTuningFooter: "Changing the transport resets the server's VP8 and SEI tuning to defaults. Reinstall to set custom values.",
        .parametersHeader:           "Parameters",
        .roomIDAutoGenHint:          "Room ID will be generated by the server.",
        .roomIDTelemostHint:         "Create a meeting in Telemost (Yandex account required) and paste its ID — the part of the link after /j/. A regular link lives 24 hours.",
        .matrixRecommended_fmt:      "★ Recommended for %@.",
        .matrixWorks_fmt:            "Works with %@.",
        .matrixQuestion_fmt:         "⚠ Working with %@ is uncertain.",
        .matrixFail_fmt:             "✗ Does not work with %@ — choose another transport.",
        .matrixUnknown_fmt:          "No compatibility data for %@.",
        // #470 was: "client-id=ios-<random> (auto-generated) · …" — no client-id exists any more (srv.sh never writes one; records get "default").
        // #471 was: "key=hex64 (auto-generated) · …" — a field name and a type, to a reader who types neither.
        .carrierFooter:          "A new encryption key is generated for this server · DNS and VP8 come from Settings",
        .transportSectionHeader:     "Transport",
        .roomIDSectionHeader:        "Room",
        .seiSettingsHeader:          "SEI Settings",
        // #461 was: "SEI params sent to srv.sh for seichannel." — a script
        // filename and a raw transport id in a footer the user reads.
        .seiSettingsFooter:          "SEI parameters, sent to the server on install. Used only by the SEI transport.",
        .actionQR:                   "QR",

        // Status banner

        // TunnelManager log lines
        .mobileStartOK:              "✓ MobileStart OK, waiting for WaitReady…",
        .mobileStartFailed_fmt:      "✗ MobileStart: %@",
        .bgKeeperFailed_fmt:         "⚠ Background audio keeper failed: %@ — app may be suspended after backgrounding",
        .transportUsesServerDefaults_fmt: "Server defaults will be used for %@ tunables — advanced parameters are not yet exposed in the iOS settings UI.",
        .waitReadyFailed_fmt:        "✗ WaitReady: %@",
        .connectNoPeer:              "No peer joined in time — check the key matches the server, the room is correct, or try another service/transport.",
        .waitReadyOK:                "✓ WaitReady OK — SOCKS5 listening, verifying tunnel…",
        .tunnelOK:                   "✓ Tunnel works — traffic is flowing through the server",
        .tunnelFailed:               "✗ Tunnel not responding (server unreachable or 403 Forbidden IP)",
        .keepAliveOK:                "♡ Keep-alive OK",
        .keepAliveLost:              "✗ Keep-alive: tunnel not responding",
        .serverConnectionLost:       "Connection to the conferencing server lost",
        .serverNotResponding:        "Conferencing server not responding",
        .disconnectingArrow:         "→ Disconnecting",
        .netPathLost:                "⚠ Network lost — waiting for connectivity",
        .waitingForPortRelease:      "⏳ Waiting for port release…",
        .netPathRestored:            "network restored",
        .netPathChanged:             "network path changed",
        .reconnecting_fmt:           "↻ Reconnecting (%@)",
        .reconnectAttempt_fmt:       "↻ attempt %d/%d in %ds",
        .reconnectAttemptSlow_fmt:   "↻ attempt %d in %ds — trying every 1–2 min until you disconnect",
        .reconnectGaveUp:            "Reconnecting failed. Tap Retry to try again.",
        .rejoinSettle_fmt:           "⏳ Room settle: %.1fs before re-join",
        .connectingOlcrtc_fmt:       "→ olcOS carrier=%@ transport=%@ clientID=%@",

        // TunnelManager errors
        .validateClientIDEmpty:      "Client ID cannot be empty",
        .validateClientIDWhitespace: "Client ID must not contain spaces",
        .validateKeyLength_fmt:      "Key must be 64 hex characters (got: %d)",
        .validateKeyNonHex:          "Key contains non-hex characters",
        .validateRoomIDEmpty:        "Room ID cannot be empty",
        .errorPortBusy_fmt:          "Port %d is busy — free it or change the port in Settings",
        .errorSecretsLocked:         "Unlock the device and reopen the app to load your saved key.",
        .errorRuntimeStillStopping:  "Previous session is still shutting down — try again in a few seconds.",

        // OlcrtcURI errors
        .uriErrorInvalidScheme:      "The link must start with olcrtc:// or vless://",
        .uriErrorMissingField_fmt:   "Missing field: %@",
        .uriErrorMixedBrackets:      "URI payload brackets are mismatched (expected [...] or <...>)",

        // Provisioning
        .provisioningSSHConnecting:  "Connecting via SSH…",
        .provisioningRebootSSH:      "Reboot: connecting via SSH…",
        .provisioningUninstallSSH:   "Delete: connecting via SSH…",
        .provisioningRebooting:      "Rebooting…",
        .provisioningUninstalling:   "Removing protocols and files…",
        .provisioningUpdating:       "Updating olcOS on the server…",
        .provisioningReconfiguring:  "Reconfiguring the protocol…",
        .provisioningStatusFetching: "Server status…",
        .provisioningLogsFetching:   "Server logs…",
        .installStep1Upload:         "[1/3] Uploading script…",
        .installStep2Launch:         "[2/3] Running install script…",
        .installStep3PollRetry_fmt:  "[3/3] Server temporarily unavailable, retry (%d)…",
        .installPhaseWaiting:        "Waiting…",
        .installPhaseSystemDeps:     "Installing system dependencies…",
        .installPhaseClone:          "Downloading the source…",
        .installPhasePullImage:      "Downloading the build image…",
        .installPhaseDeps:           "Downloading dependencies…",
        .installPhaseBuild:          "Building olcOS…",
        .installPhaseStart:          "Starting olcOS…",
        .installFailedNoURI_fmt:     "The install script finished without a connection link: %@. See Logs for details.",
        .installTimeout25min:        "Install timed out (25 minutes)",
        .installResultSuccess_fmt:   "olcOS server installed (%@/%@)",
        .uninstallResultSuccess:     "Removed from the server. Connections through it no longer work.",
        .updateResultSuccess:        "olcOS updated on the server",
        .provisioningStarting:       "Starting server…",
        .startResultSuccess:         "Server started",
        .actionStart:                "Start server",
        .provisioningStopping:       "Stopping server…",
        .stopResultSuccess:          "Server stopped",
        .actionStop:                 "Stop server",
        .scanningContainers:         "Looking for olcOS on the server…",
        .actionScanVPS:              "Scan for installed olcOS",
        .scanNoContainers:           "No olcOS install found on this server.",
        .scanRestoreAction:          "Restore",
        .actionDeepUninstall:        "Wipe all olcOS data from server",
        .deepUninstallResultSuccess:          "All olcOS data removed",
        .reconfigureResultSuccess_fmt: "Parameters updated (%@/%@)",
        .rebootResultSuccess:        "Reboot command sent",
        .logsBytesReceived_fmt:      "Logs received (%d bytes)",
        .provisionPasswordMissing:   "Password not found in Keychain",
        .provisionSSHPrefix_fmt:     "SSH: %@",
        .provisionCommandPrefix_fmt: "Command: %@",
        .provisionParsePrefix_fmt:   "Failed to parse output: %@",
        .sshAttemptFailed_fmt:       "✗ SSH attempt %d/2 failed: %@",
        .sshRetryIn4s:               "  retry in 4 s…",
        .sshPortNotResponding_fmt:   "Port %d on %@ did not respond — check SSH is open and the server is reachable",
        .serverUnreachable_fmt:      "Server %@ is not responding — check it is online and its SSH port is reachable",
        .sshTunnelDroppedMidOp_fmt:  "The SSH session was riding the app's own tunnel and that tunnel dropped mid-operation — the command may already have run on the server. Reconnect, then re-check the server state. (%@)",

        // NetPing
        .pingTCPOK_fmt:              "TCP/%d responded in %@ ms",
        .pingTCPFail_fmt:             "TCP/%d unreachable",

        // ConnectionsView per-connection ping (#234)
        .pingNoFreePort:             "No free local port available for ping",
        .pingFailed:                 "Ping failed",

        // ServersView alerts
        .alertPasswordMissingShort:  "Password not found",
        .alertKeyMissingShort:       "SSH key not found",

        // AddServerHostView
        .nameSettingLabel:           "Name",
        .sectionDescription:         "Description",
        // #451: SSH auth-method picker + private-key entry
        .authMethodPickerLabel:      "Authentication",
        .authMethodPassword:         "Password",
        .authMethodKey:              "SSH key",
        .sshKeyFooter:               "Paste the contents of an OpenSSH private-key file (ed25519 or RSA), e.g. ~/.ssh/id_ed25519. The key is stored only in the device Keychain.",
        .sshKeyPasteButton:          "Paste key from clipboard",
        .sshKeyPassphraseField:      "Key passphrase",
        .sshKeyDetected_fmt:         "✓ %@ key detected",
        .sshKeyDetectedEncrypted_fmt: "✓ %@ key detected — encrypted, passphrase required",
        .sshKeyErrorECDSA:           "ECDSA keys are not supported. Use an ed25519 or RSA key (ssh-keygen -t ed25519).",
        .sshKeyErrorUnsupportedFormat: "Unsupported key format. Convert it to OpenSSH format: ssh-keygen -p -o -f <keyfile>.",
        .sshKeyErrorNotAKey:         "This doesn't look like a private key. Paste the whole file including the BEGIN OPENSSH PRIVATE KEY lines (not the .pub file).",

        // ConnectionsView misc
        .diagnosticsTitle:           "Connection check",
        .ipCheckTitle:               "IP check",
        .ipCheckRun:                 "Check IP",
        .speedTestRun:               "Run test",

        // #311 — speed-tile metric labels/units + upload-fallback log line
        .speedLabelDL:               "Download",
        .speedLabelUL:               "Upload",
        // #342 was: "%.0f ms" / "%.1f Mbps" — unit moved to OlcMetric(unit:)
        .speedRateValue_fmt:         "%.1f",
        .speedUnitMbps:              "Mbit/s",
        .speedUploadFallback_fmt:    "  upload: %@ has no upload endpoint — using %@",

        // #236/#237 — UI strings localized after the i18n pass
        .ipChecking:                 "Checking…",
        .ipNotChecked:               "Not checked yet",
        .ipDnsLeak:                  "IPs differ — possible DNS leak",
        .ipSourcesAgree_fmt:         "✓ %@ (%d sources)",
        .socksProxyAddr_fmt:         "SOCKS5 proxy: 127.0.0.1:%@",
        .portInUseByOlcrtc:          "in use by olcOS tunnel",
        .roomPrefix_fmt:             "room: %@",
        .qrCodeURIA11y:              "Connection URI QR Code",
        .qrCodeHintA11y:             "Scan this code to import the connection on another device",
        .cameraUnavailableTitle:     "Camera not available",
        .cameraUnavailableBody:      "This device has no camera the app can use right now. Pick the QR code from a photo instead.",
        .sectionCarrier:             "Service",
        .labelTransport:             "Transport",
        // #461 was: "Telemost". Complaint 1 is that the hero must name the
        // service the traffic hides inside; that service is a Yandex product
        // and "Telemost" alone reads as a generic word.
        .carrierTelemost:            "Yandex Telemost",
        .carrierWbstream:            "WB Stream",
        .carrierJitsi:               "Jitsi",
        .transportDatachannel:       "DataChannel",
        .transportVp8channel:        "VP8",
        .transportSeichannel:        "SEI",
        .transportVideochannel:      "Video",
        .fieldRoomID:                "Room ID",
        .fieldJitsiURL:              "https://meet.example.org",

        // DNS carrier labels
        .dnsLabelMts:                "MTS",
        .dnsLabelBeeline:            "Beeline",
        .dnsLabelMegafon:            "MegaFon",
        .dnsLabelTele2:              "Tele2",
        .dnsLabelYota:               "Yota",

        // SubscriptionFetcher
        .subDohFailed_fmt:           "Secure DNS could not resolve %@",
        .subInvalidResponse_fmt:     "The list could not be downloaded (HTTP %d)",
        .subNoAddress:               "Secure DNS returned no address",

        // #111: subscription import (olcrtc-sub:// links)
        .subImportTitle:             "Import subscription",
        .subImportConfirm_fmt:       "Add %d connection(s) from “%@”?",
        .subImportAddAction:         "Add",
        .subInvalidLink:             "Subscription link must look like olcrtc-sub://host/path",
        .subEmptyList:               "The subscription contains no valid connections",
        .subImportPastedSource:      "pasted list",

        // #363: surfaced subscription metadata
        .subMetaMultipleSources_fmt: "%d sources",   // #396

        // #346: VPS-card mini-stat labels (abbreviations; ru = en per operator)
        .vpsStatPing:                "Ping",
        .vpsStatDisk:                "Disk",
        .vpsStatRAM:                 "RAM",
        .vpsStatUp:                  "Uptime",
        .scanRestored_fmt:           "Restored: %@",

        // #337: screenshot-safe IP masking
        .maskIPsLabel:               "Hide IP addresses",
        // #460 (verifier pass) was: "Masks IP addresses… Logs are not masked."
        // The toggle above it is called "Hide IP addresses"; a footer that
        // renames the control it explains reads as being about something else.
        // #471 was: "…and VPS cards" — the tab, the screen title and this footer say server.
        .maskIPsFooter:              "Hides IP addresses on screen — for screenshots. Copying and logs stay real.",

        // #328: active-carrier endpoints with one-tap copy
        // #460 (finding 23) was: `.carrierEndpointsTitle` ("Carrier endpoints")
        // and `.carrierEndpointsHint` ("Add these as DIRECT rules in your proxy
        // app so its own traffic doesn't loop through olcrtc."). Written for
        // someone who already knew what it meant, on the main screen, with
        // nothing saying who needs it. The row now opens with the question that
        // selects its audience; the sheet explains itself before the list.
        // #461: this is a ⋯ menu item on the live connection now, not a ~90 pt
        // card row, so it is a label. `carrierEndpointsRowHint`,
        // `carrierEndpointsRowConnectHint` and `carrierEndpointsShowAction`
        // went with the row; `carrierEndpointsLead` still explains the sheet.
        .carrierEndpointsRowTitle:   "Using another proxy app?",
        .carrierEndpointsScreenTitle: "Send these direct",
        // "DIRECT" stays capitalised: it is the literal name of the rule in the
        // proxy apps this screen exists for, and the word the reader must find.
        .carrierEndpointsLead:       "Only needed if another proxy or VPN app is handling this phone's traffic. Add every address below to that app's DIRECT (bypass) list, so it lets olcOS's own video call out untouched — otherwise it captures the call the tunnel is built on and nothing connects.",
        .carrierEndpointsFootnote:   "These belong to the conferencing service, and were looked up when this screen opened. They rotate — open it again after a reconnect.",
        .carrierEndpointHost:        "Host",
        .carrierEndpointResolvedIPs: "Resolved IPs",
        .carrierEndpointResolving:   "Resolving…",
        .carrierEndpointUnresolved:  "Could not resolve",
        .carrierEndpointNoHost:      "This service's room ID isn't a host — nothing to exclude.",
        .carrierEndpointCopied_fmt:  "📋 Copied: %@",
        .carrierEndpointRefresh:     "Re-resolve",
        // #460 was: `.carrierEndpointsCheckAction` ("Check" — it read as "check
        // whether these endpoints are healthy", which the button does not do),
        // plus `.carrierEndpointsConnectHint` / `.carrierEndpointsReadyHint`.
        .carrierEndpointCopyAll:     "Copy host & IPs",

        // #359: accessibility for the hero connect toggle + icon toolbar buttons
        .a11yConnectToggle:          "Connect",
        .a11yConnectHintSelectFirst: "Select a connection first",
        .a11yStateConnected:         "Connected",
        .a11yStateConnecting:        "Connecting",
        .a11yStateDisconnected:      "Disconnected",

        // #452: multi-carrier VPS — protocol rows + extras install
        .protocolsSectionHeader:      "Services and rooms",
        .addProtocolAction:           "Add service",
        .addProtocolTitle:            "Add protocol",
        .removeProtocolAction:        "Remove from server",
        .removeProtocolConfirmTitle_fmt: "Remove %@ from this server?",
        .removeProtocolConfirmBody:   "Stops and deletes this protocol and its config on the server. The matching connection is removed from your list too. The other protocols keep running.",
        // #460 (findings 7 / 16) was: `.protocolConnectedBadge` ("Connected") —
        // the longest word on a title line too narrow for it, which SwiftUI
        // hyphenated into "Connec-ted". Keep any translation short.
        .protocolLiveBadge:           "Connected",
        .protocolRecordMissing:       "No saved connection matches this protocol — use «Recover connection» in the row menu.",
        .protocolAdded_fmt:           "Added %@/%@ — connection saved",
        .protocolRemoved_fmt:         "Removed %@ from the server",
        .installExtrasHeader:         "Additional protocols",
        .installExtrasFooter:         "Installed on the same server right after the primary protocol, sharing one encryption key. Each protocol gets its own connection in the list — pick which one to use at connect time.",
        .installExtraToggle_fmt:      "Also install %@",
        .installExtrasPartialFail_fmt: "Some protocols failed to install: %@",

        // #456: verified health vocabulary. Nothing below claims success
        // without a probe behind it; "Working" is granted only by an
        // end-to-end result that is still inside the freshness window.
        .healthNeverChecked:          "Not checked yet",
        // #459 was: "Tap Verify to push a real request through this connection."
        // — the row's Verify menu item is gone (its chip is the affordance), so
        // the sentence named a control that is not on that screen. It now just
        // states the fact, which is what `healthNeverProbedHint` was added for.
        .healthNeverCheckedHint:      "No request has been pushed through this connection yet.",
        .healthChecking:              "Checking…",
        .healthCheckingHint:          "Joining the room and loading a test page",
        .healthVerified:              "Working",
        // #459 was: "Verified %@ ago · %d ms" — with an age of "just now" that
        // read "Verified just now ago". `HealthAge.phrase` now carries the
        // preposition, so no sentence here may add one.
        .healthVerifiedHint_fmt:      "Verified %@ · %d ms",
        .healthVerifiedNoRTTHint_fmt: "Verified %@",
        .healthFading:                "Worked recently",
        .healthHandshake:             "Connects, but no data",
        .healthHandshakeHint_fmt:     "Joined the room %@, but no traffic passed",
        .healthStale:                 "Out of date",
        .healthStaleHint_fmt:         "Last checked %@ — too old to trust",
        .healthInconclusive:          "Couldn't check",
        .healthCheckedAgo_fmt:        "checked %@",
        .healthChipNever:             "not checked",
        // #459 was: "%@ old" — which rendered "just now old".
        // #470 was: "last seen %@" — `.stale` is reached for ANY verdict past staleSeconds, a failed probe included; "seen" claimed it worked.
        .healthChipStale_fmt:         "checked %@",
        .healthChipFaded_fmt:        "was %@ · %@",
        .healthChipFadedNoRTT_fmt:   "worked %@",
        .healthChipFailed_fmt:        "failed %@",
        .healthChipHandshake_fmt:     "no data · %@",
        .healthChipUnchecked:         "couldn't check",
        // #459: two forms. `phrase` is a whole fragment — nothing may append
        // "ago" to it. `short` is a bare duration for a chip that already has a
        // value beside it ("215 ms · 2m"). Both are plural-safe at 1.

        // #456: failure reasons — what happened AND what to do next.
        .healthReasonKeyMismatch:      "The server's key has changed, so your saved key no longer matches. Use Recover connection to read the new one.",
        .healthReasonKeyMismatchShort: "Key no longer matches",
        .healthReasonNoPeer:           "Nobody answered in the room. The server may be stopped, on a different room, or its key may no longer match after a reinstall.",
        .healthReasonNoPeerShort:      "No answer in the room",
        .healthReasonRoomInvalid:      "The room ID isn't valid for this service. Check it in Change room / transport.",
        .healthReasonRoomInvalidShort: "Room ID rejected",
        .healthReasonCarrierRejected:  "The conferencing service refused the connection. The room may be gone, or the account token may be wrong.",
        .healthReasonCarrierRejectedShort: "Service refused",
        .healthReasonNetworkDown:      "This device has no internet connection, so this says nothing about the server.",
        .healthReasonNetworkDownShort: "No internet",
        .healthReasonHostUnreachable:  "The server didn't answer. It may be off, rebooting, or blocked by your network.",
        .healthReasonHostUnreachableShort: "Server didn't answer",
        .healthReasonSSHAuth:          "SSH login was refused. The password or key saved for this server is wrong.",
        .healthReasonSSHAuthShort:     "SSH login refused",
        .healthReasonPortBusy:         "Another app is holding the local SOCKS port. Free it, or pick a different port in Settings.",
        .healthReasonPortBusyShort:    "Local port busy",
        .healthReasonVPNActive:        "Connections can't be checked while the system VPN is on. Turn it off and check again.",
        .healthReasonVPNActiveShort:   "System VPN is on",
        .healthReasonContainerStopped: "The protocol isn't running on the server. Start it, then check again.",
        .healthReasonContainerStoppedShort: "Server stopped",
        .healthReasonTimedOut:         "The test ran out of time before any data came back.",
        .healthReasonTimedOutShort:    "Timed out",
        .healthReasonDNSUnreachable:   "The DNS resolver chosen in Settings did not answer from this network, so no host could be looked up. This says nothing about the server — pick another resolver, for example Cloudflare 1.1.1.1.",
        .healthReasonDNSUnreachableShort: "DNS resolver not answering",
        // #458 was: "The Logs tab has the raw details." — #457 deleted the Logs
        // TAB (five tabs became Connect / Servers / Settings). The log lives at
        // Settings → `settingsViewLogsRow`, so that is what this must name.
        // #460: that row was renamed, so this sentence was renamed with it.
        .healthReasonUnknown:          "The check came back with no clear answer. Settings → View all logs has the raw details.",
        .healthReasonUnknownShort:     "No clear answer",

        // #456: health actions — same wording as the same action elsewhere.
        .healthActionRecover:         "Recover connection",
        .healthActionCheckRoom:       "Change room / transport",
        .healthActionStart:           "Start server",
        .healthActionPortSettings:    "Open port settings",
        .healthActionDNSSettings:     "Open DNS settings",
        .healthActionRetry:           "Retry",
        .healthActionVerify:          "Verify",
        .healthShowReasonAction:      "What's wrong?",
        .healthLatencyNotMeasured:    "not measured",

        // #456: VPS card headlines. "Couldn't check" is not "stopped".
        .vpsHeadlineOpFailed:            "Last action failed",
        .vpsHeadlineUnreachable:         "Can't reach the server",
        .vpsHeadlineUnreachableHintNever: "The server does not answer",
        .vpsHeadlineNotChecked:          "Not checked yet",
        .vpsHeadlineNotCheckedHint:      "Checking the server…",
        .vpsHeadlineStopped:             "Server stopped",
        .vpsHeadlineStoppedHint:         "It is installed but not running — tap Start server",

        // #456: misc UI copy
        .shareConnectionOnlyBadge:    "Connection link — no server access",
        .shareConnectionOnlySub:      "The link below lets someone connect through your server. It carries no SSH login, and it cannot manage, reconfigure, or wipe the server.",
        .roomIDLastUsed_fmt:          "Use last room: %@",
        .installExistingFoundTitle_fmt: "This server already runs %@",
        .installExistingFoundBody:    "Reinstalling deletes it and every other protocol on this server, along with their rooms and keys.",
        .installUseExistingAction:    "Use the existing one",
        .installReinstallAction:      "Reinstall anyway",

        // MARK: #457 Tunnel-mode picker (the Config tab is gone; the picker
        // lives on the Connect screen now). Three questions, plainly answered —
        // the choice changes what the word "Connected" means.
        .tunnelModeLockedNote:       "You can't switch while a connection is live. Disconnect first.",
        .tunnelCompareScope:         "What goes through it",
        .tunnelCompareScopeProxy:    "Only apps you point at 127.0.0.1",
        .tunnelCompareScopeVPN:      "Everything on this device",
        .tunnelCompareNeeds:         "What it needs",
        .tunnelCompareNeedsProxy:    "Nothing — it just runs",
        .tunnelCompareNeedsVPN:      "A VPN profile iOS asks you to approve",
        .tunnelCompareRuns:          "Where it runs",
        // #470 was: "Inside this app, while it's open" — the background keeper (on by default, #455) keeps the proxy alive when backgrounded.
        .tunnelCompareRunsProxy:     "Inside this app; stays up in the background while «Background work (audio)» is on",
        .tunnelCompareRunsVPN:       "In the background, app closed",

        // #457: Logs is a detail view of the thing it explains, so its title
        // names that subject instead of saying "Logs" four times over.
        // #460 (finding 21c) was: `.settingsOpenLogsRow` ("Diagnostics and
        // logs") — the third thing in the app called "Diagnostics", and the
        // only one of the three that opens a log reader. It says so now.
        .settingsViewLogsRow:        "View all logs",
        .logsSubjectConnection:      "Connection log",
        .logsSubjectProvisioning:    "Server operations log",
        .logsSubjectContainer_fmt:   "Server log · %@",
        .logsEmptySubjectHint:       "Nothing has been recorded here yet.",

        // #457: the Connect hero. The evidence line never claims more than was
        // measured — "connected" and "checked" are two different facts.
        .actionDisconnect:           "Disconnect",
        .heroSubjectNone:            "No connection yet",
        // #459 (audit): was "Pick a connection below." — this line renders ONLY
        // when `subject == nil`, and `ConnectionStore.primary` falls back to the
        // first record, so nil means the list is EMPTY. It pointed at a list that
        // was not there; the empty state below offers the one real next step.
        .heroPickAConnection:        "Add a connection first.",
        .heroEvidenceStarting_fmt:   "starting… %d s",
        .heroEvidenceUnverified:     "Not checked through it yet",   // #471
        .heroEvidenceNoNetwork:      "holding the session until the network returns",
        // #461 was: "Proxy · only apps you point at 127.0.0.1:%@" — a sentence
        // where a caption was wanted. Same %@ (the bound port).
        .heroScopeProxy_fmt:         "Proxy · port %@",   // #471: a loopback address is not a headline
        .heroScopeVPN:               "VPN · whole device",   // #471

        // #457/#459: connection rows. The live connection is the hero's subject
        // and is not drawn in the list, so no row needs a "Live" badge.
        .connectRowTapHint:          "Connects through this connection",
        .connectRowRemove:           "Remove connection",

        // #457: a suggested action that lives on another screen says where.
        .healthActionOnServersTab_fmt: "%@ — in My servers",
        .healthActionInSettings_fmt:   "%@ — in Settings",
        .healthNeverMeasured:        "never measured",

        // #457/#459: the server card. The headline says what the server is
        // doing; all the caption adds is WHEN that was read (`vpsReadAge_fmt`),
        // or that it never has been.
        .vpsProcessUnread:           "Nothing has been read from this server yet",
        .protocolStoppedNote:        "Not running on the server",
        .vpsScanBeforeInstall:       "Looking for an existing install…",
        .vpsScanFailed_fmt:          "Couldn't look at what's on this server. %@",

        // #458: unknown is its own answer. None of these name a control that
        // is not on the same screen — that was the bug.
        .protocolsNotReadYet:        "The protocol list hasn't been read from this server yet",
        .addProtocolAllInstalled:    "Every supported protocol is already installed on this server.",
        .healthNeverProbedHint:      "No request has been pushed through this connection yet",
        .connectRowVerifyHint:       "Checks this connection with a real request",

        // #459: the one-window redesign. The hero owns the live connection, the
        // list under it is a switcher, Health and Diagnostics are one card, and
        // the server card's thirteen-item menu is five safe items plus a pushed
        // "Manage server" screen.
        // #461 was: "Switch to" — complaint 3: the header ran into the server
        // label under it and read "Switch to — ams-1". The protocol is the
        // subject on this screen, so the header says so and the row supplies it.
        .diagSessionHeader:          "This session",
        .diagToolsHeader:            "Checks",
        // #459: the owner asked, of the exit country and IP, "where do they even
        // come from?". Both hints name the service that answers.
        // #460 (findings 3 / 22) was: `.diagExitSourceHint` — "Asked ipinfo.io
        // through the tunnel", three words squeezed into the row's narrow
        // right-hand value column, where they wrapped into a ragged stack. The
        // note is full width now and says what was measured, not only who
        // answered — the city and the country are read off that one answer.
        // #460 (findings 2 / 15): the screen showed 1109 ms in red here and
        // 133 ms on a connection's chip, called both "the latency", and #460
        // explained the gap in a 250-character note.
        // #461: the owner asked twice for the numbers to agree, not for the
        // difference to be explained. Both sides now take the best of several
        // round-trips on one kept-alive connection, so the figures match, the
        // note is gone, and this row uses the same word as the chips.
        // #461 was: "Response time" and `.diagResponseNote`.
        .diagResponseLabel:          "Latency",
        // The count is enabled sources, which the user can set to 1 — hence the
        // colon rather than "%d services", which would read "1 services".
        .diagIPSourceHint_fmt:       "Asks public services for your address, over the current route. Sources: %d.",
        .vpsReadAge_fmt:             "read %@",
        .vpsManageServer:            "Manage server",
        .vpsAdvancedTitle_fmt:       "Manage %@",
        .vpsAdvancedConnectionHeader:  "Connection",
        .vpsAdvancedMaintenanceHeader: "Maintenance",
        .vpsAdvancedRemoveHeader:      "Danger zone",
        // Every destructive row says what it destroys — the sentence a menu row
        // could not carry, and the reason this screen exists.
        // #471: the two remove rows used to read as the same row twice. They now
        // differ by one clause — the build cache — and by what survives.
        .vpsAdvancedRebootFooter:      "Restarts the whole server; everything on it stops until it is back.",
        .vpsAdvancedUninstallFooter:   "Removes every protocol and its key; the tools stay for a quick reinstall.",
        // #471 was: "Removes the olcrtc containers, the deploy directory, the
        // encryption key and the Go build cache (~300 MB). Podman and the golang
        // image stay." The image is never removed (ServersView passes
        // removeImage: false), and naming Podman told the reader nothing.
        .vpsAdvancedDeepUninstallFooter: "Removes protocols, key and build cache (~300 MB); the next install starts from scratch.",
        .vpsAdvancedRemoveHostFooter:  "Forgets this server in the app; nothing changes on the machine.",

        // #460: screenshot rounds 2–4.
        // #461 was: `.heroExitSourceNote` — a full sentence of provenance under
        // the hero's country line, on the screen the owner asked to fit in one
        // page. `diagExitNote` says the same thing once, on the card.
        // Instruction 26: auto-switch moved off Settings and onto the screen
        // holding the protocols it switches between, so its explainer had to
        // shrink from a settings paragraph to one line on a card.

        // #461: with one installed protocol the switcher had a header and no
        // rows. The hint names the screen that fixes it — this screen never
        // draws a control that navigates away — and says why a second one is
        // worth installing, which is the whole point of the switcher.

        // MARK: #463 One-button Telemost room renewal
        // Yandex expires a Telemost link 24 hours after it is created, and the
        // owner used to fix that by hand over SSH — the one channel a whitelist
        // window closes. These strings cover the whole errand in one sheet.

        // Create-call failures. Each names the cause AND the next move, and none
        // of them may ever carry the session cookie or an internal symbol.
        .telemostErrNoAccount:       "No Yandex account is linked. Sign in to create Telemost rooms.",
        .telemostErrSessionRejected: "Yandex rejected the saved sign-in. Sign in again.",
        .telemostErrRateLimited:     "Yandex is refusing new meetings right now. Wait a minute and try again.",
        .telemostErrNetwork:         "Could not reach Yandex. Check the connection and try again.",
        .telemostErrMalformed:       "Yandex sent an answer the app could not read. Try again.",
        .telemostErrStatus_fmt:      "Yandex returned an error (HTTP %d). Try again in a minute.",

        // The sign-in web view. This warning is the most important string in the
        // feature: the saved sign-in opens the whole Yandex account without the
        // password, so it is shown above the web view, before anything is typed.
        .yandexLoginTitle:           "Yandex sign-in",
        .yandexLoginWarning:         "Use a throwaway Yandex account. This device will store a sign-in token that opens that account's mail, Disk and payments without the password.",

        // The sheet. One name for the menu item and the sheet it opens.
        .telemostNewRoomAction:      "New Telemost room",
        .telemostRoomServerLine_fmt: "Yandex Telemost on %@",
        .telemostRoomExplainer:      "A Telemost link stops working 24 hours after it is created. This makes a fresh room in your Yandex account and points the server at it.",
        .telemostRoomNoAccountTitle: "No Yandex account linked",
        .telemostRoomNoAccountBody:  "Creating a room needs a signed-in Yandex account. Sign in with a throwaway one — the token is kept in the Keychain and is sent only to Yandex.",
        .telemostRoomSignInAction:   "Sign in to Yandex",
        .telemostRoomIdleTitle:      "Yandex account linked",
        .telemostRoomIdleBody:       "One tap creates the room and moves this server into it.",
        .telemostRoomCreateAction:   "Create room and apply",
        .telemostRoomWorkingTitle:   "Working",
        .telemostRoomWorkingCreate:  "Creating the room in Telemost…",
        .telemostRoomWorkingApply:   "Sending the new room to the server…",
        .telemostRoomDoneTitle:      "Room replaced",
        .telemostRoomDoneBody:       "The server is in the new room. Its link is good for the next 24 hours.",
        .telemostRoomFailedTitle:    "Couldn't finish",
        .telemostRoomRetryAction:    "Try again",
        .telemostRoomOtherAccountAction:  "Use another account",
        .telemostRoomForgetAccountAction: "Forget this Yandex account",
        .telemostRoomKeychainNote:   "The sign-in token is kept in this device's Keychain only.",

        // The live-row hazard. Renewing the protocol the tunnel is riding on
        // restarts the container that carries the app's own SSH, so the command
        // loses its transport mid-flight. Say so plainly, and offer the safe
        // route first when the server has one.
        .telemostRenewLiveSwitchable_fmt: "You are connected through this protocol. Replacing its room restarts it, so the connection will drop. Connect through %@ first and it won't.",
        .telemostRenewSwitchAction_fmt:   "Connect through %@ first",
        .telemostRenewLiveOnly:      "You are connected through this protocol, and this server has no other one to use instead. Replacing the room restarts it, so the connection will drop mid-command — the app saves the new room and reconnects to it.",
        .telemostRenewDropped_fmt:   "The connection dropped while the server was switching to room %@ — expected when you renew the protocol you are connected through. The new room is saved and the app is reconnecting; run Verify from the protocol's menu to confirm the server took it.",
        .logsContainerPrimary:       "Primary",
        .vpsAdvancedMachineHeader:   "Machine",
        .vpsTitleNothingInstalled:   "Nothing installed yet",
        .settingsAdvancedRow:        "Advanced",
        .tunnelCompareDisclosure:    "How the two modes differ",
        .settingsBackgroundLabel:    "Keep running in background",
        .settingsSectionAbout:       "About",
        .settingsSectionConnection:  "Connection",
        .settingsSectionProxy:       "Proxy",
        .settingsProxyAddressLabel:  "Address for other apps (SOCKS5)",
        .protocolRecreateAction:     "Re-create this protocol",
        .carrierFooterSharedKey:     "Shares the encryption key with the protocols already on this server · DNS and VP8 come from Settings",
        .subImportAlreadySaved_fmt:  "“%@” is already saved — nothing was added.",
        .logsScanAmbiguous_fmt:      "This server runs %d olcOS installs — pick the right one on its Servers card first («Scan for installed olcOS»), then fetch again.",
        .healthLatencyNoResponse:    "no response",
        .sshTunnelLoginTimedOut_fmt: "SSH login to %@:%d through the tunnel exceeded the 10 s limit — the relayed path is too slow; try again, or disconnect the tunnel and use the direct path",
        .dnsInvalidNote:             "Enter the resolver as IP:port, for example 1.1.1.1:53 — the value is not saved until it is valid",
        .speedTunnelDropped:         "The tunnel dropped during the test — the remaining steps were skipped",
        .vpsHeadlineProbeFailed:     "Couldn't check the server",
        .protocolStopAction:         "Stop this protocol",
        .protocolStartAction:        "Start this protocol",
        .telemostExpiryTitle:        "Telemost room expires soon",
        .telemostExpiryBody_fmt:     "The room behind \"%@\" stops working in about %d min, and the tunnel goes with it. Renewing now drops the connection for a few seconds.",
        .telemostExpiryRenewAction:  "Renew now",
        // boc #480
        .telemostRenewalAttentionTitle: "Telemost renewal needs attention",
        .telemostAgeUnknown_fmt:     "The app does not know when the room for “%@” was created. A temporary Telemost link lives 24 hours. Renew it once through the app; from then on olcOS renews it ahead of time. Renewing restarts the service on the server and may drop the connection.",
        .telemostSetupRequired_fmt:  "A temporary Telemost link lives 24 hours, so the room for “%@” has to be renewed daily. To let olcOS do it, open the linked server in My servers and sign in to Yandex.",
        .telemostCreationFailed_fmt: "Could not create a new room for “%@”. The saved room and its age have not changed. Open its room sheet in My servers to check your Yandex sign-in and retry.",
        .telemostApplyUnconfirmed_fmt: "The server did not confirm renewal for “%@”. It may or may not have changed rooms. The saved room and its age have not changed. Automatic retries are paused until you explicitly renew or change the saved room. Check or recover the server configuration in My servers before retrying.",
        .telemostApplyCandidate_fmt: "The attempted new room ID is %@. Use it only after confirming the server configuration.",
        .telemostForeignVPN_fmt:     "Renewal or reconnection for “%@” was deferred because another system VPN may loop new connections. Check that VPN's routing or turn it off before retrying.",
        .telemostReconnectRequired_fmt: "The server confirmed the new room for “%@” and it is saved. Renewal was cancelled before reconnection. Connect to this record again from the app.",
        .telemostSignInSaved:        "Yandex sign-in saved",
        // eoc #480
        // #483: app-only VPN start is an intentional credential-lifetime boundary.
        .vpnStartFromAppOnlyNote:    "Start the VPN from the app. Starting it from iOS Settings works only with VPN auto-connect on: otherwise the access data is removed after it disconnects.",
        .vpnPacketDNSUnsupported:   "VPN mode needs an IPv4 DNS server on port 53. Choose a compatible resolver in Settings. Proxy mode can still use IPv6 DNS.", // #485
        .sshHostKeyFingerprintField: "SSH host-key fingerprints",
        .sshHostKeyVerificationAcknowledgement: "I verified these fingerprints through a trusted independent channel",
        .sshHostKeyVerificationHelp: "Before the first SSH action, open your hosting provider's trusted server console and run:\nfor key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"$key\" -E sha256; done\nPaste all output above and confirm. Never get these fingerprints from an unverified SSH connection or ssh-keyscan. Existing servers must be verified once. Changing the address or port requires verification again.",
        // boc #481
        .sshHostKeyFingerprintInvalid: "Enter valid SHA256 SSH host-key fingerprints or paste the complete ssh-keygen output, one key per line.",
        .sshHostKeyVerificationRequired: "The SSH server address or saved identity is invalid. Connection stopped. Check the server address and port.",
        .sshHostKeyMismatch: "The SSH server key has changed. Connection blocked before authentication. This may mean the server was reinstalled or someone is intercepting the connection. Confirm the change with your hosting provider before trusting a new key in Manage server.",
        .sshHostKeyTrustStoreUnavailable: "The saved SSH server identity could not be read or saved. Connection stopped.",
        .sshHostKeyChangedTitle: "Server key changed",
        .sshHostKeyResetAction: "Trust new server key",
        .sshHostKeyResetWarning: "Only continue if your hosting provider has confirmed this key change. An unexpected change may mean someone is intercepting your connection. This forgets the saved key for this address and port, including other entries using the same endpoint. The next SSH connection will automatically remember the key it receives. No connection starts now.",
        .sshHostKeyResetDone: "The saved server key was forgotten. You can now retry the server action. The next SSH connection will automatically remember the key it receives.",
        // eoc #481
        .later:                      "Later",
        .addFlowStepAccess: "Access",
        .addFlowStepCheck: "Check",
        .addFlowStepProtocols: "Protocols",
        .addFlowStepRoom: "Room",
        .addFlowStepInstall: "Install",
        .addFlowStepCounter_fmt: "Step %d of %d",
        .addFlowNext: "Next",
        .addFlowBack: "Back",
        .addFlowAccessLead: "Server address and login",
        .addFlowKeyPasted_fmt: "Key pasted · %@",
        .addFlowKeyReplace: "Replace key",
        .addFlowKeyNotShownNote: "The key is not shown again after pasting.",
        .addFlowClipboardEmpty: "Clipboard is empty",
        .addFlowLabelMissing: "Enter a name",
        .addFlowHostInvalid: "Enter the server address",
        .addFlowPortInvalid: "Port must be 1–65535",
        .addFlowUserMissing: "Enter the login",
        .addFlowPasswordMissing: "Enter the password",
        .addFlowKeyMissing: "Paste a private key",
        .addFlowPassphraseMissing: "This key needs a passphrase",
        .addFlowCheckLead: "We connect over SSH and look at what is already on the server.",
        .addFlowCheckRunning: "Connecting over SSH…",
        .addFlowCheckOK: "Server responds",
        .addFlowCheckFailed: "Could not connect",
        .addFlowTofuFirstTitle: "First connection",
        .addFlowTofuFirstBody: "The server's SSH key will be remembered now. If it ever changes, the app blocks the connection and warns you.",
        .addFlowTofuKnownTitle: "Known server key",
        .addFlowTofuKnownBody: "Matches the key saved earlier for this address.",
        .addFlowTofuMismatchTitle: "Server key changed",
        .addFlowFactOS: "System",
        .addFlowFactArch: "Architecture",
        .addFlowFactRuntime: "Containers",
        .addFlowFactRuntimeNone: "Not found — the installer sets up podman",
        .addFlowFactExisting_fmt: "olcOS already here: %@",
        .addFlowFactExistingNone: "olcOS is not installed yet",
        .addFlowFactUnknown: "Unknown",
        .addFlowProtocolsLead: "Pick the services the tunnel will run through. Each one gets its own connection.",
        .addFlowBadgeRecommended: "Recommended start",
        .addFlowBadgePrimary: "Primary",
        .addFlowNeedsYandex: "Needs a Yandex account",
        .addFlowTransportFor_fmt: "Transport for %@",
        .addFlowPickAtLeastOne: "Choose at least one service",
        .addFlowRoomLead: "Each service needs a room the server will join.",
        .addFlowYandexSignInBody: "The Telemost room is created from your Yandex account and handed to the server. Use a throwaway account — the sign-in token is kept only in Keychain.",
        .addFlowTelemostCreating: "Creating a Telemost room…",
        .addFlowTelemostCreated: "Room created",
        .addFlowTelemostCreatedBody: "The server will be installed with this room. The link is valid for 24 hours.",
        .addFlowTelemostFailed: "Could not create a room",
        .addFlowJitsiInstance: "Jitsi service",
        .addFlowJitsiInstanceNote: "The app checks this list from your server and marks the services that work there.",
        .addFlowJitsiCustom: "Own address",
        .addFlowJitsiRoomName: "Room name",
        .addFlowJitsiRoomHint: "A room name (letters and digits) or a full link. Empty — the server picks a name.",
        .addFlowRoomMissing_fmt: "Set a room for %@",
        .addFlowInstallLead: "Check the summary and start. The server builds olcOS on its own — keep olcOS open, it takes about 5–15 minutes.",
        .addFlowSummaryServer: "Server",
        .addFlowSummaryProtocols: "Protocols",
        .addFlowInstallRunning: "Installing…",
        .addFlowInstallDone: "Server is ready",
        .addFlowInstallFailed: "Installation failed",
        .addFlowInstallFailedHint: "Details are in the server's Logs. The server stays in the list — you can retry from there.",
        .addFlowResultConnections: "Connections",
        .addFlowResultPending: "The connections will appear on the Connections tab.",
        .installOptionsLead: "Add a protocol to this server. It shares the encryption key with the installed ones.",
        .throughputA11y_fmt: "Download %@, upload %@",
        .throughputEstimateA11y_fmt: "About %@ through the local SOCKS5 listener — an estimate from loopback traffic, not split by direction",
        .carrierJitsiDesc: "Public Jitsi servers, no account. VP8 is recommended; DataChannel and the other video transports work too. A room name or a full link.",
        .carrierTelemostDesc: "Needs a Yandex account; olcOS renews the room every 24 hours by itself.",
        .transportDatachannelDesc: "Data over the service’s own data channel. The only transport on SaluteJazz; on Jitsi slower than VP8 in our tests.",
        .transportVp8channelDesc: "Data dressed as a VP8 video stream, so the service sees an ordinary video call. The fastest in our tests (about 9 Mbit/s on Jitsi); the frame rate and batch are in Settings.",
        .transportSeichannelDesc: "Data hidden in the video stream’s service blocks (H.264 SEI), with acknowledgements. A slower fallback.",
        .transportVideochannelDesc: "Data drawn as picture frames (QR codes) in the video stream. The slowest fallback; not available in VPN mode.",
        .settingsCarrierEndpointsEmpty: "Add a connection first — the addresses come from its room.",
        .settingsConnectionSummary_fmt: "Start %d s · check every %d s",
        .settingsDiagnosticsSummary_fmt: "%@ · %d IP sources",
        .settingsConnectionsCount_fmt: "%d connections",
        .protocolAboutAction: "About this protocol",
        .protocolAboutHide: "Hide description",
        .shareServerTitle_fmt: "Share: %@",
        .shareServerProtocolsHeader: "Protocol connection",
        .shareServerNoProtocols: "No protocol connections on this server yet.",
        .sshKeyStored_fmt: "%@ key stored in Keychain",
        .sshKeyReplaceAction: "Replace key",
        .actionUpdateSub: "Updates the olcOS core on the VPS. The app itself updates in Settings.",
        .vpsAdvancedOverviewHeader: "Overview",
        .vpsAdvancedActionsHeader: "Actions",
        .vpsAdvancedRecoverSub: "Recreate the connection record for the installed container.",
        .healthActionSharedRecordNote: "This connection came from another device: its key and room are managed by the server owner. Ask them for a fresh link or QR code.",
        .deviceNameSectionHeader: "This device",
        .deviceNameLabel: "Name in the room",
        .deviceNameRegenerate: "New name",
        .deviceNameFooter: "Two random words and a number, generated on this device. It replaces 'default' when connecting, so the same shared link works on several devices at once. Contains nothing about the phone or you. A new name applies from the next connection.",
        .fieldRevealSecret: "Show",
        .fieldHideSecret: "Hide",
        .roomIDPlaceholder: "Paste the room id",
        .roomIDLinkHint: "A Telemost meeting link works too — it is shortened to the id.",
        .formAccessSectionHeader: "Access",
        .healthChipNotChecked: "Not checked",
        .healthChipNoData: "No data",
        .shareRecipientHint: "Only olcOS understands this link. The recipient installs olcOS, opens Connections → + → Paste from clipboard, or scans your QR code.",
        .connectingXray_fmt: "→ VLESS · REALITY %@:%d sni=%@",
        .xrayLocalSocksAuthIgnored: "Local SOCKS authentication is not applied to VLESS · REALITY connections; the listener accepts unauthenticated clients on this device.",
        .xrayUriUnsupported_fmt: "This vless:// link uses %@, which olcOS does not support (REALITY over TCP only).",
        .validateXrayHostEmpty: "Server host is empty.",
        .validateXrayUUIDEmpty: "Client UUID is empty — the Keychain entry may be missing; re-import the link.",
        .validateXrayPublicKeyEmpty: "REALITY public key (pbk) is missing.",
        .validateXraySNIEmpty: "REALITY server name (sni) is missing.",
        .validateXrayPortRange: "Port must be between 1 and 65535.",
        .xrayFieldServer: "Server",
        .xrayFieldSNI: "REALITY server name (SNI)",
        .xrayFieldFlow: "Flow",
        .xrayFieldFingerprint: "TLS fingerprint",
        .xrayFieldShortID: "Short ID",
        .xrayEditorFooter: "A VLESS · REALITY connection is defined entirely by its vless:// link. To change the server, paste a new link; the client UUID is stored in the Keychain and never shown.",
        .addFlowCallsSection: "Through a video call",
        .addFlowDirectSection: "Direct connection",
        .xrayServiceName: "Xray",
        .xrayProtocolTitle: "Xray · VLESS Reality",
        .xrayProtocolDesc: "A fast direct connection that looks like a visit to an ordinary website. The server has to be reachable directly, so it does not help under mobile whitelists.",
        .addFlowBadgeFast: "Fast",
        .xrayAdvancedTitle: "Advanced",
        .xrayTargetField: "Camouflage site",
        .xrayTargetPlaceholder: "Automatic",
        .xrayTargetHint: "The real foreign website the server imitates. Leave it empty and the server picks one that passes its checks.",
        .xrayTargetInvalid: "Enter a domain name, for example www.example.com",
        .xrayPortField: "Port",
        .xrayPortHint: "443 looks most like ordinary HTTPS; other ports are easier to block.",
        .provisioningXrayInstalling: "Installing Xray…",
        .xrayInstallSuccess: "Xray is installed",
        .xrayInstallAdopted: "Xray was already running on the server; its connection is added",
        .xrayInstallFailed_fmt: "Xray could not be installed: %@",
        .provisioningXrayRemoving: "Removing Xray…",
        .xrayRemoved: "Xray is removed from the server",
        .xrayInstallAction: "Install Xray",
        .xrayRemoveAction: "Remove Xray",
        .xrayRemoveConfirmTitle: "Remove Xray from this server?",
        .xrayRemoveConfirmBody: "Stops Xray and deletes its keys. Its link stops working, and its connection is removed from this app.",
        .addProtocolChooserTitle: "Add a protocol",
        .addProtocolCallOption: "Through a video call…",
        .healthBestChoice: "Best choice",
        .widgetDescription: "Turn the tunnel on or off and see whether it is up.",
        .controlDescription: "Turns the olcOS tunnel on or off.",
        .widgetStateFailed: "Didn't connect",
        .widgetStateUnknown: "Status unknown",
        .widgetHintToggle: "Tap to turn on or off",
        .widgetHintOpenApp: "Open the app to check",
        .widgetHintNoConnection: "Add a connection in the app",
        .widgetActionOn: "Turn on",
        .widgetActionOff: "Turn off",
        .widgetActionToggle: "On / Off",
        .telegramProxyAction: "Use in Telegram",
        .telegramProxyHint: "Opens Telegram and offers to use this SOCKS5 proxy",
        .tunnelStalls: "Connected, but traffic stalls after the first kilobytes — the network is likely throttling direct connections. Try a protocol that goes through a video call.",
        .tunnelModeAutomaticShort: "Auto",
        .healthReasonServerOutdatedShort: "Server core is outdated",
        .healthReasonServerOutdated: "The server runs an older version of the tunnel core than this app speaks. Update it: open the server → Manage server → Update olcOS server side.",
        .addFlowJitsiChecking: "Checking Jitsi servers from your VPS…",
        .addFlowJitsiCheckingBody: "Your server has to reach the Jitsi host and be let in as a guest. This takes about ten seconds.",
        .addFlowJitsiPicked_fmt: "Picked %@",
        .addFlowJitsiPickedBody: "Your server reaches it and it lets guests in. You can choose another below.",
        .addFlowJitsiNoneWorking: "No server in the list works from your VPS",
        .addFlowJitsiNoneWorkingBody: "Enter a Jitsi server you know works, or check again later.",
        .addFlowJitsiCheckFailed: "Couldn't check the Jitsi servers",
        .addFlowJitsiRecheck: "Check again",
        .addFlowJitsiNoCurl: "The server has no curl, so it can't test Jitsi hosts.",
        .licensesTitle: "Open-source licences",
        .licensesCoreNotice: "Tunnel core — NOTICE",
        .licensesCoreLicense: "Tunnel core — licence",
        .licensesUpstream: "Original project — licence",
        .licensesGoModules: "Go modules",
        .licensesSwiftPackages: "Swift packages",
        .licensesFooter: "Everything olcOS includes from other projects, each with its own licence and notices.",
        .inviteErrorInvalidLink: "This invite link is damaged.",
        .inviteErrorMissingKey: "The link has no key — the whole link is needed.",
        .inviteErrorNotAnInvite: "The server answered with something other than a connection list.",
        .inviteErrorWrongKey: "The list doesn’t open with this link’s key.",
        .inviteErrorRevoked: "This invite was revoked or is no longer on the server.",
        .inviteErrorUnreachable: "The server didn’t answer. If this network only lets whitelisted sites through, try again on Wi-Fi.",
        .inviteErrorUnreachableDetail_fmt: "The server didn’t answer (%@).",
        .inviteErrorServer_fmt: "The server couldn’t publish the invite: %@",
        .inviteErrorNothingToShare: "This server has no saved connection to share yet.",
        .inviteErrorNoCredentials: "No SSH login is saved for this server.",
        .invitesTitle: "Devices",
        .invitesExplanation: "Give another phone or tablet this server’s connections with one link. When something changes here — a new Telemost room, a new key, an added protocol — the device gets it by itself. With server access, that device also manages the server from its own app, the way this one does; without it, it only connects.",
        .invitesCreateAction: "Invite a device",
        .invitesListHeader: "Invited",
        .invitesRevokeFooter: "Revoking stops the updates. To close access completely, rotate the server key as well — the other devices receive the new one by themselves.",
        .invitesRevokeAction: "Revoke",
        .invitesRevokeTitle: "Revoke this invite?",
        .invitesRevokeMessage: "The device stops receiving updates. The connections it already has keep working until you rotate the server key.",
        .invitesFailureHeader: "Upload failed",
        .invitesRetryAction: "Try again",
        .invitesUnnamed: "Device",
        .invitesStatusUploading: "Uploading to the server…",
        .invitesStatusNotUploaded: "Not on the server yet",
        .invitesStatusUpdated_fmt: "Updated %@",
        .invitesNameField: "Name",
        .invitesNamePlaceholder: "e.g. iPad",
        .invitesCreateFooter: "The name is only for this list. Your server receives the list encrypted; the key exists only in the link.",
        .invitesCreateTitle: "Invite a device",
        .invitesCreateConfirm: "Create link",
        .invitesLinkExplanation: "On the other device, copy the link and paste it in olcOS, or scan the QR code from inside olcOS. olcOS adds the connections and keeps them up to date.",
        .invitesLinkSecretNote: "Whoever has this link can use the server. Send it only to your own devices or to people you trust.",
        .invitesLinkUnavailable: "This invite isn’t on the server yet. Try again when the server is reachable.",
        .invitesRowSubtitle: "A self-updating link for another phone",
        .invitesRowCount_fmt: "Invited: %d",
        .invitesCopyLink: "Copy link",
        .carrierVkcalls: "VK Calls",
        .carrierSalutejazz: "SaluteJazz",
        .carrierMtslink: "MTS Link",
        .carrierVkcallsDesc: "Video transport (VP8), about 13–19 Mbit/s. The room is a VK call link: the app makes one with your VK sign-in, or you paste a link from the VK app.",
        .carrierSalutejazzDesc: "Data transport (DataChannel), no account. The app makes the room itself.",
        .carrierMtslinkDesc: "Video transport only (VP8, sent as VP9), about 15 Mbit/s. The room is a permanent meeting: show the app once how to make one in the sign-in window, then one button makes rooms. The free plan allows two permanent meetings.",
        .addFlowNeedsVKLink: "VK sign-in or link",
        .addFlowNeedsMtsLink: "MTS Link sign-in or link",
        .addFlowNoAccount: "No account",
        .addFlowRoomInvalid_fmt: "The %@ room isn’t in the right format",
        .addFlowVKBody: "Sign in to VK and the app makes the call itself. Or paste a link from the VK app. Don’t end the call for everyone: the server stays in it.",
        .vkCallLinkField: "Call link",
        .vkCallLinkRecognized: "Recognized link",
        .mtsLinkField: "Meeting link",
        .addFlowSaluteCreating: "Creating a SaluteJazz room…",
        .addFlowSaluteCreated: "Room created",
        .addFlowSaluteFailed: "Couldn’t create the room",
        .addFlowSaluteBody: "No account. The app makes the room itself; you can also enter your own as code:password.",
        .saluteCreateRoomAction: "Create room",
        .roomIDVkHint: "A VK call link. “Create a VK call” makes one with your VK sign-in; a link copied from the VK app works too. Don’t end the call for everyone — the server stays in it.",
        .roomIDSaluteHint: "A room code and password separated by a colon, e.g. abcd12:efgh3456. The app makes the room itself: tap Create room.",
        .roomIDMtslinkHint: "A link to a permanent MTS Link meeting, as in the cabinet: https://my.mts-link.ru/j/… The server joins as a guest. The phone connects over TCP by default; for UDP, add ?ice=udp to the end of the link.",
        .saluteJazzErrNetwork: "Sber didn’t answer. Check the internet and try again.",
        .saluteJazzErrStatus_fmt: "SaluteJazz refused (HTTP %d). Try again later.",
        .saluteJazzErrMalformed: "SaluteJazz answered unexpectedly.",
        .welcomeTitle: "Where do we start?",
        .welcomeLead: "olcOS sends your traffic through a server. Pick what you have:",
        .welcomeImportTitle: "A link, QR code or file",
        .welcomeImportBody: "Someone sent you a connection, a subscription or an invite. No server of your own needed.",
        .welcomeScanAction: "QR code",
        .welcomeFileAction: "File",
        .welcomeServerTitle: "Your own server (VPS)",
        .welcomeServerBody: "Have the server's address and password? olcOS installs everything by itself.",
        .welcomeServerAction: "Set up a server",
        .welcomeNeitherTitle: "I have neither",
        .welcomeNeitherBody: "Take a ready-made list of free servers, or see where to get an invite or a server.",
        .welcomeNeitherAction: "What to do",
        .welcomeManualAction: "Enter a connection by hand",
        .welcomeFileUnreadable: "That isn’t a text file with links.",
        .welcomeImportUnrecognized: "No connection, subscription or invite was found in that.",
        .noServerInviteTitle: "Ask for an invite",
        .noServerInviteBody: "If a friend or relative runs a server in olcOS, they can send you an invite: My servers → Share → Invite a device. Open the link and you’re done.",
        .noServerRentTitle: "Or rent a VPS",
        .noServerRentBody: "Any Linux server abroad (Ubuntu or Debian) with 1 GB of memory will do. The host gives you an address and a root password: tap Set up a server and olcOS does the rest.",
        .accountsTitle: "Service accounts",
        .accountSignedIn:            "Signed in",
        .accountSignedOut:           "Not signed in",
        .accountsYandexBody: "A Yandex account lets the app create and renew Telemost rooms by itself. A spare account is best; the sign-in stays in the Keychain.",
        .accountsSignOutAction: "Sign out of Yandex",
        .accountsSignOutTitle: "Sign out of Yandex?",
        .accountsSignOutMessage: "New Telemost rooms and their renewal stop until you sign in again. Current connections are not affected.",
        .accountsVKBody: "The server joins a VK call as a guest. Sign in once and the app makes calls with your own account, or paste a link from the VK app.",
        .accountsSaluteBody: "No account. The app makes the room itself with one anonymous request.",
        .accountsJitsiBody: "Public Jitsi servers, no account; joined as a guest. A room name or a full link.",
        .accountsOthersHeader: "No account needed",
        .lanesStarting_fmt: "Joining %d rooms at once…",
        .lanesRoomCount_fmt: "Rooms: %d",
        .laneAddAction: "Add a room",
        .laneRemoveAction: "Remove",
        .laneAddTitle: "Another room",
        .pasteAction: "Paste",
        .saluteAnotherRoomAction: "Another room",
        .laneTelemostSignIn: "The Yandex sign-in has expired. Sign in again and repeat.",
        .bundleServiceName: "Whole server",
        .bundleLanes_fmt: "%@ · %d rooms",
        .bondErrorServer_fmt: "Bonding on the server: %@",
        .bundleCardDesc: "Every room of this server at once: one download goes through all of them, and when a room drops out the others carry on.",
        .bundleBonded: "together",
        .bundleBondPending: "setting up",
        .bundleBondOff: "taking turns",
        .bundleBondFailed_fmt: "Bonding is off: %@",
        .bundleRooms_fmt: "%d rooms",
        .bundleVPNOneLane: "Joining the rooms in VPN mode is off in Settings: one room carries everything.",
        .jitsiCheckSectionHeader: "Jitsi service",
        .jitsiCheckWorks_fmt: "Works · %@",
        .jitsiCheckStalls: "Connects, then the transfer breaks off",
        .jitsiCheckNoData: "Lets your server in, but no data gets through",
        .jitsiCheckUnreachable: "Does not answer your server",
        .jitsiCheckNeedsLogin: "Requires an account",
        .jitsiCheckAnswers: "Answers; data transfer not checked",
        .jitsiCheckRunning: "Checking…",
        .jitsiCheckAgain: "Check again",
        .jitsiCheckNote: "Your server tries each service with a real connection. It takes about a minute; your connections keep working.",
        .jitsiCheckPickedFastest_fmt: "Chosen: %@, the fastest service that works",
        .jitsiCheckNoneWorks: "No service carried data from your server. Try again later or enter your own address.",
        .jitsiCheckFailed_fmt: "Could not check: %@",
        .jitsiCustomHelper: "The address of another Jitsi Meet service, if you know one that works.",
        .tabHome: "Home",
        .heroChooseOther: "Choose another server",
        .listBundleSubtitle_fmt: "All services of %@",
        .listDirectSubtitle: "Direct, without a video call",
        .addMenuTitle: "Add",
        .addMenuPaste: "Paste from clipboard",
        .addMenuScan: "Scan a QR code",
        .addMenuFile: "Open a file",
        .addMenuLink: "Link or subscription",
        .addMenuManual: "Enter by hand",
        .addMenuOwnServer: "My own server (VPS)",
        .addLinkField: "Link",
        .addLinkPlaceholder: "https://… or vless://…",
        .addLinkHelper: "A subscription address, an invite or a connection link.",
        .addLinkAction: "Add",
        .listEmpty: "No connections yet. Tap + to add a link, a QR code, a file or a subscription.",
        .listAutoSwitch: "Switch when one stops working",
        .listAutoSwitchDetail: "If the connection stops working, the app moves to another one that works. A whole-server connection already keeps going when one of its rooms drops; this switch is for when the whole server stops.",
        .listOwnServerEmpty: "No connections from this server yet. Open the server to install one.",
        .listMyServersNone: "olcOS installs everything it needs on your server by itself.",
        .listRowConnected: "Connected",
        .listRowVerifyHint: "Checks this connection again",
        .listWordNotWorking: "Not working",
        .listSectionSubscriptions: "Subscriptions",
        .listSubscriptionServers_fmt: "Servers: %d",
        .listSubscriptionUsed_fmt: "Used: %@",
        .listSubscriptionAvailable_fmt: "Left: %@",
        .listSubscriptionUnnamed: "Subscription",
        .vpsHeadlineProtocolsWorking_fmt: "%d of %d work",
        .protocolsNotResponding_fmt: "Not responding: %@",
        .protocolStopped: "Stopped",
        .roomsStoppedOne_fmt: "Room stopped: %@",
        .roomsStoppedMany_fmt: "Rooms stopped: %@",
        .addMenuCurated: "Ready-made lists",
        .curatedLead: "Free servers that other people keep up to date. The app adds a list as a subscription, re-reads it every hour and checks the servers in it. Speed and uptime are not guaranteed.",
        .curatedWhiteMobileTitle: "White lists for mobile internet",
        .curatedWhiteMobileDetail: "For when the mobile network lets only allowed Russian sites through. The servers hide behind addresses of such sites.",
        .curatedWhiteCheckedTitle: "White lists: checked addresses only",
        .curatedWhiteCheckedDetail: "Fewer servers, behind addresses of VK, Yandex and other big services that white lists keep open.",
        .curatedBlackTitle: "Regular internet",
        .curatedBlackDetail: "For Wi-Fi and mobile internet without white lists, where only some sites are blocked.",
        .curatedAddAction: "Add list",
        .curatedSourceNote_fmt: "The lists are kept by igareck: %@. olcOS only reads them.",
        .searchFastest: "Find the fastest and connect",
        .searchStop: "Stop the search",
        .searchKnocking_fmt: "Checking which of %d servers answer…",
        .searchChecking_fmt: "Trying the fastest: %d of %d…",
        .searchNoneFound: "No server worked. Try again later or add another list.",
        .listViaCallSubtitle: "Inside a video call",
        .diagnosticsRowSubtitle: "Your IP address and speed",
        .welcomeFreeServersAction: "Free servers",
        .coreStaleTitle_fmt: "Update the server: %@",
        .coreStaleBody: "It runs an older version of the tunnel core, so connections through it drop. Open My servers — the update starts by itself.",
        .listOwnServerHeader_fmt: "My server · %@",
        .listSectionOwnLinks: "Your links",
        .listSectionOwnLinksFooter: "What you added yourself: links, QR codes and files.",
        .listAddOwnSubscription: "Add your own subscription",
        .listSubscriptionServersWorking_fmt: "Servers: %d · working: %d",
        .listSubscriptionOff: "Off",
        .subUpdatedToday_fmt: "Updated today at %@",
        .subUpdatedYesterday_fmt: "Updated yesterday at %@",
        .subUpdatedOn_fmt: "Updated %@ at %@",
        .subAutoRefresh_fmt: "Updates itself every %@",
        .subFrom_fmt: "From %@",
        .subEnabled: "Subscription on",
        .subEnabledFooter: "A list that is off is not updated and is never picked automatically; tap a server to use it anyway.",
        .subRefreshNow: "Update now",
        .subRefreshing: "Updating…",
        .subRefreshFailed: "Could not update the list. Check the internet and try again — the saved servers are kept.",
        .subServersHeader: "Servers",
        .subNoServers: "The list holds no servers yet. Update it to fetch them.",
        .subOffNote: "The subscription is off: these servers are used only when you tap one.",
        .subRenameAction: "Rename",
        .subRenameTitle: "Subscription name",
        .subRenamePlaceholder: "Name",
        .subRenameHint: "Leave it empty to use the name the list gives itself.",
        .subDeleteTitle: "Delete this subscription?",
        .subDeleteAction: "Delete subscription",
        .subDeleteMessage_fmt: "Its servers (%d) are removed from the app. You can add the list again by its link.",
        .throughputKbit_fmt: "%@ Kbit/s",
        .throughputMbit_fmt: "%@ Mbit/s",
        .laneUnnamed_fmt: "Room %d",
        .lanesPanelTitle: "Speed by protocol",
        .lanesPanelTotal: "Total",
        .laneRowA11y_fmt: "%@: download %@, upload %@",
        .protoCheckTitle: "Speed of each room",
        .protoCheckLead: "Each room is measured on its own, then all of them together: you see which is fastest and how much joining them adds.",
        .protoCheckRunAll: "Check all",
        .protoCheckStop: "Stop",
        .protoCheckRunOne: "Check",
        .protoCheckAllTogether: "All together",
        .protoCheckWaiting: "Waiting",
        .protoCheckMeasuring: "Measuring…",
        .protoCheckFailed: "This room isn't answering right now",
        .protoCheckFastest: "Fastest",
        .protoCheckPing_fmt: "%d ms",
        .protoCheckGain_fmt: "Together: ×%@ the fastest one alone",
        .settingsSectionWidgets: "Widgets",
        .liveActivityToggle: "Show the connection and its speed",
        .liveActivityNote: "While olcOS is connected, a card shows the server and the speed. Turn this off and it disappears at once. Swipe it off the Lock Screen and it stays away until the next connection.",
        .throughputShortKbit_fmt: "%@K",
        .throughputShortMbit_fmt: "%@M",
        .routingTitle: "Routing",
        .routingListDirect: "Sites on the list go direct",
        .routingAllTunnelFooter: "Every site and app goes through the tunnel.",
        .routingListDirectFooter: "Sites on the list open straight from your phone, the rest through the tunnel: banks, government services and other Russian sites work as usual and do not use the tunnel.",
        .routingRussianList: "Russian sites",
        .routingRussianListDetail_fmt: "The .ru, .рф and .su zones, and Yandex, VK, 2GIS, Wildberries and Avito on other domains — %d entries.",
        .routingOwnHeader: "Your sites and addresses",
        .routingOwnFooter: "One per line: a site (example.com, with everything under it), a link, an IP address or a network (10.0.0.0/8).",
        .routingBadLine_fmt: "Line %d is not a site or an address and is skipped.",
        .routingAppliesNext: "Changes apply on the next connection.",
        .routingReconnect: "Reconnect now",
        .autoConnectTitle: "VPN auto-connect",
        .autoConnectOn: "On",
        .autoConnectOff: "Off",
        .autoConnectCellular: "On mobile data",
        .autoConnectLead: "iOS turns the VPN on by itself when the phone joins a network chosen here, even with the app closed.",
        .autoConnectWiFiHeader: "Wi-Fi",
        .autoConnectWiFiOff: "Do not turn on",
        .autoConnectWiFiAny: "On any network",
        .autoConnectWiFiOnly: "Only on these networks",
        .autoConnectWiFiExcept: "Everywhere except these (trusted)",
        .autoConnectOnlyHeader: "Turn on in these networks",
        .autoConnectExceptHeader: "Trusted networks: turn off",
        .autoConnectNetworkPlaceholder: "Network name",
        .autoConnectAddNetwork: "Add",
        .autoConnectNoNetworks: "Add at least one network, or Wi-Fi will never turn the VPN on.",
        .autoConnectKeyNote: "Works only in VPN mode and applies the next time the VPN turns on. So that iOS can connect without the app, the connection key stays in the system VPN settings while auto-connect is on. Turning the VPN off by hand pauses auto-connect until you turn it on again.",
        .autoConnectNeedsVPN: "This install cannot run a VPN (it is signed with a free Apple ID). Auto-connect will work once the app is signed with a paid developer account.",
        .vpnBondingToggle: "Join all rooms in VPN mode",
        .vpnBondingNote: "A whole-server connection joins up to three of its rooms inside the VPN too, for more speed. Each room is a video-call session and iOS gives the VPN about 50 MB: if the VPN starts dropping, turn this off.",
        .laneRejoining_fmt: "Room %d (%@) dropped out — joining it again",
        .laneRejoinFailed_fmt: "Room %d (%@) could not be joined yet — trying again shortly",
        .listOpenServer: "Open server",
        .listOpenServerDetail: "Rooms, speed-up, logs, updates",
        .listAddOwnServer: "Connect your own server",
        .listBundleRooms_fmt: "Rooms: %d",
        .addRoomTitle: "Add a service or a room",
        .addRoomLead: "Each room is one more call your server sits in. A connection to the whole server runs through every room at once, so each new room adds speed.",
        .addRoomLimit_fmt: "Up to %d rooms per service.",
        .addRoomNotYet: "Not on the server yet",
        .addRoomCount_fmt: "Rooms: %d",
        .addRoomFull_fmt: "Rooms: %d — the most one service takes",
        .addRoomNeedNothing: "added right away",
        .addRoomNeedYandex: "needs a Yandex sign-in",
        .addRoomNeedLink: "needs a VK sign-in or a call link",
        .addRoomAction: "Add",
        .addRoomSignIn: "Sign in",
        .addRoomPasteLink: "Paste",
        .addRoomVKTitle: "VK call link",
        .addRoomVKHowTo: "In the VK app open Calls, tap Create call and copy the link, then paste it here. Your server will sit in that call.",
        .protoCheckReconnecting: "The room is reconnecting — check again in a minute",
        .clockToday_fmt: "at %@",
        .clockYesterday_fmt: "yesterday at %@",
        .clockOn_fmt: "%@ at %@",
        .liveRejoinNewRooms: "The new room is ready — reconnecting to use it",
        .widgetsRowOn: "Card on the Lock Screen: on",
        .widgetsRowOff: "Card on the Lock Screen: off",
        .widgetsLiveHeader: "Lock Screen and Dynamic Island",
        .widgetsHomeHeader: "Home Screen and Lock Screen widgets",
        .widgetsHomeHowTo: "To remove one: touch and hold the olcOS widget, then tap Remove Widget. To add one: touch and hold an empty spot, tap Edit → Add Widget and choose olcOS.",
        .widgetsControlHeader: "Control Centre button",
        .widgetsControlHowTo: "Open Control Centre, touch and hold an empty spot, and tap the minus on the olcOS button to remove it — or Add a Control to bring it back.",
        .widgetsOpenSystemSettings: "Open iOS Settings for olcOS",
        .widgetsSystemNote: "There you can also turn Live Activities off for olcOS entirely.",
        .laneJoiningShort: "joining…",
        .subRefreshFailedShort: "Could not update — the saved servers are kept",
        .agentKeyErrorKeychain: "Could not save the device key to the Keychain.",
        .agentKeyErrorCorrupt: "The stored device key is unreadable.",
        .agentErrorUnreachable: "The server agent did not answer.",
        .agentErrorHTTP_fmt: "The server agent returned an error (%d).",
        .agentErrorDecode: "The server agent’s answer could not be read.",
        .agentInstallError_fmt: "Could not set up server management: %@",
        .serverControlLabel: "Server connection",
        .serverControlAuto: "Automatic",
        .serverControlHTTPSTunnel: "HTTPS through the tunnel",
        .serverControlHTTPSDirect: "HTTPS directly",
        .serverControlSSH: "SSH",
        .serverControlAutoHint: "HTTPS first: through the tunnel when it runs through this server, otherwise directly. If HTTPS does not answer, the app uses SSH.",
        .serverControlHTTPSTunnelHint: "Server status and starting or stopping rooms only over HTTPS through the running tunnel. If the agent does not answer, you see an error instead of a switch to SSH. Installing, adding rooms and updates still use SSH.",
        .serverControlHTTPSDirectHint: "Server status and starting or stopping rooms only over HTTPS, straight to the server’s address. If the agent does not answer, you see an error instead of a switch to SSH. Installing, adding rooms and updates still use SSH.",
        .serverControlSSHHint: "Everything over SSH. The HTTPS agent is neither used nor installed.",
        .agentErrorPin: "The server agent’s certificate does not match the saved one.",
        .agentErrorNoTunnel: "No tunnel is running. Connect first, or choose another server connection in Settings.",
        .protocolOpenAction: "Rooms and settings",
        .protocolGone: "This protocol is no longer on the server.",
        .protocolRoomsHeader: "Rooms",
        .protocolMainRoom: "Main room",
        .protocolExtraRoom_fmt: "Room %d",
        .protocolChangeRoom: "Change",
        .protocolNewRoomAuto: "New room, made automatically",
        .protocolTypeRoom: "Enter a room by hand",
        .protocolAddRoom: "Add a room",
        .protocolRoomsFooterAuto: "The app makes new rooms itself. Each room adds speed when you connect to the whole server.",
        .protocolRoomsFooterManual: "Rooms of this service come from you: paste a link or an ID.",
        .protocolSetupHeader: "Setup",
        .protocolSettingsAction: "Transport and service settings",
        .coreVersionCurrent_fmt: "On the server: %@, the current version.",
        .coreVersionOld_fmt: "On the server: %@. This app runs %@: update.",
        .coreVersionUnknown: "The version on the server has not been read yet.",
        .listExtrasTitle: "Subscriptions and Xray",
        .listExtrasSummary_fmt: "Subscriptions: %d · Xray servers: %d",
        .listExtrasEmpty: "Your subscriptions, ready-made lists and Xray servers",
        .listSectionXray: "Xray servers",
        .xrayCardSectionHeader: "Xray",
        .protoCheckRunAgain: "Check again",
        .welcomePasteAccessAction: "Paste an access link from another phone",
        .widgetTrafficName: "olcOS traffic",
        .widgetTrafficDescription: "What came in and went out this session, the speed and how long it has run.",
        .widgetTrafficNone: "Figures appear once a connection is up.",
        .widgetTrafficRate_fmt: "Speed %@",
        .widgetTrafficAt_fmt: "at %@",
        .invitesAccessField: "Server access",
        .invitesAccessNone: "Connections only",
        .invitesAccessMember: "Rooms: view and restart",
        .invitesAccessOwner: "Full management",
        .invitesAccessUnavailable: "The server agent is not installed here yet, so the device gets connections only. Open this server's page while SSH works and try again.",
        .invitesAccessFooter: "With access, the device registers its own key with the server agent through this list. Revoking the invite takes the access back.",
        .invitesAccessMintFailed_fmt: "Could not create the access code: %@",
        .hostViaAgent_fmt: "%@ · through the server agent",
        .hostViaAgentMember_fmt: "%@ · through the server agent · rooms: view and restart",
        .hostAgentOnlyNoKey: "This server is managed through its agent, and this phone’s key could not be loaded.",
        .invitePairFailed_fmt: "Server access was not taken: %@. Ask for a new invite and open it again.",
        .addMenuPhoto: "Scan from photo",
        .photoQRNotFound: "No QR code was found in that picture.",
        .cameraDeniedTitle: "Camera access is off",
        .cameraDeniedBody: "olcOS needs the camera to scan a QR code. Allow it in Settings, or pick the QR code from a photo.",
        .openSettingsAction: "Open Settings",
        .subAllLinksSkipped_fmt: "None of the %d links could be read. Check that the list is meant for olcOS.",
        .subImportSkipped_fmt: "Links that could not be read and will be skipped: %d.",
        .subImportTitleSingle: "Add connection",
        .subImportTitleList: "Import list",
        .healthReasonKeyMismatchGuest: "The server’s key has changed, so this link no longer works. Ask whoever gave you the link for a new one.",
        .healthReasonServerOutdatedGuest: "The server runs an older version of the tunnel core than this app speaks. Ask whoever gave you the link to update the server.",
        .telemostLinkExpiresNote: "A Telemost link works for about 24 hours; after that, ask for a new one.",
        .addFlowInstallPortsNote: "The server must accept incoming connections on SSH port 22, the server-agent port, the invite share port, port 443 for Xray and the ports the chosen protocols use.",
        .invitesPortsNote: "The server must accept incoming connections on the invite share port and, for server access, on the server-agent port.",
        .installerSourcesMissing: "the files for the server are missing from this build of the app",
        .agentInstallNoEndpoint: "the server did not say where the agent listens",
        .inviteErrorPortBusy: "the share port is already in use on the server",
        .inviteErrorUploadFailed_fmt: "The list could not be put on the server: %@",
        .vpnPermissionUnavailable: "The system refused the VPN permission (a free Apple ID cannot run a VPN).",
        .invitePairPending_fmt: "Server access is not confirmed yet: %@. It confirms itself once you connect to any room of this server.",
        .invitesUsageOnline: "Connected now",
        .invitesUsageLastSeen_fmt: "Last connected: %@",
        .invitesUsageNever: "Not connected yet",
        .invitesUsageToday_fmt: "today at %@",
        .invitesUsageTrafficA11y_fmt: "Received %@, sent %@",
        .invitesUsageDevicesOne_fmt: "%d device",
        .invitesUsageDevicesFew_fmt: "%d devices",
        .invitesUsageDevicesMany_fmt: "%d devices",
        .laneJoinStuck_fmt: "Room %d (%@) took too long to join — joining it again",
        .netPathBlip: "Network dropped for a moment — checking the connection",
        .laneSilent_fmt: "Room %d (%@) brought nothing in for 3 minutes — joining it again",
        .resumeListenerGoneReason: "the local SOCKS port stopped answering while the app was away",
        .resumeTunnelDeadReason: "the tunnel stopped answering while the app was away",

        // VK Calls rooms made by the app with the user's own account.
        .vkErrNoAccount:       "No VK account is linked. Sign in to create VK calls.",
        .vkErrSessionRejected: "VK rejected the saved sign-in. Sign in again.",
        .vkErrRateLimited:     "VK is refusing new calls right now. Wait a minute and try again.",
        .vkErrNetwork:         "Could not reach VK. Check the connection and try again.",
        .vkErrMalformed:       "VK sent an answer the app could not read. Try again.",
        .vkErrStatus_fmt:      "VK returned an error (code %d). Try again in a minute.",
        .vkSignInAction:       "Sign in to VK",
        .vkLoginTitle:         "VK sign-in",
        .vkLoginWarning:       "Use a throwaway VK account. This device will store a sign-in cookie that opens that account's messages, profile and payments without the password.",
        .roomCreateAutoAction: "Create automatically",
        .roomCreateFailed:     "Could not create a room",
        .roomAnotherAction:    "Another room",
        .addFlowVKCreating:    "Creating a VK call…",
        .addFlowVKCreated:     "VK call created",
        .signOutAction_fmt:    "Sign out of %@",
        .signOutConfirmTitle_fmt:   "Sign out of %@?",
        .signOutConfirmMessage_fmt: "The app stops creating rooms for %@ until you sign in again. Current connections are not affected.",
        .roomRotationOff:            "Off",
        .roomRotationAutomatic:      "Automatic",
        .roomRotationDaily:          "Daily",
        .roomRotationWeekly:         "Weekly",
        .roomRotationNoteTelemost:   "A room lives 24 hours. The app renews it ahead of time.",
        .roomRotationNoteSteady:     "Rooms do not expire. Change them on a schedule if you like.",
        .roomRotationFooter:         "Applies to connections whose server you manage. A connection to someone else's server is left to its owner.",
        .roomRotationExceptionsHeader: "Exceptions",
        .roomRotationExceptionsFooter: "A skipped connection keeps its room until you change it yourself.",
        .roomRotationSkipConnection: "Skip this connection",
        .roomRotationEvery6Hours:    "Every 6 hours",
        .roomRotationEvery12Hours:   "Every 12 hours",
        .roomRotationEvery3Days:     "Every 3 days",
        .roomRotationHowOften:       "How often",
        .roomRotationWhen:           "When",
        .roomRotationWhenAny:        "Any time",
        .roomRotationWhenNight:      "At night",
        .roomRotationWhenHour:       "At a chosen hour",
        .roomRotationWhenNightShort: "at night",
        .roomRotationWhenHourShort_fmt: "at %@",
        .roomRotationHourLabel:      "Hour",
        .roomRotationNightNote:      "Night is 02:00–06:00 by the phone's clock. A due room waits for the next night.",
        .roomRotationHourNote:       "The change happens within that hour, by the phone's clock. A due room waits for the next one.",
        .settingsGroupConnection:    "Connection",
        .settingsGroupRooms:         "Rooms",
        .settingsGroupAccounts:      "Accounts",
        .settingsGroupNetwork:       "Network",
        .settingsGroupSpeed:         "Speed",
        .settingsGroupDiagnostics:   "Diagnostics",
        .settingsGroupLook:          "Appearance",
        .vkLoginStatusSignIn:        "Sign in to VK on this page",
        .vkLoginStatusChecking:      "Checking the sign-in…",
        .vkLoginStatusRefused:       "VK did not accept this sign-in. Tap Sign out of VK and sign in again.",
        .vkLoginSignOutAction:       "Sign out of VK",
        .accountsResetBrowserAction: "Reset sign-in in the browser",
        .accountsResetBrowserTitle_fmt: "Reset the %@ sign-in in the browser?",
        .accountsResetBrowserMessage_fmt: "The built-in browser may still remember a %@ sign-in that the app cannot use. This forgets it, so the next sign-in starts from scratch. Current connections are not affected.",
        // MTS Link rooms made by the app with the user's own account.
        .mtsErrNoAccount:       "No MTS Link account is linked. Sign in to make meetings.",
        .mtsErrSessionRejected: "MTS Link rejected the saved sign-in. Sign in again.",
        .mtsErrNoCreateRequest: "The app has not been shown how MTS Link makes a meeting yet. Make one in the sign-in window, or paste a meeting link.",
        .mtsErrRateLimited:     "MTS Link is refusing new meetings right now. Wait a minute and try again.",
        .mtsErrNetwork:         "Could not reach MTS Link. Check the connection and try again.",
        .mtsErrMalformed:       "MTS Link answered without a meeting link the app could read. Try again.",
        .mtsErrStatus_fmt:      "MTS Link returned an error (HTTP %d). Try again in a minute.",
        .mtsSignInAction:       "Sign in to MTS Link",
        .mtsLoginWarning:       "This device stores the sign-in cookies of your MTS Link account. They open that account’s meetings, recordings and billing without the password. The password itself stays with MTS Link: the app sees only the cookies and uses them only to make rooms.",
        .mtsLoginNote:          "The sign-in stays on this phone and is used only to make rooms.",
        .mtsInfoTitle:          "About this window",
        .mtsLoginStatusSignIn:  "Sign in to MTS Link on this page",
        .mtsLoginStatusChecking: "Checking the sign-in…",
        .mtsLoginStatusRefused: "MTS Link did not accept this sign-in. Sign out under ⓘ and sign in again.",
        .mtsLoginSignOutAction: "Sign out of MTS Link",
        .accountsMTSBody:       "The server joins a permanent MTS Link meeting as a guest. Sign in once and create one permanent meeting in the sign-in window so the app learns how; after that “Make a room” is one button. Or paste a link from the cabinet. The free plan allows two permanent meetings. The password stays with MTS Link — the app keeps only the sign-in cookies and uses them only to make rooms.",
        // The sign-in sheet's "what the app saw" disclosure.
        .mtsSeenTitle:  "What the app saw",
        .mtsSeenEmpty:  "Nothing captured yet.",
        .mtsSeenCopy:   "Copy the log",
        .mtsSeenHint:   "Make one permanent meeting here and press Finish at the bottom. Then copy the log if you want to send it.",
        // Making MTS Link rooms.
        .mtsMakeRoomAction:       "Make a room",
        .addFlowMTSBody:          "Press Make a room: the app makes a permanent meeting with your MTS Link account. The first time, create one meeting yourself in the sign-in window so the app learns how; after that one button is enough.",
        .addFlowMTSCreating:      "Creating an MTS Link meeting…",
        .addFlowMTSCreated:       "Meeting created",
        .roomRotationNoteMtslink: "The app changes MTS Link rooms only after it has been shown how a meeting is made and holds the sign-in (Settings → Accounts). Until then the rule stays Off.",
        .vp8MtsLinkNote: "For MTS Link the app uses at least 60 frames per second and 64 packets per frame.",
        .mtsLearnBannerTitle: "How to teach the app",
        .mtsLearnBanner: "Sign in if the site asks. It must be an account that already exists and whose e-mail is confirmed — a new account is finished through the e-mail the site sends, not here. Then open Meetings → Schedule → Permanent meeting, create it, and press Finish at the bottom. Do not use “Quick meeting”: it is a one-off and ends, while the server needs a meeting that stays. The app remembers how, and next time one button is enough.",
        .mtsLearnFinish: "Finish",
        .mtsLearnHint: "A meeting seems to be created — press Finish.",
        .mtsLearnStep: "Create a permanent meeting: Schedule → Permanent meeting, then press Finish.",
        .mtsLearnConfirm_fmt: "Room: %@ — use it?",
        .mtsLearnUse: "Use it",
        .mtsLearnNotThis: "Not this one",
        .mtsLearnBack: "Back to the page",
        .mtsLearnNone: "No meeting was found in what you did here, so the app learned nothing. Create a permanent meeting and press Finish again, or paste the meeting’s link below.",
        .mtsLearnSeveral: "Several different meetings were found, so the app learned nothing. Pick yours, or paste its link below. To teach the app, close this window and make just one meeting in a new one.",
        .mtsLearnPasteInvalid: "That is not an MTS Link meeting link.",
        .roomRotationNoteMtslinkPlan: "A new meeting is made each time; the old one stays in the cabinet. The free MTS Link plan allows 2 permanent meetings, so delete old ones in the cabinet.",
        .mtsErrMissingToken: "The MTS Link page did not give the app a sign-in token the request needs. Try again in a minute, or make the room in the sign-in window.",
        .mtsErrSameRoom: "MTS Link answered with the room you already have. The plan may be at its limit of permanent meetings — delete an old one in the cabinet and try again.",
        .mtsErrTimeout: "MTS Link took too long to answer. Try again.",
        .mtsReasonSignIn: "Not signed in to MTS Link yet — sign in on this page first.",
        .mtsReasonLearn: "The app has not learned to make rooms yet.",
        .mtsAccountLearned: "The app can make rooms: it has learned how.",
        .mtsAccountNotLearned: "The app has not learned yet — create a permanent meeting in the sign-in window once.",
        .mtsTeachAction: "Show the app how to make a room",
        .mtsForgetAction: "Forget what the app learned",
        .mtsForgetMessage: "The app will have to be shown again how to make a room. The sign-in stays.",
        .mtsErrRejected_fmt: "MTS Link refused the request (HTTP %d: %@). The saved sign-in may be gone, or the plan’s limit of permanent meetings may be reached.",
        .mtsMeetingQuick: "This is a quick meeting: it works only while you are in it. A permanent one is needed: Schedule → Permanent meeting.",
        .mtsMeetingNoSession: "This meeting has no session — the server cannot join it.",
        .mtsMeetingGone: "MTS Link does not know this meeting.",
        .mtsMeetingUnknown: "Could not check the meeting — try again.",
        .mtsMeetingChecking: "Checking the meeting…",
        .protocolOpWorking: "Working on the server…",
        .protocolOpStarted: "Started",
        .protocolOpStopped: "Stopped",
        .protocolOpSaved: "Saved",
        .protocolOpRoomChanged: "Room changed",
        .protocolOpRoomAdded: "Room added",
        .protocolOpRoomRemoved: "Room removed",
        .subFetchTitle: "Load the list?",
        .subFetchMessage_fmt: "olcOS will download it from %@, and that server will see this device's IP address.",
        .subFetchAction: "Load",
    ]

    // MARK: Russian
    // The user is addressed formally («вы») throughout.

    static let russian: [L10n: String] = [
        .vpnAutomaticFallbackSummary: "Включён запасной режим — прокси", // #488: Compact automatic-fallback disclosure label.
        // boc #488: Automatic-mode explanations requested by #487.
        .tunnelModeAutomatic: "Автоматически (рекомендуется)",
        .tunnelModeAutomaticHint: "Системный VPN, если iOS его разрешает; иначе — прокси для отдельных приложений, и приложение скажет почему.",
        .tunnelModeVPNHint: "Только системный VPN: через туннель идёт всё устройство. Нужно приложение, подписанное с правами Network Extension; одной подписки Apple Developer для этого мало.",
        .tunnelModeProxyHint: "Прокси для отдельных приложений: через туннель идут только приложения, которые на него настроены, например Telegram.",
        .vpnAutomaticFallback_fmt: "Используется прокси: установленное приложение не получило разрешение или права для VPN: %@. Это не VPN для всего устройства; настройте совместимые приложения на локальный прокси. Чтобы снова попробовать VPN, выберите VPN в Настройках.",
        // eoc #488

        // Common
        .ok:                "OK",
        .cancel:            "Отмена",
        .save:              "Сохранить",
        .close:             "Закрыть",
        .done:              "Готово",
        .error:             "Ошибка",
        .edit:              "Изменить",
        .okPrompt:          "Результат",   // #457 was: «Готово» — этим же заголовком показывались ошибки

        // Tabs
        // #457 was: «Управление VPS» — см. английскую таблицу: одно место
        // называлось тремя именами, и подсказка «на вкладке «Серверы»»
        // указывала на вкладку с другим названием.
        .tabServers:        "Подключения",
        .tabSettings:       "Настройки",
        .autoDetectedContainer_fmt: "Найдена существующая установка: %@",

        // Tunnel mode (#vpn)
        .tunnelModeProxy:           "Прокси",
        .tunnelModeVPN:             "VPN",
        .configModeSectionHeader:   "Режим туннеля",
        .configVPNUnavailableFooter: "Режим VPN недоступен в этой установке:",
        // #461 было: «videochannel» — сырой id; во всех списках он «Видео».
        .vpnVideochannelUnsupported: "Транспорт «Видео» не поддерживается в режиме VPN. Переключите подключение на другой транспорт или используйте режим прокси.",
        .vpnDisconnected:           "VPN-туннель отключён",
        .vpnSettingsEntryName:      "olcOS",
        .vpnCapabilityUnavailable_fmt: "Система отклонила конфигурацию VPN (%@). Так бывает, если доступ к VPN был отклонён или приложение подписано бесплатным Apple ID — для Network Extension нужна платная команда Apple Developer. Режим прокси продолжает работать.",

        .settingsRefreshOnEntryToggle:  "Проверять при открытии",
        .settingsRefreshOnEntryExplainer: "При открытии приложение проверяет, какие подключения работают.",
        .failoverSwitching_fmt:      "Протокол %@ не отвечает — переключаюсь на %@",
        .failoverAllFailed:          "Все протоколы этого сервера недоступны",
        // #454/#459: карточка здоровья стала блоком «Текущая сессия» внутри
        // «Диагностики» — своего заголовка, строки скорости и кнопки обновления
        // у неё больше нет.
        .healthExitLabel:            "Выход",
        // #460 было: `.healthLatencyLabel` («Задержка») — см. `diagResponseLabel`.
        .healthLatencyMs_fmt:        "%d мс",
        // #455: premium redesign editorial additions
        // #461 было: «Telemost … (только vp8channel) … datachannel … WBStream» —
        // три сырых id и имя оператора, написанное не так, как в самом списке.
        // #470 было: «(только VP8)» — см. английскую запись.
        // #460 было: `.configReliabilityHeader` («Надёжность») — в этом разделе
        // настроек остался только переключатель авто-переключения, а он переехал.
        .unitSeconds:                "с",
        .sshTestInvalidPort:         "Некорректный порт",
        .logLevelOff:                "Выкл.",
        .logLevelErrors:             "Только ошибки",
        .logLevelNormal:             "Обычный",
        .logLevelDebug:              "Отладка",
        .logLevelVerbose:            "Подробный (всё)",
        // #455: reset-to-defaults
        .resetSettingsAction:        "Сбросить все настройки",
        .resetSettingsFooter:        "Вернёт все настройки к значениям по умолчанию, включая режим туннеля. Подключения и серверы сохранятся.",
        .resetSettingsConfirmTitle:  "Сбросить все настройки?",
        .resetSettingsConfirmBody:   "Все настройки вернутся к значениям по умолчанию, включая режим туннеля. Подключения и серверы не затрагиваются.",

        // Routing
        .routingHeader:     "Маршрутизация",
        .routingAllTunnel:  "Всё через туннель",
        .routingViaTunnel:  "через туннель",
        .routingDirect:     "напрямую",

        // Connection state
        .stateDisconnected: "Отключено",
        .stateConnecting:   "Подключение…",
        .stateConnected:    "Подключено",
        .stateConnectFailed: "Сбой подключения",
        .stateWaitingForNetwork: "Ожидание сети…",
        .stateReconnecting: "Переподключение…",
        .stateErrorPrefix_fmt: "Ошибка: %@",

        // ConnectionsView
        // #303 was: "Нажми + чтобы добавить подключение вручную. Если есть VPS — перейди во вкладку Управление VPS для автоматической установки."
        .actionConnect:              "Подключить",
        .actionRetry:                "Повторить",
        .shareAction:                "Поделиться",
        .copyURIAction:              "Скопировать URI",
        .shareConnectionTitle:       "Поделиться подключением",
        // #471: «оператора» → «сервис» — sectionCarrier теперь «Сервис»; «оператор» по-русски значит сотовый оператор.
        .shareConnectionExplanation: "Отправьте этот URI, чтобы другой пользователь мог подключиться через ваш сервер. Содержит сервис, ID комнаты и ключ шифрования — SSH-данные сервера не включены.",
        .shareConnectionURIHeader:   "URI подключения",
        .fullAccessLinkRetired:      "Ссылки с полным доступом по SSH больше не поддерживаются — попросите приглашение с доступом к управлению.",
        .copiedURI_fmt:              "📋 URI скопирован: %@",

        // AddConnectionView
        .newConnectionTitle:         "Новое подключение",
        .editConnectionTitle:        "Редактирование",
        .nameField:                  "Метка",
        .namePlaceholder:            "Мой сервер",
        .groupDefault:               "Подключения",   // #344 was: "Основная"
        .importByURI:                "Импорт по ссылке",
        .scanQRAction:               "Сканировать QR",
        .pasteURIAction:             "Вставить URI",
        // #458 was: «Нажми «Вставить»…» — the button reads «Вставить URI».
        .importHint:                 "Ссылка olcrtc:// заполнит поля ниже. Ссылка на подписку или её текст откроет импорт.", // #381 was: "Если у тебя есть URI с сервера — вставь сюда и нажми «Распознать». Поля ниже заполнятся автоматически." — кнопки «Сканировать QR» / «Вставить» (с #361 «Вставить» импортирует и подписки), кнопки «Распознать» нет.
        .clientIDFooter:             "Оставьте «default» — тогда каждое устройство представляется своим ID, и одна ссылка работает на нескольких устройствах сразу. Меняйте, только если владелец сервера просил конкретное значение.",
        .keyPlaceholder:             "64 hex-символа",
        .roomIDLabel:                "Идентификатор комнаты",
        .clientIDLabel:              "ID клиента",
        .keyHexLabel:                "Ключ (hex)",
        .vp8ParamsHeader:            "VP8 параметры",
        .socksAuthHeader:            "SOCKS5 авторизация",
        .socksAuthFooter:            "Логин и пароль для доступа к локальному SOCKS5-прокси. Нужно только если хотите ограничить другие приложения от использования туннеля.",
        .socksUserLabel:             "Пользователь",
        .socksPassLabel:             "Пароль SOCKS",
        // #470 было: «без auth» — английское слово в русской подсказке.
        .socksUserPlaceholder:       "пусто = без авторизации",
        .vp8FpsLabel:                "FPS",
        .vp8BatchLabel:              "Размер пачки",
        .globalDefault_fmt:          "глобальный (%d)",
        .overrideHint:               "Переопределяют глобальные настройки только для этого подключения. «×» сбрасывает к глобальному.",
        // #365: параметры seichannel для соединения
        .seiParamsHeader:            "Параметры SEI",
        .seiFpsLabel:                "FPS",
        .seiBatchLabel:              "Размер пакета",
        .seiFragLabel:               "Размер фрагмента",
        .seiAckLabel:                "Таймаут ACK (мс)",
        // #461 было: «seichannel» — id; в списке этот транспорт называется «SEI».
        .seiParamsHint:              "Настройки SEI-канала. Отправляются только при транспорте SEI, но сохраняются в любом случае.",

        // ServersView
        // #457 was: «Список VPS» — заголовок экрана расходился с названием
        // вкладки и с текстом, который на него ссылается.
        .serversTitle:               "Мои серверы",
        .emptyNoServers:             "Нет серверов",
        .emptyNoServersHint:         "Добавьте сервер по SSH — приложение установит на него протокол. Каждый протокол станет подключением, которым можно пользоваться и делиться.",
        .newServerTitle:             "Новый сервер",
        .editServerTitle:            "Изменить",
        .sshAccessHeader:            "Доступ по SSH",
        .hostField:                  "Хост",
        .portField:                  "Порт",
        .loginField:                 "Логин",
        .passwordField:              "Пароль",
        .actionInstall:              "Установить",
        .actionUninstall:            "Удалить все протоколы с сервера",
        // #471 было: «Обновить бинарник (закреплённая сборка + пересборка)» — см. английскую запись.
        .actionUpdate:               "Обновить серверную часть olcOS",
        .actionReboot:               "Перезагрузить",
        .actionChangeRoomTransport:  "Сменить комнату / транспорт",
        .actionDone:                 "Готово",
        .actionRemoveFromList:       "Удалить сервер из приложения",
        .removeHostConfirmTitle_fmt: "Удалить %@?",
        // #458/#471: подсказка называет только существующий контрол — пункт меню
        // теперь «Удалить все протоколы с сервера» (actionUninstall).
        .removeHostConfirmMessage:   "Сервер исчезнет из списка на этом устройстве. На самой машине ничего не меняется — если хотите её вычистить, сначала выполните «Удалить все протоколы с сервера». Пароль SSH удаляется из Keychain.",
        // #471: три строки ниже согласованы между собой и со скриптами —
        // обычное удаление оставляет кеш сборки, полное его забирает, образ не
        // трогает ни одно (removeImage: false), а подключения уходят вместе с
        // протоколами. См. английскую запись.
        .uninstallConfirmTitle:      "Удалить все протоколы с сервера?",
        .uninstallConfirmBody:       "Удаляет с сервера все протоколы и ключ, а сохранённые для него подключения удаляются из приложения. Инструменты остаются, так что переустановка займёт около минуты.",
        .deepUninstallConfirmBody:   "Удаляет все протоколы, ключ и кеш сборки (~300 МБ). Остальное на сервере не меняется.",
        .rebootConfirmTitle:         "Перезагрузить сервер?",
        // #470 было: «запустится автоматически» — см. английскую запись.
        // #471 было: «контейнер olcrtc может понадобиться запустить заново» — на карточке кнопка называется «Запустить сервер».
        .rebootConfirmBody:          "Перезагружает сервер целиком. Когда он поднимется, проверьте его карточку — возможно, его придётся запустить заново.",

        // #303: Recover connection from server
        .actionRecoverConnection:    "Восстановить подключение",
        .recoverConfirmTitle:        "Восстановить подключение с этого сервера?",
        // #470 было: «carrier, room, transport» — сырые id, которых нет больше нигде в русском UI.
        // #471: «оператора» → «сервис» (sectionCarrier).
        .recoverConfirmBody:         "Считывает сервис, комнату, транспорт и ключ шифрования, уже развёрнутые на этом сервере (только чтение), и добавляет их как новое подключение здесь.",
        .recoverConfirmAction:       "Восстановить",
        .provisioningRecovering:     "Чтение конфигурации сервера…",
        .recoverResultSuccess_fmt:   "Восстановлено %@/%@ — подключение добавлено",
        .recoverErrorMissingYAML:    "Конфигурация сервера не найдена — не удалось прочитать развёрнутый server.yaml.",
        .recoverErrorMissingField_fmt: "В конфигурации сервера отсутствует поле «%@»",

        // #314: generate-new-key fallback (server.yaml unreadable/unparseable)
        .rotateKeyConfirmTitle:      "Конфигурация сервера нечитаема — создать новый ключ?",
        .rotateKeyConfirmBody:       "Развёрнутый server.yaml не удалось прочитать, поэтому восстановить существующее подключение нельзя. Будет создан новый ключ шифрования на сервере, конфигурация восстановлена, сервер перезапущен, а полученное подключение добавлено здесь. Внимание: все другие устройства, использующие этот сервер, потеряют доступ, пока не импортируют новое подключение.",
        .rotateKeyConfirmAction:     "Создать новый ключ",
        .provisioningRotatingKey:    "Создание нового ключа сервера…",
        .rotateKeyResultSuccess:     "Новый ключ активен. Все ссылки, которыми вы делились раньше, перестали работать.",
        .rotateKeyResultAdded_fmt:   "Новый ключ создан — подключение %@/%@ добавлено",
        .rotateKeyFailedNoURI:       "Ротация ключа завершилась, но сервер не вывел URI — проверьте журнал provisioning.",

        // Protocol status on the server — #471, см. английскую запись
        .containerRunning_fmt:       "Протокол работает: %@",
        .containerStopped_fmt:       "Протокол остановлен: %@",
        .containerNotFound:          "На сервере ничего не установлено",
        .containerNotFoundShort:     "не найден",
        // #458 was: «— нажми «Установить».» — see the English entry: «Установить»
        // is not on the card in the states that raise this.
        // #471 было: «…ещё не установлен контейнер olcrtc».
        .containerNotInstalled:      "На этом сервере пока ничего не установлено.",
        .readinessNoPodman:              "Готов к установке — пока ничего не настроено, полная установка ~5–7 мин",
        .readinessNoImage:               "Готов к установке — первая установка скачает около 300 МБ (~3–5 мин)",
        .readinessImageReady:            "Готов к установке — всё уже скачано, ~1–2 мин",
        .readinessContainerStopped_fmt:  "Остановлен: %@",
        .readinessContainerRunning_fmt:  "Работает: %@",

        // VPS status card (#258/#261)
        .vpsTitleUnknown:         "Не проверено",
        .vpsTitleReady:           "Готов к установке",
        .vpsTitlePodmanReady:     "Инструменты установлены",
        .vpsTitleStopped:         "Остановлен",
        .vpsTitleRunning:         "Работает",
        .vpsSubUnknown:           "Проверка ещё не запускалась.",
        .vpsSubNoPodman:          "Пока ничего не настроено — полная установка 5–7 мин",
        .vpsSubNoImage:           "Первая установка скачает около 300 МБ",
        .vpsSubImageReady:        "Всё уже скачано — установка 1–2 мин",
        .vpsSubStopped:           "Установлен, не запущен",
        .vpsSubRunning:           "Сервер запущен. Через него пока ничего не проходило.",
        .vpsVerbChecking:         "Проверка",
        .vpsVerbInstalling:       "Установка",
        .vpsVerbStarting:         "Запуск",
        .vpsVerbStopping:         "Остановка",
        .vpsVerbReconfiguring:    "Переконфигурация",
        .vpsVerbUpdating:         "Обновление",
        .vpsVerbUninstalling:     "Удаление",
        .vpsVerbDeepUninstalling: "Полное удаление",
        .vpsVerbRebooting:        "Перезагрузка",
        .vpsConnecting:           "Подключение…",
        .vpsCheckServer:          "Проверить сервер",
        .vpsWorking:              "Выполняется…",
        .vpsOpFailed_fmt:         "Сбой: %@",

        // ContainerLogsView
        // #339 was: emptyLogsTitle + emptyLogsHint_fmt (ContainerLogsView sheet, deleted)
        .closeAction:                "Закрыть",

        // LogsView
        .logsTitle:                  "Логи",
        .logsSearchPlaceholder:      "Поиск",
        .emptyLogsGeneric:           "Пусто",
        // #316 was: `emptyLogsGenericHint` — «Запусти операцию во вкладке …»;
        // удалено в #457 вместе с вкладкой логов: экран лога называет свой
        // предмет сам и не отсылает к вкладкам.
        .noSearchResults:            "Ничего не найдено",
        .noSearchResultsHint_fmt:    "По запросу «%@» совпадений нет.",
        .categoryConnection:         "Подключение",
        .categoryDiagnostics:        "Диагностика",
        .categoryProvisioning:       "Сервер",
        .categoryContainerLogs:      "Протокол",

        // #294: per-source Logs tabs
        // #316 was: lowercase fragments (под заголовком таба) — теперь
        // открывают подсказку пустого состояния, читаются как предложения.
        .logsTabDescConnection:      "Логи подключения",
        .logsTabDescDiagnostics:     "Логи проверки IP и скорости",
        .logsTabDescVPS:             "Логи операций с сервером",
        .logsTabDescContainer:       "Логи протоколов с сервера",
        .logsFileNameLabel_fmt:      "Файл: %@",
        .logsContainerSelectServer:  "Сервер",
        .logsContainerNoServers:     "Нет настроенных серверов",

        // #295: per-server container log files
        .duplicateServerNameError:   "Сервер с таким именем уже существует",

        // #296: Container tab always-present load button
        // #338 was: logsDownloadFromServer ("Загрузить логи с сервера")
        .logsCheckServer:            "Проверить сервер",
        .logsContainerEmptyHint:     "Пока ничего не загружено. Нажмите «Загрузить», чтобы получить свежие строки с этого сервера.",
        // #316: single-stack Logs tab — короткие подписи сегментов + счётчик строк
        .logsSegConnection:          "Подкл",
        .logsSegDiagnostics:         "Диаг",
        .logsSegVPS:                 "Сервер",
        .logsSegContainer:           "Протокол",
        .logsLineCount_fmt:          "%d стр.",
        .logsPeerCount_fmt:          "👥 %d участн.",
        // #338: inline container fetch — карточка источника + фазы
        .logsFetchAction:            "Загрузить",
        .logsFetchFromHost_fmt:      "Загрузить с %@",
        .logsPhaseConnecting:        "Подключение…",
        // #471 was: the raw `podman logs --tail` command line — a progress
        // phase says what is happening, not which binary is being run.
        .logsPhaseCommand_fmt:       "Читаем последние %d строк из %@…",
        .logsPhaseReceiving:         "Получение вывода…",
        // #332: rendered-line cap notice
        .logsRenderTruncated_fmt:    "Показаны последние %d строк — «Поделиться» или «Копировать всё» выгружает полную историю.",
        .logsShareThisAction:        "Поделиться этим логом",
        .logsExportAllAction:        "Выгрузить все логи",
        .earlyRestartWedgeLabel:     "Автоперезапуск зависшей сессии",
        .wedgeRestartLog:            "⚠ Похоже, сессия зависла — ранний перезапуск",
        .wedgeRestartReason:         "зависшая сессия",

        // SettingsView
        .settingsTitle:              "Настройки",
        .sectionSOCKS5:              "SOCKS5",
        .sectionDNS:                 "DNS",
        // #460 (finding 12, проверка) было: «vp8channel» — сырой
        // идентификатор транспорта. Везде в приложении он называется «VP8».
        // #460 было: `.sectionConnection` («Подключение») — один заголовок над
        // восемью строками и как минимум четырьмя разными темами. Теперь один
        // заголовок = одна тема, и подпись под разделом относится только к ней.
        .settingsSectionStart:       "Запуск подключения",
        .settingsSectionSpeedTest:   "Тест скорости",
        .sectionLogs:                "Логи",
        .sectionIPSources:           "Источники проверки IP",
        .ipSourcesFooter:            "Сервисы, опрашиваемые при проверке IP. Варианты из ru-зоны остаются доступны, когда публичные резолверы заблокированы. Если ничего не выбрано, используются значения по умолчанию.",
        // #460 было: «Провайдер спидтеста» — раздел над ним называется «Тест
        // скорости», а одна вещь должна называться одним словом.
        .sectionSpeedProvider:       "Провайдер теста скорости",
        .speedProviderFooter:        "Сервер, против которого идёт тест скорости. Смените, если выбранный медленный или заблокирован в вашей сети.",
        .speedAllFailed:             "Все измерения не удались",
        // #458: name the control that does it («Сменить комнату / транспорт»),
        // matching the English entry.
        // #461 было: «(vp8channel/sei/video)» и «на datachannel» — сырые id в
        // совете про список, который пишет все четыре словами.
        .speedSlowJitsiHint:         "Скорость зависит от сервера Jitsi и транспорта. Попробуйте другой транспорт или другой сервер Jitsi: «Сменить комнату / транспорт» в разделе «Мои серверы».",
        .settingsPortLabel:          "Порт",
        .checkPortAction:            "Проверить порт",
        .randomPortAction:           "Случайный",
        .portFree:                   "свободен",
        .portBusy:                   "занят",
        .logPortFree_fmt:            "✓ Порт %d свободен",
        .logPortBusyOther_fmt:       "✗ Порт %d занят",
        .logPortBusyOlcrtc_fmt:      "✓ Порт %d занят туннелем olcOS",
        .socksPortChangeNote:        "Изменение порта применится при следующем подключении.",
        .dnsFreeFormPlaceholder:     "IP:port",
        .dnsFooter:                  "Обычно менять не нужно: если выбранный DNS молчит, olcOS сам переходит на другой, а затем на DNS телефона. Новый DNS применяется при следующем подключении, и часто помогает именно переподключение. Используется туннелем и при установке серверов; формат IP:port. Пресеты мобильных операторов работают только внутри их сети.",
        // #460 (finding 12) было: `.vp8Footer` — «MobileSetVP8Options
        // применяется только если transport=vp8channel…»: символ gomobile и
        // строка конфига в подписи к настройке. Само слово «vp8channel»
        // остаётся — это транспорт, который пользователь выбирает на вкладке
        // «Серверы», а не внутреннее имя.
        // #461: «для Telemost» -> «под «Яндекс Телемост»» — как в списке.
        .vp8Note:                    "Действуют только для транспорта VP8. Больше кадров и крупнее пачки — больше данных за секунду. Значения по умолчанию (30 и 64) проверены.",
        .startTimeoutLabel:          "Таймаут готовности",
        .startTimeoutNote:           "Сколько ждать, пока подключение поднимется, прежде чем прекратить попытку и сообщить об ошибке.",
        .autoConnectOnLaunchLabel:   "Авто-подключение при запуске",
        .autoConnectOnLaunchNote:    "Подключается к выбранному серверу сразу при открытии приложения.",
        // #470: «соединение» → «подключение» — одно место — одно имя (вкладка «Подключения»).
        // #471 было: «…при удалении VPS» — одно слово на одну вещь: сервер.
        .autoRemoveConnectionOnUninstallLabel: "Удалять его подключения при удалении сервера",
        .autoRemoveOnUninstallNote:  "Когда вы удаляете протоколы с сервера в разделе «Мои серверы», созданные им подключения тоже исчезают из списка.",
        .tunnelCheckLabel:           "Проверка туннеля",
        .keepAliveOff:               "выкл",
        .backgroundAudioLabel:       "Фоновая работа (через аудио)",
        .backgroundAudioNote:        "Держит туннель живым, пока приложение в фоне, проигрывая беззвучную аудиодорожку. Расходует больше батареи. Если смахнуть приложение из списка открытых, прокси остановится.",
        .earlyRestartWedgeNote:      "Перезапускает сессию, как только она перестаёт пропускать трафик, не дожидаясь разрыва. По умолчанию выключено.",
        .localSocksAuthLabel:        "Требовать аутентификацию прокси",
        .logLevelLabel:              "Уровень логирования",
        .logLevelNote:               "Насколько подробно вести запись. Высокие уровни помогают разобраться с проблемой, но лог заполняется быстрее.",
        .footerKeepAlive:            "С заданным здесь интервалом делает сквозную проверку через туннель. При неудаче туннель переподключается. 0 — отключить.",
        .footerLogBuffer:            "Максимальное количество строк в памяти для каждой категории логов.",
        .logBufferLabel:             "Буфер логов",
        .containerLogsTailLabel:     "Строк из лога сервера",
        .containerLogsTailNote:      "Сколько последних строк подтягивать из лога сервера.",
        .clearAllLogsAction:         "Очистить все логи",
        .copyAllAction:              "Копировать всё",
        .clearCategoryAction:        "Очистить категорию",
        // #460 (finding 18) было: `.fontFooter` — «(через SwiftUI
        // dynamicTypeSize)»: имя фреймворка в подписи к настройке.
        .languageLabel:              "Язык",
        .themeLabel:                 "Тема",

        // #340/#299: переключатель оформления (Системное / Светлое / Тёмное / Серое)
        .appearanceSystem:           "Системное",
        .appearanceLight:            "Светлое",
        .appearanceDark:             "Тёмное",
        // #342: подсказка в подвале hero-карточки

        // InstallOptionsView
        .installTitle:               "Установка olcOS",
        .reconfigureTitle:           "Сменить комнату / транспорт",
        // #470 было: «с новыми флагами -carrier/-id/-transport» — см. английскую запись.
        // #471 было: «Перезаписывает конфиг протокола на сервере (оператор, комната, транспорт) и перезапускает его контейнер».
        .reconfigureInfoFooter:      "Перезапустит этот протокол с новыми настройками. Переустановка не нужна.",
        .reconfigureTransportTuningFooter: "Смена транспорта сбрасывает настройки VP8 и SEI на сервере к значениям по умолчанию. Для своих значений переустановите.",
        .parametersHeader:           "Параметры",
        .roomIDAutoGenHint:          "Room ID будет сгенерирован сервером.",
        .roomIDTelemostHint:         "Создайте встречу в Телемосте (нужен аккаунт Яндекса) и вставьте её ID — часть ссылки после /j/. Обычная ссылка живёт 24 часа.",
        .matrixRecommended_fmt:      "★ Рекомендуется для %@.",
        .matrixWorks_fmt:            "Работает с %@.",
        .matrixQuestion_fmt:         "⚠ Работа с %@ под вопросом.",
        .matrixFail_fmt:             "✗ Не работает с %@ — выберите другой транспорт.",
        .matrixUnknown_fmt:          "Нет данных о совместимости с %@.",
        // #470 было: «client-id=ios-<случайный> (генерируется) · …» — см. английскую запись.
        // #471 было: «key=hex64 (генерируется)» — имя поля и тип, которых пользователь не вводит.
        .carrierFooter:          "Для этого сервера создаётся новый ключ шифрования · DNS и VP8 берутся из настроек",
        .transportSectionHeader:     "Транспорт",
        .roomIDSectionHeader:        "Комната",
        .seiSettingsHeader:          "SEI-настройки",
        // #461 было: «передаются в srv.sh для seichannel» — имя скрипта и
        // сырой id транспорта в подписи, которую читает пользователь.
        .seiSettingsFooter:          "SEI-параметры, передаются на сервер при установке. Нужны только транспорту SEI.",
        .actionQR:                   "QR",

        // Status banner

        // TunnelManager log lines
        .mobileStartOK:              "✓ MobileStart OK, ожидаем WaitReady…",
        .mobileStartFailed_fmt:      "✗ MobileStart: %@",
        .bgKeeperFailed_fmt:         "⚠ Фоновый audio-keeper не запустился: %@ — приложение может быть остановлено в фоне",
        .transportUsesServerDefaults_fmt: "Будут использованы серверные дефолты для %@ — расширенные параметры пока не вынесены в настройки iOS.",
        .waitReadyFailed_fmt:        "✗ WaitReady: %@",
        // #470 было: «проверь … или смените carrier/transport» — «ты» и «вы» в одной фразе плюс сырые id.
        // #471: «оператора» → «сервис» (sectionCarrier).
        .connectNoPeer:              "Пир не присоединился вовремя — проверьте, что ключ совпадает с сервером и комната верна, или смените сервис/транспорт.",
        .waitReadyOK:                "✓ WaitReady OK — SOCKS5 слушает, проверяем туннель…",
        .tunnelOK:                   "✓ Туннель работает — данные идут через сервер",
        .tunnelFailed:               "✗ Туннель не отвечает (сервер недоступен или 403 Forbidden IP)",
        .keepAliveOK:                "♡ Keep-alive OK",
        .keepAliveLost:              "✗ Keep-alive: туннель не отвечает",
        .serverConnectionLost:       "Связь с сервером видеосвязи потеряна",
        .serverNotResponding:        "Сервер видеосвязи не отвечает",
        .disconnectingArrow:         "→ Отключение",
        .netPathLost:                "⚠ Сеть потеряна — ожидание подключения",
        .waitingForPortRelease:      "⏳ Ожидание освобождения порта…",
        .netPathRestored:            "сеть восстановлена",
        .netPathChanged:             "сеть изменилась",
        .reconnecting_fmt:           "↻ Переподключение (%@)",
        .reconnectAttempt_fmt:       "↻ попытка %d/%d через %d с",
        .reconnectAttemptSlow_fmt:   "↻ попытка %d через %d с — пробуем каждые 1–2 мин, пока вы не отключитесь",
        .reconnectGaveUp:            "Переподключиться не удалось. Нажмите «Повторить», чтобы попробовать снова.",
        .rejoinSettle_fmt:           "⏳ Очистка комнаты: %.1f с до повторного входа",
        .connectingOlcrtc_fmt:       "→ olcOS carrier=%@ transport=%@ clientID=%@",

        // TunnelManager errors
        .validateClientIDEmpty:      "Client ID не может быть пустым",
        .validateClientIDWhitespace: "Client ID не должен содержать пробелы",
        .validateKeyLength_fmt:      "Ключ должен быть 64 hex-символа (получено: %d)",
        .validateKeyNonHex:          "Ключ содержит не-hex символы",
        .validateRoomIDEmpty:        "Room ID не может быть пустым",
        // #470 было: «освободите … смените … в Настройках» — тот же совет, что healthReasonPortBusy, но на «вы».
        .errorPortBusy_fmt:          "Порт %d занят — освободите его или смените порт в настройках",
        .errorSecretsLocked:         "Разблокируйте устройство и снова откройте приложение, чтобы загрузить сохранённый ключ.",
        .errorRuntimeStillStopping:  "Предыдущая сессия ещё завершается — попробуйте снова через несколько секунд.",

        // OlcrtcURI errors
        .uriErrorInvalidScheme:      "Ссылка должна начинаться с olcrtc:// или vless://",
        .uriErrorMissingField_fmt:   "Не найдено поле: %@",
        .uriErrorMixedBrackets:      "Скобки полезной нагрузки URI не совпадают (ожидается [...] или <...>)",

        // Provisioning
        .provisioningSSHConnecting:  "Подключение по SSH…",
        // #470 было: «Reboot: …» — сосед provisioningUninstallSSH переведён.
        .provisioningRebootSSH:      "Перезагрузка: подключение по SSH…",
        .provisioningUninstallSSH:   "Удаление: подключение по SSH…",
        .provisioningRebooting:      "Перезагрузка…",
        .provisioningUninstalling:   "Удаление протоколов и файлов…",
        .provisioningUpdating:       "Обновление olcOS на сервере…",
        .provisioningReconfiguring:  "Изменение параметров протокола…",
        .provisioningStatusFetching: "Статус сервера…",
        .provisioningLogsFetching:   "Логи сервера…",
        .installStep1Upload:         "[1/3] Загружаем скрипт…",
        .installStep2Launch:         "[2/3] Запускаем скрипт установки…",
        .installStep3PollRetry_fmt:  "[3/3] Сервер временно недоступен, повтор (%d)…",
        .installPhaseWaiting:        "Ожидание…",
        .installPhaseSystemDeps:     "Установка системных пакетов…",
        .installPhaseClone:          "Загрузка исходников…",
        .installPhasePullImage:      "Загрузка образа для сборки…",
        .installPhaseDeps:           "Загрузка зависимостей…",
        .installPhaseBuild:          "Сборка olcOS…",
        .installPhaseStart:          "Запуск olcOS…",
        .installFailedNoURI_fmt:     "Скрипт установки завершился без ссылки подключения: %@. Подробности — в логах.",
        .installTimeout25min:        "Таймаут установки (25 минут)",
        .installResultSuccess_fmt:   "Сервер olcOS установлен (%@/%@)",
        .uninstallResultSuccess:     "Удалено с сервера. Подключения через него больше не работают.",
        .updateResultSuccess:        "olcOS на сервере обновлён",
        .provisioningStarting:       "Запускаем сервер…",
        .startResultSuccess:         "Сервер запущен",
        .actionStart:                "Запустить сервер",
        .provisioningStopping:       "Останавливаем сервер…",
        .stopResultSuccess:          "Сервер остановлен",
        .actionStop:                 "Остановить сервер",
        .scanningContainers:         "Ищем olcOS на сервере…",
        .actionScanVPS:              "Найти установленный olcOS",
        .scanNoContainers:           "На сервере не найдено установленного olcOS.",
        .scanRestoreAction:          "Восстановить",
        .actionDeepUninstall:        "Удалить весь olcOS с сервера",
        .deepUninstallResultSuccess:          "Все данные olcOS удалены",
        .reconfigureResultSuccess_fmt: "Параметры изменены (%@/%@)",
        // #470 было: «Команда reboot отправлена».
        .rebootResultSuccess:        "Команда перезагрузки отправлена",
        .logsBytesReceived_fmt:      "Логи получены (%d байт)",
        .provisionPasswordMissing:   "Пароль не найден в Keychain",
        .provisionSSHPrefix_fmt:     "SSH: %@",
        .provisionCommandPrefix_fmt: "Команда: %@",
        .provisionParsePrefix_fmt:   "Не удалось разобрать вывод: %@",
        // #470 было: английская строка дословно — следующая строка лога (sshRetryIn4s) уже русская.
        .sshAttemptFailed_fmt:       "✗ Попытка SSH %d/2 не удалась: %@",
        .sshRetryIn4s:               "  повтор через 4 с…",
        .sshPortNotResponding_fmt:   "Порт %d на %@ не ответил — проверьте, что SSH открыт и сервер доступен",
        .serverUnreachable_fmt:      "Сервер %@ не отвечает — проверьте, что он включён и его SSH-порт открыт",
        .sshTunnelDroppedMidOp_fmt:  "SSH-сессия шла через собственный туннель приложения, и туннель оборвался посреди операции — команда могла уже выполниться на сервере. Переподключитесь и проверьте состояние сервера. (%@)",

        // NetPing
        // #470 было: «ms» — healthLatencyMs_fmt пишет «мс».
        .pingTCPOK_fmt:              "TCP/%d отвечает за %@ мс",
        .pingTCPFail_fmt:            "TCP/%d недоступен",

        // ConnectionsView per-connection ping (#234)
        .pingNoFreePort:             "Нет свободного локального порта для пинга",
        .pingFailed:                 "Пинг не удался",

        // ServersView alerts
        .alertPasswordMissingShort:  "Пароль не найден",
        .alertKeyMissingShort:       "SSH-ключ не найден",

        // AddServerHostView
        .nameSettingLabel:           "Название",
        .sectionDescription:         "Описание",
        // #451: SSH auth-method picker + private-key entry
        .authMethodPickerLabel:      "Аутентификация",
        .authMethodPassword:         "Пароль",
        .authMethodKey:              "SSH-ключ",
        .sshKeyFooter:               "Вставьте содержимое файла приватного ключа OpenSSH (ed25519 или RSA), напр. ~/.ssh/id_ed25519. Ключ хранится только в Keychain устройства.",
        .sshKeyPasteButton:          "Вставить ключ из буфера",
        .sshKeyPassphraseField:      "Пароль ключа",
        .sshKeyDetected_fmt:         "✓ Обнаружен ключ %@",
        .sshKeyDetectedEncrypted_fmt: "✓ Обнаружен ключ %@ — зашифрован, нужен пароль ключа",
        .sshKeyErrorECDSA:           "Ключи ECDSA не поддерживаются. Используйте ed25519 или RSA (ssh-keygen -t ed25519).",
        .sshKeyErrorUnsupportedFormat: "Неподдерживаемый формат ключа. Конвертируйте в формат OpenSSH: ssh-keygen -p -o -f <файл>.",
        // #470: «Вставьте» → «Вставь».
        .sshKeyErrorNotAKey:         "Это не похоже на приватный ключ. Вставьте файл целиком, включая строки BEGIN OPENSSH PRIVATE KEY (не .pub).",

        // ConnectionsView misc
        .diagnosticsTitle:           "Проверка соединения",
        .ipCheckTitle:               "Проверка IP",   // #460 было: «IP проверка» — не по-русски
        .ipCheckRun:                 "Проверить IP",
        .speedTestRun:               "Запустить тест",

        // #311 — speed-tile metric labels/units + upload-fallback log line (ru = en, see L10n.swift)
        .speedLabelDL:               "Загрузка",
        .speedLabelUL:               "Отдача",
        // #342 was: "%.0f ms" / "%.1f Mbps" — unit moved to OlcMetric(unit:)
        .speedRateValue_fmt:         "%.1f",
        .speedUnitMbps:              "Мбит/с",
        .speedUploadFallback_fmt:    "  upload: %@ has no upload endpoint — using %@",

        // #236/#237 — UI strings localized after the i18n pass
        .ipChecking:                 "Проверка…",
        .ipNotChecked:               "Ещё не проверялось",
        .ipDnsLeak:                  "IP различаются — возможна утечка DNS",
        .ipSourcesAgree_fmt:         "✓ %@ (источников: %d)",
        .socksProxyAddr_fmt:         "SOCKS5-прокси: 127.0.0.1:%@",
        .portInUseByOlcrtc:          "занят туннелем olcOS",
        .roomPrefix_fmt:             "комната: %@",
        .qrCodeURIA11y:              "QR-код URI подключения",
        // #470: «Отсканируйте» → «Отсканируй».
        .qrCodeHintA11y:             "Отсканируйте этот код, чтобы импортировать подключение на другом устройстве",
        .cameraUnavailableTitle:     "Камера недоступна",
        .cameraUnavailableBody:      "На этом устройстве сейчас нет камеры, которой может пользоваться приложение. Выберите QR-код из фото.",
        .sectionCarrier:             "Сервис",
        .labelTransport:             "Транспорт",
        // #461 было: «Телемост» — теперь на главном экране это ИМЯ сервиса,
        // внутри которого прячется трафик, а у сервиса есть бренд.
        .carrierTelemost:            "Яндекс Телемост",
        .carrierWbstream:            "WB Stream",
        .carrierJitsi:               "Jitsi",
        .transportDatachannel:       "DataChannel",
        .transportVp8channel:        "VP8",
        .transportSeichannel:        "SEI",
        .transportVideochannel:      "Видео",
        .fieldRoomID:                "ID комнаты",
        .fieldJitsiURL:              "https://meet.example.org",

        // DNS carrier labels
        .dnsLabelMts:                "МТС",
        .dnsLabelBeeline:            "Билайн",
        .dnsLabelMegafon:            "МегаФон",
        .dnsLabelTele2:              "Tele2",
        .dnsLabelYota:               "Yota",

        // SubscriptionFetcher
        .subDohFailed_fmt:           "Защищённый DNS не смог найти адрес %@",
        .subInvalidResponse_fmt:     "Не удалось скачать список (HTTP %d)",
        .subNoAddress:               "Защищённый DNS не вернул ни одного адреса",

        // #111: subscription import (olcrtc-sub:// links)
        .subImportTitle:             "Импорт подписки",
        // #470: «соединений» → «подключений» — вкладка называется «Подключения».
        .subImportConfirm_fmt:       "Добавить подключений: %d (из «%@»)?",
        .subImportAddAction:         "Добавить",
        .subInvalidLink:             "Ссылка подписки должна иметь вид olcrtc-sub://host/path",
        // #470: «соединений» → «подключений».
        .subEmptyList:               "Подписка не содержит действительных подключений",
        .subImportPastedSource:      "вставленный список",

        // #363: отображение метаданных подписки
        .subMetaMultipleSources_fmt: "%d источников",   // #396

        // #346: подписи мини-статистики карточки VPS (аббревиатуры; ru = en по решению оператора)
        .vpsStatPing:                "Ping",
        .vpsStatDisk:                "Диск",
        .vpsStatRAM:                 "RAM",
        .vpsStatUp:                  "Аптайм",
        .scanRestored_fmt:           "Восстановлено: %@",

        // #337: безопасный для скриншотов режим — скрытие IP
        .maskIPsLabel:               "Скрывать IP-адреса",
        // #460 было: «на вкладке «Соединения»» — вкладка называется
        // «Подключения» (`.tabConnections`); одно место — одно имя.
        // #471 было: «на карточках VPS» — везде «сервер».
        .maskIPsFooter:              "Скрывает IP-адреса на экране — для скриншотов. Копирование и логи остаются настоящими.",

        // #328: конечные точки активного оператора с копированием в один тап
        // #460 (finding 23) было: `.carrierEndpointsTitle` («Точки оператора»)
        // и `.carrierEndpointsHint` — язык того, кто это сделал, на главном
        // экране и без единого слова о том, кому это вообще нужно. Строка
        // начинается с вопроса, который отбирает читателя, а экран объясняет
        // себя до списка адресов.
        // #461: теперь это пункт меню ⋯ у активного подключения, а не строка
        // карточки на ~90 pt, — значит, просто подпись. `carrierEndpointsRowHint`,
        // `carrierEndpointsRowConnectHint` и `carrierEndpointsShowAction` ушли
        // вместе со строкой; объяснение осталось в самом экране
        // (`carrierEndpointsLead`).
        .carrierEndpointsRowTitle:   "Пользуетесь другим прокси-приложением?",
        .carrierEndpointsScreenTitle: "Отправлять напрямую",
        // «DIRECT» остаётся латиницей и заглавными: так это правило называется
        // в самих прокси-приложениях, и именно это слово надо там найти.
        .carrierEndpointsLead:       "Нужно, только если трафиком телефона управляет другое прокси- или VPN-приложение. Добавьте все адреса ниже в его список DIRECT (исключений), чтобы оно выпускало видеозвонок olcOS без изменений — иначе оно перехватит звонок, на котором держится туннель, и подключения не будет.",
        .carrierEndpointsFootnote:   "Это адреса самого сервиса видеозвонков, они определены при открытии экрана. Адреса меняются — откройте экран заново после переподключения.",
        .carrierEndpointHost:        "Хост",
        .carrierEndpointResolvedIPs: "Найденные IP",
        .carrierEndpointResolving:   "Разрешение…",
        .carrierEndpointUnresolved:  "Не удалось разрешить",
        .carrierEndpointNoHost:      "ID комнаты этого сервиса не является хостом — исключать нечего.",
        .carrierEndpointCopied_fmt:  "📋 Скопировано: %@",
        .carrierEndpointRefresh:     "Разрешить заново",
        // #460 было: `.carrierEndpointsCheckAction` («Проверить» — читалось как
        // «проверить, живы ли эти адреса», чего кнопка не делает), а также
        // `.carrierEndpointsConnectHint` / `.carrierEndpointsReadyHint`.
        .carrierEndpointCopyAll:     "Скопировать хост и IP",

        // #359: доступность переключателя подключения и кнопок-иконок в тулбаре
        // #470 было: «Подключиться» — видимая кнопка (actionConnect) говорит «Подключить».
        .a11yConnectToggle:          "Подключить",
        // #470: «соединение» → «подключение».
        .a11yConnectHintSelectFirst: "Сначала выберите подключение",
        .a11yStateConnected:         "Подключено",
        .a11yStateConnecting:        "Подключение",
        .a11yStateDisconnected:      "Отключено",

        // #470: «Вставьте … оставьте» → «Вставь … оставь».
        // #470: «создайте … получите … вставьте» → «создай … получи … вставь».

        // #452: мульти-протокольный VPS — строки протоколов + доустановка
        .protocolsSectionHeader:      "Сервисы и комнаты",
        .addProtocolAction:           "Добавить сервис",
        .addProtocolTitle:            "Добавить протокол",
        .removeProtocolAction:        "Удалить с сервера",
        .removeProtocolConfirmTitle_fmt: "Удалить %@ с этого сервера?",
        .removeProtocolConfirmBody:   "Останавливает и удаляет этот протокол и его конфиг на сервере. Соответствующее подключение тоже удаляется из списка. Остальные протоколы продолжают работать.",
        // #460 (findings 7 / 16) было: `.protocolConnectedBadge` («Подключено»)
        // — самое длинное слово в строке заголовка, которой не хватало ширины,
        // и SwiftUI переносил его посреди слова. Держать перевод коротким.
        .protocolLiveBadge:           "Подключено",
        .protocolRecordMissing:       "Нет сохранённого подключения для этого протокола — используйте «Восстановить подключение» в меню строки.",
        .protocolAdded_fmt:           "Добавлен %@/%@ — подключение сохранено",
        .protocolRemoved_fmt:         "%@ удалён с сервера",
        .installExtrasHeader:         "Дополнительные протоколы",
        // #470: «выбирайте» → «выбирай».
        .installExtrasFooter:         "Устанавливаются на тот же сервер сразу после основного протокола с общим ключом шифрования. Каждый протокол получает своё подключение в списке — выбирайте нужное при подключении.",
        .installExtraToggle_fmt:      "Также установить %@",
        .installExtrasPartialFail_fmt: "Часть протоколов не установилась: %@",

        // #456: словарь проверенного состояния. Ничего здесь не утверждает
        // успех без реальной проверки; «Работает» даёт только сквозной
        // результат, который ещё не устарел.
        .healthNeverChecked:          "Ещё не проверено",
        // #459 было: «Нажми «Проверить»…» — пункта «Проверить» в меню
        // строки больше нет (его роль играет сама плашка), так что фраза
        // называла контрол, которого на экране нет. Теперь она просто констатирует факт.
        .healthNeverCheckedHint:      "Через это подключение ещё не проходил ни один запрос.",
        .healthChecking:              "Проверяем…",
        .healthCheckingHint:          "Заходим в комнату и загружаем тестовую страницу",
        .healthVerified:              "Работает",
        // #459 было: «Проверено %@ назад · %d мс» — с возрастом «только что»
        // это читалось как «Проверено только что назад». Предлог теперь внутри
        // `HealthAge.phrase`, и ни одна фраза здесь не добавляет свой.
        .healthVerifiedHint_fmt:      "Проверено %@ · %d мс",
        .healthVerifiedNoRTTHint_fmt: "Проверено %@",
        .healthFading:                "Недавно работало",
        .healthHandshake:             "Соединяется, но данные не идут",
        .healthHandshakeHint_fmt:     "Вошли в комнату %@, но трафик не прошёл",
        .healthStale:                 "Устарело",
        .healthStaleHint_fmt:         "Последняя проверка %@ — слишком давно, чтобы на неё полагаться",
        .healthInconclusive:          "Не удалось проверить",
        .healthCheckedAgo_fmt:        "проверено %@",
        .healthChipNever:             "не проверено",
        // #459 было: «давность %@» → «давность только что».
        // #470 было: «последний раз %@» — см. английскую запись.
        .healthChipStale_fmt:         "проверено %@",
        .healthChipFaded_fmt:        "было %@ · %@",
        .healthChipFadedNoRTT_fmt:   "работало %@",
        // #460: «сбой только что» без двоеточия читалось как обрывок фразы.
        .healthChipFailed_fmt:        "сбой %@",
        .healthChipHandshake_fmt:     "нет данных · %@",
        .healthChipUnchecked:         "не удалось проверить",
        // #459: две формы. `phrase` — законченный оборот, к нему нельзя ничего
        // приписывать. `short` — голая длительность для плашки, рядом с которой
        // уже стоит значение («215 мс · 2 мин»). Обе безопасны при 1.

        // #456: причины сбоя — что случилось И что делать дальше.
        .healthReasonKeyMismatch:      "Ключ сервера изменился, и сохранённый у вас ключ больше не подходит. Нажмите «Восстановить подключение», чтобы считать новый.",
        .healthReasonKeyMismatchShort: "Ключ не подходит",
        .healthReasonNoPeer:           "В комнате никто не ответил. Возможно, сервер остановлен, использует другую комнату, или его ключ после переустановки больше не совпадает.",
        .healthReasonNoPeerShort:      "Комната молчит",
        .healthReasonRoomInvalid:      "Идентификатор комнаты не подходит для этого сервиса. Проверьте его в «Сменить комнату / транспорт».",
        .healthReasonRoomInvalidShort: "ID комнаты отклонён",
        .healthReasonCarrierRejected:  "Сервис видеосвязи отклонил подключение. Возможно, комнаты больше нет или неверен токен аккаунта.",
        .healthReasonCarrierRejectedShort: "Сервис отказал",
        .healthReasonNetworkDown:      "У устройства нет интернета, поэтому о сервере это ничего не говорит.",
        .healthReasonNetworkDownShort: "Нет интернета",
        .healthReasonHostUnreachable:  "Сервер не ответил. Возможно, он выключен, перезагружается или заблокирован вашей сетью.",
        .healthReasonHostUnreachableShort: "Сервер не ответил",
        .healthReasonSSHAuth:          "SSH-вход отклонён. Сохранённый для этого сервера пароль или ключ не подходит.",
        .healthReasonSSHAuthShort:     "SSH-вход отклонён",
        .healthReasonPortBusy:         "Локальный порт SOCKS занят другим приложением. Освободите его или выберите другой порт в настройках.",
        .healthReasonPortBusyShort:    "Локальный порт занят",
        .healthReasonVPNActive:        "Пока включён системный VPN, подключения проверить нельзя. Отключите его и проверьте снова.",
        .healthReasonVPNActiveShort:   "Системный VPN включён",
        .healthReasonContainerStopped: "Протокол на сервере не запущен. Запустите его и проверьте снова.",
        .healthReasonContainerStoppedShort: "Сервер остановлен",
        .healthReasonTimedOut:         "Проверка не уложилась во время — данные так и не пришли.",
        .healthReasonTimedOutShort:    "Истекло время",
        .healthReasonDNSUnreachable:   "DNS-резолвер из настроек не ответил из этой сети, поэтому ни один адрес не удалось найти. О сервере это ничего не говорит — выберите другой резолвер, например Cloudflare 1.1.1.1.",
        .healthReasonDNSUnreachableShort: "DNS не отвечает",
        // #458 was: "… на вкладке «Логи»." — the Logs tab is gone (#457); the log
        // is reached from Settings → «Смотреть все логи» (settingsViewLogsRow).
        // #460: строку переименовали — переименована и эта фраза.
        .healthReasonUnknown:          "Проверка не дала ясного ответа. Подробности — в «Настройки → Смотреть все логи».",
        .healthReasonUnknownShort:     "Нет ясного ответа",

        // #456: действия — те же формулировки, что и у этих действий в других местах.
        .healthActionRecover:         "Восстановить подключение",
        .healthActionCheckRoom:       "Сменить комнату / транспорт",
        .healthActionStart:           "Запустить сервер",
        .healthActionPortSettings:    "Открыть настройки порта",
        .healthActionDNSSettings:     "Открыть настройки DNS",
        .healthActionRetry:           "Повторить",
        .healthActionVerify:          "Проверить",
        .healthShowReasonAction:      "Что не так?",
        .healthLatencyNotMeasured:    "не измерено",

        // #456: заголовки карточки VPS. «Не удалось проверить» — это не «остановлен».
        .vpsHeadlineOpFailed:            "Последнее действие не удалось",
        .vpsHeadlineUnreachable:         "Сервер недоступен",
        .vpsHeadlineUnreachableHintNever: "Сервер не отвечает",
        .vpsHeadlineNotChecked:          "Ещё не проверено",
        .vpsHeadlineNotCheckedHint:      "Проверяем сервер…",
        .vpsHeadlineStopped:             "Сервер остановлен",
        .vpsHeadlineStoppedHint:         "Установлен, но не запущен — нажмите «Запустить сервер»",

        // #456: прочие строки интерфейса
        .shareConnectionOnlyBadge:    "Ссылка подключения — без доступа к серверу",
        .shareConnectionOnlySub:      "По ссылке ниже можно подключаться через ваш сервер. SSH-доступа она не даёт, управлять сервером, перенастраивать или стирать его по ней нельзя.",
        .roomIDLastUsed_fmt:          "Использовать прошлую комнату: %@",
        .installExistingFoundTitle_fmt: "На этом сервере уже работает %@",
        .installExistingFoundBody:    "Переустановка удалит его и все остальные протоколы на этом сервере — вместе с их комнатами и ключами.",
        .installUseExistingAction:    "Использовать существующий",
        .installReinstallAction:      "Всё равно переустановить",

        // MARK: #457 Выбор режима туннеля (вкладка «Конфиг» удалена — выбор
        // переехал на экран подключения). От него зависит, что вообще означает
        // слово «Подключено».
        .tunnelModeLockedNote:       "Пока подключение работает, режим не переключить. Сначала отключитесь.",
        .tunnelCompareScope:         "Что идёт через него",
        .tunnelCompareScopeProxy:    "Только приложения, которые вы направите на 127.0.0.1",
        .tunnelCompareScopeVPN:      "Весь трафик этого устройства",
        .tunnelCompareNeeds:         "Что для этого нужно",
        .tunnelCompareNeedsProxy:    "Ничего — просто работает",
        .tunnelCompareNeedsVPN:      "Профиль VPN — iOS попросит его подтвердить",
        .tunnelCompareRuns:          "Где работает",
        // #470 было: «пока оно открыто» — см. английскую запись.
        .tunnelCompareRunsProxy:     "Внутри приложения; держится в фоне, пока включена «Фоновая работа (через аудио)»",
        .tunnelCompareRunsVPN:       "В фоне, приложение можно закрыть",

        // #457: лог — это подробности того, что его породило, поэтому в
        // заголовке стоит сам предмет, а не слово «Логи».
        // #460 (finding 21c) было: `.settingsOpenLogsRow` («Диагностика и
        // логи») — третье место в приложении со словом «Диагностика», и
        // единственное из трёх, которое открывает лог. Теперь так и написано.
        .settingsViewLogsRow:        "Смотреть все логи",
        .logsSubjectConnection:      "Лог подключения",
        .logsSubjectProvisioning:    "Лог операций с сервером",
        .logsSubjectContainer_fmt:   "Лог сервера · %@",
        .logsEmptySubjectHint:       "Здесь пока ничего не записано.",

        // #457: главный экран. «Подключено» и «проверено» — разные факты, и
        // строка доказательства не обещает больше, чем измерено.
        .actionDisconnect:           "Отключить",
        .heroSubjectNone:            "Пока нет подключений",
        // #459 (audit): было «Выбери подключение ниже.» — списка в этот момент нет.
        .heroPickAConnection:        "Сначала добавьте подключение.",
        .heroEvidenceStarting_fmt:   "запуск… %d с",
        .heroEvidenceUnverified:     "Проверка связи ещё не проходила",   // #471
        .heroEvidenceNoNetwork:      "держим сессию, пока не вернётся сеть",
        // #461 было: «Прокси · только приложения, которые смотрят на …» —
        // предложение там, где нужна подпись. Тот же один %@ (порт).
        .heroScopeProxy_fmt:         "Прокси · порт %@",   // #471
        .heroScopeVPN:               "VPN · всё устройство",   // #471

        // #457/#459: строки подключений. Активное подключение — это герой
        // экрана, в списке его нет, поэтому плашка «Активно» не нужна.
        .connectRowTapHint:          "Подключиться через это подключение",
        .connectRowRemove:           "Удалить подключение",

        // #457: если действие выполняется на другом экране — сказать, на каком.
        .healthActionOnServersTab_fmt: "%@ — в разделе «Мои серверы»",
        .healthActionInSettings_fmt:   "%@ — в настройках",
        .healthNeverMeasured:        "не измерялось",

        // #457: карточка сервера. Подпись про процесс говорит только о том, что
        // считано с сервера, и всегда с возрастом — это не проверка подключения.
        .vpsProcessUnread:           "С этого сервера пока ничего не считано",
        .protocolStoppedNote:        "На сервере не запущен",
        .vpsScanBeforeInstall:       "Ищем уже установленное…",
        .vpsScanFailed_fmt:          "Не удалось посмотреть, что на сервере. %@",

        // #458: «неизвестно» — это тоже ответ. Ни одна строка не называет
        // кнопку, которой нет на том же экране.
        .protocolsNotReadYet:        "Список протоколов ещё не прочитан с этого сервера",
        .addProtocolAllInstalled:    "Все поддерживаемые протоколы уже установлены на этом сервере.",
        .healthNeverProbedHint:      "Через это подключение ещё не проходил ни один запрос",
        .connectRowVerifyHint:       "Проверить это подключение настоящим запросом",

        // #459: редизайн «одного окна». Герой владеет активным подключением,
        // список под ним — переключатель, «Здоровье» и «Диагностика» слились в
        // одну карточку, а меню из тринадцати пунктов на карточке сервера стало
        // пятью безопасными пунктами плюс экран «Управление сервером».
        // #461 было: «Переключиться» — жалоба 3: заголовок сливался с меткой
        // сервера под ним и читался как «Переключиться — ams-1». Предмет этого
        // экрана — протокол, о нём заголовок и говорит.
        .diagSessionHeader:          "Текущая сессия",
        .diagToolsHeader:            "Проверки",
        // #459: владелец спросил про страну и IP выхода — «откуда они вообще
        // берутся?». Обе подсказки называют сервис, который отвечает.
        // #460 (findings 3 / 22) было: `.diagExitSourceHint` — «Запрошено у
        // ipinfo.io через туннель»: три слова в узкой правой колонке строки,
        // где они разваливались в рваный столбик. Теперь подпись во всю ширину
        // и говорит, что именно измерено, а не только кто ответил.
        // #460 (findings 2 / 15): 1109 мс красным здесь и 133 мс на плашке
        // подключения назывались одинаково, и #460 объяснил разницу заметкой
        // на 250 символов.
        // #461: владелец дважды просил, чтобы числа СОВПАДАЛИ, а не чтобы ему
        // объяснили разницу. Теперь обе стороны берут лучший из нескольких
        // круговых замеров по одному живому соединению — заметке нечего
        // примирять, и строка называется тем же словом, что и плашки.
        // #461 было: «Время ответа» и `.diagResponseNote`.
        .diagResponseLabel:          "Задержка",
        // Число — это включённые источники, их может быть и один, поэтому
        // двоеточие, а не «%d сервисов».
        .diagIPSourceHint_fmt:       "Спрашивает ваш адрес у публичных сервисов по текущему маршруту. Источников: %d.",
        .vpsReadAge_fmt:             "считано %@",
        .vpsManageServer:            "Управление сервером",
        .vpsAdvancedTitle_fmt:       "Управление: %@",
        .vpsAdvancedConnectionHeader:  "Подключение",
        .vpsAdvancedMaintenanceHeader: "Обслуживание",
        .vpsAdvancedRemoveHeader:      "Опасная зона",
        // Каждая опасная строка говорит, что именно она уничтожит, — этого не
        // умеет пункт меню, и ради этого экран и появился.
        // #471: две строки удаления читались как одна и та же дважды. Теперь они
        // различаются одной оговоркой — кеш сборки — и тем, что остаётся.
        .vpsAdvancedRebootFooter:      "Перезагружает весь сервер; всё на нём остановится, пока он не поднимется.",
        .vpsAdvancedUninstallFooter:   "Удаляет все протоколы и ключ; инструменты остаются для быстрой переустановки.",
        // #471 было: «Удаляет контейнеры olcrtc, папку развёртывания, ключ
        // шифрования и кеш сборки Go (~300 МБ). Podman и образ golang остаются.»
        // Образ не удаляется никогда (removeImage: false), а имя «Podman»
        // читателю ничего не говорит. См. английскую запись.
        .vpsAdvancedDeepUninstallFooter: "Удаляет протоколы, ключ и кеш сборки (~300 МБ); следующая установка — с нуля.",
        .vpsAdvancedRemoveHostFooter:  "Забывает сервер в приложении; на самой машине ничего не меняется.",

        // #460: раунды скриншотов 2–4.
        // #461 было: `.heroExitSourceNote` — целое предложение о происхождении
        // страны под строкой героя, на экране, который просили уместить в одну
        // страницу. То же самое один раз говорит `diagExitNote` на карточке.
        // Инструкция 26: авто-переключение уехало из настроек на экран с теми
        // самыми протоколами, между которыми оно переключает, и объяснение
        // ужалось с абзаца настроек до одной строки на карточке.

        // #461: при одном установленном протоколе у переключателя был заголовок
        // и ни одной строки. Подсказка называет экран, где это чинится (этот
        // экран не рисует кнопок, уводящих в другое место), и говорит, зачем
        // ставить второй, — ради этого переключатель и существует.

        // MARK: #463 Обновление комнаты Телемоста одной кнопкой
        // Яндекс гасит ссылку Телемоста через 24 часа после создания, и раньше
        // владелец чинил это руками по SSH — по тому самому каналу, который
        // перекрывают в белом списке. Теперь весь путь укладывается в один лист.

        // Ошибки создания комнаты. Каждая называет причину И следующий шаг; ни
        // одна не может нести куку сессии или внутреннее имя.
        .telemostErrNoAccount:       "Аккаунт Яндекса не привязан. Войдите, чтобы создавать комнаты Телемоста.",
        .telemostErrSessionRejected: "Яндекс отклонил сохранённый вход. Войдите заново.",
        .telemostErrRateLimited:     "Яндекс сейчас не даёт создавать встречи. Подождите минуту и попробуйте снова.",
        .telemostErrNetwork:         "Не удалось связаться с Яндексом. Проверьте соединение и попробуйте снова.",
        .telemostErrMalformed:       "Яндекс прислал ответ, который приложение не смогло разобрать. Попробуйте снова.",
        .telemostErrStatus_fmt:      "Яндекс вернул ошибку (HTTP %d). Попробуйте через минуту.",

        // Веб-вход. Самая важная строка во всей функции: сохранённый вход
        // открывает весь аккаунт Яндекса без пароля, поэтому предупреждение
        // висит над веб-вью — до того, как что-то будет введено.
        .yandexLoginTitle:           "Вход в Яндекс",
        .yandexLoginWarning:         "Используйте одноразовый аккаунт Яндекса. Устройство сохранит токен входа, который открывает почту, Диск и платежи этого аккаунта без пароля.",

        // Лист. Одно имя для пункта меню и для листа, который он открывает.
        .telemostNewRoomAction:      "Новая комната Телемоста",
        .telemostRoomServerLine_fmt: "Яндекс Телемост на «%@»",
        .telemostRoomExplainer:      "Ссылка Телемоста перестаёт работать через 24 часа после создания. Кнопка создаёт новую комнату в вашем аккаунте Яндекса и переключает сервер на неё.",
        .telemostRoomNoAccountTitle: "Аккаунт Яндекса не привязан",
        .telemostRoomNoAccountBody:  "Для создания комнаты нужен вход в Яндекс. Войдите под одноразовым аккаунтом — токен хранится в Keychain и отправляется только Яндексу.",
        .telemostRoomSignInAction:   "Войти в Яндекс",
        .telemostRoomIdleTitle:      "Аккаунт Яндекса привязан",
        .telemostRoomIdleBody:       "Одно нажатие создаёт комнату и переводит сервер в неё.",
        .telemostRoomCreateAction:   "Создать комнату и применить",
        .telemostRoomWorkingTitle:   "Выполняется",
        .telemostRoomWorkingCreate:  "Создаём комнату в Телемосте…",
        .telemostRoomWorkingApply:   "Передаём новую комнату на сервер…",
        .telemostRoomDoneTitle:      "Комната заменена",
        .telemostRoomDoneBody:       "Сервер в новой комнате. Её ссылка действует ближайшие 24 часа.",
        .telemostRoomFailedTitle:    "Не удалось завершить",
        .telemostRoomRetryAction:    "Повторить",
        .telemostRoomOtherAccountAction:  "Другой аккаунт",
        .telemostRoomForgetAccountAction: "Забыть этот аккаунт Яндекса",
        .telemostRoomKeychainNote:   "Токен входа хранится только в Keychain этого устройства.",

        // Опасность живой строки. Обновление протокола, через который идёт
        // туннель, перезапускает контейнер, несущий собственный SSH приложения, —
        // команда теряет транспорт на полпути. Говорим это прямо и первым
        // предлагаем безопасный путь, если он на сервере есть.
        .telemostRenewLiveSwitchable_fmt: "Сейчас соединение идёт через этот протокол. Замена комнаты перезапустит его, и соединение оборвётся. Сначала подключитесь через %@ — тогда не оборвётся.",
        .telemostRenewSwitchAction_fmt:   "Сначала подключиться через %@",
        .telemostRenewLiveOnly:      "Сейчас соединение идёт через этот протокол, а других на этом сервере нет. Замена комнаты перезапустит его, и соединение оборвётся посреди команды — приложение сохранит новую комнату и переподключится к ней.",
        .telemostRenewDropped_fmt:   "Соединение оборвалось, пока сервер переходил в комнату %@, — так и должно быть, когда обновляете протокол, через который идёт соединение. Новая комната сохранена, идёт переподключение; запустите «Проверить» в меню протокола, чтобы убедиться, что сервер её принял.",
        .logsContainerPrimary:       "Основной",
        .vpsAdvancedMachineHeader:   "Машина",
        .vpsTitleNothingInstalled:   "Пока ничего не установлено",
        .settingsAdvancedRow:        "Дополнительно",
        .tunnelCompareDisclosure:    "Чем отличаются режимы",
        .settingsBackgroundLabel:    "Работать в фоне",
        .settingsSectionAbout:       "О приложении",
        .settingsSectionConnection:  "Соединение",
        .settingsSectionProxy:       "Прокси",
        .settingsProxyAddressLabel:  "Адрес для других приложений (SOCKS5)",
        .protocolRecreateAction:     "Пересоздать этот протокол",
        .carrierFooterSharedKey:     "Ключ общий с уже установленными протоколами этого сервера · DNS и VP8 берутся из настроек",
        .subImportAlreadySaved_fmt:  "«%@» уже сохранено — ничего не добавлено.",
        .logsScanAmbiguous_fmt:      "На этом сервере %d установок olcOS — сначала выберите нужную на его карточке сервера («Найти установленный olcOS»), потом загрузите снова.",
        .healthLatencyNoResponse:    "нет ответа",
        .sshTunnelLoginTimedOut_fmt: "SSH-вход на %@:%d через туннель не уложился в лимит 10 с — путь через туннель слишком медленный; попробуйте ещё раз или отключите туннель и подключитесь напрямую",
        .dnsInvalidNote:             "Укажите резолвер как IP:port, например 1.1.1.1:53 — значение не сохранится, пока оно не станет корректным",
        .speedTunnelDropped:         "Туннель оборвался во время теста — оставшиеся шаги пропущены",
        .vpsHeadlineProbeFailed:     "Не удалось проверить сервер",
        .protocolStopAction:         "Остановить этот протокол",
        .protocolStartAction:        "Запустить этот протокол",
        .telemostExpiryTitle:        "Комната Телемоста скоро истечёт",
        .telemostExpiryBody_fmt:     "Комната под «%@» перестанет работать примерно через %d мин, и туннель уйдёт вместе с ней. Обновление сейчас оборвёт соединение на несколько секунд.",
        .telemostExpiryRenewAction:  "Обновить сейчас",
        // boc #480
        .telemostRenewalAttentionTitle: "Обновление Телемоста требует внимания",
        .telemostAgeUnknown_fmt:     "Приложение не знает, когда создана комната для «%@». Временная ссылка Телемоста действует 24 часа. Обновите комнату один раз через приложение — дальше olcOS будет продлевать её заранее. При обновлении сервис на сервере перезапустится, и соединение может прерваться.",
        .telemostSetupRequired_fmt:  "Временная ссылка Телемоста действует 24 часа, поэтому комнату для «%@» нужно обновлять ежедневно. Чтобы olcOS делал это сам, откройте связанный сервер в разделе «Мои серверы» и войдите в Яндекс.",
        .telemostCreationFailed_fmt: "Не удалось создать комнату для «%@». Сохранённая комната и её возраст не изменились. Откройте её настройки в разделе «Мои серверы», проверьте вход в Яндекс и повторите попытку.",
        .telemostApplyUnconfirmed_fmt: "Сервер не подтвердил обновление для «%@». Комната на сервере могла измениться, а могла остаться прежней. Сохранённая комната и её возраст не изменились. До явного обновления или изменения сохранённой комнаты автоматические попытки приостановлены. Перед повторной попыткой проверьте или восстановите конфигурацию в разделе «Мои серверы».",
        .telemostApplyCandidate_fmt: "ID новой комнаты, которую пыталось применить приложение: %@. Используйте его только после проверки конфигурации сервера.",
        .telemostForeignVPN_fmt:     "Обновление или переподключение для «%@» отложено: другой системный VPN может замкнуть новые соединения. Проверьте его маршрутизацию или выключите его перед повторной попыткой.",
        .telemostReconnectRequired_fmt: "Сервер подтвердил новую комнату для «%@», и она сохранена. Обновление отменено до переподключения. Подключитесь к этой записи снова из приложения.",
        .telemostSignInSaved:        "Вход в Яндекс сохранён",
        // eoc #480
        // #483
        .vpnStartFromAppOnlyNote:    "Запускайте VPN из приложения. Из настроек iOS VPN запускается, только если включено автоподключение: иначе после отключения данные доступа удаляются.",
        .vpnPacketDNSUnsupported:   "Для VPN нужен IPv4 DNS-сервер на порту 53. Выберите совместимый DNS в настройках. В режиме прокси по-прежнему можно использовать IPv6 DNS.", // #485
        .sshHostKeyFingerprintField: "Отпечатки SSH-ключей сервера",
        .sshHostKeyVerificationAcknowledgement: "Я проверил эти отпечатки через доверенный независимый канал",
        .sshHostKeyVerificationHelp: "Перед первым действием по SSH откройте доверенную консоль сервера у своего хостинг-провайдера и выполните:\nfor key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"$key\" -E sha256; done\nВставьте весь вывод выше и подтвердите проверку. Не получайте отпечатки через непроверенное SSH-соединение или ssh-keyscan. Уже добавленные серверы тоже нужно проверить один раз. После изменения адреса или порта проверьте отпечатки заново.",
        // boc #481
        .sshHostKeyFingerprintInvalid: "Введите корректные SHA256-отпечатки SSH-ключей или вставьте полный вывод ssh-keygen, по одному ключу на строку.",
        .sshHostKeyVerificationRequired: "Некорректный адрес SSH-сервера или сохранённые данные его подлинности. Подключение остановлено. Проверьте адрес и порт сервера.",
        .sshHostKeyMismatch: "SSH-ключ сервера изменился. Подключение заблокировано до аутентификации. Возможно, сервер переустановили или кто-то перехватывает соединение. Подтвердите изменение у хостинг-провайдера, прежде чем доверять новому ключу в разделе «Управление сервером».",
        .sshHostKeyTrustStoreUnavailable: "Не удалось прочитать или сохранить данные подлинности SSH-сервера. Подключение остановлено.",
        .sshHostKeyChangedTitle: "Ключ сервера изменился",
        .sshHostKeyResetAction: "Доверять новому ключу сервера",
        .sshHostKeyResetWarning: "Продолжайте, только если хостинг-провайдер подтвердил изменение ключа. Неожиданная смена ключа может означать перехват соединения. Сохранённый ключ для этого адреса и порта будет забыт, в том числе для других записей с тем же адресом и портом. При следующем SSH-подключении приложение автоматически запомнит полученный ключ. Сейчас подключение не начнётся.",
        .sshHostKeyResetDone: "Сохранённый ключ сервера забыт. Теперь можно повторить действие с сервером. При следующем SSH-подключении приложение автоматически запомнит полученный ключ.",
        // eoc #481
        .later:                      "Позже",
        .addFlowStepAccess: "Доступ",
        .addFlowStepCheck: "Проверка",
        .addFlowStepProtocols: "Протоколы",
        .addFlowStepRoom: "Комната",
        .addFlowStepInstall: "Установка",
        .addFlowStepCounter_fmt: "Шаг %d из %d",
        .addFlowNext: "Далее",
        .addFlowBack: "Назад",
        .addFlowAccessLead: "Адрес сервера и вход",
        .addFlowKeyPasted_fmt: "Ключ вставлен · %@",
        .addFlowKeyReplace: "Заменить ключ",
        .addFlowKeyNotShownNote: "После вставки ключ больше не показывается.",
        .addFlowClipboardEmpty: "Буфер обмена пуст",
        .addFlowLabelMissing: "Введите название",
        .addFlowHostInvalid: "Введите адрес сервера",
        .addFlowPortInvalid: "Порт: от 1 до 65535",
        .addFlowUserMissing: "Введите логин",
        .addFlowPasswordMissing: "Введите пароль",
        .addFlowKeyMissing: "Вставьте приватный ключ",
        .addFlowPassphraseMissing: "Для ключа нужна парольная фраза",
        .addFlowCheckLead: "Подключаемся по SSH и смотрим, что уже есть на сервере.",
        .addFlowCheckRunning: "Подключаемся по SSH…",
        .addFlowCheckOK: "Сервер отвечает",
        .addFlowCheckFailed: "Не удалось подключиться",
        .addFlowTofuFirstTitle: "Первое подключение",
        .addFlowTofuFirstBody: "Ключ SSH сервера будет запомнен сейчас. Если он изменится, приложение заблокирует подключение и предупредит.",
        .addFlowTofuKnownTitle: "Ключ сервера известен",
        .addFlowTofuKnownBody: "Совпадает с сохранённым ранее для этого адреса.",
        .addFlowTofuMismatchTitle: "Ключ сервера изменился",
        .addFlowFactOS: "Система",
        .addFlowFactArch: "Архитектура",
        .addFlowFactRuntime: "Контейнеры",
        .addFlowFactRuntimeNone: "Не найдены — установщик поставит podman",
        .addFlowFactExisting_fmt: "olcOS уже установлен: %@",
        .addFlowFactExistingNone: "olcOS ещё не установлен",
        .addFlowFactUnknown: "Неизвестно",
        .addFlowProtocolsLead: "Выберите сервисы, через которые пойдёт туннель. У каждого будет своё подключение.",
        .addFlowBadgeRecommended: "Рекомендуемый старт",
        .addFlowBadgePrimary: "Основной",
        .addFlowNeedsYandex: "Нужен аккаунт Яндекса",
        .addFlowTransportFor_fmt: "Транспорт для %@",
        .addFlowPickAtLeastOne: "Выберите хотя бы один сервис",
        .addFlowRoomLead: "Каждому сервису нужна комната, к которой подключится сервер.",
        .addFlowYandexSignInBody: "Комната Телемоста создаётся от вашего аккаунта Яндекса и передаётся серверу. Используйте одноразовый аккаунт — токен входа хранится только в Keychain.",
        .addFlowTelemostCreating: "Создаём комнату Телемоста…",
        .addFlowTelemostCreated: "Комната создана",
        .addFlowTelemostCreatedBody: "Сервер будет установлен с этой комнатой. Ссылка действует 24 часа.",
        .addFlowTelemostFailed: "Не удалось создать комнату",
        .addFlowJitsiInstance: "Сервис Jitsi",
        .addFlowJitsiInstanceNote: "Приложение проверяет этот список прямо с вашего сервера и отмечает сервисы, которые там работают.",
        .addFlowJitsiCustom: "Свой адрес",
        .addFlowJitsiRoomName: "Название комнаты",
        .addFlowJitsiRoomHint: "Название комнаты (латиница и цифры) или полная ссылка. Пусто — сервер придумает название.",
        .addFlowRoomMissing_fmt: "Укажите комнату для %@",
        .addFlowInstallLead: "Проверьте сводку и запускайте. Сервер собирает olcOS сам — держите olcOS открытым, это займёт около 5–15 минут.",
        .addFlowSummaryServer: "Сервер",
        .addFlowSummaryProtocols: "Протоколы",
        .addFlowInstallRunning: "Устанавливаем…",
        .addFlowInstallDone: "Сервер готов",
        .addFlowInstallFailed: "Установка не удалась",
        .addFlowInstallFailedHint: "Подробности — в «Логах» на странице сервера. Сервер остаётся в списке — установку можно повторить оттуда.",
        .addFlowResultConnections: "Подключения",
        .addFlowResultPending: "Подключения появятся на вкладке «Подключения».",
        .installOptionsLead: "Добавьте протокол на этот сервер. Ключ шифрования общий с уже установленными.",
        .throughputA11y_fmt: "Загрузка %@, отдача %@",
        .throughputEstimateA11y_fmt: "Около %@ через локальный SOCKS5-порт — оценка по трафику loopback, без разделения на приём и отдачу",
        .carrierJitsiDesc: "Публичные серверы Jitsi, аккаунт не нужен. Рекомендуется VP8; DataChannel и другие видеотранспорты тоже работают. Название комнаты или полная ссылка.",
        .carrierTelemostDesc: "Нужен аккаунт Яндекса; olcOS сам обновляет комнату каждые 24 часа.",
        .transportDatachannelDesc: "Данные идут по собственному каналу данных сервиса. Единственный транспорт SaluteJazz; на Jitsi в наших тестах медленнее VP8.",
        .transportVp8channelDesc: "Данные упакованы в видеопоток VP8, и сервис видит обычный видеозвонок. Самый быстрый в наших тестах (около 9 Мбит/с на Jitsi); кадры и пакеты настраиваются в Настройках.",
        .transportSeichannelDesc: "Данные спрятаны в служебных блоках видеопотока (H.264 SEI), с подтверждениями. Запасной вариант, медленнее.",
        .transportVideochannelDesc: "Данные рисуются кадрами-картинками (QR-коды) в видеопотоке. Самый медленный запасной вариант; в режиме VPN недоступен.",
        .settingsCarrierEndpointsEmpty: "Сначала добавьте подключение — адреса берутся из его комнаты.",
        .settingsConnectionSummary_fmt: "Старт %d с · проверка каждые %d с",
        .settingsDiagnosticsSummary_fmt: "%@ · источников IP: %d",
        .settingsConnectionsCount_fmt: "Подключений: %d",
        .protocolAboutAction: "О протоколе",
        .protocolAboutHide: "Скрыть описание",
        .shareServerTitle_fmt: "Поделиться: %@",
        .shareServerProtocolsHeader: "Подключение по протоколу",
        .shareServerNoProtocols: "На этом сервере пока нет подключений.",
        .sshKeyStored_fmt: "Ключ %@ сохранён в Keychain",
        .sshKeyReplaceAction: "Заменить ключ",
        .actionUpdateSub: "Обновляет ядро olcOS на VPS. Само приложение обновляется в Настройках.",
        .vpsAdvancedOverviewHeader: "Обзор",
        .vpsAdvancedActionsHeader: "Действия",
        .vpsAdvancedRecoverSub: "Восстановить запись подключения для установленного контейнера.",
        .healthActionSharedRecordNote: "Это подключение получено с другого устройства: ключ и комнату обновляет владелец сервера. Попросите у него новую ссылку или QR-код.",
        .deviceNameSectionHeader: "Это устройство",
        .deviceNameLabel: "Имя в комнате",
        .deviceNameRegenerate: "Новое имя",
        .deviceNameFooter: "Два случайных слова и число, сгенерированные на этом устройстве. При подключении оно подставляется вместо «default», поэтому одна общая ссылка работает на нескольких устройствах одновременно. Ничего о телефоне или о вас в имени нет. Новое имя применяется со следующего подключения.",
        .fieldRevealSecret: "Показать",
        .fieldHideSecret: "Скрыть",
        .roomIDPlaceholder: "Вставьте ID комнаты",
        .roomIDLinkHint: "Можно вставить ссылку на встречу Телемоста — она сократится до ID.",
        .formAccessSectionHeader: "Доступ",
        .healthChipNotChecked: "Не проверено",
        .healthChipNoData: "Нет данных",
        .shareRecipientHint: "Эту ссылку понимает только olcOS. Получатель ставит olcOS, открывает «Подключения» → + → «Вставить из буфера обмена» или сканирует ваш QR-код.",
        .connectingXray_fmt: "→ VLESS · REALITY %@:%d sni=%@",
        .xrayLocalSocksAuthIgnored: "Локальная аутентификация SOCKS не применяется к подключениям VLESS · REALITY; слушатель принимает клиентов на этом устройстве без пароля.",
        .xrayUriUnsupported_fmt: "Эта ссылка vless:// использует %@ — olcOS это не поддерживает (только REALITY поверх TCP).",
        .validateXrayHostEmpty: "Адрес сервера пуст.",
        .validateXrayUUIDEmpty: "UUID клиента пуст — запись в Keychain может отсутствовать; импортируйте ссылку заново.",
        .validateXrayPublicKeyEmpty: "Отсутствует публичный ключ REALITY (pbk).",
        .validateXraySNIEmpty: "Отсутствует имя сервера REALITY (sni).",
        .validateXrayPortRange: "Порт должен быть в диапазоне 1–65535.",
        .xrayFieldServer: "Сервер",
        .xrayFieldSNI: "Имя сервера REALITY (SNI)",
        .xrayFieldFlow: "Flow",
        .xrayFieldFingerprint: "Отпечаток TLS",
        .xrayFieldShortID: "Short ID",
        .xrayEditorFooter: "Подключение VLESS · REALITY полностью задаётся ссылкой vless://. Чтобы сменить сервер, вставьте новую ссылку; UUID клиента хранится в Keychain и не отображается.",
        .addFlowCallsSection: "Через видеозвонок",
        .addFlowDirectSection: "Прямое подключение",
        .xrayServiceName: "Xray",
        .xrayProtocolTitle: "Xray · VLESS Reality",
        .xrayProtocolDesc: "Быстрое прямое подключение, похожее на заход на обычный сайт. Сервер должен быть доступен напрямую, поэтому при белых списках мобильной связи не поможет.",
        .addFlowBadgeFast: "Быстрый",
        .xrayAdvancedTitle: "Дополнительно",
        .xrayTargetField: "Сайт для маскировки",
        .xrayTargetPlaceholder: "Автоматически",
        .xrayTargetHint: "Настоящий зарубежный сайт, под который маскируется сервер. Оставьте пустым — сервер сам выберет подходящий.",
        .xrayTargetInvalid: "Введите доменное имя, например www.example.com",
        .xrayPortField: "Порт",
        .xrayPortHint: "443 больше всего похож на обычный HTTPS, другие порты проще заблокировать.",
        .provisioningXrayInstalling: "Устанавливаю Xray…",
        .xrayInstallSuccess: "Xray установлен",
        .xrayInstallAdopted: "На сервере уже работал Xray — его подключение добавлено",
        .xrayInstallFailed_fmt: "Не удалось установить Xray: %@",
        .provisioningXrayRemoving: "Удаляю Xray…",
        .xrayRemoved: "Xray удалён с сервера",
        .xrayInstallAction: "Установить Xray",
        .xrayRemoveAction: "Удалить Xray",
        .xrayRemoveConfirmTitle: "Удалить Xray с сервера?",
        .xrayRemoveConfirmBody: "Остановит Xray и удалит его ключи. Ссылка перестанет работать, а подключение пропадёт из приложения.",
        .addProtocolChooserTitle: "Добавить протокол",
        .addProtocolCallOption: "Через видеозвонок…",
        .healthBestChoice: "Лучший выбор",
        .widgetDescription: "Включайте и выключайте туннель и смотрите, работает ли он.",
        .controlDescription: "Включает и выключает туннель olcOS.",
        .widgetStateFailed: "Не подключилось",
        .widgetStateUnknown: "Состояние неизвестно",
        .widgetHintToggle: "Нажмите, чтобы включить или выключить",
        .widgetHintOpenApp: "Откройте приложение, чтобы проверить",
        .widgetHintNoConnection: "Добавьте подключение в приложении",
        .widgetActionOn: "Включить",
        .widgetActionOff: "Выключить",
        .widgetActionToggle: "Вкл / Выкл",
        .telegramProxyAction: "В Telegram",
        .telegramProxyHint: "Откроет Telegram и предложит включить этот прокси SOCKS5",
        .tunnelStalls: "Связь есть, но данные замирают после первых килобайт — похоже, сеть душит прямые подключения. Попробуйте протокол через видеозвонок.",
        .tunnelModeAutomaticShort: "Авто",
        .healthReasonServerOutdatedShort: "Старое ядро на сервере",
        .healthReasonServerOutdated: "На сервере старая версия ядра туннеля, приложение с ней не договорится. Обновите сервер: откройте сервер → «Управление сервером» → «Обновить серверную часть olcOS».",
        .addFlowJitsiChecking: "Проверяем серверы Jitsi с вашего VPS…",
        .addFlowJitsiCheckingBody: "Сервер должен достучаться до Jitsi и войти как гость. Это займёт секунд десять.",
        .addFlowJitsiPicked_fmt: "Выбран %@",
        .addFlowJitsiPickedBody: "Ваш сервер до него достаёт, и гостей он пускает. Ниже можно выбрать другой.",
        .addFlowJitsiNoneWorking: "С вашего VPS не работает ни один сервер из списка",
        .addFlowJitsiNoneWorkingBody: "Укажите сервер Jitsi, который точно работает, или проверьте позже.",
        .addFlowJitsiCheckFailed: "Не удалось проверить серверы Jitsi",
        .addFlowJitsiRecheck: "Проверить снова",
        .addFlowJitsiNoCurl: "На сервере нет curl — проверить серверы Jitsi не получится.",
        .licensesTitle: "Лицензии открытого ПО",
        .licensesCoreNotice: "Ядро туннеля — NOTICE",
        .licensesCoreLicense: "Ядро туннеля — лицензия",
        .licensesUpstream: "Исходный проект — лицензия",
        .licensesGoModules: "Модули Go",
        .licensesSwiftPackages: "Пакеты Swift",
        .licensesFooter: "Всё, что olcOS берёт из других проектов, — с их лицензиями и уведомлениями.",
        .inviteErrorInvalidLink: "Ссылка-приглашение повреждена.",
        .inviteErrorMissingKey: "В ссылке нет ключа — нужна ссылка целиком.",
        .inviteErrorNotAnInvite: "Сервер ответил не списком подключений.",
        .inviteErrorWrongKey: "Список не открывается ключом из этой ссылки.",
        .inviteErrorRevoked: "Приглашение отозвано или его больше нет на сервере.",
        .inviteErrorUnreachable: "Сервер не ответил. Если сеть пускает только на сайты из белого списка, попробуйте снова через Wi-Fi.",
        .inviteErrorUnreachableDetail_fmt: "Сервер не ответил (%@).",
        .inviteErrorServer_fmt: "Сервер не смог выложить приглашение: %@",
        .inviteErrorNothingToShare: "У этого сервера пока нет сохранённого подключения, которым можно поделиться.",
        .inviteErrorNoCredentials: "Для этого сервера не сохранён вход по SSH.",
        .invitesTitle: "Устройства",
        .invitesExplanation: "Отдайте другому телефону или планшету подключения этого сервера одной ссылкой. Когда здесь что-то меняется — новая комната Телемоста, новый ключ, добавленный протокол, — устройство получает это само. С доступом к серверу это устройство управляет сервером из своего приложения, как это; без доступа оно только подключается.",
        .invitesCreateAction: "Пригласить устройство",
        .invitesListHeader: "Приглашены",
        .invitesRevokeFooter: "Отзыв останавливает обновления. Чтобы закрыть доступ полностью, смените ещё и ключ сервера — остальные устройства получат новый сами.",
        .invitesRevokeAction: "Отозвать",
        .invitesRevokeTitle: "Отозвать приглашение?",
        .invitesRevokeMessage: "Устройство перестанет получать обновления. Уже полученные подключения будут работать, пока вы не смените ключ сервера.",
        .invitesFailureHeader: "Не удалось обновить",
        .invitesRetryAction: "Повторить",
        .invitesUnnamed: "Устройство",
        .invitesStatusUploading: "Отправляю на сервер…",
        .invitesStatusNotUploaded: "Ещё не на сервере",
        .invitesStatusUpdated_fmt: "Обновлено %@",
        .invitesNameField: "Название",
        .invitesNamePlaceholder: "например, iPad",
        .invitesCreateFooter: "Название нужно только для этого списка. На сервер уходит зашифрованный список, а ключ к нему есть только в ссылке.",
        .invitesCreateTitle: "Пригласить устройство",
        .invitesCreateConfirm: "Создать ссылку",
        .invitesLinkExplanation: "На другом устройстве скопируйте ссылку и вставьте её в olcOS или отсканируйте QR-код из olcOS. olcOS добавит подключения и будет сам их обновлять.",
        .invitesLinkSecretNote: "Кто получит ссылку, сможет пользоваться сервером. Отправляйте её только на свои устройства или тем, кому доверяете.",
        .invitesLinkUnavailable: "Этого приглашения ещё нет на сервере. Повторите, когда сервер будет доступен.",
        .invitesRowSubtitle: "Самообновляемая ссылка для другого телефона",
        .invitesRowCount_fmt: "Приглашено: %d",
        .invitesCopyLink: "Скопировать ссылку",
        .carrierVkcalls: "VK Звонки",
        .carrierSalutejazz: "SaluteJazz",
        .carrierMtslink: "МТС Линк",
        .carrierVkcallsDesc: "Видеотранспорт (VP8), около 13–19 Мбит/с. Комната — ссылка на звонок VK: приложение создаст её после входа в VK, или вставьте ссылку из приложения VK.",
        .carrierSalutejazzDesc: "Транспорт данных (DataChannel), аккаунт не нужен. Комнату создаёт приложение.",
        .carrierMtslinkDesc: "Только видеотранспорт (VP8, передаётся как VP9), около 15 Мбит/с. Комната — постоянная встреча: один раз покажите приложению в окне входа, как её создать, — дальше комнаты создаёт одна кнопка. Бесплатный тариф допускает две постоянные встречи.",
        .addFlowNeedsVKLink: "Вход в VK или ссылка",
        .addFlowNeedsMtsLink: "Вход в «МТС Линк» или ссылка",
        .addFlowNoAccount: "Без аккаунта",
        .addFlowRoomInvalid_fmt: "Комната для %@ указана в неверном формате",
        .addFlowVKBody: "Войдите в VK — приложение само создаст звонок. Или вставьте ссылку из приложения VK. Не завершайте звонок для всех: сервер остаётся в нём.",
        .vkCallLinkField: "Ссылка на звонок",
        .vkCallLinkRecognized: "Распознана ссылка",
        .mtsLinkField: "Ссылка на встречу",
        .addFlowSaluteCreating: "Создаём комнату SaluteJazz…",
        .addFlowSaluteCreated: "Комната создана",
        .addFlowSaluteFailed: "Не удалось создать комнату",
        .addFlowSaluteBody: "Аккаунт не нужен. Комнату создаёт приложение; можно вписать свою в виде код:пароль.",
        .saluteCreateRoomAction: "Создать комнату",
        .roomIDVkHint: "Ссылка на звонок VK. Кнопка «Создать звонок VK» создаст её после входа в VK; подойдёт и ссылка из приложения VK. Не завершайте звонок для всех — сервер остаётся в нём.",
        .roomIDSaluteHint: "Код и пароль комнаты через двоеточие, например abcd12:efgh3456. Комнату создаёт приложение — нажмите «Создать комнату».",
        .roomIDMtslinkHint: "Ссылка на постоянную встречу «МТС Линк», как в кабинете: https://my.mts-link.ru/j/… Сервер заходит гостем. По умолчанию телефон подключается по TCP; для UDP добавьте в конец ссылки ?ice=udp.",
        .saluteJazzErrNetwork: "Сбер не ответил. Проверьте интернет и попробуйте ещё раз.",
        .saluteJazzErrStatus_fmt: "SaluteJazz отказал (HTTP %d). Попробуйте позже.",
        .saluteJazzErrMalformed: "SaluteJazz ответил не так, как ожидалось.",
        .welcomeTitle: "С чего начнём?",
        .welcomeLead: "Трафик olcOS идёт через сервер. Выберите, что у вас есть:",
        .welcomeImportTitle: "Ссылка, QR-код или файл",
        .welcomeImportBody: "Вам прислали подключение, подписку или приглашение. Свой сервер не нужен.",
        .welcomeScanAction: "QR-код",
        .welcomeFileAction: "Файл",
        .welcomeServerTitle: "Свой сервер (VPS)",
        .welcomeServerBody: "Есть адрес сервера и пароль? olcOS сам всё установит.",
        .welcomeServerAction: "Подключить сервер",
        .welcomeNeitherTitle: "Нет ни того, ни другого",
        .welcomeNeitherBody: "Возьмите готовую подборку бесплатных серверов или узнайте, где взять приглашение или сервер.",
        .welcomeNeitherAction: "Что делать",
        .welcomeManualAction: "Ввести подключение вручную",
        .welcomeFileUnreadable: "Это не текстовый файл со ссылками.",
        .welcomeImportUnrecognized: "Здесь не найдено ни подключения, ни подписки, ни приглашения.",
        .noServerInviteTitle: "Попросите приглашение",
        .noServerInviteBody: "Если у друга или родственника есть сервер в olcOS, он может прислать приглашение: «Мои серверы» → «Поделиться» → «Пригласить устройство». Откройте ссылку — и всё.",
        .noServerRentTitle: "Или арендуйте VPS",
        .noServerRentBody: "Подойдёт любой зарубежный сервер на Linux (Ubuntu или Debian) с 1 ГБ памяти. Хостер даст адрес и пароль root: нажмите «Подключить сервер», остальное olcOS сделает сам.",
        .accountsTitle: "Аккаунты сервисов",
        .accountSignedIn:            "Вход выполнен",
        .accountSignedOut:           "Вход не выполнен",
        .accountsYandexBody: "Аккаунт Яндекса нужен, чтобы приложение само создавало и продлевало комнаты Телемоста. Лучше отдельный аккаунт; вход хранится только в Keychain.",
        .accountsSignOutAction: "Выйти из Яндекса",
        .accountsSignOutTitle: "Выйти из аккаунта Яндекса?",
        .accountsSignOutMessage: "Новые комнаты Телемоста и их продление перестанут работать, пока не войдёте снова. Текущие подключения не пострадают.",
        .accountsVKBody: "Сервер заходит в звонок VK как гость. Войдите один раз — приложение будет создавать звонки вашим аккаунтом, или вставьте ссылку из приложения VK.",
        .accountsSaluteBody: "Аккаунт не нужен. Комнату создаёт приложение одним анонимным запросом.",
        .accountsJitsiBody: "Публичные серверы Jitsi, аккаунт не нужен, вход гостем. Название комнаты или полная ссылка.",
        .accountsOthersHeader: "Без аккаунта",
        .lanesStarting_fmt: "Подключаюсь сразу к %d комнатам…",
        .lanesRoomCount_fmt: "Комнат: %d",
        .laneAddAction: "Добавить комнату",
        .laneRemoveAction: "Убрать",
        .laneAddTitle: "Ещё одна комната",
        .pasteAction: "Вставить",
        .saluteAnotherRoomAction: "Другая комната",
        .laneTelemostSignIn: "Вход в Яндекс устарел. Войдите снова и повторите.",
        .bundleServiceName: "Весь сервер",
        .bundleLanes_fmt: "%@ · комнат: %d",
        .bondErrorServer_fmt: "Склейка на сервере: %@",
        .bundleCardDesc: "Все комнаты сервера сразу: одна загрузка идёт через все, а если комната отвалится, остальные продолжат.",
        .bundleBonded: "вместе",
        .bundleBondPending: "настройка",
        .bundleBondOff: "по очереди",
        .bundleBondFailed_fmt: "Склейка не включилась: %@",
        .bundleRooms_fmt: "комнат: %d",
        .bundleVPNOneLane: "Склейка комнат в режиме VPN выключена в настройках: работает одна комната.",
        .jitsiCheckSectionHeader: "Сервис Jitsi",
        .jitsiCheckWorks_fmt: "Работает · %@",
        .jitsiCheckStalls: "Подключается, но передача обрывается",
        .jitsiCheckNoData: "Пускает ваш сервер, но данные не проходят",
        .jitsiCheckUnreachable: "Не отвечает вашему серверу",
        .jitsiCheckNeedsLogin: "Требует вход в аккаунт",
        .jitsiCheckAnswers: "Отвечает; передачу данных проверить не удалось",
        .jitsiCheckRunning: "Проверяем…",
        .jitsiCheckAgain: "Проверить снова",
        .jitsiCheckNote: "Ваш сервер пробует каждый сервис настоящим подключением. Это около минуты; ваши подключения продолжают работать.",
        .jitsiCheckPickedFastest_fmt: "Выбран %@ — самый быстрый из работающих",
        .jitsiCheckNoneWorks: "Ни один сервис не пропустил данные с вашего сервера. Попробуйте позже или укажите свой адрес.",
        .jitsiCheckFailed_fmt: "Не удалось проверить: %@",
        .jitsiCustomHelper: "Адрес другого сервиса Jitsi Meet, если вы знаете рабочий.",
        .tabHome: "Главная",
        .heroChooseOther: "Выбрать другой сервер",
        .listBundleSubtitle_fmt: "Все сервисы сервера %@",
        .listDirectSubtitle: "Напрямую, без видеозвонка",
        .addMenuTitle: "Добавить",
        .addMenuPaste: "Вставить из буфера обмена",
        .addMenuScan: "Сканировать QR-код",
        .addMenuFile: "Открыть файл",
        .addMenuLink: "Ссылка или подписка",
        .addMenuManual: "Ввести вручную",
        .addMenuOwnServer: "Свой сервер (VPS)",
        .addLinkField: "Ссылка",
        .addLinkPlaceholder: "https://… или vless://…",
        .addLinkHelper: "Адрес подписки, приглашение или ссылка на подключение.",
        .addLinkAction: "Добавить",
        .listEmpty: "Подключений пока нет. Нажмите +, чтобы добавить ссылку, QR-код, файл или подписку.",
        .listAutoSwitch: "Переключаться, если перестало работать",
        .listAutoSwitchDetail: "Если подключение перестанет работать, приложение само перейдёт на другое работающее. Подключение ко всему серверу и так продолжает работать, когда отваливается одна из его комнат; этот переключатель — на случай, если перестал работать весь сервер.",
        .listOwnServerEmpty: "С этого сервера пока нет подключений. Откройте сервер, чтобы установить.",
        .listMyServersNone: "olcOS сам установит на ваш сервер всё, что нужно.",
        .listRowConnected: "Подключено",
        .listRowVerifyHint: "Проверяет это подключение заново",
        .listWordNotWorking: "Не работает",
        .listSectionSubscriptions: "Подписки",
        .listSubscriptionServers_fmt: "Серверов: %d",
        .listSubscriptionUsed_fmt: "Использовано: %@",
        .listSubscriptionAvailable_fmt: "Осталось: %@",
        .listSubscriptionUnnamed: "Подписка",
        .vpsHeadlineProtocolsWorking_fmt: "Работают: %d из %d",
        .protocolsNotResponding_fmt: "Не отвечает: %@",
        .protocolStopped: "Остановлен",
        .roomsStoppedOne_fmt: "Комната остановлена: %@",
        .roomsStoppedMany_fmt: "Комнаты остановлены: %@",
        .addMenuCurated: "Готовые подборки",
        .curatedLead: "Бесплатные серверы, которые обновляют другие люди. Приложение добавит список как подписку, будет обновлять его каждый час и проверять серверы в нём. Скорость и стабильная работа не гарантируются.",
        .curatedWhiteMobileTitle: "Белые списки для мобильного интернета",
        .curatedWhiteMobileDetail: "Когда мобильная сеть пускает только на разрешённые российские сайты. Серверы прячутся за адресами таких сайтов.",
        .curatedWhiteCheckedTitle: "Белые списки: только проверенные адреса",
        .curatedWhiteCheckedDetail: "Меньше серверов, зато за адресами VK, Яндекса и других крупных сервисов, которые белые списки не закрывают.",
        .curatedBlackTitle: "Обычный интернет",
        .curatedBlackDetail: "Для Wi-Fi и мобильного интернета без белых списков, где заблокированы только отдельные сайты.",
        .curatedAddAction: "Добавить список",
        .curatedSourceNote_fmt: "Списки ведёт igareck: %@. olcOS только читает их.",
        .searchFastest: "Найти самый быстрый и подключиться",
        .searchStop: "Остановить поиск",
        .searchKnocking_fmt: "Проверяем, какие из %d серверов отвечают…",
        .searchChecking_fmt: "Пробуем самые быстрые: %d из %d…",
        .searchNoneFound: "Ни один сервер не заработал. Попробуйте позже или добавьте другой список.",
        .listViaCallSubtitle: "Через видеозвонок",
        .diagnosticsRowSubtitle: "IP-адрес и скорость",
        .welcomeFreeServersAction: "Бесплатные серверы",
        .coreStaleTitle_fmt: "Нужно обновить сервер: %@",
        .coreStaleBody: "На нём старая версия ядра, и подключения через него обрываются. Откройте «Мои серверы» — обновление начнётся само.",
        .listOwnServerHeader_fmt: "Мой сервер · %@",
        .listSectionOwnLinks: "Свои ссылки",
        .listSectionOwnLinksFooter: "То, что вы добавили сами: ссылки, QR-коды и файлы.",
        .listAddOwnSubscription: "Добавить свою подписку",
        .listSubscriptionServersWorking_fmt: "Серверов: %d · работают: %d",
        .listSubscriptionOff: "Выключена",
        .subUpdatedToday_fmt: "Обновлено сегодня в %@",
        .subUpdatedYesterday_fmt: "Обновлено вчера в %@",
        .subUpdatedOn_fmt: "Обновлено %@ в %@",
        .subAutoRefresh_fmt: "Обновляется сама раз в %@",
        .subFrom_fmt: "Источник: %@",
        .subEnabled: "Подписка включена",
        .subEnabledFooter: "Выключенная подписка не обновляется и не выбирается автоматически; сервер из неё можно выбрать вручную.",
        .subRefreshNow: "Обновить сейчас",
        .subRefreshing: "Обновляется…",
        .subRefreshFailed: "Не удалось обновить список. Проверьте интернет и попробуйте ещё раз — сохранённые серверы остались.",
        .subServersHeader: "Серверы",
        .subNoServers: "В списке пока нет серверов. Обновите его, чтобы загрузить.",
        .subOffNote: "Подписка выключена: эти серверы используются, только если нажать на них самому.",
        .subRenameAction: "Переименовать",
        .subRenameTitle: "Название подписки",
        .subRenamePlaceholder: "Название",
        .subRenameHint: "Оставьте пустым, чтобы вернуть название из самого списка.",
        .subDeleteTitle: "Удалить подписку?",
        .subDeleteAction: "Удалить подписку",
        .subDeleteMessage_fmt: "Её серверы (%d) будут удалены из приложения. Список можно добавить снова по ссылке.",
        .throughputKbit_fmt: "%@ Кбит/с",
        .throughputMbit_fmt: "%@ Мбит/с",
        .laneUnnamed_fmt: "Комната %d",
        .lanesPanelTitle: "Скорость по протоколам",
        .lanesPanelTotal: "Всего",
        .laneRowA11y_fmt: "%@: загрузка %@, отдача %@",
        .protoCheckTitle: "Скорость каждой комнаты",
        .protoCheckLead: "Каждая комната замеряется отдельно, потом все вместе: видно, какая быстрее и сколько даёт их объединение.",
        .protoCheckRunAll: "Проверить все",
        .protoCheckStop: "Остановить",
        .protoCheckRunOne: "Проверить",
        .protoCheckAllTogether: "Все вместе",
        .protoCheckWaiting: "В очереди",
        .protoCheckMeasuring: "Замеряем…",
        .protoCheckFailed: "Эта комната сейчас не отвечает",
        .protoCheckFastest: "Самый быстрый",
        .protoCheckPing_fmt: "%d мс",
        .protoCheckGain_fmt: "Вместе: ×%@ к самому быстрому по отдельности",
        .settingsSectionWidgets: "Виджеты",
        .liveActivityToggle: "Показывать подключение и скорость",
        .liveActivityNote: "Пока olcOS подключён, карточка показывает сервер и скорость. Выключите — и она сразу исчезнет. Если смахнуть её с экрана блокировки, она не появится до следующего подключения.",
        .throughputShortKbit_fmt: "%@К",
        .throughputShortMbit_fmt: "%@М",
        .routingTitle: "Маршрутизация",
        .routingListDirect: "Сайты из списка — напрямую",
        .routingAllTunnelFooter: "Все сайты и приложения идут через туннель.",
        .routingListDirectFooter: "Сайты из списка открываются напрямую с телефона, остальные — через туннель: банки, Госуслуги и другие российские сайты работают как обычно и не тратят туннель.",
        .routingRussianList: "Российские сайты",
        .routingRussianListDetail_fmt: "Зоны .ru, .рф, .su и сайты Яндекса, VK, 2ГИС, Wildberries и Avito на других доменах — записей: %d.",
        .routingOwnHeader: "Свои сайты и адреса",
        .routingOwnFooter: "По одному на строке: сайт (example.com — вместе со всеми поддоменами), ссылка, IP-адрес или подсеть (10.0.0.0/8).",
        .routingBadLine_fmt: "Строка %d — не сайт и не адрес, она пропускается.",
        .routingAppliesNext: "Изменения вступят в силу при следующем подключении.",
        .routingReconnect: "Переподключиться сейчас",
        .autoConnectTitle: "Автоподключение VPN",
        .autoConnectOn: "Включено",
        .autoConnectOff: "Выключено",
        .autoConnectCellular: "На мобильном интернете",
        .autoConnectLead: "iOS сама включит VPN, когда телефон подключится к выбранной здесь сети, — даже если приложение закрыто.",
        .autoConnectWiFiHeader: "Wi-Fi",
        .autoConnectWiFiOff: "Не включать",
        .autoConnectWiFiAny: "В любой сети",
        .autoConnectWiFiOnly: "Только в этих сетях",
        .autoConnectWiFiExcept: "Везде, кроме этих (доверенных)",
        .autoConnectOnlyHeader: "Включать в этих сетях",
        .autoConnectExceptHeader: "Доверенные сети: выключать",
        .autoConnectNetworkPlaceholder: "Название сети",
        .autoConnectAddNetwork: "Добавить",
        .autoConnectNoNetworks: "Добавьте хотя бы одну сеть — иначе Wi-Fi не будет включать VPN.",
        .autoConnectKeyNote: "Работает только в режиме VPN и применяется при следующем включении VPN. Чтобы iOS могла подключиться без приложения, ключ подключения хранится в системных настройках VPN, пока автоподключение включено. Если выключить VPN вручную, автоподключение приостановится до следующего включения.",
        .autoConnectNeedsVPN: "Эта установка не может включать VPN (подписана бесплатным Apple ID). Автоподключение заработает, когда приложение будет подписано платным аккаунтом разработчика.",
        .vpnBondingToggle: "Склейка комнат в режиме VPN",
        .vpnBondingNote: "Подключение «Весь сервер» склеивает до трёх своих комнат и в режиме VPN — скорость выше. Каждая комната — отдельный видеозвонок, а iOS даёт VPN около 50 МБ памяти: если VPN начнёт отключаться, выключите это.",
        .laneRejoining_fmt: "Комната %d (%@) отключилась — подключаю её снова",
        .laneRejoinFailed_fmt: "Комнату %d (%@) пока не удалось подключить — скоро попробую ещё",
        .listOpenServer: "Открыть сервер",
        .listOpenServerDetail: "Комнаты, ускорение, журнал, обновление",
        .listAddOwnServer: "Подключить свой сервер",
        .listBundleRooms_fmt: "Комнат: %d",
        .addRoomTitle: "Добавить сервис или комнату",
        .addRoomLead: "Каждая комната — это ещё один звонок, в котором сидит ваш сервер. Подключение ко всему серверу идёт сразу через все комнаты, поэтому каждая новая добавляет скорость.",
        .addRoomLimit_fmt: "В каждом сервисе — до %d комнат.",
        .addRoomNotYet: "Пока нет на сервере",
        .addRoomCount_fmt: "Комнат: %d",
        .addRoomFull_fmt: "Комнат: %d — это максимум",
        .addRoomNeedNothing: "добавится сразу",
        .addRoomNeedYandex: "нужен вход в Яндекс",
        .addRoomNeedLink: "нужен вход в VK или ссылка на звонок",
        .addRoomAction: "Добавить",
        .addRoomSignIn: "Войти",
        .addRoomPasteLink: "Вставить",
        .addRoomVKTitle: "Ссылка на звонок VK",
        .addRoomVKHowTo: "В приложении VK откройте «Звонки», нажмите «Создать звонок» и скопируйте ссылку — затем вставьте её сюда. Ваш сервер будет сидеть в этом звонке.",
        .protoCheckReconnecting: "Комната переподключается — проверьте через минуту",
        .clockToday_fmt: "в %@",
        .clockYesterday_fmt: "вчера в %@",
        .clockOn_fmt: "%@ в %@",
        .liveRejoinNewRooms: "Новая комната готова — переподключаемся, чтобы задействовать её",
        .widgetsRowOn: "Карточка на экране блокировки: включена",
        .widgetsRowOff: "Карточка на экране блокировки: выключена",
        .widgetsLiveHeader: "Экран блокировки и Dynamic Island",
        .widgetsHomeHeader: "Виджеты на экранах «Домой» и блокировки",
        .widgetsHomeHowTo: "Убрать: удерживайте виджет olcOS и нажмите «Удалить виджет». Добавить: удерживайте пустое место на экране, нажмите «Изменить» → «Добавить виджет» и выберите olcOS.",
        .widgetsControlHeader: "Кнопка в Пункте управления",
        .widgetsControlHowTo: "Откройте Пункт управления, удерживайте пустое место и нажмите «−» на кнопке olcOS, чтобы убрать её, или «Добавить элемент», чтобы вернуть.",
        .widgetsOpenSystemSettings: "Открыть настройки iOS для olcOS",
        .widgetsSystemNote: "Там же можно совсем запретить olcOS «Живые активности».",
        .laneJoiningShort: "подключается…",
        .subRefreshFailedShort: "Не удалось обновить — сохранённые серверы остались",
        .agentKeyErrorKeychain: "Не удалось сохранить ключ устройства в связке ключей.",
        .agentKeyErrorCorrupt: "Сохранённый ключ устройства не читается.",
        .agentErrorUnreachable: "Агент сервера не ответил.",
        .agentErrorHTTP_fmt: "Агент сервера вернул ошибку (%d).",
        .agentErrorDecode: "Не удалось прочитать ответ агента сервера.",
        .agentInstallError_fmt: "Не удалось настроить управление сервером: %@",
        .serverControlLabel: "Связь с сервером",
        .serverControlAuto: "Автоматически",
        .serverControlHTTPSTunnel: "HTTPS через туннель",
        .serverControlHTTPSDirect: "HTTPS напрямую",
        .serverControlSSH: "SSH",
        .serverControlAutoHint: "Сначала HTTPS: через туннель, если он идёт через этот сервер, иначе напрямую. Если HTTPS не отвечает, приложение работает по SSH.",
        .serverControlHTTPSTunnelHint: "Состояние сервера, запуск и остановка комнат — только по HTTPS через работающий туннель. Если агент не ответит, вы увидите ошибку, а не переход на SSH. Установка, добавление комнат и обновления по-прежнему идут по SSH.",
        .serverControlHTTPSDirectHint: "Состояние сервера, запуск и остановка комнат — только по HTTPS, напрямую на адрес сервера. Если агент не ответит, вы увидите ошибку, а не переход на SSH. Установка, добавление комнат и обновления по-прежнему идут по SSH.",
        .serverControlSSHHint: "Всё по SSH. HTTPS-агент не используется и не устанавливается.",
        .agentErrorPin: "Сертификат агента сервера не совпадает с сохранённым.",
        .agentErrorNoTunnel: "Туннель не запущен. Сначала подключитесь или выберите другой способ связи с сервером в настройках.",
        .protocolOpenAction: "Комнаты и настройки",
        .protocolGone: "Этого протокола на сервере больше нет.",
        .protocolRoomsHeader: "Комнаты",
        .protocolMainRoom: "Основная комната",
        .protocolExtraRoom_fmt: "Комната %d",
        .protocolChangeRoom: "Сменить",
        .protocolNewRoomAuto: "Новая комната — создать автоматически",
        .protocolTypeRoom: "Ввести комнату вручную",
        .protocolAddRoom: "Добавить комнату",
        .protocolRoomsFooterAuto: "Новые комнаты приложение создаёт само. Каждая комната добавляет скорость, когда вы подключены ко всему серверу.",
        .protocolRoomsFooterManual: "Комнату этого сервиса даёте вы: вставьте ссылку или ID.",
        .protocolSetupHeader: "Настройка",
        .protocolSettingsAction: "Транспорт и настройки сервиса",
        .coreVersionCurrent_fmt: "На сервере: %@ — актуальная версия.",
        .coreVersionOld_fmt: "На сервере: %@. Приложение работает с %@ — обновите.",
        .coreVersionUnknown: "Версия на сервере ещё не прочитана.",
        .listExtrasTitle: "Подписки и Xray",
        .listExtrasSummary_fmt: "Подписок: %d · серверов Xray: %d",
        .listExtrasEmpty: "Свои подписки, готовые белые списки и серверы Xray",
        .listSectionXray: "Серверы Xray",
        .xrayCardSectionHeader: "Xray",
        .protoCheckRunAgain: "Проверить ещё раз",
        .welcomePasteAccessAction: "Вставить ссылку доступа с другого телефона",
        .widgetTrafficName: "olcOS · трафик",
        .widgetTrafficDescription: "Сколько пришло и ушло за сессию, скорость и сколько она идёт.",
        .widgetTrafficNone: "Цифры появятся, когда подключение заработает.",
        .widgetTrafficRate_fmt: "Скорость %@",
        .widgetTrafficAt_fmt: "на %@",
        .invitesAccessField: "Доступ к серверу",
        .invitesAccessNone: "Только подключения",
        .invitesAccessMember: "Комнаты: смотреть и перезапускать",
        .invitesAccessOwner: "Полное управление",
        .invitesAccessUnavailable: "Агент сервера здесь ещё не установлен, поэтому устройство получит только подключения. Откройте страницу этого сервера при работающем SSH и повторите.",
        .invitesAccessFooter: "С доступом устройство само зарегистрирует свой ключ у агента сервера через этот список. Отзыв приглашения отбирает и доступ.",
        .invitesAccessMintFailed_fmt: "Не удалось создать код доступа: %@",
        .hostViaAgent_fmt: "%@ · через агент сервера",
        .hostViaAgentMember_fmt: "%@ · через агент сервера · комнаты: смотреть и перезапускать",
        .hostAgentOnlyNoKey: "Этот сервер управляется через агент, а ключ этого телефона не удалось загрузить.",
        .invitePairFailed_fmt: "Доступ к серверу не получен: %@. Попросите новое приглашение и откройте его снова.",
        .addMenuPhoto: "QR-код из фото",
        .photoQRNotFound: "На этом снимке нет QR-кода.",
        .cameraDeniedTitle: "Доступ к камере выключен",
        .cameraDeniedBody: "Чтобы отсканировать QR-код, olcOS нужна камера. Разрешите её в Настройках или выберите QR-код из фото.",
        .openSettingsAction: "Открыть Настройки",
        .subAllLinksSkipped_fmt: "Ни одну из ссылок (%d) не удалось прочитать. Проверьте, что список предназначен для olcOS.",
        .subImportSkipped_fmt: "Ссылок, которые не удалось прочитать (будут пропущены): %d.",
        .subImportTitleSingle: "Добавить подключение",
        .subImportTitleList: "Импорт списка",
        .healthReasonKeyMismatchGuest: "Ключ сервера изменился, и эта ссылка больше не подходит. Попросите новую у того, кто дал вам ссылку.",
        .healthReasonServerOutdatedGuest: "На сервере старая версия ядра туннеля, приложение с ней не договорится. Попросите того, кто дал вам ссылку, обновить сервер.",
        .telemostLinkExpiresNote: "Ссылка Телемоста работает около 24 часов, потом попросите новую.",
        .addFlowInstallPortsNote: "Сервер должен принимать входящие подключения на порт SSH 22, порт агента сервера, порт раздачи приглашений, порт 443 для Xray и порты выбранных протоколов.",
        .invitesPortsNote: "Сервер должен принимать входящие подключения на порт раздачи приглашений, а для доступа к серверу — ещё и на порт агента.",
        .installerSourcesMissing: "в этой сборке приложения нет файлов для сервера",
        .agentInstallNoEndpoint: "сервер не сообщил, где слушает агент",
        .inviteErrorPortBusy: "порт раздачи на сервере уже занят",
        .inviteErrorUploadFailed_fmt: "Не удалось выложить список на сервер: %@",
        .vpnPermissionUnavailable: "Система не дала разрешение на VPN (с бесплатным Apple ID VPN не работает).",
        .invitePairPending_fmt: "Доступ к серверу пока не подтверждён: %@. Подтвердится сам, как только вы подключитесь к любой комнате этого сервера.",
        .invitesUsageOnline: "Сейчас подключено",
        .invitesUsageLastSeen_fmt: "Последнее подключение: %@",
        .invitesUsageNever: "Ещё не подключалось",
        .invitesUsageToday_fmt: "сегодня в %@",
        .invitesUsageTrafficA11y_fmt: "Получено %@, отправлено %@",
        .invitesUsageDevicesOne_fmt: "%d устройство",
        .invitesUsageDevicesFew_fmt: "%d устройства",
        .invitesUsageDevicesMany_fmt: "%d устройств",
        .laneJoinStuck_fmt: "Комната %d (%@) слишком долго подключалась — подключаю её заново",
        .netPathBlip: "Сеть пропадала на мгновение — проверяю подключение",
        .laneSilent_fmt: "Комната %d (%@) 3 минуты ничего не приносила — подключаю её заново",
        .resumeListenerGoneReason: "локальный SOCKS-порт перестал отвечать, пока приложение было неактивно",
        .resumeTunnelDeadReason: "туннель перестал отвечать, пока приложение было неактивно",

        // Звонки VK, которые приложение создаёт само —
        // аккаунтом пользователя.
        .vkErrNoAccount:       "Аккаунт VK не привязан. Войдите, чтобы создавать звонки VK.",
        .vkErrSessionRejected: "VK отклонил сохранённый вход. Войдите заново.",
        .vkErrRateLimited:     "VK сейчас не даёт создавать звонки. Подождите минуту и попробуйте снова.",
        .vkErrNetwork:         "Не удалось связаться с VK. Проверьте соединение и попробуйте снова.",
        .vkErrMalformed:       "VK прислал ответ, который приложение не смогло разобрать. Попробуйте снова.",
        .vkErrStatus_fmt:      "VK вернул ошибку (код %d). Попробуйте через минуту.",
        .vkSignInAction:       "Войти в VK",
        .vkLoginTitle:         "Вход в VK",
        .vkLoginWarning:       "Используйте одноразовый аккаунт VK. Устройство сохранит cookie входа, которая открывает сообщения, профиль и платежи этого аккаунта без пароля.",
        .roomCreateAutoAction: "Создать автоматически",
        .roomCreateFailed:     "Не удалось создать комнату",
        .roomAnotherAction:    "Другая комната",
        .addFlowVKCreating:    "Создаём звонок VK…",
        .addFlowVKCreated:     "Звонок VK создан",
        .signOutAction_fmt:    "Выйти из %@",
        .signOutConfirmTitle_fmt:   "Выйти из %@?",
        .signOutConfirmMessage_fmt: "Приложение перестанет создавать комнаты для %@, пока не войдёте снова. Текущие подключения не пострадают.",
        .roomRotationOff:            "Выкл.",
        .roomRotationAutomatic:      "Автоматически",
        .roomRotationDaily:          "Раз в сутки",
        .roomRotationWeekly:         "Раз в неделю",
        .roomRotationNoteTelemost:   "Комната живёт 24 часа. Приложение обновляет её заранее.",
        .roomRotationNoteSteady:     "Комнаты не истекают. При желании приложение будет менять их по расписанию.",
        .roomRotationFooter:         "Действует для подключений к серверам, которыми вы управляете. Подключения к чужим серверам остаются на усмотрение их владельцев.",
        .roomRotationExceptionsHeader: "Исключения",
        .roomRotationExceptionsFooter: "Пропущенное подключение сохраняет свою комнату, пока вы не смените её сами.",
        .roomRotationSkipConnection: "Пропускать это подключение",
        .roomRotationEvery6Hours:    "Раз в 6 часов",
        .roomRotationEvery12Hours:   "Раз в 12 часов",
        .roomRotationEvery3Days:     "Раз в 3 дня",
        .roomRotationHowOften:       "Как часто",
        .roomRotationWhen:           "Когда",
        .roomRotationWhenAny:        "В любое время",
        .roomRotationWhenNight:      "Ночью",
        .roomRotationWhenHour:       "В выбранный час",
        .roomRotationWhenNightShort: "ночью",
        .roomRotationWhenHourShort_fmt: "в %@",
        .roomRotationHourLabel:      "Час",
        .roomRotationNightNote:      "Ночь — с 02:00 до 06:00 по времени телефона. Комната, которой пора смениться, ждёт следующей ночи.",
        .roomRotationHourNote:       "Смена произойдёт в течение этого часа по времени телефона. Комната, которой пора смениться, ждёт следующего такого часа.",
        .settingsGroupConnection:    "Подключение",
        .settingsGroupRooms:         "Комнаты",
        .settingsGroupAccounts:      "Аккаунты",
        .settingsGroupNetwork:       "Сеть",
        .settingsGroupSpeed:         "Скорость",
        .settingsGroupDiagnostics:   "Диагностика",
        .settingsGroupLook:          "Вид",
        .vkLoginStatusSignIn:        "Войдите в VK на этой странице",
        .vkLoginStatusChecking:      "Проверяем вход…",
        .vkLoginStatusRefused:       "VK не принял этот вход. Нажмите «Выйти из VK» и войдите заново.",
        .vkLoginSignOutAction:       "Выйти из VK",
        .accountsResetBrowserAction: "Сбросить вход в браузере",
        .accountsResetBrowserTitle_fmt: "Сбросить вход в %@ в браузере?",
        .accountsResetBrowserMessage_fmt: "Встроенный браузер может помнить вход в %@, которым приложение не может воспользоваться. Сброс забудет его, и следующий вход начнётся с нуля. Текущие подключения не пострадают.",
        // Комнаты «МТС Линк», которые приложение создаёт вашим аккаунтом.
        .mtsErrNoAccount:       "Аккаунт «МТС Линк» не привязан. Войдите, чтобы создавать встречи.",
        .mtsErrSessionRejected: "«МТС Линк» отклонил сохранённый вход. Войдите заново.",
        .mtsErrNoCreateRequest: "Приложению ещё не показали, как «МТС Линк» создаёт встречу. Создайте её в окне входа или вставьте ссылку на встречу.",
        .mtsErrRateLimited:     "«МТС Линк» сейчас не даёт создавать встречи. Подождите минуту и попробуйте снова.",
        .mtsErrNetwork:         "Не удалось связаться с «МТС Линк». Проверьте соединение и попробуйте снова.",
        .mtsErrMalformed:       "«МТС Линк» ответил без ссылки на встречу, которую приложение смогло бы прочитать. Попробуйте снова.",
        .mtsErrStatus_fmt:      "«МТС Линк» вернул ошибку (HTTP %d). Попробуйте через минуту.",
        .mtsSignInAction:       "Войти в «МТС Линк»",
        .mtsLoginNote:          "Вход сохранится на этом телефоне и нужен только для создания комнат.",
        .mtsInfoTitle:          "Об этом окне",
        .mtsLoginWarning:       "Устройство сохранит cookie входа вашего аккаунта «МТС Линк». Они открывают встречи, записи и оплату этого аккаунта без пароля. Сам пароль остаётся у «МТС Линка»: приложение видит только cookie и использует их только для создания комнат.",
        .mtsLoginStatusSignIn:  "Войдите в «МТС Линк» на этой странице",
        .mtsLoginStatusChecking: "Проверяем вход…",
        .mtsLoginStatusRefused: "«МТС Линк» не принял этот вход. Выйдите из аккаунта и войдите заново.",
        .mtsLoginSignOutAction: "Выйти из «МТС Линк»",
        .accountsMTSBody:       "Сервер заходит на постоянную встречу «МТС Линк» гостем. Войдите один раз и создайте одну постоянную встречу в окне входа, чтобы приложение запомнило, как; после этого «Создать комнату» — одна кнопка. Или вставьте ссылку из кабинета. Бесплатный тариф допускает две постоянные встречи. Пароль остаётся у «МТС Линка»: приложение хранит только cookie входа и использует их только для создания комнат.",
        // Раскрытие «Что видело приложение» на странице входа.
        .mtsSeenTitle:  "Что видело приложение",
        .mtsSeenEmpty:  "Пока ничего не захвачено.",
        .mtsSeenCopy:   "Скопировать журнал",
        .mtsSeenHint:   "Создайте здесь одну постоянную встречу и нажмите «Завершить» внизу. Потом можно скопировать журнал, если нужно его отправить.",
        // Создание комнат «МТС Линк».
        .mtsMakeRoomAction:       "Создать комнату",
        .addFlowMTSBody:          "Нажмите «Создать комнату» — приложение создаст постоянную встречу вашим аккаунтом «МТС Линк». В первый раз создайте одну встречу сами в окне входа, чтобы приложение запомнило, как; дальше хватит одной кнопки.",
        .addFlowMTSCreating:      "Создаём встречу «МТС Линк»…",
        .addFlowMTSCreated:       "Встреча создана",
        .roomRotationNoteMtslink: "Приложение меняет комнаты «МТС Линк» только после того, как ему показали, как создаётся встреча, и при сохранённом входе (Настройки → Аккаунты). До этого правило остаётся выключенным.",
        .vp8MtsLinkNote: "Для «МТС Линк» приложение использует не меньше 60 кадров в секунду и 64 пакетов в кадре.",
        .mtsLearnBannerTitle: "Как научить приложение",
        .mtsLearnBanner: "Войдите, если сайт попросит. Нужен уже существующий аккаунт с подтверждённой почтой — регистрация завершается по письму от сайта, не здесь. Затем откройте «Встречи» → «Запланировать» → «Постоянную встречу», создайте её и нажмите «Завершить» внизу. Не выбирайте «Быструю встречу»: она одноразовая и заканчивается, а серверу нужна встреча, которая остаётся. Приложение запомнит, как это делается, и в следующий раз хватит одной кнопки.",
        .mtsLearnFinish: "Завершить",
        .mtsLearnHint: "Видно, что встреча создана — нажмите «Завершить».",
        .mtsLearnStep: "Создайте постоянную встречу: «Запланировать» → «Постоянная встреча», затем нажмите «Завершить».",
        .mtsLearnConfirm_fmt: "Комната: %@ — использовать?",
        .mtsLearnUse: "Использовать",
        .mtsLearnNotThis: "Это не та",
        .mtsLearnBack: "Назад к странице",
        .mtsLearnNone: "В ваших действиях не нашлось ни одной встречи, поэтому приложение ничему не научилось. Создайте постоянную встречу и снова нажмите «Завершить» или вставьте ссылку на встречу ниже.",
        .mtsLearnSeveral: "Найдено несколько разных встреч, поэтому приложение ничему не научилось. Выберите свою или вставьте её ссылку ниже. Чтобы научить приложение, закройте это окно и создайте только одну встречу в новом.",
        .mtsLearnPasteInvalid: "Это не ссылка на встречу «МТС Линк».",
        .roomRotationNoteMtslinkPlan: "Каждый раз создаётся новая встреча, старая остаётся в кабинете. Бесплатный тариф «МТС Линк» допускает 2 постоянные встречи, поэтому старые удаляйте в кабинете.",
        .mtsErrMissingToken: "Страница «МТС Линк» не дала приложению токен входа, который нужен запросу. Повторите через минуту или создайте комнату в окне входа.",
        .mtsErrSameRoom: "«МТС Линк» вернул комнату, которая у вас уже есть. Возможно, достигнут лимит постоянных встреч по тарифу — удалите старую в кабинете и повторите.",
        .mtsErrTimeout: "«МТС Линк» слишком долго не отвечает. Попробуйте снова.",
        .mtsReasonSignIn: "Вход в «МТС Линк» ещё не выполнен — сначала войдите на этой странице.",
        .mtsReasonLearn: "Приложение ещё не умеет создавать комнаты.",
        .mtsAccountLearned: "Приложение умеет создавать комнаты: оно запомнило, как.",
        .mtsAccountNotLearned: "Приложение ещё не научилось — один раз создайте постоянную встречу в окне входа.",
        .mtsTeachAction: "Показать приложению, как создавать комнату",
        .mtsForgetAction: "Забыть, чему научилось приложение",
        .mtsForgetMessage: "Приложению придётся снова показать, как создавать комнату. Вход сохранится.",
        .mtsErrRejected_fmt: "«МТС Линк» отклонил запрос (HTTP %d: %@). Возможно, вход пропал или достигнут лимит постоянных встреч по тарифу.",
        .mtsMeetingQuick: "Это быстрая встреча: она работает, только пока вы в ней. Нужна постоянная: «Запланировать» → «Постоянная встреча».",
        .mtsMeetingNoSession: "У этой встречи нет сеанса — сервер не сможет в неё войти.",
        .mtsMeetingGone: "МТС Линк не знает такую встречу.",
        .mtsMeetingUnknown: "Не удалось проверить встречу — попробуйте ещё раз.",
        .mtsMeetingChecking: "Проверяем встречу…",
        .protocolOpWorking: "Работаю с сервером…",
        .protocolOpStarted: "Запущено",
        .protocolOpStopped: "Остановлено",
        .protocolOpSaved: "Сохранено",
        .protocolOpRoomChanged: "Комната заменена",
        .protocolOpRoomAdded: "Комната добавлена",
        .protocolOpRoomRemoved: "Комната убрана",
        .subFetchTitle: "Загрузить список?",
        .subFetchMessage_fmt: "olcOS скачает его с %@, и этот сервер увидит IP-адрес устройства.",
        .subFetchAction: "Загрузить",
    ]
}
