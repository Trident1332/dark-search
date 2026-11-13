/* A SIP INVITE must carry a complete, usable audio route. SIP.js can finish
 * gathering on its timer with no candidates; FreeSWITCH cannot use trickle ICE.
 * Nothing here logs SDP, addresses, or relay credentials. */
(function (root) {
  "use strict";
  var gatheringTimeout = 20000, descriptionTimeout = 35000;
  function failure(cancelled) {
    var error = new Error(cancelled ? "The call ended before its audio connection was ready" : "The audio connection could not be prepared. Check the proxy and try again.");
    error.name = cancelled ? "AbortError" : "AudioRouteError";
    return error;
  }
  function address(value) {
    if (typeof value !== "string" || !value || /[\s\x00]/.test(value)) return false;
    if (/^\d+\.\d+\.\d+\.\d+$/.test(value)) {
      var parts = value.split(".").map(Number);
      return parts.every(function (x) { return x >= 0 && x <= 255; }) && parts[0] !== 0 && parts[0] !== 127 && parts[0] < 224;
    }
    if (value.indexOf(":") < 0 || value === "::" || value === "::1") return false;
    try { return new URL("http://[" + value + "]/").hostname.length > 2; } catch (e) { return false; }
  }
  function inspect(body, relayOnly) {
    if (typeof body !== "string" || body.length > 131072) return { usable: false, unsafe: true };
    var audio = false, usable = false, unsafe = false, related = false, relayAddresses = [];
    body.split(/\r?\n/).forEach(function (line) {
      if (/^m=/.test(line)) audio = /^m=audio [1-9]\d*\s/.test(line);
      if (!/^a=candidate:/.test(line)) return;
      var fields = line.slice(12).trim().split(/\s+/);
      var valid = fields.length >= 8 && fields[6] === "typ" && /^(udp|tcp)$/i.test(fields[2])
        && /^\d+$/.test(fields[5]) && Number(fields[5]) > 0 && Number(fields[5]) <= 65535 && address(fields[4]);
      if (relayOnly && (!valid || fields[7] !== "relay")) unsafe = true;
      if (valid && fields[7] === "relay") relayAddresses.push(fields[4].toLowerCase());
      if (audio && fields[1] === "1" && valid && (!relayOnly || fields[7] === "relay")) usable = true;
      if (fields.indexOf("raddr") >= 0 || fields.indexOf("rport") >= 0) related = true;
    });
    if (relayOnly) {
      body.split(/\r?\n/).forEach(function (line) {
        if (!/^c=IN\s+IP[46]\s+/.test(line)) return;
        var value = (line.trim().split(/\s+/)[2] || "").toLowerCase();
        if (value !== "0.0.0.0" && value !== "::" && relayAddresses.indexOf(value) < 0) unsafe = true;
      });
    }
    return { usable: usable && !unsafe, unsafe: unsafe, related: related };
  }
  function sanitize(body, relayOnly) {
    if (!relayOnly) return body;
    // Related/base addresses are optional ICE metadata, not relay endpoints.
    // Suppress them rather than exposing a local interface in SIP signaling.
    return body.replace(/^(a=candidate:[^\r\n]*)/gm, function (line) {
      return line.replace(/\s+raddr\s+\S+/g, " raddr 0.0.0.0").replace(/\s+rport\s+\d+/g, " rport 0");
    });
  }
  function guard(handler, options) {
    options = options || {};
    if (!handler || typeof handler.getDescription !== "function" || typeof handler.close !== "function") throw failure(false);
    var get = handler.getDescription, close = handler.close, closed = false, pending = new Set();
    handler.close = function () {
      if (closed) return;
      closed = true;
      Array.from(pending).forEach(function (cancel) { cancel(); });
      return close.apply(handler, arguments);
    };
    handler.getDescription = function (settings, modifiers) {
      return new Promise(function (resolve, reject) {
        var done = false, description, timer, peer = handler.peerConnection;
        var current = function () { return !closed && peer && peer.connectionState !== "closed" && (!options.current || options.current()); };
        var cancel = function () { finish(failure(true)); };
        var finish = function (error, result) {
          if (done) return;
          done = true; clearTimeout(timer); pending.delete(cancel);
          if (peer && peer.removeEventListener) {
            peer.removeEventListener("icecandidate", check);
            peer.removeEventListener("icegatheringstatechange", check);
          }
          if (error) {
            if (error.name === "AudioRouteError" && current() && options.failed) options.failed();
            reject(error);
            if (error.name === "AudioRouteError" || error.name === "AbortError") handler.close();
          } else resolve(result);
        };
        var check = function () {
          if (done || !description) return;
          if (!current()) { cancel(); return; }
          if (description.contentType !== "application/sdp") { finish(failure(false)); return; }
          var body = peer.localDescription && peer.localDescription.sdp || description.body;
          var state = inspect(body, !!options.relayOnly);
          if (state.usable) { finish(null, Object.assign({}, description, { body: sanitize(body, !!options.relayOnly) })); return; }
          if (state.unsafe || peer.iceGatheringState !== "gathering") finish(failure(false));
        };
        pending.add(cancel);
        if (!current()) { cancel(); return; }
        timer = setTimeout(function () { finish(current() ? failure(false) : failure(true)); }, options.timeout || descriptionTimeout);
        if (peer.addEventListener) {
          peer.addEventListener("icecandidate", check);
          peer.addEventListener("icegatheringstatechange", check);
        }
        Promise.resolve().then(function () {
          if (!current()) throw failure(true);
          return get.call(handler, Object.assign({}, settings, { iceGatheringTimeout: options.gatheringTimeout || gatheringTimeout }), modifiers);
        }).then(function (value) { description = value; check(); }, function (error) { finish(error); });
      });
    };
    return handler;
  }
  var api = { guard: guard, inspect: inspect, gatheringTimeout: gatheringTimeout };
  if (typeof module === "object" && module && module.exports) module.exports = api;
  else root.OttoICE = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
