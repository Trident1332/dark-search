/* Ottocaller — call records.
 *
 * When a call ends, the dialer panel turns it into one record and the background worker files
 * it in chrome.storage.local "callOutbox", where it waits until an otto page acknowledges it
 * (content.js delivers it). That is how otto writes every call onto the lead's timeline, even
 * when its tab was closed during the call.
 *
 *   { id, number, name, direction: "out" | "in", startedAt, answeredAt | null, endedAt,
 *     durationSec, outcome: "answered" | "no-answer" | "busy" | "failed" | "cancelled" | "missed",
 *     ref: <what otto sent with the dial, e.g. { ws, t, l }> | null }
 *
 * Pure logic only (no chrome.*, no DOM), so node can test it (calls.test.js). Loaded by
 * dialer.html and by the service worker (importScripts) as the global OttoCalls. */
(function (root) {
  "use strict";

  var OUTBOX_KEY = "callOutbox";   // chrome.storage.local: finished calls no otto page has acknowledged yet, newest last
  var OUTBOX_MAX = 50;             // the oldest are dropped beyond this
  var REF_MAX = 400;               // a dial reference is a small JSON object: at most this many characters
  var OUTCOMES = ["answered", "no-answer", "busy", "failed", "cancelled", "missed"];

  function newId() {
    try { if (root.crypto && root.crypto.randomUUID) return root.crypto.randomUUID(); } catch (e) { /* fall through */ }
    return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 12) + Math.random().toString(36).slice(2, 12);
  }

  /* The opaque reference otto attaches to a dial (which workspace, table and lead the call is
   * for). It is only ever carried and handed back: a plain object whose JSON is small, or null. */
  function cleanRef(ref) {
    if (!ref || typeof ref !== "object" || Object.prototype.toString.call(ref) !== "[object Object]") return null;
    var json, out;
    try { json = JSON.stringify(ref); } catch (e) { return null; }
    if (typeof json !== "string" || json.length > REF_MAX) return null;
    try { out = JSON.parse(json); } catch (e) { return null; }
    return out && typeof out === "object" && !Array.isArray(out) ? out : null;
  }

  // Digits with an optional leading "+": how a record names the other party.
  function plainNumber(n) {
    var s = String(n == null ? "" : n);
    return (/^\s*\+/.test(s) ? "+" : "") + s.replace(/\D/g, "");
  }

  /* A number that leaves the box: no * or # code and at least 6 digits, the same line the
   * FreeSWITCH dialplan draws before it routes to a trunk. Anything shorter is a seat or a
   * service number (the 9196 echo, the 9199 voice preview) and never makes a record. */
  function external(n) {
    var s = String(n == null ? "" : n);
    return !/[*#]/.test(s) && s.replace(/\D/g, "").length >= 6;
  }

  /* How a call ended, from what the SIP layer reported and nothing else:
   *   answeredAt  the session was established (200 OK and media set up)
   *   hung        hang-up was pressed, or the panel closed, before an answer
   *   error       placing the call threw before any SIP answer (microphone, voice service, …)
   *   dropped     the connection to the phone server went away while it was still dialing
   *   code        the final SIP status of our INVITE, 0 when none arrived
   * 486/600 are busy; 408/480/504 are the network's "nobody answered in time" and 487 is a
   * request ended without a local cancel, so all four are no-answer; every other final status
   * is failed. That includes 603 Decline: FreeSWITCH sends it both when the callee declines and
   * when the trunk refuses the call, and the two cannot be told apart from here. */
  function outcome(c) {
    c = c || {};
    if (c.answeredAt) return "answered";
    if (c.direction === "in") return "missed";
    if (c.hung) return "cancelled";
    if (c.error || c.dropped) return "failed";
    var code = Number(c.code) || 0;
    if (code === 486 || code === 600) return "busy";
    if (code === 408 || code === 480 || code === 487 || code === 504) return "no-answer";
    if (code >= 200) return "failed";
    return "no-answer";            // it ended unanswered and nothing more was reported
  }

  // The record for a finished call. `c` is the dialer's call object (see callStart in dialer.js).
  function record(c, endedAt) {
    var started = Number(c.at) || 0, answered = c.answeredAt ? Number(c.answeredAt) : null;
    var ended = Number(endedAt) || Date.now();
    return {
      id: String(c.id || newId()),
      number: plainNumber(c.number),
      name: String(c.name || "").slice(0, 80),
      direction: c.direction === "in" ? "in" : "out",
      startedAt: started,
      answeredAt: answered,
      endedAt: ended,
      durationSec: answered ? Math.max(0, Math.round((ended - answered) / 1000)) : 0,
      outcome: outcome(c),
      ref: cleanRef(c.ref)
    };
  }

  // What the background worker accepts into the outbox: a well-formed record of an external call, or null.
  function clean(r) {
    if (!r || typeof r !== "object") return null;
    var id = typeof r.id === "string" ? r.id : "";
    if (!id || id.length > 80 || !external(r.number) || OUTCOMES.indexOf(r.outcome) < 0) return null;
    var started = Number(r.startedAt), ended = Number(r.endedAt), answered = r.answeredAt == null ? null : Number(r.answeredAt);
    if (!isFinite(started) || !isFinite(ended) || (answered !== null && !isFinite(answered))) return null;
    return {
      id: id,
      number: plainNumber(r.number),
      name: String(r.name || "").slice(0, 80),
      direction: r.direction === "in" ? "in" : "out",
      startedAt: started,
      answeredAt: answered,
      endedAt: ended,
      durationSec: Math.max(0, Math.round(Number(r.durationSec) || 0)),
      outcome: r.outcome,
      ref: cleanRef(r.ref)
    };
  }

  /* ---- the outbox: an array of records, newest last ---- */

  function list(v) { return Array.isArray(v) ? v.filter(function (r) { return r && typeof r.id === "string" && r.id; }) : []; }

  // Adds a record (replacing one with the same id, so a retry cannot double it) and keeps the newest `max`.
  function append(outbox, rec, max) {
    var out = list(outbox).filter(function (r) { return r.id !== rec.id; });
    out.push(rec);
    max = max || OUTBOX_MAX;
    return out.length > max ? out.slice(out.length - max) : out;
  }

  // Removes the acknowledged ids.
  function ack(outbox, ids) {
    var gone = Object.create(null);
    (Array.isArray(ids) ? ids : []).forEach(function (id) { gone[String(id)] = true; });
    return list(outbox).filter(function (r) { return !gone[r.id]; });
  }

  var api = {
    OUTBOX_KEY: OUTBOX_KEY, OUTBOX_MAX: OUTBOX_MAX, REF_MAX: REF_MAX, OUTCOMES: OUTCOMES,
    newId: newId, cleanRef: cleanRef, plainNumber: plainNumber, external: external,
    outcome: outcome, record: record, clean: clean, list: list, append: append, ack: ack
  };
  if (typeof module === "object" && module && module.exports) module.exports = api;
  else root.OttoCalls = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
