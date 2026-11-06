import SwiftUI

// MARK: - AddRoomSheet
//
// "Add a service or a room" for one server — the ONE entry point for adding at
// server level (the card's "+"): every call service on one sheet, each with how
// many rooms the server already sits in and what one more needs. A connection
// to the whole server joins every room at once, so each room adds its own
// speed. Services that need nothing get the room at once (Jitsi, SaluteJazz,
// and Telemost / VK Calls once their account is linked); Telemost
// and VK Calls ask for their sign-in right here when there is none; VK Calls
// without a usable account asks for a call link. MTS Link needs nothing here:
// its room is made by one tap (the replay) or, with nothing learned yet, in the
// sign-in sheet in create mode (MTSLinkRoomMaker). Every manual path stays open.
//
// MTS Link takes ONE room per server (no lanes — CarrierTransportMatrix
// .laneCarriers), so its row fills up after the first and says so.

struct AddRoomChoice: Identifiable, Equatable {
    enum Need: Equatable {
        /// The app or the server makes the room: Jitsi, SaluteJazz, Telemost
        /// with a Yandex sign-in, VK Calls with a VK sign-in, MTS Link always
        /// (its make-a-room sheet takes care of the rest).
        case nothing
        /// Telemost with no Yandex sign-in stored.
        case yandexSignIn
        /// VK Calls with no usable account: a call link the user pastes, or the
        /// service's sign-in and the app makes the room.
        case callLink
    }

    let carrier: String
    /// Rooms of this service on the server now; 0 when it is not there yet.
    let rooms: Int
    let need: Need

    var id: String { carrier }
    /// How many rooms this service takes on one server: the lane carriers get
    /// `maxRooms` each; MTS Link keeps one (no lanes —
    /// CarrierTransportMatrix.laneCarriers).
    var roomCap: Int {
        CarrierTransportMatrix.laneCarriers.contains(carrier)
            ? CarrierTransportMatrix.maxRooms : 1
    }
    var isFull: Bool { rooms >= roomCap }

    /// The order the sheet lists the services in: the ones that need nothing first.
    static let order = ["jitsi", "salutejazz", "telemost", "vkcalls", "mtslink"]

    /// PURE. One choice per call service, from the rooms the server holds and
    /// the accounts the app holds. MTS Link is always `.nothing`: its room is
    /// made on the spot (replay or sheet), never from a pasted link here.
    static func make(rooms: [String: Int], yandexSignedIn: Bool,
                     vkSignedIn: Bool) -> [AddRoomChoice] {
        order.map { carrier in
            let need: Need
            switch carrier {
            case "telemost": need = yandexSignedIn ? .nothing : .yandexSignIn
            case "vkcalls":  need = vkSignedIn ? .nothing : .callLink
            default:         need = .nothing
            }
            return AddRoomChoice(carrier: carrier, rooms: rooms[carrier] ?? 0, need: need)
        }
    }
}

