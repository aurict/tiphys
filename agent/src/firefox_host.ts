// Firefox native messaging helper (11.2): Firefox itself starts this process for the "Tiphys Köprüsü" extension
// (~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json → launcher script → node dist/firefox_host.js).
// Relays frames without unpacking them between stdin/stdout (Firefox) ⇄ $XDG_RUNTIME_DIR/tiphys/firefox.sock (agent).
// - No network listener; the agent socket is the same user's only (directory 0700, socket 0600).
// - If the agent is down it reconnects every 5 s; meanwhile messages from the extension are dropped. On connect/
//   disconnect {type:"host", agent:true|false} is sent to the extension (the extension sends hello on connect).
// - Exits when stdin closes (Firefox closed the extension). A message from Firefox over the limit (1 MB) is logged and
//   skipped (the length is known, so the stream isn't corrupted); the helper doesn't exit.
import { connect, type Socket } from "node:net";
import { join } from "node:path";
import type { Readable, Writable } from "node:stream";
import { pathToFileURL } from "node:url";
import { FrameDecoder, encodeFrame } from "./firefox_frame.ts";

export function defaultSocketPath(env: NodeJS.ProcessEnv = process.env): string {
  if (env.TIPHYS_FIREFOX_SOCKET) return env.TIPHYS_FIREFOX_SOCKET;
  // macOS has no XDG_RUNTIME_DIR: the per-user TMPDIR (0700, /var/folders/…) the browser's helper sees too.
  const runtime = env.XDG_RUNTIME_DIR || (process.platform === "darwin" && env.TMPDIR ? env.TMPDIR : `/run/user/${process.getuid?.() ?? 1000}`);
  return join(runtime, "tiphys", "firefox.sock");
}

export interface HostOpts {
  input: Readable;
  output: Writable;
  socketPath: string;
  reconnectMs?: number;
  log?: (msg: string) => void;
}

/** Ends when stdin closes or the Firefox stream is corrupted (returns the exit code). */
export function runHost(o: HostOpts): Promise<number> {
  const reconnectMs = o.reconnectMs ?? 5000;
  const log = o.log ?? (() => {});
  let sock: Socket | null = null;
  let ready = false;
  let done = false;
  let timer: NodeJS.Timeout | null = null;
  const toFirefox = (payload: Buffer | object) => o.output.write(encodeFrame(payload));

  return new Promise((resolve) => {
    const finish = (code: number) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      sock?.destroy();
      resolve(code);
    };

    const dial = () => {
      timer = null;
      if (done) return;
      const s = connect(o.socketPath);
      sock = s;
      const dec = new FrameDecoder();
      s.on("connect", () => {
        ready = true;
        toFirefox({ type: "host", agent: true });
      });
      s.on("data", (chunk: Buffer) => {
        let frames: Buffer[];
        try {
          frames = dec.push(chunk);
        } catch (e) {
          log(`ajandan bozuk ileti: ${(e as Error).message}`);
          s.destroy();
          return;
        }
        for (const f of frames) toFirefox(f);
      });
      s.on("error", () => {}); // close handles it
      s.on("close", () => {
        if (sock !== s) return;
        const was = ready;
        ready = false;
        sock = null;
        if (done) return;
        if (was) toFirefox({ type: "host", agent: false });
        timer = setTimeout(dial, reconnectMs);
        timer.unref?.();
      });
    };

    const dec = new FrameDecoder(undefined, (size) => log(`Firefox'tan çok büyük ileti atlandı (${size} bayt)`));
    o.input.on("data", (chunk: Buffer) => {
      let frames: Buffer[];
      try {
        frames = dec.push(chunk);
      } catch (e) {
        log(`Firefox'tan bozuk ileti: ${(e as Error).message}`);
        return finish(1);
      }
      if (ready && sock) for (const f of frames) sock.write(encodeFrame(f));
    });
    o.input.on("end", () => finish(0));
    o.input.on("close", () => finish(0));
    o.input.on("error", () => finish(1));
    dial();
  });
}

// When run directly (Firefox starts it): stdout is for frames only, logs go to stderr.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void runHost({ input: process.stdin, output: process.stdout, socketPath: defaultSocketPath(), log: (m) => process.stderr.write(`tiphys-firefox-host: ${m}\n`) }).then((code) =>
    process.exit(code),
  );
}
