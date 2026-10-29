/* Search — the dialer's bridge.
 *
 * Otto's dialer (dialer.js) was written for Chrome's side panel, where it keeps its settings in
 * chrome.storage and talks to its background worker with chrome.runtime messages. In Search it
 * is the same page, loaded from the app's own files, and this script — loaded first — defines
 * the handful of chrome.* calls it makes, each answered by Search itself (Dialer.swift) through
 * one WebKit message handler, `dialer`:
 *
 *   chrome.storage.local      the connection (Settings › Dialer, the password from the keychain)
 *                             and what the panel keeps for itself (recents, the trunk, the voice)
 *   chrome.storage.session    the number Search handed over before the page was up
 *   chrome.runtime            messages to Search (a finished call) and from it (a number to dial)
 *   chrome.tabs / windows     the one-time microphone page, which Search answers with its own
 *                             explanation, and the window id, which there is only one of here
 *
 * Search → page: window.__searchDialer — deliver(msg) hands a dial request to the page as the
 * worker's runtime message would; changed(changes) says a setting changed; hangup() ends a call
 * (the panel is closing); state() reads the display, for tests.
 *
 * Nothing here is reachable from a website: the page is Search's own file, shown in its panel. */
(function () {
  "use strict";

  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dialer;
  function ask(msg) {
    if (!handler) return Promise.reject(new Error("Search isn't listening"));
    try { return Promise.resolve(handler.postMessage(msg)); } catch (e) { return Promise.reject(e); }
  }

  /* ---- listeners: runtime messages and storage changes ---- */
  var messageListeners = [], changeListeners = [], buffered = [];
  function deliver(msg) {
    if (!messageListeners.length) { buffered.push(msg); return; }   // the page is still loading: kept until it listens
    messageListeners.slice().forEach(function (f) { try { f(msg, { id: "search" }, function () {}); } catch (e) { console.error(e); } });
  }
  function changed(changes, area) {
    changeListeners.slice().forEach(function (f) { try { f(changes || {}, area || "local"); } catch (e) { console.error(e); } });
  }

  /* ---- chrome.storage ---- */
  function keyList(keys) {
    if (keys == null) return null;
    if (typeof keys === "string") return [keys];
    if (Array.isArray(keys)) return keys.map(String);
    if (typeof keys === "object") return Object.keys(keys);
    return null;
  }
  var local = {
    get: function (keys) { return ask({ op: "get", keys: keyList(keys) }).then(function (r) { return (r && r.values) || {}; }); },
    set: function (values) { return ask({ op: "set", values: values || {} }).then(function () {}); },
    remove: function (keys) { return ask({ op: "remove", keys: keyList(keys) || [] }).then(function () {}); }
  };
  var session = {
    get: function (keys) { return ask({ op: "session.get", keys: keyList(keys) }).then(function (r) { return (r && r.values) || {}; }); },
    set: function (values) { return ask({ op: "session.set", values: values || {} }).then(function () {}); },
    remove: function (keys) { return ask({ op: "session.remove", keys: keyList(keys) || [] }).then(function () {}); }
  };

  /* ---- chrome.runtime ---- */
  var runtime = {
    id: "search-dialer",
    lastError: undefined,
    getURL: function (path) { return new URL(String(path || ""), location.href).href; },
    getManifest: function () { return { name: "Dialer", version: "search" }; },
    openOptionsPage: function () { return ask({ op: "settings" }).then(function () {}); },
    sendMessage: function (msg) { return ask({ op: "message", msg: msg || {} }).then(function (r) { return r && r.reply; }); },
    getContexts: function () { return Promise.resolve([]); },
    onMessage: {
      addListener: function (f) {
        messageListeners.push(f);
        if (buffered.length) { var b = buffered; buffered = []; b.forEach(deliver); }
      },
      removeListener: function (f) { messageListeners = messageListeners.filter(function (g) { return g !== f; }); }
    }
  };

  /* ---- chrome.tabs / chrome.windows: there is one window, and the microphone is Search's to explain ---- */
  var tabs = {
    create: function () { return ask({ op: "microphone" }).then(function () { return { id: 1 }; }); },
    update: function () { return Promise.resolve({ id: 1 }); },
    remove: function () { return Promise.resolve(); },
    getCurrent: function () { return Promise.resolve(null); }
  };
  var windows = {
    getCurrent: function () { return Promise.resolve({ id: 1, type: "normal", state: "normal" }); },
    update: function () { return Promise.resolve({ id: 1 }); }
  };

  window.chrome = {
    runtime: runtime, tabs: tabs, windows: windows,
    storage: { local: local, session: session, onChanged: {
      addListener: function (f) { changeListeners.push(f); },
      removeListener: function (f) { changeListeners = changeListeners.filter(function (g) { return g !== f; }); }
    } }
  };

  /* The microphone. In Chrome the dialer checks the Permissions API before a call and sends you
   * to a page that asks, since a side panel can't. Here the panel is Search's own page and
   * Search grants it the microphone itself (DialerPage, Dialer.swift); macOS asks once, the
   * first time, for Search as a whole. So the check answers "granted", and a call goes straight
   * to getUserMedia. A microphone macOS refuses still fails there, and the dialer's own handling
   * takes over (needMic → chrome.tabs.create → Search's explanation). */
  try {
    var permissions = navigator.permissions;
    var query = permissions && permissions.query ? permissions.query.bind(permissions) : null;
    if (permissions) {
      permissions.query = function (desc) {
        if (desc && desc.name === "microphone") return Promise.resolve({ state: "granted", onchange: null });
        return query ? query(desc) : Promise.reject(new TypeError("unsupported"));
      };
    }
  } catch (e) { /* leave it */ }

  /* ---- what the display says, for Search's panel line and for tests ---- */
  function report() {
    var stat = document.getElementById("stat"), dot = document.getElementById("dot");
    var phone = document.querySelector(".phone");
    ask({ op: "status", text: stat ? stat.textContent : "", kind: dot ? dot.className.replace(/^dot\s*/, "") : "",
          state: phone ? phone.getAttribute("data-state") || "idle" : "idle" }).catch(function () {});
  }
  function watch() {
    var stat = document.getElementById("stat"), dot = document.getElementById("dot"), phone = document.querySelector(".phone");
    if (!stat || !dot || !window.MutationObserver) return;
    var o = new MutationObserver(report);
    o.observe(stat, { childList: true, characterData: true, subtree: true });
    o.observe(dot, { attributes: true, attributeFilter: ["class"] });
    if (phone) o.observe(phone, { attributes: true, attributeFilter: ["data-state"] });
    report();
  }

  window.__searchDialer = {
    deliver: deliver,
    changed: changed,
    hangup: function () {
      var hang = document.getElementById("hang");
      if (!hang || hang.inert) return false;
      hang.click();
      return true;
    },
    state: function () {
      var stat = document.getElementById("stat"), num = document.getElementById("num"), who = document.getElementById("who");
      var phone = document.querySelector(".phone"), sub = document.getElementById("sub");
      return { status: stat ? stat.textContent : "", number: num ? num.textContent : "", name: who ? who.textContent : "",
               state: phone ? phone.getAttribute("data-state") : "", note: sub ? sub.textContent : "" };
    }
  };

  // The page's scripts come after this one; once they have run, say so and start reporting.
  window.addEventListener("DOMContentLoaded", function () {
    watch();
    ask({ op: "ready" }).catch(function () {});
  });
})();
