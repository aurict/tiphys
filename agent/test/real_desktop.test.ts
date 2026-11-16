// Tests that run on the real machine (clipboard, screenshot, ports, audio). Run with TIPHYS_REAL=1.
import { describe, expect, it } from "vitest";
import { testApp } from "./helpers.ts";

const real = process.env.TIPHYS_REAL === "1";

describe.skipIf(!real)("gerçek masaüstü", () => {
  it("pano yaz/oku, ekran görüntüsü, port listesi", async () => {
    const { app, auth, sent } = await testApp((c) => {
      c.features.desktop = true;
      c.features.ports = true;
      return c;
    });
    await new Promise((r) => setTimeout(r, 1000)); // let the clipboard watcher start
    const before = (await app.inject({ method: "GET", url: "/v1/desktop/clipboard", headers: auth })).json();
    const marker = `tiphys-test ${Date.now()} ğüşiöç`;
    const put = await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: marker } });
    expect(put.json()).toEqual({ ok: true });
    expect((await app.inject({ method: "GET", url: "/v1/desktop/clipboard", headers: auth })).json().text).toBe(marker);
    // Text coming from the phone is not echoed back; text copied on the PC goes out as "clipboard.pc".
    const { execFileSync } = await import("node:child_process");
    const pcText = `${marker} pc`;
    execFileSync("wl-copy", ["--type", "text/plain;charset=utf-8", pcText], { stdio: "ignore" }); // wl-copy stays in the background
    await new Promise((r) => setTimeout(r, 2000));
    expect(sent.filter((n) => (n as { key: string }).key === "clipboard.pc").map((n) => (n as { params: { text: string } }).params.text)).toEqual([pcText]);
    // The user's clipboard is restored.
    await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: before.text ?? "" } });

    const shot = await app.inject({ method: "GET", url: "/v1/desktop/screenshot?scale=0.25", headers: auth });
    expect(shot.statusCode).toBe(200);
    expect(shot.headers["content-type"]).toBe("image/png");
    expect(shot.rawPayload.subarray(1, 4).toString()).toBe("PNG");

    const ports = (await app.inject({ method: "GET", url: "/v1/ports", headers: auth })).json();
    expect(ports.host).toMatch(/\.ts\.net$/);
    expect(ports.ports.length).toBeGreaterThan(0);
    await app.close();
  }, 60000);
});

// Read-only: window/workspace/app lists, an icon, a thumbnail of the focused window. NO control session, window
// action, launch, DPMS or border change (the user may be using the PC).
describe.skipIf(!real)("gerçek masaüstü paneli (salt okunur)", () => {
  it("pencereler, uygulamalar, simge, küçük resim", async () => {
    const { app, auth } = await testApp((c) => {
      c.features.desktop = true;
      return c;
    });
    const w = await app.inject({ method: "GET", url: "/v1/desktop/windows", headers: auth });
    expect(w.statusCode, w.body).toBe(200);
    const s = w.json();
    expect(s.hyprland).toBe(true);
    expect(s.monitors.length).toBeGreaterThan(0);
    expect(s.workspaces.length).toBeGreaterThan(0);
    console.log(`pencere ${s.windows.length}, çalışma alanı ${s.workspaces.map((x: { id: number }) => x.id).join(",")}, monitör ${s.monitors.map((m: { name: string }) => m.name).join(",")}`);

    const apps = (await app.inject({ method: "GET", url: "/v1/desktop/apps", headers: auth })).json().apps as Array<{ id: string; name: string; hasIcon: boolean }>;
    expect(apps.length).toBeGreaterThan(20);
    const withIcon = apps.filter((a) => a.hasIcon);
    let icons = 0;
    for (const a of withIcon.slice(0, 40)) {
      const r = await app.inject({ method: "GET", url: `/v1/desktop/apps/${a.id}/icon`, headers: auth });
      if (r.statusCode === 200) icons++;
    }
    const firstIcon = withIcon.find((a) => a.id.includes("firefox")) ?? withIcon[0]!;
    const icon = await app.inject({ method: "GET", url: `/v1/desktop/apps/${firstIcon.id}/icon`, headers: auth });
    console.log(`uygulama ${apps.length}, simgesi çözülen ${icons}/${Math.min(40, withIcon.length)}; ${firstIcon.id}: ${icon.statusCode} ${icon.headers["content-type"]} ${icon.rawPayload.length} B`);
    expect(icons).toBeGreaterThan(0);

    const focused = (s.windows as Array<{ address: string; focused: boolean; visible: boolean; class: string }>).find((x) => x.focused && x.visible);
    if (focused) {
      const t = await app.inject({ method: "GET", url: `/v1/desktop/windows/${focused.address}/thumb?w=320`, headers: auth });
      expect(t.statusCode, t.body.slice(0, 200)).toBe(200);
      console.log(`küçük resim ${focused.class}: ${t.headers["content-type"]} ${t.rawPayload.length} B`);
    } else console.log("odakta görünen pencere yok; küçük resim atlandı");
    await app.close();
  }, 60000);
});

