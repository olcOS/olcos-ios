import SwiftUI

// boc #490
// #490 was: default Form headers and surfaces. Signal uses shared sentence-case
// section headers, readable native rows and consistent sage action chrome.
// All fields, bindings, validation, secrets and submit/lifecycle methods remain.
// eoc #490

// MARK: - ReconfigureOptionsView
//
// Sheet shown when the user taps "Change Room / Transport" in the server menu.
// Identical layout to InstallOptionsView but with a different title and
// confirm-button label — no apt-get / go build, just rewrite server.yaml and
// restart the existing container.
//
// #258: carrier / transport use OlcChipPicker; the confirm action is a single
// full-width OlcButton(.primary) footer, with one close (✕) control.
//
// #451: gained the jitsi base-URL field so a reconfigure can produce the same
// valid config an install does: srv.sh prefixes a short room name with the base
// URL at install time, but reconfigureScript seds `id:` verbatim, and master's
// jitsi provider rejects a bare room name (ErrInvalidRoomURL). The prefixing
// therefore happens CLIENT-side in submit() (reconfigureScript ignores
// OLCRTC_JITSI_URL).
//
// #470: the jitsi base field never applied to an EXISTING install — the sheet is
// seeded with the full room URL srv.sh stores, and the prefixing above only fires
// for a bare name. `jitsiRoom(_:movedTo:)` now moves a full-URL room onto the
// edited instance in submit(). The transport footer also lost the ★/⚠ lab
// verdicts (and the raw carrier id they printed), mirroring InstallOptionsView #457.

