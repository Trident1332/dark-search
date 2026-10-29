/* Ottocaller — the dialer window.
 *
 * Search: adapted from Otto's web-dialer/extension. search.js stands in for chrome.*;
 * call controls also follow the native panel's visibility and lifetime (see Dialer.swift).
 *
 * A SIP.js softphone that registers to FreeSWITCH over WebSocket and dials whatever otto (or
 * the keypad) hands it. Numero/Telicall routing lives entirely in the FreeSWITCH dialplan; this
 * page only ever dials sip:<number>@<domain>.
 *
 * Numbers can be pasted in any shape (⌘V anywhere, or the Paste button) — see normalizeDial:
 * +E.164, national with a leading 0, 00/011 international prefixes, tel:/sip: URIs, spaces,
 * dashes, dots, parentheses, (0) trunks, full-width / Arabic-Indic digits, vanity letters,
 * "ext"/x extensions, prose around the number, and *…#/short feature codes all resolve to a
 * dial-ready string, formatted for display. The default country (for national numbers) is the
 * `region` option.
 *
 * Inputs:
 *   chrome.storage.session.pendingDial { number, name, windowId, ref, at }   set by the background
 *   runtime message { type: "dialer:dial", number, name, windowId, ref }   when the panel is open
 *   ?n=<number>&auto=1&name=<label>&ref=<json>   the popup-window fallback carries the request in the URL
 *   chrome.storage.local { wss, domain, user, password, autodial, region, provider, voice }
 *
 * Output: every finished call to or from an outside number goes to the background worker as
 * { type: "call-ended", record } (calls.js), which keeps it for otto to log on the lead's
 * timeline. `ref` is otto's reference for the lead; it is carried to the call and back, untouched. */
