import Foundation

// MARK: - DirectRoutes
//
// Which destinations skip the tunnel when Routing is set to the list. The
// ready-made list holds Russian sites: the country's own domain zones, and the
// Russian services that also live on other zones. The user adds their own:
// a site, a link, an address or a network, one per line. Everything reaches
// the engines as one text in the olcrtc core's direct-list syntax —
// `domain:<name>` for a site and everything under it, `full:<name>`, an
// address or a CIDR prefix — which the core, the bond client and Xray all
// read. Sites off the list keep going through the tunnel.

enum DirectRoutes {
    /// The ready-made list of Russian sites.
    static let russian: [String] = [
        // The zones: .ru, .su, .рф, .дети, .москва, .рус, .онлайн, .сайт, .орг
        "domain:ru", "domain:su", "domain:xn--p1ai", "domain:xn--d1acj3b", "domain:xn--80adxhks",
        "domain:xn--p1acf", "domain:xn--80asehdb", "domain:xn--80aswg", "domain:xn--c1avg",
        // Yandex
        "domain:yandex.com", "domain:yandex.net", "domain:yastatic.net", "domain:yandex.cloud",
        "domain:yandexcloud.net",
        // VK, Odnoklassniki, Mail
        "domain:vk.com", "domain:vk.me", "domain:vk.link", "domain:vk.cc", "domain:vkuser.net",
        "domain:vkuseraudio.net", "domain:vkuservideo.net", "domain:userapi.com", "domain:vk-cdn.net",
        "domain:vk-portal.net", "domain:mycdn.me", "domain:ok.me",
        // 2GIS, Wildberries, Avito
        "domain:2gis.com", "domain:wbstatic.net", "domain:avito.st",
    ]

    /// PURE. The text the engines take; empty when everything goes through the tunnel.
    static func effective(mode: RoutingMode, russian useRussian: Bool, own: String) -> String {
        guard mode == .listDirect else { return "" }
        var rules = useRussian ? russian : []
        for rule in parse(own).rules where !rules.contains(rule) {
            rules.append(rule)
        }
        return rules.joined(separator: "\n")
    }

    struct Parsed: Equatable {
        /// Every line understood, in the core's syntax.
        var rules: [String]
        /// The first line that is neither a site nor an address (1-based).
        var badLine: Int?
    }

    /// PURE. The user's own lines in the core's syntax. A bare site or a link
    /// stands for the site and everything under it; `*.` is the same; the
    /// core's own `domain:` and `full:` forms, addresses and networks pass as
    /// written. Blank lines and `#` notes are skipped.
    static func parse(_ text: String) -> Parsed {
        var out = Parsed(rules: [], badLine: nil)
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let rule = rule(line) {
                out.rules.append(rule)
            } else if out.badLine == nil {
                out.badLine = index + 1
            }
        }
        return out
    }

    private static func rule(_ line: String) -> String? {
        let lower = line.lowercased()
        for prefix in ["domain:", "full:"] where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count))
            return isName(name) ? prefix + trimmedName(name) : nil
        }
        if isAddressOrNetwork(lower) { return lower }
        var name = lower
        if let url = URL(string: lower), let host = url.host, url.scheme != nil {
            name = host
        }
        if name.hasPrefix("*.") { name.removeFirst(2) }
        return isName(name) ? "domain:" + trimmedName(name) : nil
    }

    private static func trimmedName(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// An ASCII host name: letters, digits, hyphens, at least one dot or a
    /// whole zone, no empty label.
    private static func isName(_ raw: String) -> Bool {
        let name = trimmedName(raw)
        guard !name.isEmpty, name.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// An IPv4 or IPv6 address, optionally with a prefix length.
    private static func isAddressOrNetwork(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let address = parts.first.map(String.init), !address.isEmpty else { return false }
        let isV4 = isIPv4(address)
        let isV6 = !isV4 && isIPv6(address)
        guard isV4 || isV6 else { return false }
        guard parts.count == 2 else { return true }
        guard let bits = Int(parts[1]) else { return false }
        return (0...(isV4 ? 32 : 128)).contains(bits)
    }

    private static func isIPv4(_ text: String) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255
        }
    }

    private static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":") else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }
}
