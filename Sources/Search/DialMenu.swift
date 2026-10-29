import AppKit
import WebKit

// Call <number>, from a right-click — and otto's own click-to-call.
//
// With the dialer on (Dialer.swift), a right-click on a page is read for a
// phone number: a tel: link under the pointer, the words selected, or the
// words around the point clicked — WebKit selects the word under a
// right-click, which is one part of a number, so the run of digits around it
// is read too. Found, the menu opens with "Call 020 7946 0958" at its top,
// and choosing it hands the number to the dialer, which cleans it up and
// calls. The page says what was under the click (DialRelay's script, posted
// as the click lands, a moment before WebKit asks for its menu); Search
// decides whether it is a number (Dialer.number), and the menu asks for the
// last answer (PageView.addCallItem).
//
// Otto's pages don't right-click: they post a message to the window —
// window.postMessage({ source: "otto", type: "dial", … }) — which the
// extension's content script answered. DialerSiteRelay answers it here, on
// the sites Settings › Dialer lists, with the same replies, and hands every
// finished call back to them the same way.

// MARK: - the right-click

final class DialRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeDial"

    weak var tab: Tab?
    /// What the last right-click found, and when: the menu that follows
    /// asks for it, and nothing a second old counts.
    private var found: (number: String, at: Date)?

    /// Every frame: what is under a right-click, as it lands. A field's own
    /// selection, or the page's; a tel: link around the element; and the
    /// words around the point, from the text node under it and its parent,
    /// for a number WebKit's word selection would cut in half.
    static let watch = """
    (function () {
      if (window.__officeDial) return;
      window.__officeDial = true;
      document.addEventListener('contextmenu', function (e) {
        if (!e.isTrusted) return;
        var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeDial;
        if (!relay) return;
        var out = { selection: '', link: '', around: '', offset: -1 };
        var el = e.target;
        try {
          var a = el && el.closest ? el.closest('a[href]') : null;
          if (a) { var h = a.getAttribute('href') || ''; if (/^\\s*(tel|callto):/i.test(h)) out.link = h.slice(0, 200); }
        } catch (x) {}
        try {
          if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'password'))) {
            var from = el.selectionStart, to = el.selectionEnd;
            if (typeof from === 'number' && typeof to === 'number' && to > from) out.selection = el.value.slice(from, to).slice(0, 200);
            var value = String(el.value || ''), at = typeof from === 'number' ? from : 0, start = Math.max(0, at - 200);
            out.around = value.slice(start, at + 200); out.offset = at - start;
          } else {
            var s = document.getSelection();
            if (s && !s.isCollapsed) out.selection = s.toString().slice(0, 200);
            var r = document.caretRangeFromPoint ? document.caretRangeFromPoint(e.clientX, e.clientY) : null;
            var node = r && r.startContainer;
            if (node && node.nodeType === 3) {
              var data = node.data || '', offset = r.startOffset, text = data;
              var parent = node.parentElement, whole = parent ? String(parent.textContent || '') : '';
              if (whole && whole.length <= 2000) { var i = whole.indexOf(data); if (i >= 0) { text = whole; offset = i + offset; } }
              var begin = Math.max(0, offset - 200);
              out.around = text.slice(begin, offset + 200); out.offset = offset - begin;
            }
          }
        } catch (x) {}
        relay.postMessage(out);
      }, true);
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        let number = Dialer.number(link: body["link"] as? String ?? "", selection: body["selection"] as? String ?? "",
                                   around: body["around"] as? String ?? "", offset: body["offset"] as? Int ?? -1)
        MainActor.assumeIsolated { [weak self] in
            self?.found = number.map { ($0, Date()) }
        }
    }

    /// The number the last right-click found, for the menu it opens.
    @MainActor func take() -> String? {
        guard let found, Date().timeIntervalSince(found.at) < 2 else { return nil }
        return found.number
    }
}

extension PageView {
    /// Call <number>, at the top of the page's menu, when the right-click
    /// landed on one and the dialer is on.
    func addCallItem(to menu: NSMenu) {
        guard Shared.prefs.dialerOn, let number = dialNumber?() else { return }
        let item = NSMenuItem(title: "Call \(number)", action: #selector(callNumber(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("SearchCall")
        item.target = self
        item.representedObject = number
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func callNumber(_ item: NSMenuItem) {
        guard let number = item.representedObject as? String else { return }
        onCall?(number)
    }
}

extension Dialer {
    /// The phone number a right-click landed on, as the menu will show it:
    /// a tel: link's, the words selected, or the words around the pointer —
    /// the first that holds one. Nil when none does.
    nonisolated static func number(link: String, selection: String, around: String, offset: Int) -> String? {
        if let number = number(ofTel: link) { return number }
        if let number = number(in: selection) { return number }
        if offset >= 0, let number = number(in: around, near: offset) { return number }
        return nil
    }

    /// A tel: or callto: address's number: what is left of it after the
    /// scheme, the marks numbers are dialled with and nothing else.
    nonisolated static func number(ofTel text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"),
              ["tel", "callto"].contains(trimmed[..<colon].lowercased())
        else { return nil }
        var rest = String(trimmed[trimmed.index(after: colon)...])
        rest = rest.removingPercentEncoding ?? rest
        if let semicolon = rest.firstIndex(of: ";") { rest = String(rest[..<semicolon]) }
        let number = rest.filter { $0.isNumber || "+*#".contains($0) }
        guard number.filter(\.isNumber).count >= 3 else { return nil }
        return number
    }

    /// A phone number in some words, as written: a run of seven to fifteen
    /// digits with the spaces, dots, dashes and brackets numbers are written
    /// with, a leading + or 00 kept. Not a date, and nothing far from
    /// `near`, where given: the number has to be under the pointer.
    nonisolated static func number(in text: String, near offset: Int? = nil) -> String? {
        guard !text.isEmpty, text.count <= 1200 else { return nil }
        // ICU's own escapes: a raw string hands them over as written.
        let pattern = #"(?:\+\s?|\(\+|\()?\d[\d\s().\-\x{00a0}\x{2009}\x{2011}/]{4,28}\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let utf16Offset = offset.map { text.index(text.startIndex, offsetBy: min(max($0, 0), text.count), limitedBy: text.endIndex) ?? text.endIndex }
            .map { text.utf16.distance(from: text.utf16.startIndex, to: $0) }
        var matches: [(NSRange, String)] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            matches.append((match.range, nsText.substring(with: match.range)))
        }
        for (range, raw) in matches {
            if let utf16Offset, utf16Offset < range.location - 1 || utf16Offset > range.location + range.length + 1 { continue }
            if let number = clean(raw) { return number }
        }
        return nil
    }

    /// A run the regex found, as a number worth offering: tidied, with
    /// enough digits and not too many, and not a date in disguise.
    nonisolated private static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{2011}", with: "-")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .-/"))
        // A bracket left on its own at either end goes; a pair stays.
        if text.hasPrefix("("), !text.contains(")") { text.removeFirst() }
        if text.hasSuffix(")"), !text.contains("(") { text.removeLast() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .-/"))
        let digits = text.filter(\.isNumber).count
        guard (7...15).contains(digits) else { return nil }
        // 2026-10-29, 29/10/2026, 29.10.26: dates, not numbers.
        let dates = [#"^\d{4}[-./]\d{1,2}[-./]\d{1,2}$"#, #"^\d{1,2}[-./]\d{1,2}[-./]\d{2,4}$"#]
        if dates.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return nil }
        // A long run of digits broken only by dashes or dots and nothing a
        // number is written with — an order number, a serial — unless it
        // starts the way a phone number does.
        let separators = text.filter { !$0.isNumber && $0 != " " }
        let looksDialled = text.hasPrefix("+") || text.hasPrefix("0") || text.hasPrefix("(")
        if !looksDialled, !separators.isEmpty, !text.contains(" "), digits > 10 { return nil }
        return text
    }
}

// MARK: - otto's pages

/// The bridge otto's pages expect from the extension's content script,
/// answered by Search on the sites Settings › Dialer lists. Replies come
/// back to the script, which posts them on to the page as the extension's
/// script did; finished calls arrive through Dialer.tellSites.
final class DialerSiteRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "officeDialerSite"
    static let scriptMarker = "/* SearchDialerSiteBridge */"

    weak var tab: Tab?

    /// The main frame of a page on a listed site, ahead of its scripts: the
    /// mark otto reads to know a dialer is there, then the bridge. `hosts`
    /// contains exact origins; the label is retained for existing callers.
    /// The origin is checked here and again where the message arrives.
    static func script(hosts: [String]) -> String {
        let list = (try? JSONSerialization.data(withJSONObject: DialerOrigin.normalized(hosts))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        \(scriptMarker)
        (function () {
          var old = window.__searchDialerSite;
          if (old && typeof old.dispose === 'function') old.dispose();
          try { delete window.__searchDialerSite; document.documentElement.removeAttribute('data-otto-dialer'); } catch (e) {}
          var origins = \(list), origin = String(location.origin || '');
          if (origins.indexOf(origin) < 0) return;
          var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeDialerSite;
          if (!relay) return;
          var VERSION = 'search', active = true;
          try { document.documentElement.setAttribute('data-otto-dialer', VERSION); } catch (e) {}
          function post(msg) {
            if (!active || String(location.origin || '') !== origin) return;
            msg.source = 'otto-dialer'; window.postMessage(msg, origin);
          }
          function ready() { post({ type: 'ready', version: VERSION, features: ['calls'] }); }
          var posted = {};
          function postCalls(list, all) {
            list = Array.isArray(list) ? list : [];
            var out = [], now = {}, i, r;
            for (i = 0; i < list.length; i++) {
              r = list[i];
              if (!r || !r.id) continue;
              if (all || !posted[r.id]) out.push(r);
              now[r.id] = true;
            }
            if (all) posted = now; else for (var id in now) posted[id] = true;
            if (all || out.length) post({ type: 'calls', calls: out });
          }
          function receive(e) {
            if (!active || e.source !== window || e.origin !== origin || !e.data || e.data.source !== 'otto') return;
            var m = e.data;
            if (m.type === 'ping') { ready(); return; }
            var send = { type: m.type };
            if (m.type === 'dial') { send.number = m.number; send.name = m.name; send.ref = m.ref; }
            else if (m.type === 'getConfig' || m.type === 'setConfig') { send.config = m.config; }
            else if (m.type === 'calls-ack') { send.ids = m.ids; }
            else if (m.type !== 'calls-sync') return;
            Promise.resolve(relay.postMessage(send)).then(function (r) {
              r = r || {};
              if (m.type === 'dial') post(r.ok ? { type: 'dialing', number: r.number, mode: 'panel' }
                                             : { type: 'error', number: r.number || '', error: r.error || 'The dialer did not respond' });
              else if (m.type === 'getConfig') post({ type: 'config', reqId: m.reqId, ok: !!r.ok, config: r.config, error: r.error });
              else if (m.type === 'setConfig') post({ type: 'configSaved', reqId: m.reqId, ok: !!r.ok, error: r.error });
              else if (m.type === 'calls-sync') postCalls(r.calls, true);
            }, function (err) {
              var text = String((err && err.message) || err || 'The dialer did not respond');
              if (m.type === 'dial') post({ type: 'error', number: String(m.number || ''), error: text });
              else if (m.type === 'getConfig' || m.type === 'setConfig') post({ type: m.type === 'getConfig' ? 'config' : 'configSaved', reqId: m.reqId, ok: false, error: text });
            });
          }
          var bridge = {
            calls: function (list) { if (active) postCalls(list, false); },
            dispose: function () {
              active = false;
              window.removeEventListener('message', receive);
              if (window.__searchDialerSite === bridge) {
                delete window.__searchDialerSite;
                try { document.documentElement.removeAttribute('data-otto-dialer'); } catch (e) {}
              }
            }
          };
          window.__searchDialerSite = bridge;
          window.addEventListener('message', receive);
          ready();
        })();
        """
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, let tab, message.webView === tab.built, !tab.shy, !tab.usesTor,
                  Dialer.shared.allows(scheme: origin.protocol, host: origin.host, port: origin.port),
                  let body = message.body as? [String: Any], let type = body["type"] as? String
            else { return replyHandler(["ok": false, "error": "Not a site the dialer answers"], nil) }
            replyHandler(answer(type, body), nil)
        }
    }

    @MainActor private func answer(_ type: String, _ body: [String: Any]) -> [String: Any] {
        let dialer = Dialer.shared
        switch type {
        case "dial":
            let number = (body["number"] as? String ?? "").filter { $0.isNumber || "+*#".contains($0) }
            guard !number.isEmpty else { return ["ok": false, "error": "No number to dial"] }
            guard let tab, let browser = Browsers.all.first(where: { $0.tabs.contains { $0 === tab } })
            else { return ["ok": false, "error": "No window to call from"] }
            let name = String((body["name"] as? String ?? "").prefix(80))
            guard browser.call(number, name: name, ref: Dialer.cleanRef(body["ref"])) else {
                return ["ok": false, "error": dialer.blockedReason ?? "The dialer is unavailable"]
            }
            return ["ok": true, "number": number, "mode": "panel"]
        case "getConfig":
            return ["ok": true, "config": dialer.configForSites()]
        case "setConfig":
            dialer.takeConfig(body["config"] as? [String: Any] ?? [:])
            return ["ok": true]
        case "calls-sync":
            return ["ok": true, "calls": dialer.outbox]
        case "calls-ack":
            return ["ok": true, "pending": dialer.ackCalls((body["ids"] as? [Any] ?? []).map { "\($0)" })]
        default:
            return ["ok": false, "error": "Unknown request"]
        }
    }
}
