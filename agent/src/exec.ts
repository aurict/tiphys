// Runs external commands without a shell, with a timeout and an output limit.
import { execFile } from "node:child_process";
import { AppError } from "./errors.ts";

export interface ExecResult {
  stdout: string;
  stderr: string;
  code: number;
}

export function run(
  cmd: string,
  args: string[],
  opts: { timeoutMs?: number; allowFail?: boolean; env?: NodeJS.ProcessEnv; cwd?: string } = {},
): Promise<ExecResult> {
  return new Promise((resolve, reject) => {
    execFile(
      cmd,
      args,
      {
        timeout: opts.timeoutMs ?? 15000,
        maxBuffer: 16 * 1024 * 1024,
        ...(opts.cwd ? { cwd: opts.cwd } : {}),
        env: { ...process.env, LC_ALL: "C.UTF-8", ...opts.env },
      },
      (err, stdout, stderr) => {
        const code = err ? (typeof err.code === "number" ? err.code : -1) : 0;
        if (err && (err as NodeJS.ErrnoException).code === "ENOENT") {
          reject(new AppError("agent.exec.commandMissing", 500, { command: cmd }));
          return;
        }
        if (err && (err as { killed?: boolean }).killed) {
          reject(new AppError("agent.exec.timeout", 504, { command: cmd }));
          return;
        }
        if (err && !opts.allowFail) {
          reject(new AppError("agent.exec.failed", 502, { command: cmd, code, stderr: stderr.slice(0, 2000) }));
          return;
        }
        resolve({ stdout, stderr, code });
      },
    );
  });
}
