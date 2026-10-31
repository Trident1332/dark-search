import Foundation
import WebKit

/// The exact website range handed to Ask AI. Moving focus or selecting other
/// text never changes this target, and an edit never searches the page for it.
@MainActor
final class AISelectedText {
    let originalText: String
    private(set) var text: String
    var onReplace: ((String) -> Void)?

    private weak var web: WKWebView?
    private let id: String
    private var active = true
    private var navigation: NSKeyValueObservation?
    private static let pending = NSMapTable<WKWebView, AISelectedText>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private init(web: WKWebView, id: String, text: String) {
        self.web = web
        self.id = id
        self.originalText = text
        self.text = text
        navigation = web.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }

    /// Capture while the context menu still owns the website selection. Even
    /// an unsafe edit target can still supply a read-only quote to Ask AI.
    static func capture(in web: WKWebView) async -> (text: String, target: AISelectedText?) {
        pending.object(forKey: web)?.invalidate()
        pending.removeObject(forKey: web)
        let id = UUID().uuidString
        let script = "const quote = " + AIPage.selected + ";\n" + helpers + #"""
        if (!quote) return {text:''};
        const selection = window.getSelection();
        if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) return {text:quote};
        try {
          const range = selection.getRangeAt(0).cloneRange();
          const state = inspect(range);
          if (state.filtered !== quote) return {text:quote};
          store[id] = {range, startNode:range.startContainer, endNode:range.endContainer,
                       document, url:location.href, raw:state.raw, filtered:state.filtered, text:quote};
          return {text:quote, anchored:true};
        } catch (_) { return {text:quote}; }
        """#
        guard let result = try? await web.callAsyncJavaScript(script, arguments: ["id": id], in: nil, contentWorld: Web.world),
              let value = result as? [String: Any], let text = value["text"] as? String else { return ("", nil) }
        guard value["anchored"] as? Bool == true, !text.isEmpty, !web.isLoading else { return (text, nil) }
        let target = AISelectedText(web: web, id: id, text: text)
        pending.setObject(target, forKey: web)
        return (text, target)
    }

    /// Consume only the quote from this web view's latest context-menu
    /// capture. Equal text elsewhere never creates or substitutes a target.
    static func take(in web: WKWebView, matching text: String) -> AISelectedText? {
        guard let target = pending.object(forKey: web) else { return nil }
        pending.removeObject(forKey: web)
        guard target.active, target.originalText == text else { target.invalidate(); return nil }
        return target
    }

    func invalidate() {
        guard active else { return }
        active = false
        navigation?.invalidate()
        navigation = nil
        guard let web else { return }
        if Self.pending.object(forKey: web) === self { Self.pending.removeObject(forKey: web) }
        web.callAsyncJavaScript("delete globalThis.__searchSelectedText_v1?.[id]", arguments: ["id": id], in: nil, in: Web.world, completionHandler: { _ in })
    }

    static let definitions: [[String: Any]] = [
        ["name": "read_selected_text", "description": "Read the exact captured website selection and its current text. This target stays fixed when focus moves. It is website prose, not the tab title or Ask AI's UI.",
         "parameters": ["type": "object", "properties": [:], "additionalProperties": false]],
        ["name": "replace_selected_text", "description": "Replace only the captured website selection with plain text. Read it first and pass its exact current text as expectedText. Never substitute the document title, another occurrence, or Ask AI's context card. Returns the verified selection and unchanged current page title. The website may reset local edits on reload.",
         "parameters": ["type": "object", "properties": ["text": ["type": "string", "maxLength": 24000], "expectedText": ["type": "string", "maxLength": 24000]],
                        "required": ["text", "expectedText"], "additionalProperties": false]]
    ]

    func tool(_ name: String, arguments: [String: Any]) async -> String {
        guard active, let web, !web.isLoading else { return Self.json(["ok": false, "error": "The captured website selection is no longer available. Select the website text and choose Ask AI again."]) }
        guard name == "read_selected_text" || name == "replace_selected_text" else { return Self.json(["ok": false, "error": "Unknown selected-text tool."]) }
        var values: [String: Any] = ["id": id, "replace": name == "replace_selected_text", "replacement": "", "expected": ""]
        if name == "replace_selected_text" {
            guard let replacement = arguments["text"] as? String, replacement.utf16.count <= 24000,
                  let expected = arguments["expectedText"] as? String else {
                return Self.json(["ok": false, "error": "Replacement needs plain text (at most 24000 UTF-16 units) and the exact current expectedText."])
            }
            values["replacement"] = replacement
            values["expected"] = expected
        }
        do {
            let value = try await web.callAsyncJavaScript(Self.helpers + Self.operation, arguments: values, in: nil, contentWorld: Web.world)
            guard active else { return Self.json(["ok": false, "error": "The selection was invalidated while the operation was pending. Read fresh website state before retrying."]) }
            guard let result = value as? [String: Any] else { return Self.json(["ok": false, "error": "The selection result could not be read."]) }
            if result["invalidated"] as? Bool == true { invalidate() }
            if result["ok"] as? Bool == true, name == "replace_selected_text", let updated = result["text"] as? String {
                text = updated
                onReplace?(updated)
            }
            return Self.json(result)
        } catch {
            invalidate()
            return Self.json(["ok": false, "error": "The selected website range could not be verified. Select the text and choose Ask AI again."])
        }
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static let helpers = #"""
    const store = globalThis.__searchSelectedText_v1 ||= Object.create(null);
    const forbidden = 'input,textarea,select,option,button,iframe,frame,script,style,noscript,template,img,picture,video,audio,canvas,svg,object,embed,[contenteditable]';
    const normalized = text => text.replace(/\s+/g, ' ').trim();
    function visible(node) {
      for (let el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement, depth = 0; el; el = el.parentElement) {
        if (++depth > 64 || el.matches(forbidden) || el.hidden || el.inert || el.getAttribute('aria-hidden') === 'true') return false;
        const style = getComputedStyle(el), rect = el.getBoundingClientRect();
        if (style.display === 'none' || style.visibility !== 'visible' || parseFloat(style.opacity) < .1 ||
            style.contentVisibility === 'hidden' || parseFloat(style.fontSize) < 6 || (rect.width < 1 && rect.height < 1)) return false;
      }
      return true;
    }
    function inspect(range) {
      if (!range.startContainer.isConnected || !range.endContainer.isConnected ||
          range.startContainer.ownerDocument !== document || range.endContainer.ownerDocument !== document) throw Error('The original selection is detached.');
      if (!visible(range.startContainer) || !visible(range.endContainer)) throw Error('The selection endpoints are hidden or non-prose content.');
      const raw = range.toString();
      if (raw.length > 96000) throw Error('The original selection is too large to edit.');
      const root = range.commonAncestorContainer, walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      const parts = []; let count = 0, inspected = 0;
      for (let node = root; node; node = walker.nextNode()) {
        if (++inspected > 20000) throw Error('The selection is too complex to edit.');
        if (!range.intersectsNode(node)) continue;
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (!visible(node)) throw Error('The selection contains hidden or non-prose content.');
        } else {
          const start = node === range.startContainer ? range.startOffset : 0;
          const end = node === range.endContainer ? range.endOffset : node.length;
          const part = node.data.slice(start, end);
          if (!part) continue;
          if (!visible(node)) throw Error('The selection contains hidden or non-prose text.');
          parts.push(part); count += part.length;
          if (count > 24000) throw Error('The selection is too large to edit.');
        }
      }
      return {raw, filtered:normalized(parts.join(' '))};
    }
    function verified(record) {
      if (!record || record.document !== document || record.url !== location.href) throw Error('The selected document changed.');
      if (!record.startNode.isConnected || !record.endNode.isConnected ||
          record.range.startContainer !== record.startNode || record.range.endContainer !== record.endNode) throw Error('The original selection endpoints changed.');
      const state = inspect(record.range);
      if (state.raw !== record.raw || state.filtered !== record.filtered) throw Error('The selected website text changed.');
      return state;
    }
    """#

    private static let operation = #"""
    const record = store[id]; let mayHaveChanged = false;
    try {
      verified(record);
      if (replace) {
        if (expected !== record.text) return {ok:false, error:'expectedText does not match the captured selection. Read read_selected_text and use its exact current text.'};
        const node = document.createTextNode(replacement);
        mayHaveChanged = true;
        record.range.deleteContents(); record.range.insertNode(node);
        const anchored = document.createRange(); anchored.selectNodeContents(node);
        record.range = anchored; record.startNode = node; record.endNode = node;
        record.raw = replacement; record.filtered = normalized(replacement); record.text = replacement;
        await Promise.resolve();
        verified(record);
      }
      return {ok:true, text:record.text, title:document.title, target:'captured website selection', replaced:replace};
    } catch (error) {
      delete store[id];
      return {ok:false, invalidated:true, mayHaveChanged, error:String(error.message || error)};
    }
    """#
}
