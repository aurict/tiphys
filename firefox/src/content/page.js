// Tiphys Köprüsü page script (11.3; injected at request time, only if the optional "Sayfa içeriği" permission is
// granted). Since it is re-injected on every call, only `function`/`var` (redefinable).
// SECURITY: form values are not read or sent. If a password field is focused or filled (only emptiness is checked),
// reading and writing are refused. No network requests.
/* global Readability */
/* exported tiphysPage */

var TIPHYS_TEXT_MAX = 200 * 1024;
var TIPHYS_SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, CANVAS: 1, IFRAME: 1, INPUT: 1, TEXTAREA: 1, SELECT: 1, BUTTON: 1, OPTION: 1, FORM: 1 };
var TIPHYS_BLOCK = { P: 1, DIV: 1, SECTION: 1, ARTICLE: 1, HEADER: 1, FOOTER: 1, ASIDE: 1, MAIN: 1, NAV: 1, BLOCKQUOTE: 1, FIGURE: 1, FIGCAPTION: 1, TABLE: 1, TR: 1, UL: 1, OL: 1, DL: 1, DT: 1, DD: 1, HR: 1 };

function tiphysPasswordActive(doc) {
  var list = doc.querySelectorAll("input[type=password]");
  for (var i = 0; i < list.length; i++) {
    if (list[i] === doc.activeElement || list[i].value !== "") return true;
  }
  return false;
}

/** Node tree → plain text: headings "#", list items "•" / "1.", blank line between blocks. */
function tiphysToText(root) {
  var out = [];
  function walk(n, pre) {
    if (n.nodeType === 3) {
      out.push(pre ? n.nodeValue : n.nodeValue.replace(/\s+/g, " "));
      return;
    }
    if (n.nodeType !== 1) return;
    var tag = String(n.nodeName).toUpperCase();
    if (TIPHYS_SKIP[tag]) return;
    var kids = n.childNodes || [];
    var m = /^H([1-6])$/.exec(tag);
    if (tag === "BR") return void out.push("\n");
    if (m) out.push("\n\n" + "#".repeat(Number(m[1])) + " ");
    else if (tag === "LI") {
      var parent = n.parentNode && String(n.parentNode.nodeName).toUpperCase();
      var nth = 1;
      for (var s = n.previousSibling; s; s = s.previousSibling) if (s.nodeType === 1 && String(s.nodeName).toUpperCase() === "LI") nth++;
      out.push("\n" + (parent === "OL" ? nth + ". " : "• "));
    } else if (tag === "PRE") out.push("\n\n");
    else if (TIPHYS_BLOCK[tag]) out.push("\n\n");
    else if (tag === "TD" || tag === "TH") out.push(" | ");
    for (var i = 0; i < kids.length; i++) walk(kids[i], pre || tag === "PRE");
    if (m || tag === "PRE" || TIPHYS_BLOCK[tag]) out.push("\n\n");
  }
  walk(root, false);
  return out
    .join("")
    .split("\n")
    .map(function (l) {
      return l.replace(/[ \t]+$/g, "").replace(/^ +(?=\S)/, "");
    })
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Truncates by a UTF-8 byte limit. */
function tiphysClip(text, max) {
  var enc = new TextEncoder();
  if (enc.encode(text).length <= max) return { text: text, truncated: false };
  var t = text.slice(0, max);
  while (enc.encode(t).length > max) t = t.slice(0, Math.floor(t.length * 0.95));
  return { text: t, truncated: true };
}

function tiphysReader() {
  if (tiphysPasswordActive(document)) return { error: "passwordField" };
  var doc = document.cloneNode(true);
  // Form controls are removed from the copy: their value attributes must not leak into the text.
  var forms = doc.querySelectorAll("input,textarea,select,option,button");
  for (var i = 0; i < forms.length; i++) forms[i].remove();
  var art = new Readability(doc, { serializer: function (el) { return el; } }).parse();
  if (!art || !art.content) return { error: "noArticle" };
  var c = tiphysClip(tiphysToText(art.content), TIPHYS_TEXT_MAX);
  return { title: art.title || document.title || "", byline: art.byline || null, siteName: art.siteName || null, lang: art.lang || null, text: c.text, truncated: c.truncated };
}

function tiphysMedia(a) {
  var list = Array.prototype.slice.call(document.querySelectorAll("video,audio"));
  if (!list.length) return { error: "noMedia" };
  var el =
    list.find(function (m) { return !m.paused; }) ||
    list.slice().sort(function (x, y) { return y.clientWidth * y.clientHeight - x.clientWidth * x.clientHeight; })[0];
  if (a.action === "play" || (a.action === "toggle" && el.paused)) el.play().catch(function () {});
  else if (a.action === "pause" || a.action === "toggle") el.pause();
  else if (a.action === "seek") {
    var end = isFinite(el.duration) ? el.duration : Infinity;
    el.currentTime = Math.max(0, Math.min(end, el.currentTime + Number(a.seconds || 0)));
  } else if (a.action === "rate") el.playbackRate = Math.max(0.25, Math.min(4, Number(a.rate) || 1));
  return { kind: el.nodeName.toLowerCase(), paused: el.paused, currentTime: el.currentTime, duration: isFinite(el.duration) ? el.duration : null, rate: el.playbackRate };
}

function tiphysScroll(a) {
  var f = Number(a.fraction) || 0;
  if (f) window.scrollBy({ top: f * window.innerHeight, behavior: "instant" });
  var max = document.documentElement.scrollHeight - window.innerHeight;
  return { percent: max > 0 ? Math.round((window.scrollY / max) * 100) : 100 };
}

var TIPHYS_INPUT = "input:not([type]),input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],textarea,[contenteditable=''],[contenteditable=true]";

function tiphysEditable(el) {
  if (!el || el.disabled || el.readOnly) return false;
  if (el.type === "password") return false;
  return el.matches(TIPHYS_INPUT);
}

function tiphysText(a) {
  if (tiphysPasswordActive(document)) return { error: "passwordField" };
  // Only the focused editable field: refused if focus is in a frame (iframe) or there is no editable field (typing into
  // the first visible field could send the text somewhere the user didn't expect).
  var el = document.activeElement;
  if (!el || String(el.nodeName).toUpperCase() === "IFRAME" || String(el.nodeName).toUpperCase() === "FRAME" || !tiphysEditable(el)) return { error: "noInput" };
  el.focus();
  // execCommand inserts as if the user typed (input events, undo); otherwise setRangeText.
  if (!document.execCommand("insertText", false, String(a.text))) {
    if (typeof el.setRangeText !== "function") return { error: "noInput" };
    el.setRangeText(String(a.text), el.selectionStart, el.selectionEnd, "end");
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }
  return { ok: true, target: el.isContentEditable ? "editable" : el.nodeName.toLowerCase() };
}

function tiphysPage(op, args) {
  try {
    if (op === "reader") return tiphysReader();
    if (op === "media") return tiphysMedia(args || {});
    if (op === "scroll") return tiphysScroll(args || {});
    if (op === "text") return tiphysText(args || {});
    return { error: "badRequest" };
  } catch (e) {
    return { error: "failed" };
  }
}
