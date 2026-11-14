// Terminalde (Tiphys dışında) çalışan Claude Code oturumları.
// Claude Code her canlı oturum için <yapılandırma klasörü>/sessions/<pid>.json yazar. Dosya kapanışta
// silinmeyebilir; bu yüzden süreç hâlâ yaşıyor mu ve aynı süreç mi (pid yeniden kullanılmış olabilir)
// /proc/<pid>/stat içindeki başlangıç zamanıyla (procStart) doğrulanır.
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

export interface TerminalSession {
  pid: number;
  sdkSessionId: string;
  cwd: string | null;
  name: string | null;
  /** Claude Code'un bildirdiği durum: busy | idle | … */
  status: string | null;
  startedAt: string | null;
  updatedAt: string | null;
}

/** /proc/<pid>/stat → başlangıç zamanı (22. alan). Süreç yoksa null. */
export async function procStart(procRoot: string, pid: number): Promise<string | null> {
  try {
    const stat = await readFile(join(procRoot, String(pid), "stat"), "utf8");
    // 2. alan (komut adı) boşluk/parantez içerebilir: son ')' sonrasından say.
    const rest = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return rest[19] ?? null; // rest[0] = 3. alan → 22. alan = rest[19]
  } catch {
    return null;
  }
}

const iso = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? new Date(v).toISOString() : null);
const str = (v: unknown) => (typeof v === "string" && v.length > 0 ? v : null);

export async function terminalSessions(configDir: string, procRoot = "/proc"): Promise<TerminalSession[]> {
  const dir = join(configDir, "sessions");
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  const out: TerminalSession[] = [];
  for (const n of names.filter((n) => /^\d+\.json$/.test(n))) {
    let j: Record<string, unknown>;
    try {
      j = JSON.parse(await readFile(join(dir, n), "utf8")) as Record<string, unknown>;
    } catch {
      continue; // yazılırken okunmuş ya da bozuk: bu tur atla
    }
    const pid = Number(j.pid);
    const sessionId = str(j.sessionId);
    if (!Number.isInteger(pid) || pid <= 0 || !sessionId) continue;
    const started = await procStart(procRoot, pid);
    if (started === null) continue; // süreç yok
    if (j.procStart !== undefined && String(j.procStart) !== started) continue; // pid başka sürece geçmiş
    out.push({
      pid,
      sdkSessionId: sessionId,
      cwd: str(j.cwd),
      name: str(j.name),
      status: str(j.status),
      startedAt: iso(j.startedAt),
      updatedAt: iso(j.updatedAt),
    });
  }
  return out.sort((a, b) => (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""));
}

/**
 * Terminaldeki oturumu kapatır (SIGTERM: Claude Code kaydı zaten her mesajda diske yazar) ve sürecin
 * gerçekten bittiğini bekler. Süre dolarsa false döner; SIGKILL kullanılmaz.
 */
export async function stopTerminalSession(pid: number, procRoot = "/proc", timeoutMs = 8000): Promise<boolean> {
  const start = await procStart(procRoot, pid);
  if (start === null) return true;
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return (await procStart(procRoot, pid)) !== start;
  }
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    await new Promise((r) => setTimeout(r, 100));
    if ((await procStart(procRoot, pid)) !== start) return true;
  }
  return false;
}
