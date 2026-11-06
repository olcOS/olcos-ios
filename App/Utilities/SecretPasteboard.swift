import UIKit
import UniformTypeIdentifiers

// MARK: - SecretPasteboard
//
// Copies text that carries a key (connection links, device invites). The copy
// stays on this device, so Universal Clipboard does not hand it to the user's
// other Apple devices, and it expires after `lifetime`, so other apps can read
// it for a short while at most. Plain text such as room links keeps using
// `UIPasteboard.general.string`.
enum SecretPasteboard {

    /// Long enough to switch apps and paste, short enough not to linger.
    static let lifetime: TimeInterval = 10 * 60

    static func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(lifetime),
            ])
    }
}
