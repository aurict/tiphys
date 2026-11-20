#!/usr/bin/env node
// Fake `tiphys-desktop` (desktop_helper.test.ts): a small imitation of desktop-helper/PROTOCOL.md (protocol 1).
// serve: FAKE_HELPER_MODE ok | badProtocol (protocol 99) | silent (no hello) | crash (dies after the hello);
// FAKE_HELPER_CAPS: comma-separated capabilities (default: all); FAKE_HELPER_ICON: the first app's icon (a path). Special ops for the tests: slow (answers after
// 80 ms), hang (never answers), die (exits 1), and err:<code> (answers that helper error).
// stream: writes FAKE_STREAM_FRAMES (default 3) distinct JPEGs, then stays until stdin closes; FAKE_STREAM_EXIT=n exits
// with n before any frame.
// If FAKE_HELPER_LOG is set, every start (`start serve|stream <args>`) and request (`op` + its JSON fields) is appended
// to that file, so tests can check what reached the helper.
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const log = (s) => process.env.FAKE_HELPER_LOG && appendFileSync(process.env.FAKE_HELPER_LOG, s + "\n");
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
const [mode, ...args] = process.argv.slice(2);
log(`start ${mode} ${args.join(" ")}`.trim());

/** Smallest well-formed JPEG (same shape as in stream.test.ts). */
function jpeg(tag) {
  const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01]);
  app0.writeUInt16BE(app0.length - 2, 2);
  const sos = Buffer.from([0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, sos, Buffer.from([tag, 0xff, 0x00, 0x12]), Buffer.from([0xff, 0xd9])]);
}
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);

if (mode === "stream") {
  if (process.env.FAKE_STREAM_EXIT) {
    process.stderr.write("izin yok\n");
    process.exit(Number(process.env.FAKE_STREAM_EXIT));
  }
  const n = Number(process.env.FAKE_STREAM_FRAMES ?? 3);
  let i = 0;
  const t = setInterval(() => {
    if (i >= n) return clearInterval(t);
    process.stdout.write(jpeg(++i));
  }, 20);
  process.stdin.on("data", () => {});
  process.stdin.on("end", () => process.exit(0));
} else if (mode === "serve") {
  const fake = process.env.FAKE_HELPER_MODE ?? "ok";
  const all = ["windows", "windowActions", "workspaces", "monitors", "screenshot", "stream", "input", "text", "apps", "launch", "dpms", "clipboard", "audio"];
  const caps = process.env.FAKE_HELPER_CAPS !== undefined ? process.env.FAKE_HELPER_CAPS.split(",").filter(Boolean) : all;
  if (fake !== "silent") out({ hello: { protocol: fake === "badProtocol" ? 99 : 1, version: "0.0.1-fake", backend: "x11", capabilities: caps } });
  if (fake === "crash") setTimeout(() => process.exit(1), 10);

  const WINDOWS = [
    { id: "0x3a00007", title: "Belge — Yazıcı", appId: "org.gnome.TextEditor", pid: 1201, workspace: "1", monitor: "DP-1", x: 10, y: 40, w: 900, h: 700, focused: true, minimized: false, fullscreen: false, floating: false },
    { id: "0x3a00010", title: "Terminal", appId: "foot", pid: 1202, workspace: "2", monitor: "DP-1", x: 0, y: 0, w: 800, h: 600, focused: false, minimized: false, fullscreen: false, floating: true },
    { id: "0x3a00020", title: "Gizli", appId: "foot", pid: 1203, workspace: "1", monitor: "DP-1", x: 0, y: 0, w: 400, h: 300, focused: false, minimized: true, fullscreen: false, floating: false },
  ];
  const WORKSPACES = [
    { id: "1", name: "1", focused: true, monitor: "DP-1" },
    { id: "2", name: "2", focused: false, monitor: "DP-1" },
    { id: "w-mail", name: "mail", focused: false, monitor: "DP-1" },
  ];
  const MONITORS = [{ id: "DP-1", name: "DP-1", x: 0, y: 0, w: 1920, h: 1080, scale: 1, primary: true }];
  const APPS = [
    { id: "org.gnome.TextEditor.desktop", name: "Text Editor", icon: process.env.FAKE_HELPER_ICON },
    { id: "foot.desktop", name: "Foot" },
  ];
  let clipboard = "";
  const answer = (id, result) => out({ id, ok: true, result });
  const fail = (id, code, message = code) => out({ id, ok: false, error: { code, message } });

  createInterface({ input: process.stdin }).on("line", (line) => {
    const req = JSON.parse(line);
    const { id, op, ...fields } = req;
    log(`${op} ${JSON.stringify(fields)}`);
    if (op.startsWith("err:")) return fail(id, op.slice(4), op.slice(4) === "permission" ? "Accessibility" : "x");
    switch (op) {
      case "ping":
        return answer(id, {});
      case "slow":
        return setTimeout(() => answer(id, { slow: true }), 80);
      case "hang":
        return;
      case "die":
        return process.exit(1);
      case "windows":
        return answer(id, WINDOWS);
      case "workspaces":
        return answer(id, WORKSPACES);
      case "monitors":
        return answer(id, MONITORS);
      case "window":
        return WINDOWS.some((w) => w.id === fields.window) ? answer(id, {}) : fail(id, "notFound");
      case "move-to-workspace":
      case "workspace":
      case "pointer":
      case "click":
      case "button":
      case "scroll":
      case "key":
      case "text":
      case "dpms":
        return answer(id, {});
      case "screenshot":
        return answer(id, { format: fields.format, width: 2, height: 2, data: (fields.format === "jpeg" ? jpeg(9) : PNG).toString("base64") });
      case "apps":
        return answer(id, APPS);
      case "launch":
        return APPS.some((a) => a.id === fields.app) ? answer(id, {}) : fail(id, "notFound");
      case "clipboard-get":
        return answer(id, { text: clipboard || null });
      case "clipboard-set":
        clipboard = fields.text;
        return answer(id, {});
      case "subscribe":
        answer(id, {});
        return setTimeout(() => out({ event: "focus", window: WINDOWS[1] }), 20);
      default:
        return fail(id, "badRequest");
    }
  });
  process.stdin.on("end", () => process.exit(0));
} else {
  process.exit(2);
}
