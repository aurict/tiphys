// Sistem metrikleri: işlemci, bellek, disk, GPU, sıcaklık, çalışma süresi.
import si from "systeminformation";
import type { FastifyInstance } from "fastify";
import { run } from "../exec.ts";
import type { Ctx } from "../server.ts";

interface Gpu {
  name: string;
  temperatureC: number | null;
  utilizationPercent: number | null;
  memoryUsedMiB: number | null;
  memoryTotalMiB: number | null;
}

async function nvidiaGpus(): Promise<Gpu[]> {
  try {
    const { stdout } = await run(
      "nvidia-smi",
      ["--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total", "--format=csv,noheader,nounits"],
      { timeoutMs: 5000 },
    );
    return stdout
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => {
        const [name = "", t, u, mu, mt] = line.split(",").map((s) => s.trim());
        const num = (s: string | undefined) => (s === undefined || Number.isNaN(Number(s)) ? null : Number(s));
        return { name, temperatureC: num(t), utilizationPercent: num(u), memoryUsedMiB: num(mu), memoryTotalMiB: num(mt) };
      });
  } catch {
    return []; // NVIDIA yoksa GPU bölümü boş kalır
  }
}

let cache: { at: number; value: unknown } | null = null;

export async function systemSnapshot() {
  if (cache && Date.now() - cache.at < 2000) return cache.value;
  const [load, mem, fs, temp, time, os, gpus] = await Promise.all([
    si.currentLoad(),
    si.mem(),
    si.fsSize(),
    si.cpuTemperature(),
    Promise.resolve(si.time()),
    si.osInfo(),
    nvidiaGpus(),
  ]);
  const value = {
    hostname: os.hostname,
    os: `${os.distro} ${os.release}`.trim(),
    kernel: os.kernel,
    uptimeSeconds: Math.round(Number(time.uptime)),
    cpu: {
      loadPercent: Math.round(load.currentLoad * 10) / 10,
      cores: load.cpus.length,
      temperatureC: temp.main ?? null,
    },
    memory: {
      totalBytes: mem.total,
      usedBytes: mem.active,
      swapTotalBytes: mem.swaptotal,
      swapUsedBytes: mem.swapused,
    },
    disks: fs
      .filter((d) => d.size > 0 && !d.mount.startsWith("/snap") && !d.mount.startsWith("/boot/efi"))
      .map((d) => ({ mount: d.mount, fs: d.type, totalBytes: d.size, usedBytes: d.used })),
    gpus,
  };
  cache = { at: Date.now(), value };
  return value;
}

export function systemRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.get("/v1/system", async () => systemSnapshot());
}
