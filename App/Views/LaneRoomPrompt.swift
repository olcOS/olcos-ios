import SwiftUI

// MARK: - Extra rooms ("lanes")
//
// A server can sit in several rooms of one carrier, and the app spreads its
// connections over all of them (OlcrtcEngine, LaneBalancer). Jitsi and
// SaluteJazz rooms are made by the server or the app; a VK call link or a WB
// Stream room has to come from the user, which is what this prompt asks for.

/// "Add a room" for a carrier whose room the user must supply.
struct LaneRoomRequest: Identifiable {
    let id = UUID()
    let host: ServerHost
    let row: SSHRunner.CarrierInfo
}

struct LaneRoomPrompt: ViewModifier {
    @Binding var request: LaneRoomRequest?
    @Binding var text: String
    let onAdd: (LaneRoomRequest, String) -> Void

    func body(content: Content) -> some View {
        content.alert(L10n.laneAddTitle.localized(),
                      isPresented: Binding(get: { request != nil },
                                           set: { if !$0 { request = nil } }),
                      presenting: request) { req in
            TextField(CarrierRoomInput.placeholder(carrier: req.row.provider), text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.laneAddAction.localized()) { onAdd(req, text) }
            Button(L10n.cancel.localized(), role: .cancel) {}
        } message: { req in
            Text(CarrierRoomInput.hint(carrier: req.row.provider))
        }
    }
}