(function () {
  "use strict";

  var $ = function (id) { return document.getElementById(id); };
  var numEl = $("num"), statEl = $("stat"), dot = $("dot"), subEl = $("sub"), timerEl = $("timer"), whoEl = $("who");
  var callBtn = $("call"), hangBtn = $("hang"), setupEl = $("setup");

  var CFG = null;              // current config from chrome.storage.local
  var simple = null;           // SIP.Web.SimpleUser
  var registered = false, inCall = false, connecting = false;
  var calling = false;         // outbound call placed but not yet answered (dialing/ringing)
  var tStart = 0, tInt = null, muted = false;
  var pending = null;          // { number, name } waiting for registration
  var generation = 0;          // bumps on every (re)boot so stale delegates are ignored
  var panelVisible = false, stopped = false, incoming = false, endingCall = false;
  var attempt = 0, activeAttempt = 0; // invalidates permission/media work after cancellation
  var cancelEpoch = 0;        // a close/cancel, distinct from reconnecting or starting a call
  var reconnectPending = false;
  var recoveryRevision = 0, recovering = null;
  var mediaWaiters = [], mediaFailure = null;
  var MEDIA_START_TIMEOUT = 15000;
  var MEDIA_TIMEOUT_NOTE = "The microphone didn't start. Keep Dark Search in front and check microphone access in System Settings, then try again.";
  var provider = "numero";     // outbound trunk; "telicall" adds an X-Provider INVITE header
  var numeroLine = "us";      // an owned Numero line, chosen explicitly in the Number menu
  var voice = "";              // voice changer: semitones sent as an X-Voice INVITE header, "" = off
  var region = "GB";           // default country for national numbers (options: region)
  var entry = "";              // canonical dial string (digits / + / * / #), no spaces
  var entryExt = "";           // extension to auto-send as DTMF once the call is answered
  var history = [];            // recent calls, newest first (chrome.storage.local "history")
  var HISTORY_MAX = 80;
  var cur = null;              // the call in progress, becomes a history entry and a call record when it ends
  var lead = null;             // { number, ref }: otto's reference for the number it loaded; the next call to that number carries it
  var ending = [];             // calls that have ended and are about to be filed (see callEnd)
  var outbox = [];             // copy of chrome.storage.local "callOutbox", so a closing panel can add to it without reading first
  var Calls = window.OttoCalls;   // calls.js: the call record and how an ending maps to an outcome
  var activeNetworkRoute = null, routeExpiryTimer = null, routeSettingsEpoch = 0, connectionRefreshID = 0;
  var sessionHandlers = new Set();

  function routeFailure(message) { var error = new Error(message); error.name = "ProtectedRouteError"; return error; }
  function validatedNetworkRoute(value, allowExpired, minimumRemaining) {
    if (!value || typeof value !== "object") throw routeFailure("The call route isn't ready. Try again when the proxy is connected");
    if (value.mode === "blocked") throw routeFailure(typeof value.error === "string" && value.error ? value.error.slice(0, 240) : "The protected call route isn't ready");
    if (value.mode === "direct") return Object.freeze({ mode: "direct" });
    if (value.mode !== "proxy") throw routeFailure("The call route is invalid");
    var match = typeof value.turnURL === "string" && /^turn:127\.0\.0\.1:([1-9]\d{0,4})\?transport=tcp$/.exec(value.turnURL);
    if (!match || Number(match[1]) > 65535 || typeof value.revision !== "string" || !value.revision || value.revision.length > 256
        || typeof value.username !== "string" || !value.username || value.username.length > 1024 || /[\r\n\0]/.test(value.username)
        || typeof value.credential !== "string" || !value.credential || value.credential.length > 4096 || /[\r\n\0]/.test(value.credential)
        || typeof value.expiresAt !== "number" || !Number.isFinite(value.expiresAt)) throw routeFailure("The protected call route is invalid");
    if (!allowExpired && value.expiresAt * 1000 <= Date.now()) throw routeFailure("The protected call route expired. Reconnect the proxy before calling");
    if (!allowExpired && minimumRemaining && value.expiresAt * 1000 < Date.now() + minimumRemaining) throw routeFailure("The protected call route needs to refresh before another call can start");
    return Object.freeze({ mode: "proxy", revision: value.revision, turnURL: value.turnURL,
      username: value.username, credential: value.credential, expiresAt: value.expiresAt });
  }
  function sameNetworkRoute(a, b) {
    return !!(a && b && ["mode", "revision", "turnURL", "username", "credential", "expiresAt"].every(function (key) { return a[key] === b[key]; }));
  }
  function networkRouteCurrent(route, gen, allowExpired) {
    if (stopped || !route || route !== activeNetworkRoute || gen !== generation) return false;
    try { return sameNetworkRoute(route, validatedNetworkRoute(CFG && CFG.protectedRoute, allowExpired)); } catch (e) { return false; }
  }
  function closeSessionHandlers() {
    sessionHandlers.forEach(function (handler) { try { handler.close(); } catch (e) { /* close every remaining peer as well */ } });
    sessionHandlers.clear();
  }
  function stopNetworkRoute(message) {
    generation++; recoveryRevision++; activeNetworkRoute = null;
    clearTimeout(routeExpiryTimer); routeExpiryTimer = null;
    closeSessionHandlers();
    hangup();
    var previous = simple; simple = null; registered = false; connecting = false; callBtn.disabled = true;
    if (previous) { try { Promise.resolve(previous.disconnect()).catch(function () {}); } catch (e) { /* already closed */ } }
    setStatus("Calls paused", "err"); subEl.textContent = message;
  }
  function requireNetworkRoute() {
    try {
      var current = validatedNetworkRoute(CFG && CFG.protectedRoute, false, 60000);
      if (!sameNetworkRoute(current, activeNetworkRoute)) throw routeFailure("The call route changed. Wait for it to reconnect before calling");
      return true;
    } catch (error) { stopNetworkRoute(error.message); return false; }
  }
  function armRouteExpiry(route) {
    clearTimeout(routeExpiryTimer); routeExpiryTimer = null;
    if (route.mode !== "proxy") return;
    routeExpiryTimer = setTimeout(function () {
      if (route !== activeNetworkRoute) return;
      routeExpiryTimer = null;
      if (route.expiresAt * 1000 <= Date.now()) {
        // An authenticated TURN allocation can refresh with its existing key.
        // Keep an established call, but never create another peer from this lease.
        callBtn.disabled = true;
        if (!inCall) stopNetworkRoute("The protected call route expired. Reconnect the proxy before calling");
      }
      else armRouteExpiry(route);
    }, Math.min(Math.max(0, route.expiresAt * 1000 - Date.now()), 2147483647));
  }
  function iceConfiguration(route) {
    return { iceCandidatePoolSize: 0, iceTransportPolicy: route.mode === "proxy" ? "relay" : "all",
      iceServers: route.mode === "proxy" ? [{ urls: route.turnURL, username: route.username, credential: route.credential }] : [] };
  }
  function callDescriptionFactory(route, gen) {
    var make = SIP.Web.defaultSessionDescriptionHandlerFactory(function (constraints) { return localMedia(constraints, gen); });
    return function (session, options) {
      if (gen !== generation || route !== activeNetworkRoute) throw routeFailure("The call route changed or expired");
      if (!networkRouteCurrent(route, gen)) {
        if (!inCall || !networkRouteCurrent(route, gen, true)) stopNetworkRoute("The call route changed or expired. Reconnect before calling");
        throw routeFailure("The call route changed or expired");
      }
      try { validatedNetworkRoute(CFG.protectedRoute, false, 60000); }
      catch (error) {
        if (!inCall) stopNetworkRoute(error.message);
        throw routeFailure(error.message);
      }
      var handler;
      try {
        var settings = Object.assign({}, options, { peerConnectionConfiguration: Object.assign({}, options && options.peerConnectionConfiguration, iceConfiguration(route)) });
        handler = make(session, settings);
        var peer = handler && handler.peerConnection, config = peer && peer.getConfiguration();
        var servers = config && config.iceServers, urls = servers && servers.length === 1 && servers[0].urls;
        if (typeof urls === "string") urls = [urls];
        if (!config || config.iceCandidatePoolSize !== 0 || config.iceTransportPolicy !== (route.mode === "proxy" ? "relay" : "all")
            || !Array.isArray(servers) || (route.mode === "proxy" ? !Array.isArray(urls) || urls.length !== 1 || urls[0] !== route.turnURL : servers.length !== 0)) {
          throw routeFailure("WebRTC couldn't enforce the selected call route");
        }
        var close = handler.close;
        handler.close = function () { sessionHandlers.delete(handler); return close.apply(handler, arguments); };
        sessionHandlers.add(handler);
        return handler;
      } catch (error) {
        if (handler) { try { handler.close(); } catch (e) { /* already closed */ } }
        stopNetworkRoute("WebRTC couldn't use the selected call route");
        throw routeFailure("WebRTC couldn't use the selected call route");
      }
    };
  }
  function applyConfiguration(values, replace) {
    CFG = replace ? values : Object.assign(CFG || {}, values);
    if (!activeNetworkRoute) return false;
    var matches = false;
    try { matches = sameNetworkRoute(activeNetworkRoute, validatedNetworkRoute(CFG.protectedRoute, inCall)); } catch (e) { /* fail closed */ }
    if (!matches) { stopNetworkRoute("The call route changed. Reconnecting…"); return true; }
    return false;
  }
  async function freshConfiguration(keys) {
    var epoch = routeSettingsEpoch;
    var values = await chrome.storage.local.get(keys.concat(["protectedRoute"]));
    return epoch === routeSettingsEpoch ? values : freshConfiguration(keys);
  }
  function refreshConnectionConfiguration(force) {
    var request = ++connectionRefreshID;
    freshConfiguration(CFG_KEYS.concat(NUMERO_KEYS, TELICALL_KEYS)).then(function (values) {
      if (stopped || request !== connectionRefreshID) return;
      var changedRoute = applyConfiguration(values, true);
      if (force || changedRoute || (!inCall && !calling && !incoming && !endingCall)) boot();
      else { reconnectPending = true; subEl.textContent = "Settings saved — reconnects after this call"; }
    }).catch(function () { if (!stopped && request === connectionRefreshID) stopNetworkRoute("The call route couldn't be read. Try again"); });
  }

  function lineChoice(value) { return value == null ? "us" : value === "us" || value === "ca" ? value : ""; }
  function numeroNumber(line) {
    var value = CFG && CFG[line === "us" ? "numeroUS" : line === "ca" ? "numeroCA" : ""];
    return typeof value === "string" && /^\+1[2-9]\d{2}[2-9]\d{6}$/.test(value) ? value : "";
  }
  function numeroBound() {
    return !!(CFG && [CFG.numeroUS, CFG.numeroCA].some(function (value) { return typeof value === "string" && value.trim(); }));
  }
  function telicallNumber() {
    var value = CFG && CFG.telicallUK;
    return typeof value === "string" && /^\+44[1-9]\d{8,9}$/.test(value) ? value : "";
  }
  function telicallBound() { return !!(CFG && typeof CFG.telicallUK === "string" && CFG.telicallUK.trim()); }
  function numberRoute(number) {
    var route = { user: number, provider: provider, numeroLine: "", telicallLine: "", fromNumber: "" };
    if (provider === "telicall" && Calls.external(number) && telicallBound()) {
      var uk = telicallNumber();
      if (!uk) return { error: "Set a valid UK number in Settings › Dialer before calling" };
      route.telicallLine = "uk"; route.fromNumber = uk;
      return route;
    }
    if (provider !== "numero" || !Calls.external(number) || !numeroBound()) return route;
    var owned = numeroNumber(numeroLine);
    if (!owned) return { error: "Choose an available Numero number before calling" };
    if (!/^\+?[1-9]\d{5,14}$/.test(number)) return { error: "Use a complete international number for this call" };
    route.user = "numero-" + numeroLine + "-" + number.replace(/^\+/, "");
    route.numeroLine = numeroLine; route.fromNumber = owned;
    return route;
  }
  function retryCurrent(context) {
    if (!context || stopped || !panelVisible || context.token !== attempt || context.gen !== generation || context.client !== simple
        || context.cancelEpoch !== cancelEpoch || context.revision !== recoveryRevision || !networkRouteCurrent(activeNetworkRoute, generation)) return false;
    if (context.kind !== "out") return true;
    var currentRoute = numberRoute(context.number);
    return cleanNumber(entry) === context.number && !currentRoute.error
      && ["user", "provider", "numeroLine", "telicallLine", "fromNumber"].every(function (key) { return currentRoute[key] === context.route[key]; });
  }
  function retryContext(kind, number, route, ref) {
    return { microphoneRetry: true, kind: kind, number: number, route: route, ref: ref, name: whoEl.textContent,
      client: simple, gen: generation, cancelEpoch: cancelEpoch, revision: recoveryRevision, offered: false,
      session: simple && simple.session, call: cur };
  }
  async function recoverMicrophone(context) {
    if (context.offered || !retryCurrent(context) || !window.__searchDialer || typeof window.__searchDialer.recoverMicrophone !== "function") return false;
    context.offered = true;
    var previous = { note: subEl.textContent, status: statEl.textContent, kind: dot.className.replace(/^dot\s*/, "") };
    recovering = context; syncButtons();
    subEl.textContent = "Choose Allow to retry this call with microphone access";
    setStatus("Microphone permission");
    var result;
    try {
      result = await window.__searchDialer.recoverMicrophone();
      if (result && result.state === "granted" && retryCurrent(context) && context.cleanup) {
        subEl.textContent = "Finishing the previous call before retrying…";
        var timer, cleaned = await Promise.race([
          context.cleanup.then(function () { return true; }),
          new Promise(function (resolve) { timer = setTimeout(function () { resolve(false); }, 5000); })
        ]);
        clearTimeout(timer);
        if (!cleaned || context.client.session) result = { state: "cleanup-pending" };
      }
    } catch (e) { result = { state: "denied" }; }
    finally { if (recovering === context) { recovering = null; syncButtons(); } }
    if (!retryCurrent(context)) {
      if (!stopped && panelVisible && context.token === attempt) {
        subEl.textContent = "Call cancelled — place a new call with the current settings";
        setStatus(registered ? "Registered" : "Not registered", registered ? "reg" : "");
      }
      return false;
    }
    if (result && result.state === "granted") return true;
    if (result && result.state === "cleanup-pending") {
      subEl.textContent = "The previous call is still closing. Try Call again in a moment";
      setStatus("Call still closing", "err");
      return false;
    }
    subEl.textContent = previous.note;
    setStatus(previous.status, previous.kind);
    return false;
  }
  function sameIncoming(context) {
    return retryCurrent(context) && context.client.session === context.session && cur === context.call
      && context.session && (!context.session.state || context.session.state === "Initial");
  }

  /* ------------------------------ number normalisation ------------------------------ */
  /* Turns any pasted text into a dial-ready number. Uses the global PhoneLib
   * (vendor/phone.min.js = libphonenumber-js); if that failed to load it still cleans to
   * digits, just without country validation. Kept byte-identical to the node-tested version
   * in the build dir so the case matrix that proves it also covers this copy. */
  function makeNormalizer(PhoneLib) {
    var NANP = { US:1, CA:1, BS:1, BB:1, AI:1, AG:1, VG:1, VI:1, KY:1, BM:1, GD:1, TC:1, MS:1,
                 MP:1, GU:1, AS:1, SX:1, DM:1, DO:1, JM:1, KN:1, LC:1, VC:1, TT:1, PR:1 };
    var VANITY = { A:'2',B:'2',C:'2',D:'3',E:'3',F:'3',G:'4',H:'4',I:'4',J:'5',K:'5',L:'5',
                   M:'6',N:'6',O:'6',P:'7',Q:'7',R:'7',S:'7',T:'8',U:'8',V:'8',W:'9',X:'9',Y:'9',Z:'9' };
    function toAsciiDigits(s) {
      return s.replace(/[٠-٩]/g, function (c) { return String(c.charCodeAt(0) - 0x0660); })
              .replace(/[۰-۹]/g, function (c) { return String(c.charCodeAt(0) - 0x06F0); });
    }
    function group(d) { return d.replace(/\B(?=(\d{3})+(?!\d))/g, " "); }
    function tryParse(input, r) { try { return PhoneLib && PhoneLib.parse ? PhoneLib.parse(input, r) : null; } catch (e) { return null; } }

    return function normalizeDial(raw, reg) {
      reg = (reg || "GB").toUpperCase();
      if (raw == null) return { dial: "", display: "", ext: "", kind: "empty", country: "" };

      var s = String(raw);
      try { s = s.normalize("NFKC"); } catch (e) {}
      s = toAsciiDigits(s);
      s = s.replace(/^\s*(tel|callto|sip|sips)\s*:\s*/i, "");
      s = s.replace(/@.*$/, "");

      var ext = "";
      var em = s.match(/(?:\s*(?:ext|extension|poste|post)\.?\s*[:=]?\s*|\s*x\s*|\s*#\s*)(\d{1,6})\s*$/i);
      if (em && em.index > 0) { ext = em[1]; s = s.slice(0, em.index); }

      var vraw = s.replace(/[\s().\-\/]/g, "");
      if (/[A-Za-z]/.test(vraw) && /^\+?\d[0-9A-Za-z]*$/.test(vraw)) {
        var body = vraw.replace(/^\+/, "");
        var runs = body.match(/[A-Za-z]+/g) || [];
        if (runs.length === 1) {
          var mapped = body.replace(/[A-Za-z]/g, function (c) { return VANITY[c.toUpperCase()] || ""; });
          if (mapped.length >= 6) s = (/^\+/.test(vraw) ? "+" : "") + mapped;
        }
      }

      var keypad = s.replace(/[^\d*#+]/g, "");
      var d0 = keypad.replace(/\D/g, "");
      if (/[*#]/.test(keypad) || (d0.length > 0 && d0.length < 6 && !/^\+/.test(keypad))) {
        var code = keypad.replace(/\+/g, "");
        if (!code) return { dial: "", display: "", ext: ext, kind: "empty", country: "" };
        return { dial: code, display: code, ext: ext, kind: "code", country: "" };
      }

      var run = s.match(/\+?\s*\d[\d\s().\-\/]{3,}\d/);
      var candidate = run ? run[0] : s;
      var digits = candidate.replace(/\D/g, "");
      var hasPlus = /^\s*\+/.test(candidate);
      var has00 = /^\s*[(]?0{2}\d/.test(candidate);

      var tries = [];
      if (hasPlus) tries.push(["+" + digits, undefined]);
      if (has00) tries.push(["+" + digits.replace(/^0{2}/, ""), undefined]);
      if (NANP[reg] && /^\s*[(]?011\d/.test(candidate)) tries.push(["+" + digits.replace(/^011/, ""), undefined]);
      tries.push([candidate, reg]);
      tries.push(["+" + digits, reg]);

      var best = null, i;
      for (i = 0; i < tries.length && !best; i++) { var pn = tryParse(tries[i][0], tries[i][1]); if (pn && pn.isValid()) best = pn; }
      for (i = 0; i < tries.length && !best; i++) { var pp = tryParse(tries[i][0], tries[i][1]); if (pp && pp.isPossible && pp.isPossible()) best = pp; }
      if (best) return { dial: best.number, display: best.formatInternational(), ext: ext || best.ext || "", kind: "e164", country: best.country || "" };

      if (!digits) return { dial: "", display: "", ext: ext, kind: "empty", country: "" };
      if (hasPlus || has00) {
        var intl = "+" + (has00 && !hasPlus ? digits.replace(/^0{2}/, "") : digits);
        return { dial: intl, display: "+" + group(intl.slice(1)), ext: ext, kind: "e164-raw", country: "" };
      }
      return { dial: digits, display: group(digits), ext: ext, kind: "national-raw", country: "" };
    };
  }
  var NORMALIZE = makeNormalizer(window.PhoneLib || null);

  /* ------------------------------ UI helpers ------------------------------ */

  function setStatus(t, cls) { statEl.textContent = t; statEl.title = t; dot.className = "dot" + (cls ? " " + cls : ""); }
  // Runs a one-shot CSS animation class on an element (restartable mid-flight; removed when it ends).
  function nudge(el, cls) {
    if (!el) return;
    el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls);
    el.addEventListener("animationend", function done(e) { if (e.target !== el) return; el.classList.remove(cls); el.removeEventListener("animationend", done); });
  }
  function fmt(s) { var m = Math.floor(s / 60), ss = String(s % 60).padStart(2, "0"); return m + ":" + ss; }
  function startTimer() {
    tStart = Date.now();
    tInt = setInterval(function () { timerEl.textContent = " " + fmt(Math.floor((Date.now() - tStart) / 1000)); }, 500);
  }
  function stopTimer() { clearInterval(tInt); timerEl.textContent = ""; }
  // The green call button becomes the red hang-up button whenever a call is placing, ringing,
  // or connected — so you can always cancel it. Both live in the same grid cell; the card's
  // data-state picks which one shows (dialer.css rotates and cross-fades the handset) and the
  // hidden one is inert so it can't be clicked or tabbed to.
  var phoneEl = document.querySelector(".phone");
  function syncButtons() {
    var busy = calling || inCall || incoming || recovering;
    if (phoneEl) phoneEl.setAttribute("data-state", inCall ? "incall" : incoming && !recovering ? "incoming" : calling || recovering ? "calling" : "idle");
    callBtn.inert = busy; hangBtn.inert = !busy;
    $("incoming").hidden = !incoming || !!recovering;
    dot.className = "dot " + (inCall ? "oncall" : calling || incoming ? "calling" : (registered ? "reg" : ""));
  }

  /* ------------------------------ recents ------------------------------ */
  /* Every call becomes one entry: who, the number as dialed, when, how long, and how it
   * ended. Tapping an entry loads it into the display and, when registered, redials it. */
  var recentsEl = $("recents"), rlistEl = $("rlist"), rcountEl = $("rcount");
  var HANDSET = "M13.832 16.568a1 1 0 0 0 1.213-.303l.355-.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2A18 18 0 0 1 2 4a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2v3a2 2 0 0 1-.8 1.6l-.468.351a1 1 0 0 0-.292 1.233 14 14 0 0 0 6.392 6.384";
  var ICON_OUT = '<svg viewBox="0 0 24 24"><path d="m16 8 6-6M22 8V2h-6"/><path d="' + HANDSET + '"/></svg>';     // answered call we placed
  var ICON_IN = '<svg viewBox="0 0 24 24"><path d="M16 2v6h6M22 2l-6 6"/><path d="' + HANDSET + '"/></svg>';     // incoming
  var ICON_MISS = '<svg viewBox="0 0 24 24"><path d="m16 2 6 6M22 2l-6 6"/><path d="' + HANDSET + '"/></svg>';   // no answer, busy, cancelled, failed
  var OUTCOME = { answered: ["ok", ""], "no-answer": ["miss", "No answer"], cancelled: ["", "Cancelled"],
                  failed: ["fail", "Failed"], busy: ["miss", "Busy"], missed: ["miss", "Missed"] };
  /* A call from its first moment. What ends it is noted on the object as it happens — hung
   * (hang-up pressed before an answer), code (the final SIP status of our INVITE), error (placing
   * it threw), dropped (the server connection went) — and Calls.outcome() reads those at the end. */
  function callStart(number, name, direction, ref, route) {
    cur = { id: Calls.newId(), at: Date.now(), number: number, display: formatDisplay(number) || number, name: name || "",
            provider: route ? route.provider : provider, direction: direction || "out", answeredAt: 0,
            numeroLine: route ? route.numeroLine : "", telicallLine: route ? route.telicallLine : "", fromNumber: route ? route.fromNumber : "",
            voice: (direction || "out") === "out" ? voice : "",     // only calls we place are shifted
            ref: ref || null, hung: false, code: 0, error: false, dropped: false, endedAt: 0, filed: false };
    return cur;
  }
  /* The call is over. SIP.js reports the hang-up first and the reason second: the final status
   * of a rejected INVITE reaches dial()'s request delegate later in the same turn, and an error
   * thrown while placing the call reaches its catch a few promise hops later. So the call is
   * stamped now and filed one tick on, when the reason is in. `now` (the panel is closing)
   * files it on the spot. */
  function callEnd(call, now) {
    if (!call || call.endedAt) return;
    call.endedAt = Date.now();
    if (cur === call) cur = null;
    ending.push(call);
    if (now) fileCall(call, true); else setTimeout(function () { fileCall(call); }, 0);
  }
  function fileCall(call, now) {
    if (call.filed) return;
    call.filed = true;
    ending = ending.filter(function (c) { return c !== call; });
    var rec = Calls.record(call, call.endedAt);
    history.unshift({ at: call.at, number: call.number, display: call.display, name: call.name, provider: call.provider,
                      numeroLine: call.numeroLine, telicallLine: call.telicallLine, fromNumber: call.fromNumber,
                      direction: call.direction, voice: call.voice, outcome: rec.outcome, duration: rec.durationSec });
    if (history.length > HISTORY_MAX) history.length = HISTORY_MAX;
    try { chrome.storage.local.set({ history: history }); } catch (e) { /* storage unavailable */ }
    renderHistory();
    if (Calls.external(call.number)) reportCall(rec, now);   // seats and test numbers (9196, 9199) stay out of otto
  }
  /* Hands the record to the background worker, which makes every change to the "callOutbox"
   * otto reads, one at a time (content.js delivers it). If the worker cannot be reached, the
   * panel files it itself. A closing panel (`now`) cannot wait for either: it writes the outbox
   * in one go from its own copy, and tells the worker as well (the same id is never filed twice). */
  function reportCall(rec, now) {
    var write = function (list) { var o = {}; o[Calls.OUTBOX_KEY] = Calls.append(list, rec); return chrome.storage.local.set(o); };
    var direct = function () {
      try {
        chrome.storage.local.get(Calls.OUTBOX_KEY).then(function (r) { return write(r && r[Calls.OUTBOX_KEY]); })
          .catch(function (e) { console.error("call record not stored:", e); });
      } catch (e) { console.error("call record not stored:", e); }
    };
    if (now) { try { write(outbox); } catch (e) { /* storage unavailable */ } }
    try {
      chrome.runtime.sendMessage({ type: "call-ended", record: rec }).then(function (res) { if (!now && (!res || !res.ok)) direct(); }, function () { if (!now) direct(); });
    } catch (e) { if (!now) direct(); }
  }
  try {
    chrome.storage.local.get(Calls.OUTBOX_KEY).then(function (r) { outbox = Calls.list(r && r[Calls.OUTBOX_KEY]); }).catch(function () {});
  } catch (e) { /* storage unavailable */ }
  /* The panel (or its window) is closing: a call still up ends with it, and there is no later
   * tick. "beforeunload" comes first where the browser sends it, and this listener runs ahead of
   * the one SIP.js adds for itself (it hangs up there), so a call cut off while ringing is filed
   * as cancelled by us, not as an unanswered one. */
  function closing() {
    if (cur) { if (!cur.answeredAt) cur.hung = true; callEnd(cur, true); }
    ending.slice().forEach(function (c) { fileCall(c, true); });
  }
  window.addEventListener("beforeunload", closing);
  window.addEventListener("pagehide", closing);
  function dayLabel(at) {
    var d = new Date(at), now = new Date();
    var sameDay = function (a, b) { return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate(); };
    if (sameDay(d, now)) return "Today";
    var y = new Date(now); y.setDate(now.getDate() - 1);
    if (sameDay(d, y)) return "Yesterday";
    return d.toLocaleDateString(undefined, { day: "numeric", month: "short" }) + (d.getFullYear() !== now.getFullYear() ? " " + d.getFullYear() : "");
  }
  function timeLabel(at) { return new Date(at).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); }
  function esc(t) { return String(t == null ? "" : t).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function renderHistory() {
    if (!recentsEl) return;
    recentsEl.hidden = false;
    rcountEl.textContent = history.length ? String(history.length) : "";
    if (!history.length) { rlistEl.innerHTML = '<li class="rempty">Calls you place will show up here.</li>'; return; }
    var html = "", lastDay = "";
    history.forEach(function (h, i) {
      var day = dayLabel(h.at);
      if (day !== lastDay) { html += '<li class="rday">' + esc(day) + "</li>"; lastDay = day; }
      var o = OUTCOME[h.outcome] || ["", h.outcome || ""];
      var cls = h.direction === "in" ? "in" : o[0];
      var title = h.name || h.display || h.number;
      var lineLabel = h.provider === "telicall" ? h.telicallLine === "uk" ? "Telicall UK" : "Telicall" : h.numeroLine === "us" ? "Numero US" : h.numeroLine === "ca" ? "Numero Canada" : "Numero";
      var sub = (h.name ? (h.display || h.number) + " · " : "") + lineLabel + (h.fromNumber ? " · " + h.fromNumber : "") +
                (h.direction === "in" ? " · incoming" : "");
      var right = h.outcome === "answered" ? fmt(h.duration || 0) : o[1];
      html += '<li style="--i:' + Math.min(i, 12) + '"><button type="button" class="rrow" data-i="' + i + '" title="Call again">' +
        '<span class="ric ' + cls + '">' + (h.direction === "in" ? ICON_IN : h.outcome === "answered" ? ICON_OUT : ICON_MISS) + "</span>" +
        '<span class="rmain"><span class="rname">' + esc(title) + '</span><span class="rsub">' + esc(sub) + "</span></span>" +
        '<span class="rmeta"><span class="rwhen">' + esc(timeLabel(h.at)) + '</span><span class="rdur ' + o[0] + '">' + esc(right) + "</span></span>" +
        "</button></li>";
    });
    rlistEl.innerHTML = html;
  }
  if (rlistEl) rlistEl.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest(".rrow"); if (!b) return;
    if (!recentsEl.classList.contains("open")) return;             // a tap on the collapsed peek just opens the sheet
    var h = history[Number(b.getAttribute("data-i"))]; if (!h) return;
    closeSheet();
    if (inCall || calling) { subEl.textContent = "Hang up to call " + (h.display || h.number); return; }
    setEntry(h.number, ""); whoEl.textContent = h.name || "";
    provider = h.provider === "telicall" ? "telicall" : "numero";
    recoveryRevision++;
    if (h.numeroLine === "us" || h.numeroLine === "ca") numeroLine = h.numeroLine;
    renderProvider();
    chrome.storage.local.set({ provider: provider, numeroLine: numeroLine }).catch(function () {});
    if (provider === "numero" && h.fromNumber && h.fromNumber !== numeroNumber(numeroLine)) {
      subEl.textContent = "That Numero number changed — choose a number before calling";
      return;
    }
    if (provider === "telicall" && h.telicallLine === "uk" && h.fromNumber !== telicallNumber()) {
      subEl.textContent = "That UK number changed — choose a number before calling";
      return;
    }
    if (registered) dial(); else subEl.textContent = "Not registered yet";
  });
  var rclearEl = $("rclear");
  if (rclearEl) rclearEl.addEventListener("click", function () {
    if (!history.length) return;
    history = [];
    try { chrome.storage.local.set({ history: [] }); } catch (e) { /* storage unavailable */ }
    renderHistory();
  });
  try {
    chrome.storage.local.get("history").then(function (r) {
      history = Array.isArray(r && r.history) ? r.history.filter(function (h) { return h && h.at && h.number; }) : [];
      renderHistory();
    }).catch(function () { renderHistory(); });
  } catch (e) { renderHistory(); }

  /* Recents is a bottom sheet, so the panel itself never scrolls: collapsed, it peeks under the
   * dialer card (its header plus whatever rows fit, fading out); a tap slides it up over the
   * keypad and the list scrolls inside it. Its resting top follows the dialer card's height. */
  var rheadEl = $("rhead"), scrimEl = $("scrim");
  function placeSheet() {
    if (!phoneEl) return;
    document.body.style.setProperty("--sheet-top", Math.round(phoneEl.getBoundingClientRect().bottom + 12) + "px");
  }
  function sheetOpen() { return !!recentsEl && recentsEl.classList.contains("open"); }
  function openSheet() {
    if (!recentsEl || sheetOpen()) return;
    closeAllMenus(); closeMenu();
    var h = document.body.clientHeight, need = (rheadEl ? rheadEl.offsetHeight : 40) + rlistEl.scrollHeight + 24;
    document.body.style.setProperty("--sheet-open", Math.round(Math.max(Math.max(12, h * 0.22), h - 12 - need)) + "px");
    recentsEl.classList.add("open"); document.body.classList.add("sheet");
    if (rheadEl) rheadEl.setAttribute("aria-expanded", "true");
  }
  function closeSheet() {
    if (!sheetOpen()) return;
    recentsEl.classList.remove("open"); document.body.classList.remove("sheet");
    if (rheadEl) rheadEl.setAttribute("aria-expanded", "false");
  }
  function toggleSheet() { if (sheetOpen()) closeSheet(); else openSheet(); }
  if (rheadEl) {
    rheadEl.addEventListener("click", function (e) { if (e.target.closest("#rclear")) return; e.stopPropagation(); toggleSheet(); });
    rheadEl.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggleSheet(); } });
  }
  if (recentsEl) recentsEl.addEventListener("click", function (e) { if (!sheetOpen() && !e.target.closest("#rclear")) openSheet(); });   // any tap on the peek opens it
  if (scrimEl) scrimEl.addEventListener("click", closeSheet);
  document.addEventListener("keydown", function (e) {   // Escape closes the sheet and nothing else (the hang-up shortcut listens after this)
    if (e.key === "Escape" && sheetOpen()) { closeSheet(); e.stopImmediatePropagation(); }
  });
  window.addEventListener("resize", placeSheet);
  if (window.ResizeObserver && phoneEl) new ResizeObserver(placeSheet).observe(phoneEl);
  placeSheet();

  /* ------------------------------ local ringback ------------------------------ */
  /* Trunks usually answer the INVITE with a plain 180 Ringing and send no audio until the
   * callee picks up (getcontact's 183 early media arrives about half a second before the
   * answer), so relying on early media alone leaves the caller in silence for the whole ring.
   * Like every softphone we generate the ring tone locally on 180 and stop the moment real
   * early media (183 with SDP), the answer, a hang-up or a failure arrives. The tone is a WAV
   * built once in memory and played through an <audio> element — the same autoplay rules as
   * the remote audio, which already works in the side panel — so no AudioContext is needed. */
  var ringEl = null;
  function ensureRingEl() {
    if (ringEl) return ringEl;
    ringEl = document.createElement("audio");
    ringEl.loop = true; ringEl.volume = 0.5; ringEl.setAttribute("aria-hidden", "true");
    ringEl.src = URL.createObjectURL(new Blob([ringToneWav()], { type: "audio/wav" }));
    document.body.appendChild(ringEl);
    return ringEl;
  }
  // Any tap in the panel (keypad, call button) counts as the user gesture that lets the
  // ring element play later even when the call itself is started from the otto page.
  var ringPrimed = false;
  function primeRingback() {
    if (ringPrimed) return;
    var el = ensureRingEl(), p = el.play();
    if (p && p.then) p.then(function () { if (!calling) { el.pause(); el.currentTime = 0; } ringPrimed = true; })
                     .catch(function () { /* not yet allowed; the next tap tries again */ });
  }
  document.addEventListener("pointerdown", primeRingback, true);
  function ringToneWav() {
    // UK cadence at 400 Hz + 450 Hz: 400 ms on, 200 off, 400 on, 2000 off (FreeSWITCH's uk-ring)
    var rate = 8000, cadence = [[400, true], [200, false], [400, true], [2000, false]], total = 0;
    cadence.forEach(function (c) { total += c[0]; });
    var n = Math.round(rate * total / 1000), pcm = new Int16Array(n), i = 0;
    cadence.forEach(function (c) {
      var len = Math.round(rate * c[0] / 1000);
      for (var k = 0; k < len && i < n; k++, i++) {
        if (!c[1]) { pcm[i] = 0; continue; }
        var t = k / rate, env = Math.min(1, k / 80, (len - k) / 80);        // 10 ms fades, no clicks
        pcm[i] = Math.round(0.3 * 32767 * env * (Math.sin(2 * Math.PI * 400 * t) + Math.sin(2 * Math.PI * 450 * t)) / 2);
      }
    });
    var buf = new ArrayBuffer(44 + n * 2), v = new DataView(buf);
    var str = function (o, s) { for (var j = 0; j < s.length; j++) v.setUint8(o + j, s.charCodeAt(j)); };
    str(0, "RIFF"); v.setUint32(4, 36 + n * 2, true); str(8, "WAVE"); str(12, "fmt ");
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    str(36, "data"); v.setUint32(40, n * 2, true);
    new Int16Array(buf, 44).set(pcm);
    return buf;
  }
  function startRingback() {
    ensureRingEl();
    if (!ringEl.paused) return;
    ringEl.currentTime = 0;
    var p = ringEl.play();
    if (p && p.catch) p.catch(function (e) { console.warn("ringback blocked:", e && e.name); });
  }
  function stopRingback() { if (ringEl && !ringEl.paused) ringEl.pause(); }
  function cleanNumber(n) { return String(n || "").replace(/[^+\d*#]/g, ""); }

  // Pretty display of the current entry, without changing what gets dialed.
  function formatDisplay(e) {
    if (!e) return "";
    if (/[*#]/.test(e)) return e;                                  // feature code
    var digits = e.replace(/\D/g, "");
    if (digits.length < 6 && !/^\+/.test(e)) return e;             // short/internal code
    try {
      if (window.PhoneLib && window.PhoneLib.AsYouType) {
        var f = new window.PhoneLib.AsYouType(region).input(e);
        if (f) return f;
      }
    } catch (x) { /* fall through to raw */ }
    return e;
  }
  // Renders the readout. A character the keypad appended slides in on its own; a new number
  // (paste, otto, recents) fades in whole; a deletion just redraws. Long numbers step down a size.
  function renderNum() {
    var t = formatDisplay(entry), prev = numEl.textContent || "";
    if (prev && t.length > prev.length && t.indexOf(prev) === 0) {
      numEl.textContent = prev;
      var s = document.createElement("span"); s.className = "din"; s.textContent = t.slice(prev.length);
      numEl.appendChild(s);
    } else {
      numEl.textContent = t;
      if (t && prev.indexOf(t) !== 0) nudge(numEl, "swap");
    }
    numEl.setAttribute("data-size", t.length > 20 ? "xs" : t.length > 17 ? "s" : t.length > 12 ? "m" : "l");
    document.body.classList.toggle("has-entry", !!entry);
  }

  // Replace the current entry (keypad edits append to it instead).
  function setEntry(dialStr, ext) { entry = dialStr || ""; entryExt = ext || ""; renderNum(); }

  function setNumber(n, name) {
    var r = NORMALIZE(n, region);
    setEntry(r.dial || cleanNumber(n), r.ext);
    whoEl.textContent = name ? String(name) : "";
    hintFor(r);
  }

  // otto's reference for the number now in the display; the call dial() starts to it takes it along.
  function setLead(ref) { lead = ref ? { number: cleanNumber(entry), ref: ref } : null; }

  // A quiet one-line hint under the number for the ambiguous cases.
  function hintFor(r) {
    if (!r || inCall) return;
    if (r.kind === "national-raw") subEl.textContent = "No country code — set your default country in settings";
    else if (r.kind === "e164-raw") subEl.textContent = "Number kept as-is (couldn't verify the country)";
    else if (r.kind === "e164" && r.country) subEl.textContent = "";
    else subEl.textContent = "";
  }

  /* ------------------------------ keypad ------------------------------ */

  var KEYS = [["1", ""], ["2", "ABC"], ["3", "DEF"], ["4", "GHI"], ["5", "JKL"], ["6", "MNO"],
              ["7", "PQRS"], ["8", "TUV"], ["9", "WXYZ"], ["*", ""], ["0", "+"], ["#", ""]];
  var pad = $("pad");
  KEYS.forEach(function (k) {
    var b = document.createElement("button");
    b.className = "key"; b.type = "button"; b.setAttribute("data-key", k[0]);
    b.innerHTML = "<span>" + k[0] + "</span><span class=\"l\">" + k[1] + "</span>";
    b.addEventListener("click", function () { press(k[0]); });
    pad.appendChild(b);
  });
  function press(d) {
    if (inCall) { try { simple.sendDTMF(d); } catch (e) { /* not in a session */ } return; }
    entry += d; whoEl.textContent = ""; renderNum();
  }
  // A key typed on the keyboard lights its on-screen twin, like a tap would.
  function flashKey(d) {
    var b = pad.querySelector('[data-key="' + d + '"]'); if (!b) return;
    b.classList.remove("pressed"); void b.offsetWidth; b.classList.add("pressed");
    setTimeout(function () { b.classList.remove("pressed"); }, 200);
  }
  // long-press 0 => "+"
  var zeroTimer = null, zeroKey = pad.querySelectorAll(".key")[10];
  zeroKey.addEventListener("pointerdown", function () {
    if (inCall) return;
    zeroTimer = setTimeout(function () {
      entry = entry.slice(0, -1) + "+"; renderNum();
      zeroTimer = null;
    }, 450);
  });
  ["pointerup", "pointerleave"].forEach(function (ev) {
    zeroKey.addEventListener(ev, function () { if (zeroTimer) { clearTimeout(zeroTimer); zeroTimer = null; } });
  });

  function clearAll() { entry = ""; entryExt = ""; whoEl.textContent = ""; renderNum(); }
  // ⌫ — a tap deletes one character; holding it for ~3s clears the whole number.
  var backHold = null, backCleared = false, backBtn = $("back");
  backBtn.addEventListener("click", function () {
    if (backCleared) { backCleared = false; return; }        // the hold already cleared it
    if (!inCall) { entry = entry.slice(0, -1); renderNum(); }
  });
  backBtn.addEventListener("pointerdown", function () {
    if (inCall) return;
    backCleared = false;
    if (entry) backBtn.classList.add("hold");                       // the ring that fills while you hold
    backHold = setTimeout(function () {
      backHold = null; backCleared = true; backBtn.classList.remove("hold");
      clearAll(); nudge(displayEl, "wipe");
    }, 2000);
  });
  ["pointerup", "pointerleave", "pointercancel"].forEach(function (ev) {
    backBtn.addEventListener(ev, function () { backBtn.classList.remove("hold"); if (backHold) { clearTimeout(backHold); backHold = null; } });
  });
  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;               // let ⌘V / ⌘A through to paste/copy
    if (/^[0-9*#+]$/.test(e.key)) { press(e.key); flashKey(e.key); }
    else if (e.key === "Backspace") { if (!inCall) { entry = entry.slice(0, -1); renderNum(); } }
    else if (e.key === "Enter") { if (inCall) hangup(); else dial(); }
    else if (e.key === "Escape") { if (!sheetOpen() && !document.querySelector(".menu:not([hidden])") && inCall) hangup(); }   // dismiss first; hang up only when nothing is open
  });

  /* ------------------------------ paste ------------------------------ */
  /* The readout is a <div>, so nothing catches ⌘V on its own — listen on the document. A
   * paste replaces the field (paste a number to call it). Paste is also on the right-click menu. */
  function applyPaste(text) {
    if (inCall || !text) return;
    var r = NORMALIZE(text, region);
    if (r.kind === "empty" || !r.dial) { subEl.textContent = "No phone number in what you pasted"; nudge(displayEl, "shake"); return; }
    whoEl.textContent = "";
    setEntry(r.dial, r.ext);
    hintFor(r);
    if (r.kind === "e164" && !r.ext) subEl.textContent = "Pasted" + (r.country ? " · " + r.country : "");
  }
  document.addEventListener("paste", function (e) {
    var text = "";
    try { text = (e.clipboardData || window.clipboardData).getData("text"); } catch (x) {}
    if (text) { e.preventDefault(); applyPaste(text); }
  });
  function pasteFromClipboard() {
    if (inCall) return;
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(applyPaste).catch(function () { subEl.textContent = "Press ⌘V to paste a number"; });
    } else subEl.textContent = "Press ⌘V to paste a number";
  }

  /* ---- right-click / secondary-click menu on the number area: Paste · Copy · Select all ---- */
  var menu = $("numMenu");
  function closeMenu() { if (menu) menu.hidden = true; }
  function selectNum() {
    try { var r = document.createRange(); r.selectNodeContents(numEl); var s = window.getSelection(); s.removeAllRanges(); s.addRange(r); } catch (e) {}
  }
  function copyNum() {
    var text = numEl.textContent || entry;
    if (!text) return;
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { subEl.textContent = "Copied"; }).catch(function () {});
    else { selectNum(); try { document.execCommand("copy"); subEl.textContent = "Copied"; } catch (e) {} }
  }
  function openMenu(x, y) {
    if (!menu) return;
    var has = !!entry;
    menu.querySelector('[data-act="paste"]').disabled = inCall;
    menu.querySelector('[data-act="copy"]').disabled = !has;
    menu.querySelector('[data-act="selectall"]').disabled = !has;
    menu.hidden = false;
    var w = menu.offsetWidth, h = menu.offsetHeight;
    menu.style.left = Math.max(6, Math.min(x, window.innerWidth - w - 6)) + "px";
    menu.style.top = Math.max(6, Math.min(y, window.innerHeight - h - 6)) + "px";
  }
  var displayEl = document.querySelector(".display");
  if (displayEl) displayEl.addEventListener("contextmenu", function (e) { e.preventDefault(); openMenu(e.clientX, e.clientY); });
  if (menu) menu.addEventListener("click", function (e) {
    var btn = e.target.closest("button[data-act]"); if (!btn || btn.disabled) return;
    var act = btn.getAttribute("data-act"); closeMenu();
    if (act === "paste") pasteFromClipboard();
    else if (act === "copy") copyNum();
    else if (act === "selectall") selectNum();
  });
  document.addEventListener("click", function (e) { if (menu && !menu.hidden && !menu.contains(e.target)) closeMenu(); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeMenu(); });
  document.addEventListener("contextmenu", function (e) { if (menu && !menu.hidden && !e.target.closest(".display") && !menu.contains(e.target)) closeMenu(); });
  window.addEventListener("blur", closeMenu);
  window.addEventListener("resize", closeMenu);

  /* ---- footer menus: Number (Numero / Telicall) and Voice (Off | Deep › levels | Light › levels) ----
   * Both open upward from their toolbar segment; a ".vparent" item flies a ".vsub" submenu out to
   * the left (hover or click opens it; picking an item closes everything). Neither choice triggers
   * a reconnect: the trunk only decides whether the INVITE carries "X-Provider: telicall", the
   * voice only whether it carries "X-Voice: <semitones>" (00_voice.xml → mod_soundtouch on what you
   * say once answered; the other side hears it, you don't — dial 9199 to hear yourself; only calls
   * you place are shifted; values are -12..12, never 0). */
  var footerMenus = [];
  function closeAllMenus() { footerMenus.forEach(function (c) { c(); }); }
  function attachMenu(btn, menuEl, attr, current, onPick) {
    if (!btn || !menuEl) return;
    var foldTimer = null;
    function closeSubs() {
      if (foldTimer) { clearTimeout(foldTimer); foldTimer = null; }
      menuEl.querySelectorAll(".vsub").forEach(function (sub) { sub.hidden = true; });
      menuEl.querySelectorAll(".vparent").forEach(function (par) { par.setAttribute("aria-expanded", "false"); });
    }
    function foldSoon() {   // a diagonal move from a row into its flyout survives the beat; only one row stays lit
      if (foldTimer) clearTimeout(foldTimer);
      foldTimer = setTimeout(function () { foldTimer = null; closeSubs(); }, 180);
    }
    function close() { menuEl.hidden = true; btn.setAttribute("aria-expanded", "false"); closeSubs(); }
    function openSub(parent) {
      var sub = $(parent.getAttribute("data-sub")); if (!sub) return;
      if (foldTimer) { clearTimeout(foldTimer); foldTimer = null; }
      menuEl.querySelectorAll(".vsub").forEach(function (o) { if (o !== sub) o.hidden = true; });
      menuEl.querySelectorAll(".vparent").forEach(function (par) { par.setAttribute("aria-expanded", par === parent ? "true" : "false"); });
      sub.hidden = false; sub.style.bottom = "0px";
      // A list flyout (Mac voices) lines its first row up with the parent row like a submenu; a
      // level strip sits centred on the row. Either stays within the menu's own height when it
      // fits, and only overhangs downward when it is taller. "bottom" counts from the menu's
      // padding edge.
      var mr = menuEl.getBoundingClientRect(), pr = parent.getBoundingClientRect(), sr = sub.getBoundingClientRect();
      var top = sub.querySelector(".vlist") ? pr.top - 4 : pr.top + (pr.height - sr.height) / 2;
      var b = Math.round(mr.bottom - 1 - (top + sr.height)), maxB = Math.round(mr.height - 2 - sr.height);
      sub.style.bottom = Math.max(Math.min(0, maxB), Math.min(Math.max(0, maxB), b)) + "px";
    }
    btn.addEventListener("click", function (e) {
      e.stopPropagation();
      if (!menuEl.hidden) { close(); return; }
      closeAllMenus();
      menuEl.hidden = false; btn.setAttribute("aria-expanded", "true");
      var cur = current() ? menuEl.querySelector("[" + attr + '="' + current() + '"]') : null;   // reopen on the current choice
      var sub = cur && cur.closest(".vsub");
      if (sub) openSub(menuEl.querySelector('[data-sub="' + sub.id + '"]'));
    });
    menuEl.addEventListener("click", function (e) {
      var parent = e.target.closest(".vparent");
      if (parent) { e.stopPropagation(); openSub(parent); return; }   // hover already opened it; a click must not toggle it shut
      var item = e.target.closest("button[" + attr + "]");
      if (item) { onPick(item.getAttribute(attr)); close(); }
    });
    menuEl.addEventListener("mouseover", function (e) {
      var parent = e.target.closest(".vparent");
      if (parent) { openSub(parent); return; }
      if (e.target.closest(".vsub")) { if (foldTimer) { clearTimeout(foldTimer); foldTimer = null; } return; }
      foldSoon();
    });
    menuEl.addEventListener("mouseleave", foldSoon);
    document.addEventListener("click", function (e) { if (!menuEl.hidden && !menuEl.contains(e.target) && !btn.contains(e.target)) close(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
    window.addEventListener("blur", close);
    footerMenus.push(close);
  }

  // Number: which trunk (and therefore which caller number) the call goes out on.
  var providerBtn = $("provider"), providerMenu = $("providerMenu"), providerLbl = $("providerLbl");
  function providerChoice() { return provider === "numero" && numeroBound() ? "numero-" + numeroLine : provider; }
  // A line with a number is a row of its country's flag (search.css draws it from data-flag),
  // a middle dot and the number as the readout would show it; the provider's name is the
  // row's tooltip and what a screen reader says. A provider without a number is its name.
  function lineRow(button, flag, name, number, otherwise) {
    var shown = number ? formatDisplay(number) || number : otherwise;
    button.setAttribute("data-flag", flag);
    button.setAttribute("aria-label", flag ? name + " · " + shown : name);
    button.title = flag ? name : "";
    button.textContent = flag ? "· " + shown : name;
  }
  function renderProvider() {
    var bound = numeroBound(), selected = numeroNumber(numeroLine), ukBound = telicallBound(), uk = telicallNumber();
    if (providerLbl) providerLbl.textContent = provider === "telicall" ? ukBound ? uk ? "UK" : "Choose" : "Telicall" : !bound ? "Numero" : selected ? numeroLine === "ca" ? "Canada" : "US" : "Choose";
    if (providerBtn) providerBtn.title = provider === "telicall" && ukBound ? uk ? "Telicall UK · " + (formatDisplay(uk) || uk) : "Set a valid UK number in Settings › Dialer" : provider === "numero" && bound ? selected ? "Numero " + (numeroLine === "ca" ? "Canada" : "US") + " · " + (formatDisplay(selected) || selected) : "Choose an available owned Numero number" : "Number the call goes out on";
    lineRow($("telicallUK"), ukBound ? "GB" : "", ukBound ? "Telicall UK" : "Telicall", uk, "invalid number");
    $("telicallUK").disabled = ukBound && !uk;
    $("numeroDefault").hidden = bound;
    ["us", "ca"].forEach(function (line) {
      var button = $(line === "us" ? "numeroUS" : "numeroCA"), number = numeroNumber(line);
      button.hidden = !bound; button.disabled = !number;
      lineRow(button, line === "us" ? "US" : "CA", "Numero " + (line === "us" ? "US" : "Canada"), number, "not configured");
    });
    if (providerMenu) providerMenu.querySelectorAll("[data-provider]").forEach(function (b) {
      b.setAttribute("aria-checked", b.getAttribute("data-provider") === providerChoice() ? "true" : "false");
    });
  }
  attachMenu(providerBtn, providerMenu, "data-provider", providerChoice, function (v) {
    var before = providerChoice();
    if (v === "numero-us" || v === "numero-ca") {
      var line = v.slice(7);
      if (!numeroNumber(line)) return;
      numeroLine = line; provider = "numero";
    } else if (v === "telicall" && (!telicallBound() || telicallNumber())) provider = "telicall";
    else if (v === "numero" && !numeroBound()) provider = "numero";
    else return;
    if (before !== providerChoice()) recoveryRevision++;
    renderProvider();
    try { chrome.storage.local.set({ provider: provider, numeroLine: numeroLine }); } catch (e) { /* storage unavailable */ }
  });
  renderProvider();

  // Voice: mode (Deep = down, Light = up) and level 1–3. Level steps are smaller upward on
  // purpose: a plain shift moves the formants with the pitch, which turns cartoonish sooner going up.
  var VOICE_MODES = { deep: { label: "Deep", levels: ["-3", "-5", "-8"] }, light: { label: "Light", levels: ["2", "4", "6"] },
                      female: { label: "Female", levels: ["female"], ai: true } };   // "female" = the server's AI voice (vc-worker), no levels
  var VOICE_ICONS = { voice: "M2 10v3M6 6v11M10 3v18M14 8v7M18 5v13M22 10v3", deep: "M2 12C5.5 4 8.5 4 12 12s6.5 8 10 0", light: "M2 12c1.2-5 2.3-5 3.5 0s2.3 5 3.5 0 2.3-5 3.5 0 2.3 5 3.5 0 2.3-5 3.5 0 2.3 5 3.5 0",
                      female: "M17 8a5 5 0 1 1-10 0 5 5 0 0 1 10 0M20 21a8 8 0 0 0-16 0",   // audio lines / low wave / high wave / person
                      mac: "M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2zM20.054 15.987H3.946" };   // laptop: a voice converted on this Mac
  var voiceBtn = $("voice"), voiceMenu = $("voiceMenu"), voiceLbl = $("voiceLbl");
  var voiceIco = $("voiceIco"), voicePips = $("voicePips"), voiceChev = $("voiceChev");
  var MAC_PITCH = 12;   // semitones the Mac voices raise the tracked pitch by: a male voice into a female model
  function macVoice(v) { return /^mac:.+/.test(String(v || "")) ? String(v).slice(4) : ""; }   // "mac:<name>" → the voice's name, else ""
  function validVoice(v) { return /^(?:-?(?:1[0-2]|[1-9])|female|mac:.+)$/.test(String(v || "")) ? String(v) : ""; }   // semitones, the server's AI voice, or a Mac voice
  function voiceInfo(v) {   // header value → { mode, level, label }, or null when off / a custom value
    if (macVoice(v)) return { mode: "mac", level: 0, label: macVoice(v), ai: true };
    for (var m in VOICE_MODES) { var i = VOICE_MODES[m].levels.indexOf(v); if (i >= 0) return { mode: m, level: i + 1, label: VOICE_MODES[m].label, ai: !!VOICE_MODES[m].ai }; }
    return null;
  }
  function renderVoice() {
    if (!voiceBtn) return;
    var info = voiceInfo(voice);
    if (voiceLbl) voiceLbl.textContent = info ? (info.label.length > 14 ? info.label.slice(0, 13) + "…" : info.label) : (voice ? voice + " st" : "Voice");
    if (voiceIco) voiceIco.setAttribute("d", VOICE_ICONS[info ? info.mode : "voice"]);
    if (voicePips) { voicePips.hidden = !info || !!info.ai; voicePips.querySelectorAll("i").forEach(function (b, i) { b.classList.toggle("f", !!info && !info.ai && i < info.level); }); }
    if (voiceChev) voiceChev.style.display = info ? "none" : "";   // an <svg> has no .hidden property
    voiceBtn.classList.toggle("on", !!voice);
    if (!voiceMenu) return;
    voiceMenu.querySelectorAll("[data-voice]").forEach(function (b) { b.setAttribute("aria-checked", b.getAttribute("data-voice") === voice ? "true" : "false"); });
    voiceMenu.querySelectorAll(".vparent").forEach(function (row) {   // Deep › / Light › rows show the current level
      var on = !!info && info.mode === row.getAttribute("data-mode");
      row.classList.toggle("sel", on);
      row.querySelectorAll(".pips i").forEach(function (b, i) { b.classList.toggle("f", on && i < info.level); });
    });
    voiceMenu.querySelectorAll(".lvls button, .vlist button").forEach(function (b) { b.classList.toggle("on", b.getAttribute("data-voice") === voice); });
  }
  attachMenu(voiceBtn, voiceMenu, "data-voice", function () { return voice; }, function (v) {
    voice = validVoice(v); renderVoice();
    try { chrome.storage.local.set({ voice: voice }); } catch (e) { /* storage unavailable */ }
  });
  renderVoice();

  // Mac voices: RVC models converted on this Mac by the local voice service (macvoice.js →
  // web-dialer/mac-voice). The Mac › flyout lists whatever the service reports; while the service
  // is off the row is dimmed and the flyout says so. Nothing is sent to the server for these.
  var macList = $("voiceMacList"), macRow = voiceMenu && voiceMenu.querySelector('.vparent[data-mode="mac"]');
  function renderMacVoices() {
    if (!macList) return;
    var on = MacVoice.online(), names = MacVoice.voices();
    macList.textContent = "";
    if (!on || !names.length) {
      var note = document.createElement("button"); note.type = "button"; note.disabled = true; note.className = "note";
      note.textContent = on ? "No voices in ~/Ottocaller/Voices" : "Voice service is off";
      macList.appendChild(note);
    }
    names.forEach(function (n) {
      var b = document.createElement("button"); b.type = "button"; b.setAttribute("role", "menuitemradio");
      b.setAttribute("data-voice", "mac:" + n); b.title = n;
      b.innerHTML = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="' + VOICE_ICONS.female + '"/></svg>';
      b.appendChild(document.createTextNode(n));   // a file name: text, never markup
      macList.appendChild(b);
    });
    if (macRow) macRow.classList.toggle("off", !on);
    renderVoice();
  }
  MacVoice.onChange(renderMacVoices);
  renderMacVoices();
  MacVoice.connect();
  if (voiceBtn) voiceBtn.addEventListener("click", function () { MacVoice.refresh(); });   // pick up renamed / added voice files

  /* SIP.js asks this for the call's local media (defaultSessionDescriptionHandlerFactory above).
   * A Mac voice hands back the service's converted stream; anything else is the plain microphone. */
  function stopStream(stream) {
    if (stream) stream.getTracks().forEach(function (track) { try { track.stop(); } catch (e) { /* already stopped */ } });
  }
  function cancelPendingMedia() { mediaWaiters.slice().forEach(function (cancel) { cancel(); }); }
  function mediaFailed(token, gen) {
    return !!(mediaFailure && mediaFailure.token === token && mediaFailure.gen === gen && attempt === token && generation === gen && !stopped && panelVisible);
  }
  function showMediaFailure() {
    if (!mediaFailure || !mediaFailed(mediaFailure.token, mediaFailure.gen)) return;
    subEl.textContent = mediaFailure.kind === "denied" ? "Microphone blocked — allow Dark Search to use the microphone, then try again" : MEDIA_TIMEOUT_NOTE;
    setStatus(mediaFailure.kind === "denied" ? "Microphone blocked" : "Microphone didn't start", "err");
  }
  function startMedia(start, token, gen, usesMacVoice) {
    return new Promise(function (resolve, reject) {
      var settled = false, timer;
      function current() { return !settled && !stopped && panelVisible && token === activeAttempt && gen === generation && networkRouteCurrent(activeNetworkRoute, gen); }
      function finish(error, stream) {
        if (settled) { stopStream(stream); return; }
        if (error && current() && /NotAllowed|PermissionDenied|permission|not allowed/i.test(String((error.name || "") + " " + (error.message || "")))) {
          mediaFailure = { token: token, gen: gen, kind: "denied" };
        }
        settled = true; clearTimeout(timer);
        mediaWaiters = mediaWaiters.filter(function (value) { return value !== cancel; });
        if (error) reject(error); else resolve(stream);
      }
      function cancel(error) {
        if (usesMacVoice && token === activeAttempt) MacVoice.stop();
        finish(error || new DOMException("Call cancelled", "AbortError"));
      }
      mediaWaiters.push(cancel);
      timer = setTimeout(function () {
        if (!current()) { cancel(); return; }
        mediaFailure = { token: token, gen: gen, kind: "timeout" };
        var error = new Error("Microphone did not start in time"); error.name = "MediaStartTimeoutError";
        cancel(error);
      }, MEDIA_START_TIMEOUT);
      Promise.resolve().then(function () {
        if (!current()) throw new DOMException("Call cancelled", "AbortError");
        return start(current);
      }).then(function (stream) {
        if (!current()) { stopStream(stream); if (!settled) cancel(); return; }
        finish(null, stream);
      }, function (error) { finish(error); });
    });
  }
  async function localMedia(constraints, gen) {
    var token = activeAttempt;
    if (stopped || !panelVisible || !token || gen !== generation || !networkRouteCurrent(activeNetworkRoute, gen)) throw new DOMException("Call cancelled", "AbortError");
    var stream;
    if (macVoice(voice)) stream = await startMedia(function (current) { return MacVoice.start(macVoice(voice), MAC_PITCH, current); }, token, gen, true);
    else if (!constraints || (!constraints.audio && !constraints.video)) stream = new MediaStream();
    else stream = await startMedia(function () { return navigator.mediaDevices.getUserMedia(constraints); }, token, gen, false);
    if (stopped || !panelVisible || token !== activeAttempt || gen !== generation || !networkRouteCurrent(activeNetworkRoute, gen)) {
      stopStream(stream);
      MacVoice.stop();
      throw new DOMException("Call cancelled", "AbortError");
    }
    if (calling && cur && cur.direction === "out") { subEl.textContent = "Calling…"; setStatus("Calling…", "calling"); }
    return stream;
  }

  /* ------------------------------ SIP ------------------------------ */

  function configured(c) { return !!(c && c.wss && c.domain && c.user && c.password); }

  async function boot() {
    if (stopped) return;
    var gen = ++generation;
    activeNetworkRoute = null;
    clearTimeout(routeExpiryTimer); routeExpiryTimer = null;
    closeSessionHandlers();
    reconnectPending = false;
    cancelPendingMedia();
    activeAttempt = 0; attempt++;
    stopRingback();
    if (cur) {                 // a call still dialing goes down with the old connection (its delegate is stale from here on)
      cur.dropped = true; callEnd(cur);
      MacVoice.stop();
      calling = false; syncButtons(); subEl.textContent = "Call ended";
    }
    registered = false; connecting = true;
    callBtn.disabled = true;

    if (simple) {
      var old = simple; simple = null;
      try { await old.disconnect(); } catch (e) { /* already down */ }
    }
    if (gen !== generation) return;

    if (!configured(CFG)) {
      setupEl.hidden = false;
      setStatus("Not configured", "err");
      connecting = false;
      return;
    }
    setupEl.hidden = true;
    var network;
    try { network = validatedNetworkRoute(CFG.protectedRoute); }
    catch (error) { stopNetworkRoute(error.message); return; }
    activeNetworkRoute = network;
    armRouteExpiry(network);

    var remote = $("remote");
    var su = new SIP.Web.SimpleUser(CFG.wss, {
      aor: "sip:" + CFG.user + "@" + CFG.domain,
      media: { remote: { audio: remote } },
      userAgentOptions: {
        authorizationUsername: CFG.user,
        authorizationPassword: CFG.password,
        displayName: CFG.user,
        logConfiguration: false,
        logBuiltinEnabled: false,
        // Where the call's microphone comes from: the real one, or the Mac voice service's
        // converted stream when a Mac voice is selected (macvoice.js, localMedia below).
        sessionDescriptionHandlerFactoryOptions: { peerConnectionConfiguration: iceConfiguration(network) },
        sessionDescriptionHandlerFactory: callDescriptionFactory(network, gen)
      }
    });
    su.delegate = {
      onCallReceived: async function () {
        if (gen === generation && (inCall || calling || incoming)) {
          // SimpleUser owns one session. A repeated callback must not replace it
          // or expire an established allocation merely because another call arrived.
          if (!networkRouteCurrent(network, gen, inCall)) stopNetworkRoute("The call route changed or expired. Reconnect before calling");
          return;
        }
        if (gen !== generation || stopped || !panelVisible || endingCall || !networkRouteCurrent(network, gen)) {
          try { await su.decline(); } catch (e) { /* the caller may already have left */ }
          return;
        }
        closeSheet();
        attempt++; recovering = null;
        subEl.textContent = "Incoming call — answer when you're ready";
        whoEl.textContent = "";
        var from = "";
        try { from = su.session && su.session.remoteIdentity && su.session.remoteIdentity.uri ? String(su.session.remoteIdentity.uri.user || "") : ""; } catch (e) { from = ""; }
        callStart(from || "unknown", "", "in");
        incoming = true; syncButtons();
        setStatus("Incoming call", "calling");
      },
      onCallAnswered: function () {
        if (gen !== generation) return;
        if (stopped || !panelVisible || !activeAttempt || !networkRouteCurrent(network, gen)) {
          try { Promise.resolve(su.hangup()).catch(function () {}); } catch (e) { /* already ended */ }
          return;
        }
        if (cur) cur.answeredAt = Date.now();
        stopRingback();
        inCall = true; calling = false; incoming = false; syncButtons(); startTimer();
        setStatus("In a call", "oncall");
        var vi = cur && cur.voice ? voiceInfo(cur.voice) : null;
        subEl.textContent = cur && cur.voice ? "Connected · voice " + (vi ? vi.label : cur.voice) : "Connected";
        sendPendingExt();
      },
      onCallHangup: function () {
        if (gen !== generation) return;
        if (cur && mediaFailed(attempt, gen)) cur.error = true;
        callEnd(cur);
        cancelPendingMedia();
        stopRingback();
        MacVoice.stop();
        activeAttempt = 0; incoming = false; inCall = false; muted = false;
        $("mute").classList.remove("on"); $("muteLbl").textContent = "Mute";
        calling = false; syncButtons(); subEl.textContent = "Call ended"; stopTimer();
        setStatus(registered ? "Registered" : "Not registered", registered ? "reg" : "");
        showMediaFailure();
        if (network.mode === "proxy" && network.expiresAt * 1000 <= Date.now()) {
          stopNetworkRoute("The protected call route expired. Reconnect the proxy before calling");
          return;
        }
        if (reconnectPending) boot();
      },
      onRegistered: function () {
        if (gen !== generation) return;
        if (!networkRouteCurrent(network, gen) && !(inCall && networkRouteCurrent(network, gen, true))) {
          stopNetworkRoute("The call route changed or expired. Reconnect before calling"); return;
        }
        registered = true; connecting = false;
        if (inCall) return;
        setStatus("Registered", "reg");
        callBtn.disabled = false;
        if (pending) {
          var p = pending; pending = null;
          if (panelVisible && !stopped) {
            setNumber(p.number, p.name); setLead(p.ref);
            if (CFG.autodial !== false) dial();
          }
        }
      },
      onUnregistered: function () {
        if (gen !== generation) return;
        registered = false; setStatus("Not registered", "err"); callBtn.disabled = true;
      },
      onServerConnect: function () {
        if (gen !== generation) return;
        setStatus("Connected, registering…");
        su.register().catch(function (e) { setStatus("Registration failed", "err"); console.error(e); });
      },
      onServerDisconnect: function (e) {
        if (gen !== generation) return;
        if (cur && !cur.answeredAt) cur.dropped = true;   // SIP.js ends the call next; it failed, nobody declined it
        registered = false; connecting = false;
        setStatus(e ? "Disconnected — " + (e.message || "connection lost") : "Disconnected", "err");
        callBtn.disabled = true;
      }
    };
    simple = su;
    try {
      setStatus("Connecting…");
      await su.connect();
    } catch (e) {
      if (gen !== generation) return;
      connecting = false;
      setStatus("Connect failed — check the WebSocket URL", "err");
      console.error(e);
    }
  }

  // Post-dial extension: send the captured "ext" digits as DTMF once connected.
  function sendPendingExt() {
    if (!entryExt) return;
    var digits = String(entryExt).replace(/\D/g, ""), ext = entryExt; entryExt = "";
    if (!digits) return;
    var i = 0;
    setTimeout(function tick() {
      if (!inCall || !simple || i >= digits.length) return;
      try { simple.sendDTMF(digits[i]); } catch (e) { /* session gone */ }
      i++; setTimeout(tick, 350);
    }, 1200);
    subEl.textContent = "Sending extension " + ext;
  }

  /* Search asks macOS explicitly from a visible Call or Answer gesture. This bundled page
   * shows a denial inline; it never queues an automatic retry or opens a permission page. */
  async function micState() {
    if (window.__searchDialer && typeof window.__searchDialer.requestMicrophone === "function") {
      try {
        var permission = await window.__searchDialer.requestMicrophone();
        return permission && permission.state === "granted" ? "granted" : "denied";
      } catch (e) { return "denied"; }
    }
    try { var st = await navigator.permissions.query({ name: "microphone" }); return st.state; }
    catch (e) { return "prompt"; }
  }
  function needMic(n, state, ref) {
    // A denial never leaves an old number waiting to call after a later permission change.
    pending = null; activeAttempt = 0;
    subEl.textContent = "Microphone blocked — allow Dark Search in System Settings › Privacy & Security, then try again";
    setStatus("Microphone blocked", "err");
  }

  async function dial(retry) {
    var context = retry && retry.microphoneRetry && retry.kind === "out" ? retry : null;
    if (context && !retryCurrent(context)) return;
    var n = context ? context.number : cleanNumber(entry);
    if (!n || stopped || !panelVisible || !registered || inCall || calling || incoming || endingCall || recovering || !simple) return;
    if (!requireNetworkRoute()) return;
    var route = context ? context.route : numberRoute(n); // freeze the chosen line before permission/media work can yield
    if (route.error) { subEl.textContent = route.error; return; }
    var ref = context ? context.ref : lead && lead.number === n ? lead.ref : null;
    context = context || retryContext("out", n, route, ref);
    var token = ++attempt, gen = generation, client = simple;
    context.token = token;
    mediaFailure = null;
    activeAttempt = token;
    subEl.textContent = "Allow Dark Search to use the microphone if macOS asks…";
    setStatus("Checking microphone…");
    var mic = await micState();
    if (stopped || !panelVisible || token !== activeAttempt || gen !== generation || client !== simple) return;
    if (mic !== "granted") {
      needMic();
      if (await recoverMicrophone(context)) return dial(context);
      return;
    }
    if (inCall || calling) return;               // a second tap got here while the first was checking the microphone
    if (macVoice(voice) && !MacVoice.online()) { subEl.textContent = "Voice service is off — start it or pick another voice"; return; }
    subEl.textContent = "Starting microphone…";
    setStatus("Starting microphone…", "calling");
    calling = true; syncButtons();               // show the red hang-up straight away
    lead = null;                                 // one call per reference
    var call = callStart(n, context.name, "out", ref, route);
    // The final answer to our INVITE (486 busy, 480 no answer, …), kept for the call record.
    var finalStatus = function (resp) { var sc = resp && resp.message && resp.message.statusCode; if (sc) call.code = sc; };
    startRingback();                             // ring while dialing, not only once 180 arrives
    try {
      var extraHeaders = call.provider === "telicall" ? ["X-Provider: telicall"] : [];
      if (call.provider === "numero" && call.numeroLine) extraHeaders.push("X-Numero-Line: " + call.numeroLine);
      if (voice && !macVoice(voice)) extraHeaders.push("X-Voice: " + voice);   // 00_voice.xml: semitones → mod_soundtouch, "female" → vc_start.lua; Mac voices are converted here
      // earlyMedia:true makes SIP.js apply the 183 Session Progress media and attach the remote
      // audio while it's still ringing. A bare 180 carries no audio, so we ring locally until
      // real early media (183 with an SDP body), the answer or a hang-up replaces it.
      // extraHeaders must sit at the top level of the InviterOptions: SIP.js 0.21 builds the
      // INVITE in the Inviter constructor from options.extraHeaders. A nested requestOptions
      // object is only read for re-INVITEs, so headers placed there silently never leave.
      await client.call("sip:" + encodeURIComponent(route.user) + "@" + CFG.domain,
        { earlyMedia: true, inviteWithoutSdp: false, extraHeaders: extraHeaders },
        { requestDelegate: { onProgress: function (resp) {
            if (inCall) return;
            var msg = resp && resp.message, sc = msg && msg.statusCode;
            if (sc === 180 || sc === 183) subEl.textContent = "Ringing…";
            if (sc === 183 && msg.body) stopRingback();   // real early media takes over
            else startRingback();                          // 180, or 183 without audio: keep ringing
        }, onAccept: finalStatus, onRedirect: finalStatus, onReject: finalStatus } });
    } catch (e) {
      if (mediaFailed(token, gen)) {
        context.cleanup = failMediaStart(client, call);
        if (await recoverMicrophone(context)) return dial(context);
        return;
      }
      if (token !== activeAttempt || gen !== generation || stopped || !panelVisible) return;
      // Nothing was sent, or it could not be: the microphone, the voice service, the connection.
      // A busy or unanswered number never lands here; it ends through onCallHangup with a status.
      stopRingback();
      MacVoice.stop();
      calling = false; syncButtons();
      var text = String(e && ((e.name || "") + " " + (e.message || "")) || e);
      call.error = true; callEnd(call);
      nudge(displayEl, "shake");
      if (/voice service/i.test(text)) subEl.textContent = text.replace(/^\w*Error\s*/, "");
      else if (/NotAllowed|PermissionDenied|permission|not allowed/i.test(text)) {
        needMic();
        context.cleanup = failMediaStart(client, call);
        if (await recoverMicrophone(context)) return dial(context);
      }
      else subEl.textContent = "Call failed";
      console.error(e);
    }
  }
  function failMediaStart(client, call) {
    if (call) { call.error = true; callEnd(call); }
    stopRingback(); MacVoice.stop();
    activeAttempt = 0; incoming = false; calling = false; inCall = false; syncButtons();
    var cleanup;
    try { cleanup = Promise.resolve(client.hangup()).catch(function () {}); } catch (e) { cleanup = Promise.resolve(); }
    showMediaFailure();
    return cleanup;
  }
  async function hangup() {
    // A queued number or permission check is a call too, even while the red button is inert.
    cancelPendingMedia();
    pending = null; activeAttempt = 0; attempt++; cancelEpoch++; recovering = null; entryExt = ""; lead = null;
    var client = simple, decline = incoming, hadCall = !!cur;
    if (!inCall && cur) cur.hung = true;
    if (cur) callEnd(cur, stopped);
    stopRingback(); MacVoice.stop(); stopTimer();
    incoming = false; calling = false; inCall = false; muted = false;
    $("mute").classList.remove("on"); $("muteLbl").textContent = "Mute";
    syncButtons();
    if (hadCall) subEl.textContent = "Call ended";
    if (!client || endingCall) return;
    endingCall = true;
    try { await (decline ? client.decline() : client.hangup()); } catch (e) { /* no session, or it already ended */ }
    finally {
      endingCall = false;
      if (!stopped && client === simple && reconnectPending) boot();
    }
  }

  async function answerIncoming(retry) {
    var context = retry && retry.microphoneRetry && retry.kind === "in" ? retry : null;
    if (context && !sameIncoming(context)) return;
    if (!incoming || stopped || !panelVisible || endingCall || recovering || !simple) return;
    if (!requireNetworkRoute()) return;
    context = context || retryContext("in", cur && cur.number || "", null, null);
    var client = simple, token = ++attempt, gen = generation;
    context.token = token;
    mediaFailure = null;
    activeAttempt = token;
    incoming = false; calling = true; syncButtons(); subEl.textContent = "Answering…";
    setStatus("Answering…", "calling");
    try {
      subEl.textContent = "Allow Dark Search to use the microphone if macOS asks…";
      var mic = await micState();
      if (token !== activeAttempt || gen !== generation || stopped || !panelVisible) return;
      if (mic !== "granted") {
        calling = false; incoming = true; syncButtons(); needMic();
        if (await recoverMicrophone(context)) {
          if (sameIncoming(context)) return answerIncoming(context);
          subEl.textContent = "Microphone allowed. The incoming call ended — ask the caller to try again";
          return;
        }
        if (sameIncoming(context)) { await hangup(); needMic(); }
        return;
      }
      subEl.textContent = "Starting microphone…";
      await client.answer();
    }
    catch (e) {
      if (mediaFailed(token, gen) || /NotAllowed|PermissionDenied|permission|not allowed/i.test(String((e && e.name || "") + " " + (e && e.message || "")))) {
        if (!retryCurrent(context)) return;
        // SIP may already have terminated an Invitation whose media failed. Never
        // treat a later incoming call as the one the user originally answered.
        if (sameIncoming(context)) {
          activeAttempt = 0; calling = false; incoming = true; syncButtons(); showMediaFailure();
        } else failMediaStart(client, context.call);
        if (await recoverMicrophone(context)) {
          if (sameIncoming(context)) return answerIncoming(context);
          subEl.textContent = "Microphone allowed. The incoming call ended — ask the caller to try again";
          setStatus(registered ? "Registered" : "Not registered", registered ? "reg" : "");
          return;
        }
        if (sameIncoming(context)) { await hangup(); needMic(); }
        return;
      }
      if (token !== activeAttempt || gen !== generation || stopped || !panelVisible) return;
      await hangup();
      subEl.textContent = "Could not answer";
    }
  }

  function setVisible(value) {
    panelVisible = !!value && !stopped;
    if (!panelVisible) return hangup();
    return true;
  }
  function shutdown() {
    if (stopped) return false;
    stopped = true; panelVisible = false; generation++;
    activeNetworkRoute = null;
    clearTimeout(routeExpiryTimer); routeExpiryTimer = null;
    closeSessionHandlers();
    var client = simple, hangupTask = hangup();
    ending.slice().forEach(function (call) { fileCall(call, true); });
    simple = null; registered = false; connecting = false;
    return Promise.allSettled([hangupTask, client ? Promise.resolve().then(function () { return client.disconnect(); }) : Promise.resolve()]);
  }

  callBtn.addEventListener("click", dial);
  hangBtn.addEventListener("click", hangup);
  $("answer").addEventListener("click", answerIncoming);
  $("decline").addEventListener("click", hangup);
  $("mute").addEventListener("click", function () {
    if (!inCall || !simple) return;
    muted = !muted;
    var sdh = simple.session && simple.session.sessionDescriptionHandler;
    var pc = sdh && sdh.peerConnection;
    if (pc) pc.getSenders().forEach(function (s) { if (s.track && s.track.kind === "audio") s.track.enabled = !muted; });
    $("mute").classList.toggle("on", muted);
    $("muteLbl").textContent = muted ? "Unmute" : "Mute";
  });

  /* ------------------------------ requests from otto ------------------------------ */

  function requestDial(number, name, ref) {
    if (stopped || !panelVisible) return;
    var r = NORMALIZE(number, region);
    var n = r.dial || cleanNumber(number);
    if (!n) return;
    if (inCall || calling || incoming || endingCall) {
      // A new dial request cannot use this lease, and must not expire a healthy
      // established call. A different native route still cancels that call.
      if (activeNetworkRoute && !networkRouteCurrent(activeNetworkRoute, generation, inCall)) {
        stopNetworkRoute("The call route changed or expired. Reconnect before calling"); return;
      }
      closeSheet();
      subEl.textContent = "Hang up to call " + (r.display || n);
      return;
    }
    if (CFG) {
      try { validatedNetworkRoute(CFG.protectedRoute); }
      catch (error) { stopNetworkRoute(error.message); return; }
    }
    closeSheet();
    setEntry(n, r.ext); whoEl.textContent = name ? String(name) : "";
    setLead(ref);
    if (CFG && CFG.autodial === false) { pending = null; subEl.textContent = "Ready to call"; return; }
    if (registered) dial();
    else {
      pending = { number: number, name: name, ref: ref };
      subEl.textContent = connecting ? "Will call once registered…" : "Not registered";
    }
  }

  // Which browser window this page lives in (side panels are per window). A request that
  // names another window is for a different panel.
  var myWindowId = null;
  var windowReady = chrome.windows.getCurrent().then(function (w) { myWindowId = w.id; return w; }).catch(function () { return null; });
  function forMe(windowId) { return windowId == null || myWindowId == null || windowId === myWindowId; }

  chrome.runtime.onMessage.addListener(function (msg) {
    if (!msg) return;
    if (msg.type === "mic-granted") {
      // the one-time microphone tab reported back: resume the call it interrupted
      if (panelVisible && !stopped && pending && registered && !inCall) { var p = pending; pending = null; setNumber(p.number, p.name); setLead(p.ref); dial(); }
      else if (panelVisible && !stopped && !inCall) subEl.textContent = "Microphone allowed";
      return;
    }
    if (msg.type !== "dialer:dial") return;
    var requestEpoch = cancelEpoch, wasVisible = panelVisible;
    windowReady.then(function () {
      if (!wasVisible || requestEpoch !== cancelEpoch || !forMe(msg.windowId)) return;
      chrome.storage.session.remove("pendingDial").catch(function () {});
      requestDial(msg.number, msg.name, Calls.cleanRef(msg.ref));
    });
  });

  /* ------------------------------ settings ------------------------------ */

  function openSettings() { chrome.runtime.openOptionsPage(); }
  $("gear").addEventListener("click", openSettings);
  $("setupBtn").addEventListener("click", openSettings);

  // The Number and Voice footer menus (see "footer menus" above) persist their choices in
  // chrome.storage.local and never trigger a reconnect.

  var CFG_KEYS = ["wss", "domain", "user", "password", "autodial"];
  var NUMERO_KEYS = ["numeroUS", "numeroCA"];
  var TELICALL_KEYS = ["telicallUK"];
  chrome.storage.onChanged.addListener(function (changes, area) {
    if (area !== "local") return;
    var changedNetwork = "protectedRoute" in changes;
    if (changedNetwork) {
      routeSettingsEpoch++;
      CFG = Object.assign(CFG || {}, { protectedRoute: changes.protectedRoute.newValue });
      stopNetworkRoute("The call route changed. Reconnecting…");
    }
    if (CFG_KEYS.concat(NUMERO_KEYS, TELICALL_KEYS).some(function (key) { return key in changes; })) recoveryRevision++;
    if (changes[Calls.OUTBOX_KEY]) outbox = Calls.list(changes[Calls.OUTBOX_KEY].newValue);
    if (changes.provider) {  // trunk choice — sync the selector, never reconnect
      if ((changes.provider.newValue === "telicall" ? "telicall" : "numero") !== provider) recoveryRevision++;
      provider = changes.provider.newValue === "telicall" ? "telicall" : "numero";
      renderProvider();
    }
    if (changes.numeroLine) {
      if (lineChoice(changes.numeroLine.newValue) !== numeroLine) recoveryRevision++;
      numeroLine = lineChoice(changes.numeroLine.newValue);
      renderProvider();
    }
    if (NUMERO_KEYS.some(function (key) { return key in changes; })) {
      freshConfiguration(NUMERO_KEYS).then(function (values) {
        if (stopped) return;
        if (applyConfiguration(values, false)) boot();
        renderProvider();
      }).catch(function () { if (!stopped) stopNetworkRoute("The call route couldn't be read. Try again"); });
    }
    if (TELICALL_KEYS.some(function (key) { return key in changes; })) {
      freshConfiguration(TELICALL_KEYS).then(function (values) {
        if (stopped) return;
        if (applyConfiguration(values, false)) boot();
        renderProvider();
      }).catch(function () { if (!stopped) stopNetworkRoute("The call route couldn't be read. Try again"); });
    }
    if (changes.voice) {     // voice changer — sync the menu, never reconnect
      voice = validVoice(changes.voice.newValue);
      renderVoice();
    }
    if (changes.region) {    // default country — re-render the current number, never reconnect
      region = (changes.region.newValue || "GB").toUpperCase();
      renderNum();
    }
    if (changedNetwork) { refreshConnectionConfiguration(true); return; }
    if (CFG_KEYS.some(function (key) { return key in changes; })) refreshConnectionConfiguration(false);
  });

  /* ------------------------------ window size (popup fallback only) ------------------------------ */
  // If the popup fallback landed in a full-screen or maximized window (macOS can inherit that
  // from the opener), shrink it. Never touch a normal browser window: in the side panel,
  // getCurrent() is the user's main window.
  setTimeout(function () {
    windowReady.then(function (w) {
      if (w && w.type === "popup" && (w.state === "fullscreen" || w.state === "maximized")) {
        chrome.windows.update(w.id, { state: "normal", width: 380, height: 680 });
      }
    });
  }, 400);

  /* ------------------------------ start ------------------------------ */

  callBtn.disabled = true;
  window.__searchDialer.bindLifecycle({ setVisible: setVisible, hangup: hangup, shutdown: shutdown });
  placeSheet();
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(placeSheet);
  var q = new URLSearchParams(location.search);
  var startName = q.get("name") || "";
  var startNumber = q.get("n") ? NORMALIZE(q.get("n"), region).dial : "";
  var startRef = null;
  try { startRef = q.get("ref") ? Calls.cleanRef(JSON.parse(q.get("ref"))) : null; } catch (e) { startRef = null; }
  if (startNumber) { setNumber(q.get("n"), startName); setLead(startRef); }

  var startupEpoch = cancelEpoch;
  Promise.all([freshConfiguration(CFG_KEYS.concat(NUMERO_KEYS, TELICALL_KEYS, ["provider", "numeroLine", "region", "voice"])), chrome.storage.session.get("pendingDial"), windowReady]).then(function (r) {
    if (stopped) return;
    CFG = r[0];
    provider = r[0].provider === "telicall" ? "telicall" : "numero";
    numeroLine = lineChoice(r[0].numeroLine);
    renderProvider();
    voice = validVoice(r[0].voice);
    renderVoice();
    region = (r[0].region || "GB").toUpperCase();
    if (entry) renderNum();                       // re-render a URL-supplied number with the real region
    var pd = r[1] && r[1].pendingDial;
    if (cancelEpoch === startupEpoch && panelVisible && startNumber && q.get("auto") === "1" && CFG.autodial !== false) {
      pending = { number: q.get("n"), name: startName, ref: startRef };   // popup fallback: request in the URL
    } else if (pd && pd.number && Date.now() - (pd.at || 0) < 60000 && forMe(pd.windowId)) {
      chrome.storage.session.remove("pendingDial").catch(function () {});
      var pdRef = Calls.cleanRef(pd.ref);
      setNumber(pd.number, pd.name); setLead(pdRef);              // with autodial off, the Call button still dials for this lead
      if (cancelEpoch === startupEpoch && panelVisible && CFG.autodial !== false) pending = { number: pd.number, name: pd.name, ref: pdRef };
    }
    boot();
  }).catch(function () { if (!stopped) stopNetworkRoute("The call route couldn't be read. Try again"); });
})();
