import Foundation

/// A stable, per-install identity for the carrier room.
///
/// The Go CLI (`internal/client/client.go`, `resolveDeviceID`) never sends the
/// literal `default`: when no device id is configured it generates a UUID once
/// and persists it, so two installs never share one identity. The app kept the
/// literal `default` in every record and — worse — in every shared link, so a
/// phone that scanned a QR code entered the room under the SAME identity as the
/// phone that produced it. The server logs this as
/// `Current peers count: 2, Devices: [default, default]`, followed by one of the
/// two sessions going silent (`control missed pong` → `reason=liveness`).
///
/// `default` therefore stays a *placeholder* in the record (so shares and QR
/// codes remain identical for every device), and is replaced by this install's
/// own name at the moment the engine is configured. A clientID the user typed
/// deliberately is passed through untouched.
///
/// The name is two words and a number — `quiet-harbor-42` — so a server log
/// or a peer list reads like a roster rather than a hex dump. It is drawn from
/// fixed word lists and a random number: nothing about the phone (model, owner,
/// locale) goes into it, and it can be re-rolled from Settings at any time.
///
/// Not a secret: it is a random label visible to the server, comparable to the
/// `olc-ping-XXXXXXXX` ids batch pings already send. Hence UserDefaults.
enum DeviceIdentity {

    /// The record-level placeholder meaning "let this install pick its own id".
    static let placeholder = "default"

    static let storageKey = "olcrtc_device_id"

    /// Posted after `regenerate` so any view showing the name refreshes.
    static let didChange = Notification.Name("DeviceIdentity.didChange")

    /// This install's name, generated on first use and persisted.
    static func current(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: storageKey), isWellFormed(saved) {
            return saved
        }
        let fresh = make()
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }

    /// Draws a new name, persists it and returns it. Takes effect on the next
    /// connect / probe; a live session keeps the name it announced.
    @discardableResult
    static func regenerate(defaults: UserDefaults = .standard) -> String {
        let previous = defaults.string(forKey: storageKey)
        var fresh = make()
        while fresh == previous { fresh = make() }
        defaults.set(fresh, forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
        return fresh
    }

    /// `adjective-noun-NN`. Pure given its generator, so tests can pin a value.
    static func make<G: RandomNumberGenerator>(using rng: inout G) -> String {
        let adjective = adjectives.randomElement(using: &rng)!
        let noun = nouns.randomElement(using: &rng)!
        let number = Int.random(in: 10...99, using: &rng)
        return "\(adjective)-\(noun)-\(number)"
    }

    static func make() -> String {
        var rng = SystemRandomNumberGenerator()
        return make(using: &rng)
    }

    /// Whether a stored value is one of ours, so a corrupted or foreign value
    /// (including an old-format id) is regenerated rather than sent as-is.
    static func isWellFormed(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              adjectives.contains(String(parts[0])),
              nouns.contains(String(parts[1])),
              parts[2].count == 2, parts[2].allSatisfy(\.isNumber)
        else { return false }
        return true
    }

    /// The id the engine should announce for a record's `clientID`: the
    /// install's own name for the placeholder (or an empty value); for a device
    /// invite's id the invite AND the install's name, `inv-1a2b3c4d-quiet-harbor-42`;
    /// the user's explicit id otherwise. Every engine entry point reaches this
    /// through `resolving`, so the tunnel, the VPN extension's config, checks
    /// and pings all announce the same id.
    static func effectiveClientID(_ raw: String, deviceID: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == placeholder { return deviceID }
        // Several installs may take one invite (a family's phones, a
        // reinstall); one shared identity is the `[x, x]` collision the server
        // punishes, so each keeps the invite and adds its own name.
        if isInviteClientID(trimmed) { return "\(trimmed)-\(deviceID)" }
        return trimmed
    }

    // MARK: Invite identities
    //
    // A device invite's list gives every olcrtc link the clientID `inv-<tag>`
    // (DeviceInvite.tag), so the owner's server agent can tell which invite a
    // session came in on (Devices screen). The Android app composes the
    // announced id the same way.

    static let invitePrefix = "inv-"

    /// `inv-<tag>`: the clientID an invite's list puts on its links.
    static func inviteClientID(tag: String) -> String { invitePrefix + tag }

    /// Whether `clientID` is exactly `inv-` and 8 lowercase hex digits (ASCII
    /// only: `isHexDigit` would also take uppercase and fullwidth forms).
    static func isInviteClientID(_ clientID: String) -> Bool {
        guard clientID.hasPrefix(invitePrefix) else { return false }
        let tag = clientID.utf8.dropFirst(invitePrefix.utf8.count)
        return tag.count == 8 && tag.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// A copy of `params` with the placeholder resolved. Every engine entry
    /// point (start / check / ping / VPN config) goes through this, so the
    /// stored record and its shares keep the placeholder.
    static func resolving(_ params: OlcrtcConnection,
                          deviceID: String = current()) -> OlcrtcConnection {
        var p = params
        p.clientID = effectiveClientID(params.clientID, deviceID: deviceID)
        return p
    }

    // MARK: Word lists
    //
    // Neutral, lowercase ASCII, no brands, no device or people words, nothing
    // that reads as a location of the user. 64 × 64 × 90 ≈ 369k names.

    static let adjectives: [String] = [
        "amber", "arctic", "bold", "brave", "bright", "brisk", "calm", "candid",
        "cedar", "civil", "clear", "clever", "cobalt", "cool", "coral", "crisp",
        "deep", "eager", "early", "even", "fair", "fleet", "fond", "frank",
        "gentle", "glad", "golden", "grand", "hardy", "hazel", "humble", "ivory",
        "jade", "keen", "kind", "light", "lively", "lucid", "lunar", "mellow",
        "merry", "mild", "modest", "noble", "olive", "opal", "pale", "plain",
        "proud", "quick", "quiet", "rapid", "rustic", "sage", "silver", "sleek",
        "steady", "still", "swift", "tidy", "true", "vivid", "warm", "wise",
    ]

    static let nouns: [String] = [
        "anchor", "arch", "aspen", "atlas", "beacon", "birch", "bridge", "brook",
        "canyon", "cedar", "cliff", "cloud", "comet", "compass", "coral", "crane",
        "creek", "delta", "dune", "ember", "falcon", "fern", "field", "fjord",
        "forge", "glade", "grove", "harbor", "heron", "island", "juniper", "lagoon",
        "lantern", "lark", "ledge", "lotus", "maple", "meadow", "meridian", "mesa",
        "orbit", "orchid", "otter", "pebble", "pine", "prairie", "quartz", "reef",
        "ridge", "river", "sail", "sequoia", "shore", "signal", "sparrow", "spruce",
        "summit", "thistle", "tide", "trail", "valley", "willow", "yarrow", "zenith",
    ]
}