struct AddRoomSheet: View {
    let serverName: String
    let choices: [AddRoomChoice]
    /// A room was asked for; `link` is the VK call link when one was needed. The sheet closes itself first, and the server page shows
    /// the progress.
    let onAdd: (AddRoomChoice, _ link: String?) -> Void
    /// The Yandex sign-in finished with this session cookie.
    let onYandexSession: (String) -> Void
    /// The VK sign-in finished with this session cookie.
    let onVKSession: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var signInFor: AddRoomChoice?
    /// Signed in: the room is added once the sign-in sheet has gone.
    @State private var afterSignIn: AddRoomChoice?
    @State private var linkFor: AddRoomChoice?
    @State private var linkText = ""
    /// The VK sign-in sheet, opened from the paste-link alert's own button; the
    /// choice it was opened for.
    @State private var vkSignInFor: AddRoomChoice?
    @State private var showVKLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.addRoomLead.localized())
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .signalFormRows()
                Section {
                    ForEach(choices) { choice in
                        AddRoomRow(choice: choice) { tap(choice) }
                    }
                } footer: {
                    Text(L10n.addRoomLimit_fmt.formatted(CarrierTransportMatrix.maxRooms))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .signalFormRows()
            }
            .signalFormChrome()
            .navigationTitle(L10n.addRoomTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel.localized()) { dismiss() }
                }
            }
            .sheet(item: $signInFor, onDismiss: {
                guard let choice = afterSignIn else { return }
                afterSignIn = nil
                add(choice, link: nil)
            }) { choice in
                YandexLoginView { session in
                    onYandexSession(session)
                    afterSignIn = choice
                }
            }
            .sheet(isPresented: $showVKLogin, onDismiss: {
                vkSignInFor = nil
                // Only a sign-in that actually produced a session adds the
                // room; a cancelled sheet leaves `afterSignIn` nil.
                guard let choice = afterSignIn else { return }
                afterSignIn = nil
                // The sign-in sheet has dismissed ITSELF a moment ago;
                // dismissing this one inside that animation makes iOS drop
                // the second dismissal. The same deferral ServersView uses
                // after a sheet closes (~650 ms).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    add(choice, link: nil)
                }
            }) {
                VKLoginView { session in
                    onVKSession(session)
                    afterSignIn = vkSignInFor
                }
            }
            // The paste-link alert is VK Calls' (MTS Link rooms need none).
            .alert(linkFor.map { Self.pasteTitle(for: $0.carrier) } ?? "",
                   isPresented: Binding(get: { linkFor != nil }, set: { if !$0 { linkFor = nil } }),
                   presenting: linkFor) { choice in
                TextField(CarrierRoomInput.placeholder(carrier: choice.carrier), text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.addRoomAction.localized()) { add(choice, link: linkText) }
                Button(L10n.vkSignInAction.localized()) {
                    vkSignInFor = choice
                    showVKLogin = true
                }
                Button(L10n.cancel.localized(), role: .cancel) {}
            } message: { choice in
                Text(L10n.addRoomVKHowTo.localized())
            }
        }
    }

    /// What the paste-link alert is asking for, per service.
    static func pasteTitle(for carrier: String) -> String {
        carrier == "mtslink" ? L10n.mtsLinkField.localized() : L10n.addRoomVKTitle.localized()
    }

    private func tap(_ choice: AddRoomChoice) {
        switch choice.need {
        case .nothing:
            add(choice, link: nil)
        case .yandexSignIn:
            signInFor = choice
        case .callLink:
            linkText = ""
            linkFor = choice
        }
    }

    private func add(_ choice: AddRoomChoice, link: String?) {
        dismiss()
        onAdd(choice, link)
    }
}

/// One service: its name, how many rooms it has and what one more needs, and
/// the button that adds it.
private struct AddRoomRow: View {
    let choice: AddRoomChoice
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metrics.s3) {
            VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                Text(CarrierTransportMatrix.carrierLabel(choice.carrier))
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Metrics.s2)
            OlcButton(buttonTitle, role: isDisabled ? .secondary : .primary, compact: true, action: onTap)
                .disabled(isDisabled)
        }
        .padding(.vertical, Theme.Metrics.s1)
        .accessibilityElement(children: .combine)
    }

    /// A full service takes no more rooms.
    private var isDisabled: Bool {
        choice.isFull
    }

    private var status: String {
        let count = choice.rooms == 0
            ? L10n.addRoomNotYet.localized()
            : L10n.addRoomCount_fmt.formatted(choice.rooms)
        if choice.isFull { return L10n.addRoomFull_fmt.formatted(choice.rooms) }
        let need: String
        switch choice.need {
        case .nothing:      need = L10n.addRoomNeedNothing.localized()
        case .yandexSignIn: need = L10n.addRoomNeedYandex.localized()
        case .callLink:     need = L10n.addRoomNeedLink.localized()
        }
        return "\(count) · \(need)"
    }

    private var buttonTitle: String {
        switch choice.need {
        case .yandexSignIn: return L10n.addRoomSignIn.localized()
        case .callLink:     return L10n.addRoomPasteLink.localized()
        case .nothing:      return L10n.addRoomAction.localized()
        }
    }
}