describe.skipIf(!real)("gerçek ses yazıya çevirme", () => {
  it("m4a yüklenir, transcribe betiği çalışır, metin döner", async () => {
    const { execFileSync } = await import("node:child_process");
    const { mkdtemp, readFile } = await import("node:fs/promises");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = await mkdtemp(join(tmpdir(), "tiphys-ses-"));
    const file = join(dir, "ton.m4a");
    // No speech (no TTS tool installed): only verifies the end-to-end path.
    execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "1", "-ar", "16000", "-c:a", "aac", file]);
    const { app, auth } = await testApp((c) => {
      c.features.transcribe = true;
      return c;
    });
    const res = await app.inject({ method: "POST", url: "/v1/transcribe", headers: auth, payload: { data: (await readFile(file)).toString("base64"), ext: "m4a", language: "tr" } });
    expect(res.statusCode, res.body).toBe(200);
    expect(typeof res.json().text).toBe("string");
    await app.close();
  }, 600_000);
});

// Live screen (10.2): ~3 s stream with the real wf-recorder (frame rate, first-frame latency, frame size), then
// verifies no child process is left. The control session is opened with a fake PC indicator (border/notification
// unchanged). The only real input: the cursor is moved a few pixels and back; NO click, key, text or wheel is sent.
describe.skipIf(!real)("gerçek canlı ekran", () => {
  it("akış kareleri, gecikme, temizlik; imleç kaydır-geri al", async () => {
    const { execFileSync } = await import("node:child_process");
    const { hyprRoutes, hyprEnv } = await import("../src/routes/hypr.ts");
    const { streamRoutes } = await import("../src/routes/stream.ts");
    const ours = () => {
      try {
        return execFileSync("pgrep", ["-P", String(process.pid), "-x", "wf-recorder"], { encoding: "utf8" }).trim();
      } catch {
        return "";
      }
    };
    const { app, auth, token } = await testApp(
      (c) => {
        c.features.control = true;
        return c;
      },
      [
        (a, ctx) => {
          hyprRoutes(a, ctx, undefined, { indicator: { on: async () => {}, off: async () => {} } });
          streamRoutes(a, ctx, undefined, { statsMs: 500 });
        },
      ],
    );
    await app.ready();
    const ctl = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json().token as string;
    const fps = 12;
    const t0 = performance.now();
    const ws = await app.injectWS(`/v1/desktop/stream?token=${token}&fps=${fps}&scale=0.6&q=70`, { headers: { "x-tiphys-control": ctl } });
    const frames: Array<{ at: number; size: number; w: number; h: number }> = [];
    const texts: Array<Record<string, unknown>> = [];
    ws.on("message", (d: Buffer, binary: boolean) => {
      if (binary) frames.push({ at: performance.now() - t0, size: d.length - 16, w: d.readUInt16BE(12), h: d.readUInt16BE(14) });
      else texts.push(JSON.parse(d.toString()));
    });
    await new Promise((r) => setTimeout(r, 3000));
    const hello = texts.find((m) => m.type === "hello") as { width: number; height: number; source: string; cursor: unknown };
    expect(hello?.source).toBe("wf-recorder");
    expect(frames.length).toBeGreaterThan(0);
    expect(frames[0]!.w).toBe(hello.width);
    // On a static screen identical frames are skipped: produced frames = sent + skipped.
    const stats = texts.filter((m) => m.type === "stats") as Array<{ sent: number; skipped: number; dropped: number; bytes: number }>;
    const produced = stats.reduce((a, s) => a + s.sent + s.skipped + s.dropped, 0);
    const statSecs = stats.length * 0.5;
    const avg = Math.round(frames.reduce((a, f) => a + f.size, 0) / frames.length);
    console.log(
      `canlı ekran: ${hello.width}x${hello.height}, ilk kare ${Math.round(frames[0]!.at)} ms, gönderilen ${frames.length} kare, üretilen ~${(produced / statSecs).toFixed(1)} fps (istenen ${fps}), ortalama kare ${(avg / 1024).toFixed(1)} KB`,
    );
    expect(produced / statSecs).toBeGreaterThan(fps * 0.7);
    expect(produced / statSecs).toBeLessThan(fps * 1.3);
    expect(ours()).not.toBe("");

    // Cursor: read, move 5 px (image coordinates given at full size), verify, move back.
    const pos = () => JSON.parse(execFileSync("hyprctl", ["-j", "cursorpos"], { encoding: "utf8", env: { ...process.env } })) as { x: number; y: number };
    void hyprEnv;
    const start = pos();
    const region = (hello as unknown as { region: { x: number; y: number; w: number; h: number } }).region;
    const move = (x: number, y: number) => ws.send(JSON.stringify({ type: "move", x: x - region.x, y: y - region.y, w: region.w, h: region.h }));
    const dx = start.x + 5 < region.x + region.w ? 5 : -5;
    move(start.x + dx, start.y);
    await new Promise((r) => setTimeout(r, 300));
    const moved = pos();
    move(start.x, start.y);
    await new Promise((r) => setTimeout(r, 300));
    const back = pos();
    console.log(`imleç ${start.x},${start.y} → ${moved.x},${moved.y} → ${back.x},${back.y}`);
    expect(moved).toEqual({ x: start.x + dx, y: start.y });
    expect(back).toEqual(start);

    ws.terminate();
    await new Promise((r) => setTimeout(r, 1500));
    expect(ours()).toBe("");
    await app.close();
    expect(ours()).toBe("");
  }, 30000);
});

