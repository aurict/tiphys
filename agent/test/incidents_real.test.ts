// Real docker crash on this machine (PLAN.md §13.1 I-1): `docker run --name tiphys-crash alpine sh -c 'exit 3'` must
// open an incident with context. Needs TIPHYS_REAL=1 and a local docker; the container is removed afterwards.
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DockerEventWatcher } from "../src/alerts.ts";
import { ConfigStore } from "../src/config.ts";
import { EventLog, eventsPath } from "../src/events.ts";
import { run } from "../src/exec.ts";
import { IncidentService } from "../src/incidents/service.ts";
import { Notifier, type Notice } from "../src/notify.ts";
import type { Ctx } from "../src/server.ts";

const real = process.env.TIPHYS_REAL === "1";
const NAME = "tiphys-crash";

describe.skipIf(!real)("incident from a real container crash", () => {
  it(
    "docker run … exit 3 → docker.died → incident with context",
    async () => {
      const dir = await mkdtemp(join(tmpdir(), "tiphys-incident-real-"));
      const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test-pc");
      await store.update((c) => {
        c.features.incidents = true;
        c.stacks.roots = [join(dir, "stack")];
        return c;
      });
      const notifier = new Notifier(() => store.get(), () => {}, new EventLog(eventsPath(store.path)));
      const svc = await IncidentService.open({ store, notifier, dir: join(dir, "incidents"), contextDelayMs: 0 });
      notifier.observe(svc.observe);
      const sent: Notice[] = [];
      notifier.observe((n) => void sent.push(n));
      const watcher = new DockerEventWatcher({ store, notifier } as Ctx);
      await run("docker", ["rm", "-f", NAME], { allowFail: true });
      watcher.start();
      try {
        await new Promise((r) => setTimeout(r, 1500)); // let `docker events` subscribe
        const r = await run("docker", ["run", "--name", NAME, "alpine", "sh", "-c", "echo boot; echo password=hunter2secret; exit 3"], { allowFail: true, timeoutMs: 120_000 });
        expect(r.code).toBe(3);
        for (let i = 0; i < 60 && !svc.list().length; i++) await new Promise((res) => setTimeout(res, 250));
        await svc.idle();
        const [sum] = svc.list();
        expect(sum).toMatchObject({ kind: "docker.died", target: NAME, status: "open" });
        const inc = await svc.get(sum!.id);
        console.log(JSON.stringify({ incident: { ...inc, context: { ...inc.context, events: inc.context?.events?.length } }, sent }, null, 1));
        expect(sent[0]).toMatchObject({ key: "docker.died", link: `tiphys://incidents/${sum!.id}`, data: { incidentId: sum!.id }, params: { container: NAME, code: 3 } });
        expect(inc.context?.inspect).toMatchObject({ exitCode: 3, running: false });
        expect(inc.context?.logs?.lines.join("\n")).toContain("boot");
        expect(JSON.stringify(inc.context)).not.toContain("hunter2secret");
        expect(inc.hints.map((h) => h.code)).toContain("exitCode");
        expect((await svc.actions(sum!.id)).actions.map((a) => a.kind)).toEqual(["container.restart"]);
      } finally {
        watcher.stop();
        await run("docker", ["rm", "-f", NAME], { allowFail: true });
        await svc.close();
      }
    },
    180_000,
  );
});
