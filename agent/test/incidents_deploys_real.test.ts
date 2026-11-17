// Real docker on this machine (PLAN.md §13.1 I-2): a temporary compose stack deployed as v1 then v2 must leave v1
// tagged tiphys-rollback/…:prev, a dangling-only prune must keep it, and compose.rollback must bring v1 back.
// Needs TIPHYS_REAL=1, a local docker with compose and the alpine image. Only touches what it creates: images carry
// the label tiphys.i2test=1, the prune is filtered by that label, and everything is removed afterwards.
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ConfigStore } from "../src/config.ts";
import { run } from "../src/exec.ts";
import { DeployTracker, rollbackTag } from "../src/incidents/deploys.ts";
import { IncidentService } from "../src/incidents/service.ts";
import { Notifier } from "../src/notify.ts";

const real = process.env.TIPHYS_REAL === "1";
const P = "tiphys-i2test";
const REF = `${P}-app:latest`;
const LABEL = "tiphys.i2test=1";
const SRC = `${P}-src`;

const docker = (args: string[], cwd?: string) => run("docker", args, { allowFail: true, timeoutMs: 120_000, ...(cwd ? { cwd } : {}) });
const imageId = async (ref: string) => {
  const r = await docker(["image", "inspect", "--format", "{{.Id}}", ref]);
  return r.code === 0 ? r.stdout.trim() : null;
};
/** An image from alpine with the test label and a version label; no build (no build cache left behind). */
async function commit(version: string, ref?: string) {
  const r = await docker(["commit", "--change", `LABEL ${LABEL}`, "--change", `LABEL tiphys.i2test.v=${version}`, SRC, ...(ref ? [ref] : [])]);
  expect(r.code, r.stderr).toBe(0);
  return r.stdout.trim();
}

describe.skipIf(!real)("deploy tracking and rollback with real docker", () => {
  it(
    "v1 → v2 tags v1 :prev; prune keeps it; compose.rollback runs v1 again",
    async () => {
      const dir = await mkdtemp(join(tmpdir(), "tiphys-i2-real-"));
      const stackDir = join(dir, "stack", P);
      await mkdir(stackDir, { recursive: true });
      await writeFile(join(stackDir, "compose.yaml"), `services:\n  app:\n    image: ${REF}\n    command: ["sleep", "3600"]\n    init: true\n`);
      const ids: string[] = [];
      let svc: IncidentService | undefined;
      try {
        await docker(["rm", "-f", SRC]);
        expect((await docker(["create", "--pull", "never", "--name", SRC, "alpine", "true"])).code).toBe(0);
        const v1 = await commit("1", REF);
        ids.push(v1);
        const up = await docker(["compose", "up", "-d", "--pull", "never"], stackDir);
        expect(up.code, up.stderr).toBe(0);

        const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test-pc");
        await store.update((c) => {
          c.features.incidents = true;
          c.stacks.roots = [join(dir, "stack")];
          return c;
        });
        const tracker = new DeployTracker({ file: join(dir, "incidents", "deploys.jsonl"), project: P });
        await tracker.load();
        const seen = await tracker.snapshot();
        expect(seen.map((r) => [r.kind, r.service, r.imageId])).toEqual([["seen", "app", v1]]);

        // deploy v2 under the same reference: v1 loses its tag (it would be dangling now)
        const v2 = await commit("2", REF);
        ids.push(v2);
        expect((await docker(["compose", "up", "-d", "--pull", "never"], stackDir)).code).toBe(0);
        const [changed] = await tracker.snapshot();
        const tag = rollbackTag(P, "app");
        expect(changed).toMatchObject({ kind: "changed", imageId: v2, prevImageId: v1, rollbackTag: tag });
        expect(await imageId(tag)).toBe(v1);

        // a dangling image of ours goes, the tagged :prev stays
        const junk = await commit("junk");
        ids.push(junk);
        expect(await imageId(junk)).toBe(junk);
        const prune = await docker(["image", "prune", "-f", "--filter", `label=${LABEL}`]);
        expect(prune.code, prune.stderr).toBe(0);
        expect(await imageId(junk)).toBeNull();
        expect(await imageId(tag)).toBe(v1);

        // rollback through the incident service
        const notifier = new Notifier(() => store.get(), () => {});
        svc = await IncidentService.open({ store, notifier, dir: join(dir, "incidents"), contextDelayMs: 0, postCheckDelayMs: 3000, deploys: tracker });
        const inc = svc.onSignal({
          key: "docker.died",
          role: "open",
          kind: "docker.died",
          fingerprint: `docker.died|test-pc|${P}-app-1`,
          host: "test-pc",
          target: `${P}-app-1`,
          targetType: "container",
          severity: "critical",
          stack: P,
          service: "app",
          params: { host: "test-pc", container: `${P}-app-1`, code: 1 },
        })!;
        await svc.idle();
        expect((await svc.get(inc.id)).hints.map((h) => h.code)).toContain("recentDeploy");
        const rb = (await svc.actions(inc.id)).actions.find((a) => a.kind === "compose.rollback");
        expect(rb).toBeTruthy();
        const pv = await svc.preview(inc.id, rb!.id, "phone");
        console.log(JSON.stringify(pv, null, 1));
        expect(pv.steps[0]!.argv).toEqual(["docker", "tag", v1, REF]);
        expect(pv.steps[1]!.argv.slice(-6)).toEqual(["up", "-d", "--no-deps", "--pull", "never", "app"]);
        const ex = await svc.execute(inc.id, rb!.id, "phone", pv.previewToken);
        expect(ex).toEqual({ ok: true, code: 0 });
        await new Promise((r) => setTimeout(r, 3500)); // the post-check timer
        await svc.idle();
        const running = await docker(["inspect", "--format", "{{.Image}} {{.State.Running}}", `${P}-app-1`]);
        expect(running.stdout.trim()).toBe(`${v1} true`);
        const done = await svc.get(inc.id);
        expect(done.timeline.find((e) => e.type === "postCheck")?.data).toMatchObject({ action: "compose.rollback", ok: true });
        // the next snapshot sees the rollback as a change and tags v2 as :prev (so it can be rolled forward)
        const [back] = await tracker.snapshot();
        expect(back).toMatchObject({ imageId: v1, prevImageId: v2, rollbackTag: tag });
        expect(await imageId(tag)).toBe(v2);
      } finally {
        await svc?.close();
        await docker(["compose", "down", "--remove-orphans"], stackDir);
        await docker(["rm", "-f", SRC]);
        await docker(["image", "rm", rollbackTag(P, "app"), REF]);
        for (const id of ids) await docker(["image", "rm", id]);
        await docker(["image", "prune", "-f", "--filter", `label=${LABEL}`]);
        await rm(dir, { recursive: true, force: true });
      }
    },
    300_000,
  );
});
