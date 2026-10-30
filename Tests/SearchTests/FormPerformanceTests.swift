import AppKit
import WebKit
import XCTest
@testable import Search

/// Only synthetic chat content is loaded. Instrument the script's isolated
/// world, so page rendering and unrelated WebKit work cannot count as a
/// browser-injected geometry read or form query.
@MainActor
final class FormPerformanceTests: XCTestCase {
    private var views: [WKWebView] = []
    private var holding: [AnyObject] = []
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "form-performance-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        try await super.setUp()
    }

    override func tearDown() async throws {
        for web in views {
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: FormRelay.name, contentWorld: Web.world)
            ProxyTimeZone.close(web)
        }
        views.removeAll()
        holding.removeAll()
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    func testUnrelatedChatAnimationAndScrollDoNotForceFormLayoutOrFocusMessages() async throws {
        let actual = try await page(script: FormRelay.script)
        // Let the real 700/2200 ms startup probes finish before measurement.
        // The offscreen views deliberately never become live browser tabs.
        try await Task.sleep(for: .milliseconds(3_500))
        let mutations = try await exercise(actual, scrolling: false)
        let scroll = try await exercise(actual, scrolling: true)
        try record(["actual-mutations": mutations, "actual-scroll": scroll])
        quiet(mutations, frames: 0)
        quiet(scroll, frames: 32)
    }

    func testChatFrameWithHiddenHeaderLoginDoesNotForceLayoutEachScrollFrame() async throws {
        let fixture = try await page(script: FormRelay.script, framed: true, hiddenLogin: true)
        try await Task.sleep(for: .milliseconds(3_500))
        let metrics = try await exercise(fixture, scrolling: true)
        try record(["iframe-hidden-login-scroll": metrics])
        quiet(metrics, frames: 32)
    }

    func testSameOriginFrameLeafFocusChangeRechecksTypingOnScroll() async throws {
        // Only the parent gets Forms here, isolating editable()'s recursive
        // frame path from a child's own independent focus notifications.
        let fixture = try await page(script: FormRelay.script, framed: true, formsInChild: false)
        fixture.messages.focus = 0
        let changed = try await call(fixture.web, """
        var child = document.getElementById('chat').contentDocument;
        child.getElementById('other').focus();
        window.dispatchEvent(new Event('scroll'));
        window.__formPerformance.frame();
        return { outer: document.activeElement.id, inner: child.activeElement.id };
        """)
        let focus = try XCTUnwrap(changed as? [String: String])
        XCTAssertEqual(focus["outer"], "chat")
        XCTAssertEqual(focus["inner"], "other")
        try await until { fixture.messages.focus > 0 && !fixture.messages.typing }
    }

    func testResizeRevalidatesOrdinaryEditorVisibilityWithoutDOMMutation() async throws {
        let fixture = try await page(script: FormRelay.script)
        fixture.messages.focus = 0
        // CSSOM changes do not deliver MutationObserver records. This is
        // the same availability change a responsive media query can make.
        try await call(fixture.web, """
        document.styleSheets[0].insertRule('textarea { display: none !important; }', 0);
        window.dispatchEvent(new Event('resize'));
        window.__formPerformance.frame();
        return true;
        """)
        try await until { fixture.messages.focus > 0 && !fixture.messages.typing }
    }

    func testMessageInputClassificationRejectsBeforeGeometry() async throws {
        let fixture = try await page(script: FormRelay.script, inputComposer: true)
        let metrics = try await call(fixture.web, """
        window.__formPerformance.reset();
        for (var i = 0; i < 40; i++) {
          if (window.__officeForms.verdict(document.getElementById('message')) !== null) throw Error('Composer classified as login');
        }
        return window.__formPerformance.snapshot();
        """)
        let measured = try XCTUnwrap(metrics as? [String: Any])
        XCTAssertEqual(number(measured, "rects"), 0)
        XCTAssertEqual(number(measured, "styles"), 0)
        XCTAssertEqual(number(measured, "passwordQueries"), 0)
    }

    private func quiet(_ metrics: [String: Any], frames: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(number(metrics, "passwordQueries"), 0, "Animation must reuse password discovery", file: file, line: line)
        XCTAssertEqual(number(metrics, "focusMessages"), 0, "Unchanged passive focus must stay quiet", file: file, line: line)
        XCTAssertEqual(number(metrics, "framesRun"), frames, "The real scroll callbacks must run", file: file, line: line)
        XCTAssertEqual(number(metrics, "frameRects"), 0, "Ordinary chat focus needs no per-scroll geometry", file: file, line: line)
        XCTAssertEqual(number(metrics, "frameStyles"), 0, "Ordinary chat focus needs no per-scroll computed styles", file: file, line: line)
        // Debounced availability checks deliberately remain: sibling CSS
        // can hide a focused editor or reveal an existing password stage.
        // Their count depends on elapsed real time; frame reads do not.
    }

    private func record(_ metrics: [String: [String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("FORM_PERFORMANCE " + String(decoding: data, as: UTF8.self))
    }

    private struct Fixture {
        let web: WKWebView
        let messages: Messages
    }

    private func page(script: String, framed: Bool = false, hiddenLogin: Bool = false, formsInChild: Bool = false, inputComposer: Bool = false) async throws -> Fixture {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let messages = Messages()
        configuration.userContentController.add(messages, contentWorld: Web.world, name: FormRelay.name)
        configuration.userContentController.addUserScript(WKUserScript(source: Self.instrumentation,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world))
        configuration.userContentController.addUserScript(WKUserScript(source: script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: !formsInChild, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: configuration)
        let loaded = Loaded()
        web.navigationDelegate = loaded
        views.append(web)
        holding += [messages, loaded]
        let nodes = (0..<5_000).map { "<span>synthetic message \($0)</span>" }.joined()
        let editor = inputComposer ? "<input id='message' aria-label='Support message'>" : "<textarea id='message' aria-label='Support message'></textarea>"
        let chat = """
        <!doctype html><style>
        #transcript { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); width: 860px; gap: 3px; }
        #transcript span { display: block; padding: 3px; border: 1px solid #777; }
        textarea { width: 500px; height: 45px; }
        </style><div id='transcript'>\(nodes)</div>\(editor)<button id='other'>Close</button>
        """
        let header = hiddenLogin ? "<form hidden><input autocomplete='username'><input type='password' autocomplete='current-password'></form>" : ""
        let escaped = chat.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let content = framed ? "<!doctype html>\(header)<iframe id='chat' style='width:880px;height:600px' srcdoc=\"\(escaped)\"></iframe>" : "\(header)\(chat)"
        web.loadHTMLString(content, baseURL: URL(string: "https://chat-performance.invalid/support")!)
        try await until { loaded.finished }
        if framed {
            var ready = false
            for _ in 0..<150 {
                ready = (try await call(web, "var f = document.getElementById('chat'); return !!(f && f.contentDocument && f.contentDocument.getElementById('message') && (f.contentWindow.__officeForms !== undefined) === includeForms);", arguments: ["includeForms": formsInChild])) as? Bool ?? false
                if ready { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(ready, "The synthetic same-origin chat frame must load")
        }
        let focusState = try await call(web, """
        var frame = document.getElementById('chat');
        (frame ? frame.contentDocument : document).getElementById('message').focus();
        document.dispatchEvent(new FocusEvent('focusin'));
        var active = document.activeElement;
        var inside = frame && frame.contentDocument.activeElement;
        return { outer: active.id, outerTag: active.tagName, inner: inside && inside.id,
          innerTag: inside && inside.tagName, innerRect: inside && [inside.getBoundingClientRect().width, inside.getBoundingClientRect().height],
          childInstrumentation: !!(frame && frame.contentWindow.__formPerformance) };
        """)
        if framed {
            let state = try XCTUnwrap(focusState as? [String: Any])
            XCTAssertEqual(state["outer"] as? String, "chat")
            XCTAssertEqual(state["inner"] as? String, "message")
            XCTAssertEqual(state["childInstrumentation"] as? Bool, true)
        }
        try await until { messages.typing }
        return Fixture(web: web, messages: messages)
    }

    private func exercise(_ fixture: Fixture, scrolling: Bool) async throws -> [String: Any] {
        try await call(fixture.web, "window.__formPerformance.reset(); return true;")
        fixture.messages.focus = 0
        // Drive the pulse clock from XCTest: chained native JS timers in an
        // offscreen view may each clamp to a full second. Only our isolated
        // rAF scheduler is advanced manually; the real observer debounce is
        // left intact and can run between these calls.
        for index in 0..<32 {
            try await call(fixture.web, """
            var frame = document.getElementById('chat');
            var chat = frame ? frame.contentDocument : document;
            chat.getElementById('transcript').style.width = (860 + index % 2) + 'px';
            if (frame) document.body.style.setProperty('--chat-animation', index);
            if (scrolling) {
              window.dispatchEvent(new Event('scroll'));
              if (frame) frame.contentWindow.dispatchEvent(new Event('scroll'));
            }
            window.__formPerformance.frame();
            return true;
            """, arguments: ["scrolling": scrolling, "index": index], context: scrolling ? "chat animation with scroll" : "chat animation without scroll")
            try await Task.sleep(for: .milliseconds(16))
        }
        // A detached WebKit process can also clamp a one-shot debounce to
        // one second. Let it flush without changing the production delay.
        try await Task.sleep(for: .milliseconds(1_400))
        let result = try await call(fixture.web, "return window.__formPerformance.snapshot();")
        // Let messages posted in the script's last task reach the test handler.
        try await Task.sleep(for: .milliseconds(30))
        var measured = try XCTUnwrap(result as? [String: Any])
        measured["focusMessages"] = fixture.messages.focus
        return measured
    }

    private func number(_ metrics: [String: Any]?, _ key: String) -> Int? {
        (metrics?[key] as? NSNumber)?.intValue
    }

    @discardableResult
    private func call(_ web: WKWebView, _ body: String, arguments: [String: Any] = [:], context: String? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let timeout = DispatchWorkItem {
                guard !finished else { return }
                finished = true
                ProxyTimeZone.close(web)
                let operation = context ?? String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                continuation.resume(throwing: NSError(domain: "FormPerformanceTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Synthetic chat JavaScript callback timed out: \(operation)"]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Web.world) { (result: Result<Any, Error>) in
                guard !finished else { return }
                finished = true
                timeout.cancel()
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    private static let instrumentation = """
    (function () {
      var counts, inFrame = false;
      function reset() { counts = { rects: 0, styles: 0, frameRects: 0, frameStyles: 0, passwordQueries: 0, framesScheduled: 0, framesRun: 0, geometryMS: 0, longestGeometryMS: 0 }; }
      reset();
      var rect = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = function () {
        counts.rects++;
        if (inFrame) counts.frameRects++;
        var start = performance.now();
        try { return rect.apply(this, arguments); }
        finally {
          var elapsed = performance.now() - start;
          counts.geometryMS += elapsed;
          counts.longestGeometryMS = Math.max(counts.longestGeometryMS, elapsed);
        }
      };
      var style = window.getComputedStyle;
      window.getComputedStyle = function () { counts.styles++; if (inFrame) counts.frameStyles++; return style.apply(this, arguments); };
      var query = Document.prototype.querySelectorAll;
      Document.prototype.querySelectorAll = function (selector) {
        if (selector === 'input[type="password"]') counts.passwordQueries++;
        return query.apply(this, arguments);
      };
      // Detached WKWebViews can suspend native rAF forever. Preserve the
      // script's real scroll listener/coalescing, but explicitly advance
      // each frame in precisely the script's own content world.
      var nextFrame = 0, frames = new Map();
      window.requestAnimationFrame = function (callback) {
        counts.framesScheduled++;
        frames.set(++nextFrame, callback);
        return nextFrame;
      };
      window.cancelAnimationFrame = function (token) { frames.delete(token); };
      function frame() {
        var pending = Array.from(frames.values());
        frames.clear();
        setFrame(true);
        try {
          pending.forEach(function (callback) { counts.framesRun++; callback(performance.now()); });
          children(function (child) { child.frame(); });
        } finally { setFrame(false); }
      }
      function setFrame(on) {
        inFrame = on;
        children(function (child) { child.setFrame(on); });
      }
      function children(each) {
        for (var i = 0; i < window.frames.length; i++) {
          try {
            var child = window.frames[i].__formPerformance;
            if (child) each(child);
          } catch (ignored) {}
        }
      }
      window.__formPerformance = {
        reset: function () { frame(); reset(); children(function (child) { child.reset(); }); },
        frame: frame,
        setFrame: setFrame,
        snapshot: function () {
          var all = Object.assign({}, counts);
          children(function (child) {
            var nested = child.snapshot();
            Object.keys(all).forEach(function (key) {
              all[key] = key === 'longestGeometryMS' ? Math.max(all[key], nested[key]) : all[key] + nested[key];
            });
          });
          return all;
        }
      };
    })();
    """

    private final class Messages: NSObject, WKScriptMessageHandler {
        var focus = 0
        var typing = false
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["kind"] as? String == "focus" else { return }
            focus += 1
            typing = body["typing"] as? Bool ?? false
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(finished && navigationAction.targetFrame?.isMainFrame == true ? .cancel : .allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }
}
