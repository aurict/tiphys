// W0 draft: writes city.json (the code city's input) from the repository this file lives in.
// Same rules as the planned `city` topic: `git ls-files -z`, line count per file, binaries and files > 2 MB skipped,
// at most 20 000 files. Paths are relative to the repository root. Usage: node display/draft/make-snapshot.mjs
import { execFileSync } from 'node:child_process';
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = execFileSync('git', ['rev-parse', '--show-toplevel'], { cwd: here, encoding: 'utf8' }).trim();
const MAX_BYTES = 2 * 1024 * 1024;
const MAX_FILES = 20000;

// File type → one of six palette tones (draft/city.js maps them to colours).
const KIND = {
  code: ['.ts', '.tsx', '.js', '.mjs', '.cjs', '.jsx'],
  dart: ['.dart'],
  docs: ['.md', '.txt', '.arb'],
  config: ['.json', '.yaml', '.yml', '.toml', '.lock', '.gradle', '.kts', '.properties', '.xml', '.plist', '.cfg', '.ini'],
  web: ['.html', '.css', '.svg'],
};
const kindOf = (p) => {
  const e = extname(p).toLowerCase();
  for (const [k, list] of Object.entries(KIND)) if (list.includes(e)) return k;
  return 'other';
};

const paths = execFileSync('git', ['ls-files', '-z'], { cwd: root, maxBuffer: 64 * 1024 * 1024 }).toString('utf8').split('\0').filter(Boolean);
const files = [];
let skipped = 0;
for (const p of paths) {
  let st;
  try { st = statSync(join(root, p)); } catch { skipped++; continue; } // deleted in the work tree
  if (!st.isFile() || st.size > MAX_BYTES) { skipped++; continue; }
  const buf = readFileSync(join(root, p));
  if (buf.subarray(0, 8000).includes(0)) { skipped++; continue; } // binary
  let lines = 0;
  for (let i = 0; i < buf.length; i++) if (buf[i] === 10) lines++;
  if (buf.length && buf[buf.length - 1] !== 10) lines++;
  files.push([p, lines, kindOf(p)]);
  if (files.length >= MAX_FILES) break;
}

// The Git card's message ({type:"git"} in the plan), from the same repository.
const git = (...a) => { try { return execFileSync('git', a, { cwd: root, encoding: 'utf8' }).trim(); } catch { return ''; } };
const status = git('status', '--porcelain=v2', '--branch').split('\n');
const ab = (status.find((l) => l.startsWith('# branch.ab')) ?? '# branch.ab +0 -0').split(' ');
const count = (re) => status.filter((l) => re.test(l)).length;
const gitInfo = {
  type: 'git', root: basename(root), branch: git('rev-parse', '--abbrev-ref', 'HEAD'),
  ahead: Number(ab[2]), behind: -Number(ab[3]),
  changed: count(/^[12] /), untracked: count(/^\? /), conflicts: count(/^u /),
  commits: git('log', '-3', '--format=%h%x09%ct%x09%s').split('\n').filter(Boolean).map((l) => {
    const [hash7, at, ...s] = l.split('\t');
    return { hash7: hash7.slice(0, 7), subject: s.join('\t').slice(0, 80), at: Number(at) * 1000 };
  }),
};

const out = { type: 'city', root: basename(root), files, truncated: files.length >= MAX_FILES, skipped, git: gitInfo };
writeFileSync(join(here, 'city.json'), JSON.stringify(out));
console.log(`${files.length} files, ${files.reduce((a, f) => a + f[1], 0)} lines, ${skipped} skipped → city.json`);
