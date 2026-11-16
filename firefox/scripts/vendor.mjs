// Copies Readability from the npm copy into src/vendor/; its SHA-256 is pinned after a byte-for-byte comparison with
// the file at the GitHub 0.6.0 tag (PLAN.md §11 "Phase 2a status"). If the version changes, verification is redone.
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PINNED = {
  "Readability.js": "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174",
  "LICENSE.md": "a5b1e8181751ce05b85b7bfaa832b785e87086250a5148e679d17ca9bdcfa958",
};
const pkg = JSON.parse(await readFile(join(root, "node_modules/@mozilla/readability/package.json"), "utf8"));
if (pkg.version !== "0.6.0") throw new Error(`beklenmeyen Readability sürümü: ${pkg.version}`);
await mkdir(join(root, "src/vendor"), { recursive: true });
for (const [name, sha] of Object.entries(PINNED)) {
  const body = await readFile(join(root, "node_modules/@mozilla/readability", name));
  const got = createHash("sha256").update(body).digest("hex");
  if (got !== sha) throw new Error(`${name} özeti tutmuyor: ${got}`);
  await writeFile(join(root, "src/vendor", name), body);
}
console.log("Readability 0.6.0 → src/vendor/ (özet doğrulandı)");