struct ReconfigureOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier   = "telemost"
    @State private var transport = CarrierTransportMatrix.defaultTransport(for: "telemost")
    @State private var roomID    = ""

    // boc #452: seed the form from the protocol row being reconfigured (the
    // host card now has one row per carrier). nil params keep the old blank
    // defaults, so the pre-#452 host-level entry point is unchanged.
    init(initialCarrier: String? = nil,
         initialTransport: String? = nil,
         initialRoom: String? = nil,
         // A self-hosted jitsi instance already on the record is seeded, or it
         // would silently revert to the shared public default.
         initialJitsiBase: String? = nil,
         checkJitsi: JitsiInstanceCheck.Run? = nil,
         lockCarrier: Bool = false,
         onConfirm: @escaping (InstallOptions) -> Void) {
        self.onConfirm = onConfirm
        self.checkJitsi = checkJitsi
        self.lockCarrier = lockCarrier
        if let c = initialCarrier {
            _carrier   = State(initialValue: c)
            _transport = State(initialValue: initialTransport ?? CarrierTransportMatrix.defaultTransport(for: c))
        }
        if let r = initialRoom {
            _roomID = State(initialValue: r)
        }
        if let j = initialJitsiBase, !j.isEmpty {
            _jitsiBaseURL = State(initialValue: j)
        }
    }
    // eoc #452
    // #451: jitsi rendezvous base URL — mirrors InstallOptionsView (#256);
    // used only to normalise a short jitsi room name in submit().
    @State private var jitsiBaseURL = AppConstants.defaultJitsiBaseURL

    /// The room-creation half, same as the install sheet: which service is
    /// creating right now and why the last attempt failed.
    @State private var creatingRoomFor: String?
    @State private var roomCreationError: String?
    /// The MTS Link meeting is being checked before the sheet hands it on,
    /// and why the last check refused it.
    @State private var checkingMeeting = false
    @State private var meetingRefusal: String?
    /// The linked accounts behind "Create automatically" and their sign-in
    /// sheets. The stores are observed only for `hasSession`, so the sign-in
    /// buttons disappear the moment a sign-in lands.
    @StateObject private var yandexSession = YandexSessionStore()
    @StateObject private var vkSession = VKSessionStore()
    /// MTS Link has no account button of its own: "Create automatically" replays
    /// what the app learned, and opens the sign-in sheet in create mode when it cannot.
    @StateObject private var mtsMaker = MTSLinkRoomMaker()
    @State private var showYandexLogin = false
    @State private var showVKLogin = false

    let onConfirm: (InstallOptions) -> Void
    /// Tries the Jitsi services from the user's server; nil when there is none to ask.
    let checkJitsi: JitsiInstanceCheck.Run?
    /// An extra room keeps its service (a protocol's rooms are joined
    /// together): only its room and transport can change.
    let lockCarrier: Bool
    @StateObject private var jitsiCheck = JitsiInstanceCheck()

    private var requiresRoomID: Bool { CarrierTransportMatrix.requiresRoomID(carrier: carrier) }

    private var canSubmit: Bool {
        // (audit) `!= .fail` is belt-and-braces: the ✗ chips are disabled and the
        // carrier onChange resets transport to the default, but a submit of a
        // combo the matrix marks broken must never reconfigure to a dead server.
        // Jitsi too: reconfigure writes `id:` verbatim and cannot generate a room.
        (!requiresRoomID || (!roomID.trimmingCharacters(in: .whitespaces).isEmpty
                             && CarrierRoomInput.isValid(carrier: carrier, roomID)))
            && CarrierTransportMatrix.compat(carrier: carrier, transport: transport) != .fail
            // A protocol the app no longer offers (a saved WB Stream server)
            // can only be moved to one it does.
            && (lockCarrier || CarrierTransportMatrix.carriers.contains(carrier))
    }

    /// (audit) transport chips with the ✗ combos for the current carrier
    /// disabled (OlcOption.disabled) and the reason surfaced to VoiceOver.
    private var transportOptions: [OlcOption<String>] {
        CarrierTransportMatrix.transports.map { t -> OlcOption<String> in
            let fails = CarrierTransportMatrix.compat(carrier: carrier, transport: t) == .fail
            return OlcOption(
                value: t,
                label: CarrierTransportMatrix.transportLabel(t),
                disabled: fails,
                disabledReason: fails
                    ? L10n.matrixFail_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier))
                    : nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !lockCarrier { carrierSection }
                transportSection
                roomIDSection
                jitsiSection
                infoSection
            }
            .signalFormChrome() // #490 was: default grouped-form chrome.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.reconfigureTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: L10n.actionChangeRoomTransport.localized(),
                      icon: "slider.horizontal.3", disabled: !canSubmit || checkingMeeting) { submit() }
            .onChange(of: carrier, initial: true) { _, c in
                if c == "jitsi" { startJitsiCheck() } else { jitsiCheck.cancel() }
            }
            .onDisappear { jitsiCheck.cancel() }
        }
        // Linking an account is all these sheets do — the room field fills on
        // the next "Create automatically" press (the fill needs the very field
        // binding these callbacks cannot see).
        .sheet(isPresented: $showYandexLogin) {
            YandexLoginView { session in
                showYandexLogin = false
                _ = yandexSession.save(session)
            }
        }
        .sheet(isPresented: $showVKLogin) {
            VKLoginView { session in
                showVKLogin = false
                _ = vkSession.save(session)
            }
        }
        .mtsLessonSheet(mtsMaker)
    }

    /// Each public Jitsi service is tried from the user's server when the sheet
    /// opens on Jitsi; a service that does not work is swapped for the fastest
    /// one that does, unless the user has picked one.
    private func startJitsiCheck() {
        guard let checkJitsi else { return }
        jitsiCheck.start(checkJitsi, current: CarrierEndpoints.host(fromRoomID: jitsiBaseURL),
                         transport: transport) { pick in
            jitsiBaseURL = CarrierEndpoints.jitsiBaseURL(forInstance: pick)
        }
    }

    private var jitsiRerun: (() -> Void)? {
        guard checkJitsi != nil else { return nil }
        return { startJitsiCheck() }
    }

    // MARK: Sections

    private var carrierSection: some View {
        Section {
            ServerSignalOptions(
                selection: $carrier,
                options: CarrierTransportMatrix.carriers.map { ($0, CarrierTransportMatrix.carrierLabel($0)) },
                details: Self.carrierDetails)
                .onChange(of: carrier) { _, c in
                    transport = CarrierTransportMatrix.defaultTransport(for: c)
                    meetingRefusal = nil
                }
        } header: {
            SignalSectionHeader(L10n.sectionCarrier.localized())
        }
        .signalFormRows()
    }

    /// One verified line per carrier / transport (dev-notes/PROTOCOLS.md), drawn
    /// under the option name instead of a footer paragraph.
    private static var carrierDetails: [String: String] {
        Dictionary(uniqueKeysWithValues: CarrierTransportMatrix.carriers.compactMap { id in
            ProtocolDescriptions.carrier(id).map { (id, $0) }
        })
    }

    private static var transportDetails: [String: String] {
        Dictionary(uniqueKeysWithValues: CarrierTransportMatrix.transports.compactMap { id in
            ProtocolDescriptions.transport(id).map { (id, $0) }
        })
    }

    private var transportSection: some View {
        Section {
            // Options carry disabled + reason for the ✗ carrier/transport combos.
            ServerSignalOptions(selection: $transport, options: transportOptions,
                                details: Self.transportDetails)
            if !transportFooter.isEmpty {
                FormNote(text: transportFooter)
                    .listRowSeparator(.hidden)
            }
        } header: {
            SignalSectionHeader(L10n.transportSectionHeader.localized())
        }
        .signalFormRows()
    }

    /// #456: offer the last room used with this carrier instead of asking for a
    /// value the app already has (requirement 8). Only while the field is empty.
    @ViewBuilder
    private var roomSuggestion: some View {
        if roomID.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = RoomMemory.lastRoom(forCarrier: carrier) {
            Button(L10n.roomIDLastUsed_fmt.formatted(last)) { roomID = last }
                .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                .foregroundStyle(Theme.Signal.stroke) // #490: Signal action tint.
        }
    }

    // MARK: Room source ("Create automatically")
    //
    // The sheet used to offer the room field alone: with an account linked the
    // room still had to be typed out by hand, and MTS Link gave no clue why a
    // made room was not on offer. The same row the install sheet has, then: the
    // app makes the room where it can (Telemost via the Yandex account, VK
    // Calls, SaluteJazz), the sign-in sits right
    // where an account is missing, and MTS Link goes through MTSLinkRoomMaker:
    // the silent replay, or the sign-in sheet in create mode (with the reason)
    // when the app has not learned how yet or the replay failed.
    // The filled field is still confirmed by hand.

    @ViewBuilder
    private var roomSourceRow: some View {
        switch carrier {
        case "telemost", "salutejazz", "vkcalls", "mtslink":
            roomCreateRow
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var roomCreateRow: some View {
        Group {
            HStack(spacing: Theme.Metrics.s3) {
                OlcButton(L10n.roomCreateAutoAction.localized(), systemImage: "sparkles",
                          role: .secondary, isBusy: creatingRoomFor != nil, compact: true) {
                    createRoomAutomatically()
                }
                .disabled(creatingRoomFor != nil)
                if let signIn = signInTitle {
                    OlcButton(signIn, systemImage: "person.crop.circle.badge.checkmark",
                              role: .ghost, compact: true) { showSignInSheet() }
                }
            }
            if let roomCreationError {
                AddServerInlineError(message: roomCreationError)
            }
        }
    }

    /// The sign-in the missing account needs, or nil where there is nothing to
    /// sign in to (SaluteJazz) or the account is already linked.
    private var signInTitle: String? {
        switch carrier {
        case "telemost": return yandexSession.hasSession ? nil : L10n.telemostRoomSignInAction.localized()
        case "vkcalls":  return vkSession.hasSession ? nil : L10n.vkSignInAction.localized()
        default:         return nil
        }
    }

    private func showSignInSheet() {
        switch carrier {
        case "telemost": showYandexLogin = true
        case "vkcalls":  showVKLogin = true
        default:         break
        }
    }

    /// One room from the app, into the field it was asked for.
    private func createRoomAutomatically() {
        creatingRoomFor = carrier
        roomCreationError = nil
        Task {
            defer { creatingRoomFor = nil }
            do {
                switch carrier {
                case "telemost":
                    roomID = try await TelemostRoomService.createRoom().id
                case "salutejazz":
                    roomID = try await SaluteJazzRoomService.createRoom()
                case "vkcalls":
                    roomID = try await VKCallRoomService.createRoom().link
                case "mtslink":
                    guard let link = await mtsMaker.makeRoom(current: roomID) else { return }
                    roomID = link
                default:
                    return
                }
                Haptics.success()
            } catch {
                roomCreationError = error.localizedDescription
                // The one failure with an obvious next step: go straight to it.
                if (error as? TelemostRoomError)?.needsSignIn == true { showYandexLogin = true }
                if (error as? VKCallRoomError)?.needsSignIn == true { showVKLogin = true }
            }
        }
    }

    @ViewBuilder
    private var roomIDSection: some View {
        if requiresRoomID {
            Section {
                // Round 2 was: a bare monospaced TextField whose only label was
                // its placeholder, so a filled field had no caption at all. The
                // shared FormField draws label / plate / helper like the other sheets.
                FormField(label: L10n.fieldRoomID.localized(),
                          placeholder: CarrierRoomInput.placeholder(carrier: carrier),
                          text: $roomID, mono: true, helper: roomFooter)
                    .onChange(of: roomID) { _, _ in meetingRefusal = nil }
                roomSuggestion   // #456
                roomSourceRow
                if checkingMeeting {
                    FormNote(text: L10n.mtsMeetingChecking.localized())
                }
                if let meetingRefusal {
                    AddServerInlineError(message: meetingRefusal)
                }
            } header: {
                SignalSectionHeader(L10n.roomIDSectionHeader.localized())
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        } else {
            Section {
                Label(L10n.roomIDAutoGenHint.localized(),
                      systemImage: "wand.and.stars")
                    .font(Theme.Typography.caption)   // #471: B9 — was: .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .signalFormRows() // #490: retain native rows on Signal surfaces.
        }
    }

    // The service a short room name is prefixed with, and a full-URL room is
    // moved onto (client-side, see submit()).
    @ViewBuilder
    private var jitsiSection: some View {
        if carrier == "jitsi" {
            JitsiInstanceSection(baseURL: $jitsiBaseURL, check: jitsiCheck, rerun: jitsiRerun)
        }
    }

    private var infoSection: some View {
        Section {
            // #451: second line — reconfigure rewrites only provider/id/
            // transport (+ auth.token); it does NOT write vp8:/sei: tuning
            // blocks, so after a transport switch the server runs its engine
            // defaults (master overlays only keys present in the YAML).
            // Round 2: the same neutral FormNote the Add-protocol sheet ends with.
            FormNote(text: L10n.reconfigureInfoFooter.localized() + " " +
                           L10n.reconfigureTransportTuningFooter.localized())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Logic

    private func submit() {
        // Telemost shows room IDs with spaces ("3528 5410 1234") for readability;
        // the API form has no spaces. Strip them so users can paste either form.
        var cleanedRoom = roomID
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        // A pasted invite link becomes the bare id the server stores; see
        // TelemostRoomService.normalizedRoomInput for why the string must match.
        // VK links, SaluteJazz `<code>:<password>` and MTS Link meeting links
        // take the same shape the install wrote (CarrierRoomInput), or the room
        // string would not match. An MTS Link link keeps its phone-only ICE
        // hint here; the server is given it plain (SSHRunner.installEnv).
        if ["telemost", "vkcalls", "salutejazz", "mtslink"].contains(carrier) {
            cleanedRoom = CarrierRoomInput.normalized(carrier: carrier, roomID)
        }
        // #451: normalise a short jitsi room name into the full URL the server
        // requires — the same rule srv.sh applies at install (base + "/" + name;
        // full http(s) URLs and host/room forms pass through verbatim).
        // reconfigureScript writes `id:` verbatim, so this must happen here.
        if carrier == "jitsi", !cleanedRoom.isEmpty,
           !cleanedRoom.contains("://"), !cleanedRoom.contains("/") {
            let trimmedBase = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            var base = trimmedBase.isEmpty ? AppConstants.defaultJitsiBaseURL : trimmedBase
            while base.hasSuffix("/") { base.removeLast() }   // srv.sh: ${JITSI_BASE%/}
            cleanedRoom = base + "/" + cleanedRoom
        } else if carrier == "jitsi" {
            // #470: an existing install is seeded with the FULL room URL, so the
            // branch above never ran and the Jitsi-server field was a no-op —
            // move the room onto the edited instance instead.
            cleanedRoom = Self.jitsiRoom(cleanedRoom, movedTo: jitsiBaseURL)
        }
        let cleanedJitsi = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = InstallOptions(
            carrier:      carrier,
            transport:    transport,
            roomID:       requiresRoomID ? cleanedRoom : "",
            jitsiBaseURL: cleanedJitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : cleanedJitsi
        )
        // An MTS Link meeting is checked before the sheet hands it on.
        guard !MTSLinkMeetingCheck.roomsToCheck([options]).isEmpty else {
            onConfirm(options)
            dismiss()
            return
        }
        guard !checkingMeeting else { return }
        checkingMeeting = true
        meetingRefusal = nil
        Task { @MainActor in
            let refusal = await MTSLinkMeetingCheck.refusal(for: [options])
            checkingMeeting = false
            if let refusal {
                meetingRefusal = refusal
                Haptics.error()
                return
            }
            onConfirm(options)
            dismiss()
        }
    }

    /// #470: a jitsi room is stored as the FULL URL srv.sh writes
    /// ("https://host/room"), so editing the Jitsi-server field did nothing for
    /// an existing install. Moves a full-URL room onto `base` (scheme://host[:port],
    /// trailing slashes ignored), keeping the room's path. Anything else — a bare
    /// name, a host/room form, an empty base, the same instance — comes back
    /// unchanged. Pure → unit-tested (Tests/Review470Chunk2Tests.swift).
    static func jitsiRoom(_ room: String, movedTo base: String) -> String {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, room.contains("://"),
              let url = URL(string: room), let scheme = url.scheme,
              let host = url.host, !host.isEmpty else { return room }
        let hostPart = url.port.map { "\(host):\($0)" } ?? host
        if base == "\(scheme)://\(hostPart)" || base == hostPart { return room }
        return base + url.path + (url.query.map { "?\($0)" } ?? "")
    }

    // MARK: Footer helpers

    /// The server-defaults note applies to videochannel only; a seichannel
    /// tuning reset is already stated by `reconfigureTransportTuningFooter`.
    private var transportFooter: String {
        transport == "videochannel"
            ? L10n.transportUsesServerDefaults_fmt.formatted(CarrierTransportMatrix.transportLabel(transport))
            : ""
    }

    /// Room helper under the field. Telemost also says a pasted invite link is
    /// accepted (submit() collapses it via `TelemostRoomService.normalizedRoomInput`).
    private var roomFooter: String {
        carrier == "jitsi" ? "" : CarrierRoomInput.hint(carrier: carrier)
    }
}
