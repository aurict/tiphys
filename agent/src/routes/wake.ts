// Wake-on-LAN: sends a "magic packet" to the target's MAC address.
// Note: the packet is a local network broadcast; the agent must run on the SAME local network as the device to wake.
import { createSocket } from "node:dgram";
import type { FastifyInstance } from "fastify";
import { notFound } from "../errors.ts";
import type { Ctx } from "../server.ts";

export function magicPacket(mac: string): Buffer {
  const bytes = Buffer.from(mac.replace(/[:-]/g, ""), "hex");
  if (bytes.length !== 6) throw new Error("geçersiz MAC");
  return Buffer.concat([Buffer.alloc(6, 0xff), ...Array.from({ length: 16 }, () => bytes)]);
}

export function sendMagicPacket(mac: string, broadcast: string, port: number): Promise<void> {
  const packet = magicPacket(mac);
  return new Promise((resolve, reject) => {
    const sock = createSocket("udp4");
    sock.once("error", (e) => {
      sock.close();
      reject(e);
    });
    sock.bind(() => {
      sock.setBroadcast(true);
      sock.send(packet, port, broadcast, (err) => {
        sock.close();
        if (err) reject(err);
        else resolve();
      });
    });
  });
}

export function wakeRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get("/v1/wake", async () => ({ targets: ctx.store.get().wake.targets.map(({ hostId }) => ({ hostId })) }));

  app.post("/v1/wake/:hostId", async (req) => {
    const hostId = (req.params as Record<string, string>).hostId;
    const t = ctx.store.get().wake.targets.find((x) => x.hostId === hostId);
    if (!t) throw notFound("wake.target", { hostId });
    await sendMagicPacket(t.mac, t.broadcast, t.port);
    return { ok: true };
  });
}
