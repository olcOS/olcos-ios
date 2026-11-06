import Foundation

// MARK: - RetiredFullAccessLink
//
// Older versions could share a server's SSH login as `olcrtc://host/v1/<blob>`.
// That link is no longer imported: a device invite with management access moves
// a server to another phone through its agent instead. Only the shape is still
// recognised, so an old link opened or pasted gets one line of explanation
// rather than being read as a connection.

enum RetiredFullAccessLink {
    /// A connection link's authority is a carrier followed by `?`; this one's is `host/`.
    static let prefix = "olcrtc://host/"

    static func matches(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(prefix)
    }

    /// The line shown in place of an import.
    static var notice: String { L10n.fullAccessLinkRetired.localized() }
}
