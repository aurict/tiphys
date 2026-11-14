// Masaüstü (Wayland): pano okuma/yazma (wl-paste / wl-copy) ve ekran görüntüsü (grim).
// systemd kullanıcı servisi WAYLAND_DISPLAY'i bilmeyebilir; yoksa $XDG_RUNTIME_DIR altındaki soket bulunur.
import { execFile, spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

export async function waylandEnv(): Promise<NodeJS.ProcessEnv> {
  const runtime = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? 1000}`;
  let display = process.env.WAYLAND_DISPLAY;
  if (!display) {
    const names = await readdir(runtime).catch(() => [] as string[]);
    display = names.filter((n) => /^wayland-\d+$/.test(n)).sort()[0];
  }
  if (!display) throw new AppError("agent.desktop.noDisplay", 503);
  return { ...process.env, XDG_RUNTIME_DIR: runtime, WAYLAND_DISPLAY: display };
}

function runBuffer(cmd: string, args: string[], env: NodeJS.ProcessEnv, timeoutMs = 15000): Promise<{ out: Buffer; code: number; err: string }> {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { env, timeout: timeoutMs, encoding: "buffer", maxBuffer: 64 * 1024 * 1024 }, (e, stdout, stderr) => {
      if (e && (e as NodeJS.ErrnoException).code === "ENOENT") return reject(new AppError("agent.exec.commandMissing", 500, { command: cmd }));
      if (e && (e as { killed?: boolean }).killed) return reject(new AppError("agent.exec.timeout", 504, { command: cmd }));
      resolve({ out: stdout, code: e ? (typeof e.code === "number" ? e.code : -1) : 0, err: stderr.toString("utf8").slice(0, 1000) });
    });
  });
}

/** wl-copy panoyu tutmak için arka plana çatallanır; çıktı akışları kapalı başlatılmazsa execFile hiç bitmez. */
function copy(text: string, env: NodeJS.ProcessEnv): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn("wl-copy", ["--type", "text/plain;charset=utf-8"], { env, stdio: ["pipe", "ignore", "ignore"] });
    const t = setTimeout(() => p.kill(), 10000);
    p.on("error", (e) => {
      clearTimeout(t);
      reject((e as NodeJS.ErrnoException).code === "ENOENT" ? new AppError("agent.exec.commandMissing", 500, { command: "wl-copy" }) : e);
    });
    p.on("exit", (code) => {
      clearTimeout(t);
      code === 0 ? resolve() : reject(new AppError("agent.desktop.clipboardFailed", 502, { code }));
    });
    p.stdin.end(text, "utf8");
  });
}

export function desktopRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.get("/v1/desktop/clipboard", async () => {
    const env = await waylandEnv();
    const r = await runBuffer("wl-paste", ["--no-newline", "--type", "text"], env);
    // Pano boşsa ya da metin değilse wl-paste 1 döner.
    return { text: r.code === 0 ? r.out.toString("utf8").slice(0, 1_000_000) : "" };
  });

  app.put("/v1/desktop/clipboard", async (req) => {
    const { text } = z.object({ text: z.string().max(1_000_000) }).parse(req.body);
    await copy(text, await waylandEnv());
    return { ok: true };
  });

  app.get("/v1/desktop/screenshot", async (req, reply) => {
    const q = z.object({ scale: z.coerce.number().min(0.1).max(1).default(0.5) }).parse(req.query);
    // PNG: dağıtımların grim paketlerinde JPEG desteği çoğu zaman kapalı derlenir.
    const r = await runBuffer("grim", ["-s", String(q.scale), "-t", "png", "-l", "3", "-"], await waylandEnv(), 20000);
    if (r.code !== 0 || r.out.length === 0) throw new AppError("agent.desktop.screenshotFailed", 502, { stderr: r.err });
    return reply.header("content-type", "image/png").header("cache-control", "no-store").send(r.out);
  });
}
