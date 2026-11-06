import Foundation

// MARK: - MTSLinkDesktop
//
// The MTS Link pages are built for a desktop browser: on a phone the site hides
// or breaks buttons such as "Quick meeting". The sign-in sheet
// (MTSLinkLoginView) and the offscreen replay page (MTSLinkReplay) therefore
// present themselves as desktop Chrome on Windows: the user agent
// (`MTSLinkRoomService.desktopUserAgent`), the desktop content mode, and the
// script below, which hides the touch screen from the page. The pure decisions
// of the sheet's navigation live here too, so they are testable without a web
// view.
enum MTSLinkDesktop {

    /// What to do with a navigation the page asked for.
    enum LinkDecision: Equatable {
        case allow
        /// Cancel it; the payload names the scheme (or `app-store`) for the log.
        case blocked(String)
    }

    private static let webSchemes: Set<String> = ["http", "https"]
    /// Schemes that render inside the page and never leave it.
    private static let inPageSchemes: Set<String> = ["about", "blob", "data", "javascript"]
    private static let storeHosts: [String] = ["apps.apple.com", "itunes.apple.com", "appstore.com"]

    /// PURE. Whether the web view may follow `url`. Anything that is not a web
    /// address (`mtslink:`, `intent:`, `itms-apps:`, `tel:`, …) and the app
    /// stores' pages are links to an app the sheet cannot open.
    static func decide(_ url: URL?) -> LinkDecision {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .allow }
        if webSchemes.contains(scheme) {
            return isStorePage(url) ? .blocked("app-store") : .allow
        }
        if inPageSchemes.contains(scheme) { return .allow }
        return .blocked(scheme)
    }

    private static func isStorePage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        for store in storeHosts where host == store || host.hasSuffix("." + store) { return true }
        return host == "play.google.com" && url.path.lowercased().hasPrefix("/store")
    }

    /// PURE. Whether a window the page opened is loaded into the same web view:
    /// only web addresses are (`window.open("")` is `about:blank`, and loading
    /// that would blank the page it was opened from).
    static func opensInSameView(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return webSchemes.contains(scheme)
    }

    /// PURE. The address for the log: scheme, host and path, never the query,
    /// the fragment or credentials. A non-web address shows its scheme only.
    static func loggable(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return "(no address)" }
        guard webSchemes.contains(scheme), let host = url.host, !host.isEmpty else { return scheme + ":" }
        return scheme + "://" + host + url.path
    }

    /// PURE. The log line for a cancelled link.
    static func blockedLine(_ label: String) -> String {
        "blocked \(label) link (the site wanted the MTS Link app)"
    }

    /// PURE. The log line for a window the page opened.
    static func newWindowLine(_ url: URL?) -> String {
        "new window → same view: " + loggable(url)
    }

    /// Injected at document start into every frame of the sheet and of the
    /// replay page. Every step is guarded: the page must never break because of
    /// it. Media queries are rewritten rather than answered by hand, so compound
    /// queries and change listeners keep working; style sheets are out of its
    /// reach.
    static let shimScript = #"""
    (function() {
        try {
            if (window.__olcDesktop) { return; }
            window.__olcDesktop = true;

            function define(target, name, value) {
                try {
                    Object.defineProperty(target, name, { get: function() { return value; }, configurable: true });
                } catch (e) {}
            }
            try {
                define(Navigator.prototype, "maxTouchPoints", 0);
                define(Navigator.prototype, "platform", "Win32");
            } catch (e) {}
            try {
                define(navigator, "maxTouchPoints", 0);
                define(navigator, "platform", "Win32");
            } catch (e) {}

            try {
                var handlers = ["ontouchstart", "ontouchmove", "ontouchend"];
                var targets = [window];
                if (typeof Window !== "undefined") { targets.push(Window.prototype); }
                if (typeof Document !== "undefined") { targets.push(Document.prototype); }
                if (typeof HTMLElement !== "undefined") { targets.push(HTMLElement.prototype); }
                targets.forEach(function(target) {
                    handlers.forEach(function(name) {
                        try {
                            var descriptor = Object.getOwnPropertyDescriptor(target, name);
                            if (descriptor && descriptor.configurable) { delete target[name]; }
                        } catch (e) {}
                    });
                });
            } catch (e) {}

            try {
                var realMatchMedia = window.matchMedia;
                if (typeof realMatchMedia === "function") {
                    var NO = /\(\s*(?:any-)?pointer\s*:\s*coarse\s*\)|\(\s*(?:any-)?hover\s*:\s*none\s*\)/gi;
                    var YES = /\(\s*(?:any-)?pointer\s*:\s*fine\s*\)|\(\s*(?:any-)?hover\s*:\s*hover\s*\)/gi;
                    window.matchMedia = function(query) {
                        var rewritten = query;
                        try {
                            rewritten = String(query).replace(NO, "(min-width: 100000px)").replace(YES, "(min-width: 0px)");
                        } catch (e) {}
                        return realMatchMedia.call(window, rewritten);
                    };
                }
            } catch (e) {}
        } catch (e) {}
    })();
    """#
}
