import Foundation

// MARK: - MTSLinkHook
//
// The page-side script of the sign-in sheet (MTSLinkLoginView) and of the
// offscreen page a silent replay runs in (MTSLinkReplay). It is a watcher,
// never a proxy: every call still runs exactly as the page made it.
//
// It reports to the `olcCapture` message handler, one message per event:
//
//   { kind: "req",  id, method, url, headers, body, tpl, status, response }
//       one fetch / XHR with its answer (first 16 KB). The VALUE of every
//       credential-named header is replaced IN the page by a provenance marker
//       (MTSLinkProvenance) — only the name and where the value lives leave it.
//       `body` is a text rendition for the (scrubbed) list. `tpl` (POST / PUT /
//       PATCH only) is the request as the page sent it, the source of a
//       template: `{url, kind, text, fields, why}` where kind is none | text |
//       json | urlencoded | formdata | unsupported (`why` says what: a file
//       part, a Blob, …). A value equal to a cookie / localStorage /
//       sessionStorage item is replaced IN the page by a marker:
//       `olc:KIND:NAME` as a whole field value, `<<olc:KIND:NAME>>` inside a
//       string or the URL (`;enc` before `>>` for a URL-encoded occurrence).
//       Nothing else is rewritten.
//   { kind: "nav",  url }      the page's address changed (also pushState / popstate)
//   { kind: "page", links }    the meeting links the page shows, when they change
//
// And it keeps, in page memory only, the latest value of every credential-named
// header the page itself sent: `window.__olcosSeen[<lower-case name>]`. A replay
// reads those to rebuild the headers of a learned request.
enum MTSLinkHook {

    static let messageHandler = "olcCapture"