// 10.2 Phase C: 5 s H.264 stream (screen capture only; NO input). SPS/PPS + IDR must arrive; first-frame latency,
// fps, average bandwidth and wf-recorder CPU are measured; the captured stream is decoded with ffmpeg to prove it is
// valid.
describe.skipIf(!real)("gerçek H.264 canlı ekran", () => {
  it("5 sn akış: yapılandırma + IDR, ölçümler, ffmpeg çözer, artık süreç yok", async () => {
    const { execFileSync } = await import("node:child_process");
    const { readFileSync } = await import("node:fs");
    const { hyprRoutes } = await import("../src/routes/hypr.ts");
    const { streamRoutes } = await import("../src/routes/stream.ts");
    const { FRAME, parseHeader } = await import("../src/h264.ts");
    const ours = () => {
      try {
        return execFileSync("pgrep", ["-P", String(process.pid), "-x", "wf-recorder"], { encoding: "utf8" }).trim();
      } catch {
        return "";
      }
    };
    const cpuTicks = (pid: string) => {
      const f = readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1]!.split(" ");
      return Number(f[11]) + Number(f[12]);
    };
    const { app, auth, token } = await testApp(
      (c) => {
        c.features.control = true;
        return c;
      },
      [
        (a, ctx) => {
          hyprRoutes(a, ctx, undefined, { indicator: { on: async () => {}, off: async () => {} } });
          streamRoutes(a, ctx, undefined, { statsMs: 1000 });
        },
      ],
    );
    await app.ready();
    const ctl = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json().token as string;
    const fps = 30;
    const t0 = performance.now();
    const ws = await app.injectWS(`/v1/desktop/stream?token=${token}&codec=h264&fps=${fps}&scale=0.6&kbps=2000`, { headers: { "x-tiphys-control": ctl } });
    const frames: Array<{ at: number; flags: number; size: number; w: number; h: number }> = [];
    const texts: Array<Record<string, unknown>> = [];
    const chunks: Buffer[] = [];
    ws.on("message", (d: Buffer, binary: boolean) => {
      if (!binary) return void texts.push(JSON.parse(d.toString()));
      const h = parseHeader(d);
      frames.push({ at: performance.now() - t0, flags: h.flags, size: d.length - 16, w: h.w, h: h.h });
      chunks.push(Buffer.from(d.subarray(16)));
    });
    await new Promise((r) => setTimeout(r, 1000));
    const pid = ours().split("\n")[0]!;
    expect(pid).not.toBe("");
    const c0 = cpuTicks(pid);
    const n0 = frames.length;
    const b0 = frames.reduce((a, f) => a + f.size, 0);
    const m0 = performance.now();
    await new Promise((r) => setTimeout(r, 4000));
    const secs = (performance.now() - m0) / 1000;
    const cpu = ((cpuTicks(pid) - c0) / 100 / secs) * 100;
    const pics = frames.slice(n0).filter((f) => !(f.flags & FRAME.config)).length;
    const bytes = frames.reduce((a, f) => a + f.size, 0) - b0;
    const hello = texts.find((m) => m.type === "hello") as { width: number; height: number; codec: string };
    expect(hello?.codec).toBe("h264");
    expect(texts.filter((m) => m.type === "notice")).toEqual([]);
    expect(frames[0]!.flags).toBe(FRAME.h264 | FRAME.config);
    expect(frames[1]!.flags).toBe(FRAME.h264 | FRAME.key);
    expect(frames.every((f) => f.flags & FRAME.h264 && f.w === hello.width)).toBe(true);
    const keys = frames.filter((f) => f.flags & FRAME.key).length;
    const configs = frames.filter((f) => f.flags & FRAME.config).length;
    expect(configs).toBe(keys); // SPS+PPS before every IDR
    const sizes = frames.filter((f) => !(f.flags & FRAME.config)).map((f) => f.size).sort((a, b) => a - b);
    console.log(
      `H.264: ${hello.width}x${hello.height}, ilk kare ${Math.round(frames[1]!.at)} ms, ${(pics / secs).toFixed(1)} fps (istenen ${fps}), ` +
        `${((bytes / secs) / 1024).toFixed(0)} KB/sn, IDR ${keys} (en büyük kare ${(sizes.at(-1)! / 1024).toFixed(1)} KB, ortanca ${sizes[sizes.length >> 1]} B), ` +
        `wf-recorder CPU %${cpu.toFixed(0)}`,
    );
    expect(pics / secs).toBeGreaterThan(fps * 0.7);
    expect(keys).toBeGreaterThanOrEqual(2); // GOP 2 sn
    ws.terminate();
    await new Promise((r) => setTimeout(r, 1500));
    expect(ours()).toBe("");
    await app.close();
    // The sent byte stream (config + frames) must be valid H.264.
    const out = execFileSync("ffmpeg", ["-v", "error", "-f", "h264", "-i", "-", "-f", "null", "-"], { input: Buffer.concat(chunks), encoding: "utf8" });
    expect(out.trim()).toBe("");
    const count = execFileSync("ffprobe", ["-v", "error", "-f", "h264", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames,width,height", "-of", "csv=p=0", "-"], { input: Buffer.concat(chunks), encoding: "utf8" }).trim();
    console.log(`ffmpeg/ffprobe: hatasız çözüldü, ${count} (en,boy,kare)`);
    expect(Number(count.split(",").at(-1))).toBe(frames.filter((f) => !(f.flags & FRAME.config)).length);
  }, 30000);
});

// Hyprland adapter: mode probe and writing back the border's CURRENT value through the same path (no visible
// change). Focus, close, move, launch, workspace and DPMS are not tried.
describe.skipIf(!real)("gerçek Hyprland bağdaştırıcısı", () => {
  it("kip algılanır; kenarlık mevcut değeriyle yazılır ve aynı okunur", async () => {
    const { execFileSync } = await import("node:child_process");
    const { Hyprctl } = await import("../src/hyprctl.ts");
    const { hyprEnv } = await import("../src/routes/hypr.ts");
    const { run } = await import("../src/exec.ts");
    const { gradientValue } = await import("../src/control.ts");
    const env = await hyprEnv();
    const read = () => ({
      border: gradientValue(JSON.parse(execFileSync("hyprctl", ["-j", "getoption", "general:col.active_border"], { encoding: "utf8", env }))),
      size: Number(JSON.parse(execFileSync("hyprctl", ["-j", "getoption", "general:border_size"], { encoding: "utf8", env })).int),
    });
    const h = new Hyprctl(run, hyprEnv);
    const mode = await h.mode();
    const before = read();
    expect(before.border).not.toBeNull();
    await h.setLook({ border: before.border!, size: before.size });
    const after = read();
    console.log(`Hyprland kipi: ${mode}; kenarlık ${before.border} / ${before.size} → ${after.border} / ${after.size}`);
    expect(after).toEqual(before);
  });
});

describe.skipIf(!real)("gerçek Claude PC aracı (yalnız ekran görüntüsü)", () => {
  it("screenshot: grim + küçültme, 1280×800 sınırında geçerli JPEG; hiçbir giriş gönderilmez", async () => {
    const { mkdtemp } = await import("node:fs/promises");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const { PcSession, ShotStore, SHOT_MAX } = await import("../src/claude/pc.ts");
    const { RateLimit } = await import("../src/control.ts");
    const { Hyprctl } = await import("../src/hyprctl.ts");
    const { realStreamIo } = await import("../src/routes/stream.ts");
    const fail = () => {
      throw new Error("bu testte giriş/onay yok");
    };
    const pc = new PcSession({
      io: realStreamIo,
      hyprctl: new Hyprctl(realStreamIo.exec, realStreamIo.hyprEnv),
      apps: async () => [],
      binds: async () => new Map(),
      shots: new ShotStore(await mkdtemp(join(tmpdir(), "tiphys-real-shots-"))),
      guard: async () => {},
      approve: fail,
      lost: fail,
      limit: new RateLimit(0, 1000), // no input action can get through
      key: "real",
    });
    const t0 = Date.now();
    const r = await pc.call("screenshot", {});
    const ms = Date.now() - t0;
    expect(r.isError).toBeUndefined();
    const img = r.content[0] as { type: string; data: string; mimeType: string };
    expect(img).toMatchObject({ type: "image", mimeType: "image/jpeg" });
    const jpeg = Buffer.from(img.data, "base64");
    expect(jpeg[0]).toBe(0xff);
    expect(jpeg[1]).toBe(0xd8);
    expect(jpeg.length).toBeLessThan(1024 * 1024);
    // Real size from the SOF0/SOF2 segment.
    let i = 2;
    let size: { w: number; h: number } | null = null;
    while (i + 9 < jpeg.length && !size) {
      const marker = jpeg[i + 1]!;
      const len = jpeg.readUInt16BE(i + 2);
      if (marker === 0xc0 || marker === 0xc2) size = { h: jpeg.readUInt16BE(i + 5), w: jpeg.readUInt16BE(i + 7) };
      i += 2 + len;
    }
    expect(size).not.toBeNull();
    expect(size!.w).toBeLessThanOrEqual(SHOT_MAX.w);
    expect(size!.h).toBeLessThanOrEqual(SHOT_MAX.h);
    expect(size!.w === SHOT_MAX.w || size!.h === SHOT_MAX.h).toBe(true);
    expect(pc.shot!.img).toEqual(size);
    const text = (r.content[1] as { text: string }).text;
    expect(text).toContain(`${size!.w}×${size!.h}`);
    console.log(`gerçek ekran görüntüsü: ${size!.w}×${size!.h}, ${Math.round(jpeg.length / 1024)} KB, ${ms} ms — ${text}`);
  }, 30000);
});
