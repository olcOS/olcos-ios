import SwiftUI

// MARK: - MTSLinkRoomMaker
//
// The ONE path every "Make a room" button for MTS Link goes through (the Add
// server wizard, the install and change-room sheets, the protocol page, the
// Add-service sheet): the silent replay first (MTSLinkRoomService.createRoom →
// MTSLinkReplay), and — when there is nothing to replay yet, or the replay
// failed — the sign-in sheet in create mode (MTSLinkLoginView), opened with a
// one-line reason. Whichever way the room arrives it comes back from
// `makeRoom`; nil means the owner cancelled (or a make was already running).
//
// A surface owns one maker, applies `.mtsLessonSheet(maker)` once, and awaits
// `makeRoom(current:)`.
@MainActor
final class MTSLinkRoomMaker: ObservableObject {

    struct Request: Identifiable {
        let id = UUID()
        /// Why the sheet is open instead of a silent make; "" for none.
        let reason: String
    }

    /// The sheet to show, when one is wanted.
    @Published var request: Request?
    @Published private(set) var busy = false

    private var waiter: CheckedContinuation<String?, Never>?

    /// A new meeting's link, normalized (`https://my.mts-link.ru/j/<owner>/<event>`),
    /// or nil when the owner closed the sheet without one. `current` is the
    /// room now in use: a replay that returns it counts as a failure.
    func makeRoom(current: String) async -> String? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }

        let reason: String
        if MTSLinkRoomService.canCreateRooms {
            do {
                let room = try await MTSLinkRoomService.createRoom(current: current)
                Haptics.success()
                return room
            } catch {
                reason = error.localizedDescription
                LogStore.shared.log(.provisioning,
                    "MTS Link: the silent make failed (\((error as? MTSLinkRoomError)?.logText ?? "error")) — opening the sheet")
            }
        } else {
            reason = MTSLinkRoomService.lessonReason()
            LogStore.shared.log(.provisioning,
                "MTS Link: nothing to replay yet (\(MTSLinkSessionStore.hasStoredSession() ? "not learned" : "no account")) — opening the sheet")
        }
        return await ask(reason: reason)
    }

    /// The sheet's way out with a room.
    func deliver(_ link: String) {
        let pending = waiter
        waiter = nil
        pending?.resume(returning: link)
    }

    /// The sheet went away: if nobody delivered a room, the answer is nil.
    func sheetDismissed() {
        let pending = waiter
        waiter = nil
        pending?.resume(returning: nil)
    }

    private func ask(reason: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            waiter = continuation
            request = Request(reason: reason)
        }
    }
}

// MARK: - The sheet

private struct MTSLessonSheetModifier: ViewModifier {
    @ObservedObject var maker: MTSLinkRoomMaker

    func body(content: Content) -> some View {
        // Full screen: the page needs all of it.
        content.fullScreenCover(item: $maker.request, onDismiss: { maker.sheetDismissed() }) { request in
            // Signing in only links the account; the window stays open for the
            // lesson, and the room goes back through `deliver`.
            MTSLinkLoginView(onSession: { session in _ = MTSLinkSessionStore().save(session) },
                             onRoom: { link in maker.deliver(link) },
                             reason: request.reason.isEmpty ? nil : request.reason)
        }
    }
}

extension View {
    /// The create-mode MTS Link sheet behind `maker` (one per surface).
    func mtsLessonSheet(_ maker: MTSLinkRoomMaker) -> some View {
        modifier(MTSLessonSheetModifier(maker: maker))
    }
}