    static let script = #"""
    (function() {
        if (window.__olcCapture) { return; }
        window.__olcCapture = true;
        window.__olcosSeen = window.__olcosSeen || {};
        var CRED_NAME = /auth|token|csrf|xsrf|api[-_]?key|secret|session/i;
        var SKIP = { "cookie": 1, "set-cookie": 1, "host": 1, "content-length": 1, "connection": 1,
                     "accept-encoding": 1, "user-agent": 1, "origin": 1, "referer": 1 };
        var LIMIT = 16384;
        var seq = 0;

        function post(message) {
            try { window.webkit.messageHandlers.olcCapture.postMessage(message); } catch (e) {}
        }
        function abs(u) {
            try { return new URL(String(u), location.href).href; } catch (e) { return String(u || ""); }
        }
        function cookies() {
            var out = {};
            try {
                document.cookie.split(";").forEach(function(p) {
                    var i = p.indexOf("=");
                    if (i > 0) { out[p.slice(0, i).trim()] = p.slice(i + 1).trim(); }
                });
            } catch (e) {}
            return out;
        }
        function decoded(v) {
            try { return decodeURIComponent(v); } catch (e) { return v; }
        }
        function isCredential(name, value) {
            return CRED_NAME.test(name) || /^(Bearer\s+)?eyJ/.test(String(value));
        }
        function provenance(name, value) {
            var raw = String(value);
            var bearer = false;
            var m = /^Bearer\s+(.+)$/i.exec(raw);
            if (m) { bearer = true; raw = m[1]; }
            var tag = bearer ? "+bearer" : "";
            if (raw) {
                var jar = cookies();
                for (var k in jar) {
                    if (jar[k] === raw || decoded(jar[k]) === raw) { return "olc:cookie" + tag + ":" + k; }
                }
                var stores = [["local", "localStorage"], ["session", "sessionStorage"]];
                for (var s = 0; s < stores.length; s++) {
                    try {
                        var st = window[stores[s][1]];
                        for (var i = 0; i < st.length; i++) {
                            var key = st.key(i);
                            if (st.getItem(key) === raw) { return "olc:" + stores[s][0] + tag + ":" + key; }
                        }
                    } catch (e) {}
                }
            }
            return "olc:seen" + tag + ":" + name;
        }
        function headerMap(src) {
            var out = {};
            try {
                if (!src) { return out; }
                if (Array.isArray(src)) {
                    src.forEach(function(p) { if (p && p.length >= 2) { out[p[0]] = p[1]; } });
                } else if (typeof src.forEach === "function") {
                    src.forEach(function(v, k) { out[k] = v; });
                } else {
                    for (var k in src) { if (Object.prototype.hasOwnProperty.call(src, k)) { out[k] = src[k]; } }
                }
            } catch (e) {}
            return out;
        }
        function scrubHeaders(raw) {
            var out = {};
            for (var name in raw) {
                if (!Object.prototype.hasOwnProperty.call(raw, name)) { continue; }
                if (SKIP[name.toLowerCase()]) { continue; }
                var value = raw[name];
                if (isCredential(name, value)) {
                    try { window.__olcosSeen[name.toLowerCase()] = String(value); } catch (e) {}
                    out[name] = provenance(name, value);
                } else {
                    out[name] = String(value);
                }
            }
            return out;
        }
        // Values of the page's cookies and storages that a request may carry.
        var MIN_FIELD = 8;
        var MIN_TEXT = 16;
        function secrets() {
            var list = [];
            function add(v, kind, name) {
                if (typeof v === "string" && v.length >= MIN_FIELD) { list.push({ v: v, kind: kind, name: name }); }
            }
            var jar = cookies();
            for (var k in jar) { add(jar[k], "cookie", k); }
            var stores = [["local", "localStorage"], ["session", "sessionStorage"]];
            for (var s = 0; s < stores.length; s++) {
                try {
                    var st = window[stores[s][1]];
                    for (var i = 0; i < st.length; i++) { var key = st.key(i); add(st.getItem(key), stores[s][0], key); }
                } catch (e) {}
            }
            return list;
        }
        function fieldValue(v, list) {
            for (var i = 0; i < list.length; i++) {
                if (list[i].v === v) { return "olc:" + list[i].kind + ":" + list[i].name; }
            }
            return v;
        }
        function textReplace(text, list) {
            var long = list.filter(function(x) { return x.v.length >= MIN_TEXT; })
                           .sort(function(a, b) { return b.v.length - a.v.length; });
            for (var i = 0; i < long.length; i++) {
                var s = long[i];
                var tag = "olc:" + s.kind + ":" + s.name;
                text = text.split(s.v).join("<<" + tag + ">>");
                var enc = encodeURIComponent(s.v);
                if (enc !== s.v) { text = text.split(enc).join("<<" + tag + ";enc>>"); }
            }
            return text;
        }
        function jsonReplace(text, list) {
            var parsed;
            try { parsed = JSON.parse(text); } catch (e) { return null; }
            if (parsed === null || typeof parsed !== "object") { return null; }
            var hits = {};
            (function walk(n) {
                if (typeof n === "string") {
                    for (var i = 0; i < list.length; i++) { if (list[i].v === n) { hits[n] = list[i]; break; } }
                } else if (Array.isArray(n)) {
                    n.forEach(walk);
                } else if (n && typeof n === "object") {
                    Object.keys(n).forEach(function(k) { walk(n[k]); });
                }
            })(parsed);
            var out = text;
            Object.keys(hits).forEach(function(v) {
                var h = hits[v];
                out = out.split(JSON.stringify(v)).join(JSON.stringify("<<olc:" + h.kind + ":" + h.name + ">>"));
            });
            return textReplace(out, list);
        }
        // What the page sent as a body: a text rendition for the list, and the
        // template copy with its kind.
        function describeBody(b, list) {
            try {
                if (b === null || b === undefined) { return { display: "", kind: "none" }; }
                if (typeof b === "string") {
                    var asJson = jsonReplace(b, list);
                    if (asJson !== null) { return { display: b, kind: "json", text: asJson }; }
                    return { display: b, kind: "text", text: textReplace(b, list) };
                }
                if (typeof URLSearchParams !== "undefined" && b instanceof URLSearchParams) {
                    var pairs = [];
                    b.forEach(function(v, k) { pairs.push([k, fieldValue(v, list)]); });
                    return { display: b.toString(), kind: "urlencoded", fields: pairs };
                }
                if (typeof FormData !== "undefined" && b instanceof FormData) {
                    var fields = [];
                    var shown = [];
                    var why = null;
                    b.forEach(function(v, k) {
                        if (typeof v === "string") { fields.push([k, fieldValue(v, list)]); shown.push(k + "=" + v); }
                        else { why = "a file part in the form"; shown.push(k + "=[file]"); }
                    });
                    return { display: shown.join("&"), kind: why ? "unsupported" : "formdata", fields: fields, why: why };
                }
                if (typeof Blob !== "undefined" && b instanceof Blob) { return { display: "[blob]", kind: "unsupported", why: "a Blob body" }; }
                if ((typeof ArrayBuffer !== "undefined") && (b instanceof ArrayBuffer || ArrayBuffer.isView(b))) {
                    return { display: "[binary]", kind: "unsupported", why: "a binary body" };
                }
                if (typeof ReadableStream !== "undefined" && b instanceof ReadableStream) {
                    return { display: "[stream]", kind: "unsupported", why: "a stream body" };
                }
                return { display: String(b), kind: "unsupported", why: "a body of an unsupported kind" };
            } catch (e) { return { display: "", kind: "unsupported", why: "a body the page hook could not read" }; }
        }
        // The call as reported: `tpl` only for requests that change something.
        function callInfo(id, method, url, rawHeaders, body, bodyWhy) {
            var info = { id: id, method: method, url: url, headers: scrubHeaders(rawHeaders), body: "", tpl: null };
            var list = secrets();
            var described = bodyWhy ? { display: "[" + bodyWhy + "]", kind: "unsupported", why: bodyWhy }
                                    : describeBody(body, list);
            info.body = described.display;
            if (method === "POST" || method === "PUT" || method === "PATCH") {
                info.tpl = { url: textReplace(url, list), kind: described.kind, text: described.text,
                             fields: described.fields, why: described.why };
            }
            return info;
        }
        function reportCall(info, status, text) {
            post({ kind: "req", id: info.id, method: info.method, url: info.url,
                   headers: info.headers, body: info.body, tpl: info.tpl,
                   status: status || 0, response: String(text || "").slice(0, LIMIT) });
        }

        var realFetch = window.fetch;
        if (realFetch) {
            window.fetch = function(input, init) {
                var info = null;
                try {
                    var isRequest = (typeof Request !== "undefined") && (input instanceof Request);
                    var method = String((init && init.method) || (isRequest && input.method) || "GET").toUpperCase();
                    var rawHeaders = headerMap(init && init.headers ? init.headers : (isRequest ? input.headers : null));
                    var hasInitBody = init && init.body !== undefined && init.body !== null;
                    var whyUnreadable = (isRequest && !hasInitBody && input.body) ? "a Request object's body" : null;
                    info = callInfo(++seq, method, abs(isRequest ? input.url : input), rawHeaders,
                                    hasInitBody ? init.body : null, whyUnreadable);
                } catch (e) { info = null; }
                var result = realFetch.apply(this, arguments);
                if (!info) { return result; }
                return result.then(function(resp) {
                    try {
                        resp.clone().text().then(
                            function(text) { reportCall(info, resp.status, text); },
                            function() { reportCall(info, resp.status, ""); });
                    } catch (e) { reportCall(info, resp.status, ""); }
                    return resp;
                }, function(err) {
                    reportCall(info, 0, "");
                    throw err;
                });
            };
        }

        var xhrOpen = XMLHttpRequest.prototype.open;
        var xhrSend = XMLHttpRequest.prototype.send;
        var xhrHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.open = function(method, url) {
            try { this.__olc = { method: String(method || "GET").toUpperCase(), url: abs(url), raw: {} }; } catch (e) {}
            return xhrOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            try { if (this.__olc) { this.__olc.raw[name] = value; } } catch (e) {}
            return xhrHeader.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(body) {
            try {
                var self = this;
                var o = this.__olc;
                if (o) {
                    var info = callInfo(++seq, o.method, o.url, o.raw, body, null);
                    this.addEventListener("loadend", function() {
                        var text = "";
                        try {
                            if (self.responseType === "" || self.responseType === "text") { text = self.responseText || ""; }
                        } catch (e) {}
                        reportCall(info, self.status, text);
                    });
                }
            } catch (e) {}
            return xhrSend.apply(this, arguments);
        };

        if (window === window.top) {
            var lastHref = "";
            var nav = function() {
                var h = location.href;
                if (h !== lastHref) { lastHref = h; post({ kind: "nav", url: h }); }
            };
            ["pushState", "replaceState"].forEach(function(fn) {
                var real = history[fn];
                if (!real) { return; }
                history[fn] = function() {
                    var r = real.apply(this, arguments);
                    setTimeout(nav, 0);
                    return r;
                };
            });
            window.addEventListener("popstate", nav);
            window.addEventListener("hashchange", nav);
            setInterval(nav, 500);
            nav();

            var JOIN = /(?:https?:\/\/)?(?:my\.)?mts-link\.ru\/j\/[A-Za-z0-9_\-]+\/[A-Za-z0-9_\-]+/gi;
            var lastLinks = null;
            setInterval(function() {
                try {
                    var found = [];
                    var anchors = document.querySelectorAll("a[href]");
                    for (var i = 0; i < anchors.length && found.length < 60; i++) {
                        var h = anchors[i].href || "";
                        if (/mts-link\.ru\/j\//i.test(h)) { found.push(h); }
                    }
                    var text = document.body ? document.body.innerText : "";
                    if (text && text.length < 200000) {
                        var m = text.match(JOIN) || [];
                        for (var j = 0; j < m.length && found.length < 60; j++) { found.push(m[j]); }
                    }
                    var key = found.join("\n");
                    if (key !== lastLinks) { lastLinks = key; post({ kind: "page", links: found }); }
                } catch (e) {}
            }, 1500);
        }
    })();
    """#
}
