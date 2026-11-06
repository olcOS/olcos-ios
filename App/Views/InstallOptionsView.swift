import SwiftUI

/// Protocol options sheet for an existing server: the "add missing protocols"
/// path (`singleOnly`) and the legacy full install. New servers go through
/// `AddServerFlowView`; this sheet shares its look and copy.
struct InstallOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier: String
    @State private var transport: String
    @State private var roomID = ""
    @State private var jitsiBaseURL = AppConstants.defaultJitsiBaseURL

    @State private var seiFPS: Int = 30
    @State private var seiBatch: Int = 10
    @State private var seiFrag: Int = 1200
    @State private var seiACK: Int = 1

    /// The carrier whose room the app is creating right now (SaluteJazz), and
    /// why the last attempt failed.
    @State private var creatingRoomFor: String?
    @State private var roomCreationError: String?
    /// The MTS Link meeting is being checked before the sheet hands it on,
    /// and why the last check refused it.
    @State private var checkingMeeting = false
    @State private var meetingRefusal: String?
    /// The linked VK / Yandex / MTS Link accounts behind "Create
    /// automatically", and their sign-in sheets. The stores are observed only
    /// for `hasSession`, so the sign-in buttons disappear the moment a sign-in
    /// lands.
    @StateObject private var yandexSession = YandexSessionStore()
    @StateObject private var vkSession = VKSessionStore()
    /// MTS Link has no account button of its own: "Make a room" replays what the
    /// app learned, and opens the sign-in sheet in create mode when it cannot.
    @StateObject private var mtsMaker = MTSLinkRoomMaker()
    @State private var showYandexLogin = false
    @State private var showVKLogin = false
    @StateObject private var jitsiCheck = JitsiInstanceCheck()

    private struct ExtraDraft {
        var enabled = false
        var transport: String
        var roomID = ""
        var jitsiBaseURL = AppConstants.defaultJitsiBaseURL
    }
    @State private var extras: [String: ExtraDraft] = [:]

    private let limitToCarriers: [String]?
    private let singleOnly: Bool
    /// Tries the Jitsi services from the user's server; nil before an install.
    private let checkJitsi: JitsiInstanceCheck.Run?

    let onConfirm: (_ primary: InstallOptions, _ extras: [InstallOptions]) -> Void

    init(limitToCarriers: [String]? = nil,
         singleOnly: Bool = false,
         checkJitsi: JitsiInstanceCheck.Run? = nil,
         onConfirm: @escaping (_ primary: InstallOptions, _ extras: [InstallOptions]) -> Void) {
        self.limitToCarriers = limitToCarriers
        self.singleOnly = singleOnly
        self.checkJitsi = checkJitsi
        self.onConfirm = onConfirm
        let first = limitToCarriers?.first ?? "jitsi"
        _carrier = State(initialValue: first)
        _transport = State(initialValue: CarrierTransportMatrix.defaultTransport(for: first))
    }

    // MARK: Derived

    private var availableCarriers: [String] {
        limitToCarriers ?? CarrierTransportMatrix.carriers
    }

    private var extraCarriers: [String] {
        CarrierTransportMatrix.carriers.filter { $0 != carrier }
    }

    private var enabledExtraCarriers: [String] {
        extraCarriers.filter { extras[$0]?.enabled == true }
    }

    private func draft(_ c: String) -> ExtraDraft {
        extras[c] ?? ExtraDraft(transport: CarrierTransportMatrix.defaultTransport(for: c))
    }

    private func draftBinding(_ c: String) -> Binding<ExtraDraft> {
        Binding(get: { draft(c) }, set: { extras[c] = $0 })
    }

    /// Jitsi accepts an empty room (the server generates one); the others need
    /// one in their own shape (`CarrierRoomInput`).
    static func roomIsValid(carrier: String, roomID: String) -> Bool {
        CarrierRoomInput.isValid(carrier: carrier, roomID)
    }

    private func extraIsValid(_ c: String) -> Bool {
        let d = draft(c)
        return CarrierTransportMatrix.compat(carrier: c, transport: d.transport) != .fail
            && Self.roomIsValid(carrier: c, roomID: d.roomID)
    }

    private var canSubmit: Bool {
        Self.roomIsValid(carrier: carrier, roomID: roomID)
            && CarrierTransportMatrix.compat(carrier: carrier, transport: transport) != .fail
            && enabledExtraCarriers.allSatisfy { extraIsValid($0) }
    }

    // MARK: Body

    // Round 2 was: a ScrollView of OlcCards with uppercase OlcSectionHeaders —
    // a third look beside the Form-based Edit and Reconfigure sheets. The sheet
    // is now the same grouped Form (SignalSectionHeader rows, one pinned primary
    // action); every field is a FormField with a placeholder and a helper line.
    var body: some View {
        NavigationStack {
            Form {
                leadSection
                carrierSection
                transportSection(for: carrier, selection: $transport)
                if carrier == "jitsi", checkJitsi != nil {
                    JitsiInstanceSection(baseURL: $jitsiBaseURL, check: jitsiCheck,
                                         rerun: { startJitsiCheck() })
                }
                roomSection(for: carrier, roomID: $roomID, jitsiBaseURL: $jitsiBaseURL)
                if transport == "seichannel" { seiSection }
                if !singleOnly { extrasSections }
                footerSection
            }
            .signalFormChrome()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle((singleOnly ? L10n.addProtocolTitle : L10n.installTitle).localized())
            .navigationBarTitleDisplayMode(.inline)
            .olcSheet(confirm: (singleOnly ? L10n.addProtocolAction : L10n.actionInstall).localized(),
                      icon: singleOnly ? "plus.circle" : "arrow.down.app",
                      disabled: !canSubmit || checkingMeeting) { submit() }
        }
        .onChange(of: carrier) { _, c in
            transport = CarrierTransportMatrix.defaultTransport(for: c)
            extras[c] = nil
        }
        .onChange(of: transport) { _, t in
            if t != "seichannel" { seiFPS = 30; seiBatch = 10; seiFrag = 1200; seiACK = 1 }
        }
        .onChange(of: carrier, initial: true) { _, c in
            if c == "jitsi" { startJitsiCheck() } else { jitsiCheck.cancel() }
        }
        .onDisappear { jitsiCheck.cancel() }
        .sheet(isPresented: $showYandexLogin) {
            // Linking the account is all this sheet does — the fields fill on
            // the next "Create automatically" press (the fill needs the very
            // field bindings this callback cannot see).
            YandexLoginView { session in
                showYandexLogin = false
                _ = yandexSession.save(session)
            }
        }
        .sheet(isPresented: $showVKLogin) {
            // Linking the account is all this sheet does — the fields fill on
            // the next "Create automatically" press (the fill needs the very
            // field bindings this callback cannot see).
            VKLoginView { session in
                showVKLogin = false
                _ = vkSession.save(session)
            }
        }
        .mtsLessonSheet(mtsMaker)
    }

    /// The services are tried from the user's server as soon as Jitsi is the
    /// chosen protocol; one that does not work is swapped for the fastest one
    /// that does, unless the user has picked one.
    private func startJitsiCheck() {
        guard let checkJitsi else { return }
        jitsiCheck.start(checkJitsi, current: CarrierEndpoints.host(fromRoomID: jitsiBaseURL),
                         transport: transport) { pick in
            jitsiBaseURL = CarrierEndpoints.jitsiBaseURL(forInstance: pick)
        }
    }

    // MARK: Lead / footer

    /// The one-sentence purpose line, drawn as plain text on the ground (not a
    /// card row) so the first card is the first choice.
    private var leadSection: some View {
        Section {
            Text((singleOnly ? L10n.installOptionsLead : L10n.addFlowProtocolsLead).localized())
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    private var footerSection: some View {
        Section {
            FormNote(text: (singleOnly ? L10n.carrierFooterSharedKey : L10n.carrierFooter).localized())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Carrier

    private var carrierSection: some View {
        Section {
            ForEach(availableCarriers, id: \.self) { c in
                carrierRow(c)
            }
        } header: {
            SignalSectionHeader(L10n.sectionCarrier.localized())
        }
        .signalFormRows()
    }

    private func carrierRow(_ c: String) -> some View {
        let selected = carrier == c
        return Button {
            Haptics.tap()
            withAnimation(.snappy) { carrier = c }
        } label: {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    // Badges wrap as a group so the title never gets squeezed.
                    FlowLayout(spacing: Theme.Metrics.s2, lineSpacing: Theme.Metrics.s1) {
                        Text(CarrierTransportMatrix.carrierLabel(c))
                            .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if let badge = AddServerCarrierPlan.badge(for: c).title {
                            AddServerBadge(text: badge.localized(),
                                           tone: AddServerCarrierPlan.badge(for: c) == .recommended ? .ok : .unknown)
                        }
                        if let need = AddServerCarrierPlan.requirement(for: c) {
                            AddServerBadge(text: need.text.localized(), tone: need.tone)
                        }
                    }
                    Text(AddServerCarrierPlan.descriptionKey(forCarrier: c).localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    // Round 2: the same selection tint as ServerSignalOptions (Reconfigure).
                    .foregroundStyle(selected ? Theme.Signal.stroke : Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Transport

    private func transportSection(for c: String, selection: Binding<String>) -> some View {
        let recommended = CarrierTransportMatrix.defaultTransport(for: c)
        return Section {
            ForEach(AddServerCarrierPlan.transportOptions(for: c), id: \.self) { t in
                transportRow(t, carrier: c, selected: selection.wrappedValue == t,
                             recommended: t == recommended) {
                    Haptics.tap()
                    selection.wrappedValue = t
                }
            }
        } header: {
            SignalSectionHeader(L10n.addFlowTransportFor_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)))
        } footer: {
            if selection.wrappedValue == "videochannel" {
                Text(L10n.transportUsesServerDefaults_fmt.formatted(
                    CarrierTransportMatrix.transportLabel("videochannel")))
            }
        }
        .signalFormRows()
    }

    private func transportRow(_ t: String, carrier c: String, selected: Bool,
                              recommended: Bool, action: @escaping () -> Void) -> some View {
        let compat = CarrierTransportMatrix.compat(carrier: c, transport: t)
        return Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    HStack(spacing: Theme.Metrics.s2) {
                        Text(CarrierTransportMatrix.transportLabel(t))
                            .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if recommended {
                            AddServerBadge(text: L10n.addFlowBadgeRecommended.localized(), tone: .ok)
                        }
                    }
                    Text(AddServerCarrierPlan.descriptionKey(forTransport: t).localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if compat == .question {
                        // Round 2: the ⚠ verdict as a tinted note, not a bare glyph line.
                        FormNote(text: L10n.matrixQuestion_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)),
                                 tone: .warn)
                    }
                }
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Signal.stroke : Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Room

    /// Field label above the value, helper below — one FormField per input, with
    /// the same per-service placeholder and hint the other room forms use
    /// (`CarrierRoomInput.placeholder` / `.hint`) instead of one example id
    /// beside blank fields.
    private func roomSection(for c: String, roomID: Binding<String>,
                             jitsiBaseURL: Binding<String>) -> some View {
        Section {
            switch c {
            case "jitsi":
                // The checked service list is a section of its own for the
                // primary protocol when the server can run the check.
                if c != carrier || checkJitsi == nil {
                    jitsiInstanceMenu(jitsiBaseURL: jitsiBaseURL)
                    FormField(label: L10n.addFlowJitsiCustom.localized(),
                              placeholder: L10n.fieldJitsiURL.localized(),
                              text: jitsiBaseURL, keyboard: .URL, mono: true,
                              helper: L10n.addFlowJitsiInstanceNote.localized())
                }
                FormField(label: L10n.addFlowJitsiRoomName.localized(),
                          placeholder: "olc-room", text: roomID, mono: true,
                          helper: L10n.addFlowJitsiRoomHint.localized())
            case "vkcalls":
                FormField(label: L10n.vkCallLinkField.localized(),
                          placeholder: CarrierRoomInput.placeholder(carrier: c),
                          text: roomID, keyboard: .URL, mono: true,
                          helper: CarrierRoomInput.hint(carrier: c))
                autoCreateRow(carrier: c, roomID: roomID)
            case "mtslink":
                FormField(label: L10n.mtsLinkField.localized(),
                          placeholder: CarrierRoomInput.placeholder(carrier: c),
                          text: roomID, keyboard: .URL, mono: true,
                          helper: CarrierRoomInput.hint(carrier: c))
                    .onChange(of: roomID.wrappedValue) { _, _ in meetingRefusal = nil }
                autoCreateRow(carrier: c, roomID: roomID)
                roomSuggestion(carrier: c, into: roomID)
                if checkingMeeting {
                    FormNote(text: L10n.mtsMeetingChecking.localized())
                }
                if let meetingRefusal {
                    AddServerInlineError(message: meetingRefusal)
                }
            case "salutejazz":
                FormField(label: L10n.fieldRoomID.localized(),
                          placeholder: CarrierRoomInput.placeholder(carrier: c),
                          text: roomID, mono: true,
                          helper: CarrierRoomInput.hint(carrier: c))
                OlcButton(L10n.saluteCreateRoomAction.localized(), systemImage: "plus.bubble",
                          role: .secondary, isBusy: creatingRoomFor == c, compact: true) {
                    createSaluteRoom(into: roomID)
                }
                .disabled(creatingRoomFor != nil)
                if let roomCreationError {
                    AddServerInlineError(message: roomCreationError)
                }
            case "telemost":
                // Telemost rooms come from the Yandex account, like the
                // wizard's card makes them.
                FormField(label: L10n.fieldRoomID.localized(),
                          placeholder: CarrierRoomInput.placeholder(carrier: c),
                          text: roomID, mono: true,
                          helper: CarrierRoomInput.hint(carrier: c))
                autoCreateRow(carrier: c, roomID: roomID)
                roomSuggestion(carrier: c, into: roomID)
            default:
                FormField(label: L10n.fieldRoomID.localized(),
                          placeholder: CarrierRoomInput.placeholder(carrier: c),
                          text: roomID, mono: true,
                          helper: CarrierRoomInput.hint(carrier: c))
                roomSuggestion(carrier: c, into: roomID)
            }
        } header: {
            SignalSectionHeader(L10n.roomIDSectionHeader.localized())
        }
        .signalFormRows()
    }

    private func jitsiInstanceMenu(jitsiBaseURL: Binding<String>) -> some View {
        Menu {
            ForEach(CarrierEndpoints.jitsiInstances, id: \.self) { host in
                Button(host) {
                    jitsiBaseURL.wrappedValue = CarrierEndpoints.jitsiBaseURL(forInstance: host)
                }
            }
        } label: {
            HStack {
                Text(CarrierEndpoints.host(fromRoomID: jitsiBaseURL.wrappedValue) ?? jitsiBaseURL.wrappedValue)
                    .font(Theme.Typography.metricValue)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .padding(.horizontal, Theme.Metrics.s3)
            .background(Theme.Palette.fill, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.fillBorder, lineWidth: 1)
            }
        }
    }

    /// One anonymous request; the new room lands in the field it was asked for.
    private func createSaluteRoom(into binding: Binding<String>) {
        creatingRoomFor = "salutejazz"
        roomCreationError = nil
        Task {
            defer { creatingRoomFor = nil }
            do {
                binding.wrappedValue = try await SaluteJazzRoomService.createRoom()
                Haptics.success()
            } catch {
                roomCreationError = error.localizedDescription
            }
        }
    }

    // MARK: Auto-created rooms

    /// "Create automatically" for the services whose rooms the app mints from a
    /// linked account: the room fills the fields (a Telemost room comes from
    /// the Yandex account).
    /// With no account linked the sign-in button is the way in — and a create
    /// that fails for exactly that reason opens the sign-in sheet by itself.
    /// Manual entry stays open either way:
    /// the fields above are never locked. MTS Link goes through
    /// MTSLinkRoomMaker: the silent replay, or the sign-in sheet in create mode
    /// (with the reason) when the app has not learned how yet or the replay failed.
    @ViewBuilder
    private func autoCreateRow(carrier c: String, roomID: Binding<String>) -> some View {
        Group {
            HStack(spacing: Theme.Metrics.s3) {
                OlcButton(L10n.roomCreateAutoAction.localized(), systemImage: "sparkles",
                          role: .secondary, isBusy: creatingRoomFor == c, compact: true) {
                    createRoomAutomatically(carrier: c, roomID: roomID)
                }
                .disabled(creatingRoomFor != nil)
                if !hasAccount(c) {
                    OlcButton(signInTitle(c), systemImage: "person.crop.circle.badge.checkmark",
                              role: .ghost, compact: true) {
                        switch c {
                        case "telemost": showYandexLogin = true
                        case "vkcalls":  showVKLogin = true
                        default:         break
                        }
                    }
                }
            }
            if let roomCreationError {
                AddServerInlineError(message: roomCreationError)
            }
        }
    }

    private func hasAccount(_ c: String) -> Bool {
        switch c {
        case "telemost": return yandexSession.hasSession
        case "vkcalls":  return vkSession.hasSession
        default:         return true   // MTS Link signs in inside the make-a-room sheet
        }
    }

    private func signInTitle(_ c: String) -> String {
        c == "vkcalls" ? L10n.vkSignInAction.localized() : L10n.telemostRoomSignInAction.localized()
    }

    private func createRoomAutomatically(carrier c: String, roomID: Binding<String>) {
        creatingRoomFor = c
        roomCreationError = nil
        Task {
            defer { creatingRoomFor = nil }
            do {
                switch c {
                case "telemost":
                    roomID.wrappedValue = try await TelemostRoomService.createRoom().id
                case "vkcalls":
                    roomID.wrappedValue = try await VKCallRoomService.createRoom().link
                case "mtslink":
                    guard let link = await mtsMaker.makeRoom(current: roomID.wrappedValue) else { return }
                    roomID.wrappedValue = link
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
    private func roomSuggestion(carrier c: String, into binding: Binding<String>) -> some View {
        if binding.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty,
           let last = RoomMemory.lastRoom(forCarrier: c) {
            OlcButton(L10n.roomIDLastUsed_fmt.formatted(last), systemImage: "clock.arrow.circlepath",
                      role: .ghost, compact: true) { binding.wrappedValue = last }
        }
    }

    // MARK: SEI

    private var seiSection: some View {
        Section {
            Stepper("\(L10n.seiFpsLabel.localized()): \(seiFPS)", value: $seiFPS, in: SettingsStore.Defaults.seiFPSRange)
            Stepper("\(L10n.seiBatchLabel.localized()): \(seiBatch)", value: $seiBatch, in: SettingsStore.Defaults.seiBatchRange)
            Stepper("\(L10n.seiFragLabel.localized()): \(seiFrag)", value: $seiFrag, in: SettingsStore.Defaults.seiFragRange, step: 100)
            Stepper("\(L10n.seiAckLabel.localized()): \(seiACK)", value: $seiACK, in: SettingsStore.Defaults.seiACKRange, step: 100)
        } header: {
            SignalSectionHeader(L10n.seiSettingsHeader.localized())
        } footer: {
            Text(L10n.seiSettingsFooter.localized())
        }
        .font(Theme.Typography.body)
        .signalFormRows()
    }

    // MARK: Extras

    @ViewBuilder private var extrasSections: some View {
        Section {
            ForEach(extraCarriers, id: \.self) { c in
                Toggle(isOn: draftBinding(c).enabled) {
                    Text(L10n.installExtraToggle_fmt.formatted(CarrierTransportMatrix.carrierLabel(c)))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .frame(minHeight: Theme.Metrics.controlHeight)
            }
        } header: {
            SignalSectionHeader(L10n.installExtrasHeader.localized())
        } footer: {
            Text(L10n.installExtrasFooter.localized())
        }
        .signalFormRows()
        ForEach(enabledExtraCarriers, id: \.self) { c in
            let binding = draftBinding(c)
            transportSection(for: c, selection: binding.transport)
            roomSection(for: c, roomID: binding.roomID, jitsiBaseURL: binding.jitsiBaseURL)
        }
    }

    // MARK: Submit

    private func submit() {
        let primary = Self.options(carrier: carrier, transport: transport, roomID: roomID,
                                   jitsiBaseURL: jitsiBaseURL,
                                   sei: (seiFPS, seiBatch, seiFrag, seiACK))
        let extraOptions: [InstallOptions] = singleOnly ? [] : enabledExtraCarriers.map { c in
            let d = draft(c)
            return Self.options(carrier: c, transport: d.transport, roomID: d.roomID,
                                jitsiBaseURL: d.jitsiBaseURL, sei: nil)
        }
        // An MTS Link meeting is checked before the sheet hands it on.
        guard !MTSLinkMeetingCheck.roomsToCheck([primary] + extraOptions).isEmpty else {
            onConfirm(primary, extraOptions)
            dismiss()
            return
        }
        guard !checkingMeeting else { return }
        checkingMeeting = true
        meetingRefusal = nil
        Task { @MainActor in
            let refusal = await MTSLinkMeetingCheck.refusal(for: [primary] + extraOptions)
            checkingMeeting = false
            if let refusal {
                meetingRefusal = refusal
                Haptics.error()
                return
            }
            onConfirm(primary, extraOptions)
            dismiss()
        }
    }

    /// Pure mapping from the sheet's fields to `InstallOptions` (unit-tested).
    static func options(carrier: String, transport: String, roomID: String,
                        jitsiBaseURL: String,
                        sei: (fps: Int, batch: Int, frag: Int, ack: Int)?) -> InstallOptions {
        let cleanedRoom = CarrierRoomInput.normalized(carrier: carrier, roomID)
        let cleanedJitsi = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var o = InstallOptions(carrier: carrier, transport: transport, roomID: cleanedRoom)
        o.jitsiBaseURL = cleanedJitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : cleanedJitsi
        if let sei {
            o.seiFPS = sei.fps; o.seiBatch = sei.batch; o.seiFrag = sei.frag; o.seiACK = sei.ack
        }
        return o
    }
}
