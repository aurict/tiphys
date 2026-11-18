// Host firewall evaluation (PLAN.md §15 S-1): synthetic nft JSON rulesets in the shapes nft and iptables-nft produce.
import { describe, expect, it } from "vitest";
import { defaultDeny, parseRuleset, probe } from "../src/security/firewall.ts";
import { parseReport } from "../src/security/report.ts";
import { evaluate } from "../src/security/rules.ts";

const m = (left: unknown, right: unknown, op = "==") => ({ match: { op, left, right } });
const iif = (n: unknown, op = "==") => m({ meta: { key: "iifname" } }, n, op);
const dport = (proto: string, p: unknown) => m({ payload: { protocol: proto, field: "dport" } }, p);
const ipProto = (p: string) => m({ payload: { protocol: "ip", field: "protocol" } }, p);
const saddr = m({ payload: { protocol: "ip", field: "saddr" } }, { prefix: { addr: "100.64.0.0", len: 10 } });
const ct = (s: unknown) => m({ ct: { key: "state" } }, s);

function rs(chains: Array<{ family?: string; table?: string; name: string; hook?: string; policy?: string; rules: unknown[][] }>) {
  const out: unknown[] = [{ metainfo: { json_schema_version: 1 } }];
  for (const c of chains) {
    const family = c.family ?? "inet";
    const table = c.table ?? "t";
    out.push({ chain: { family, table, name: c.name, ...(c.hook ? { type: "filter", hook: c.hook, prio: 0, policy: c.policy ?? "accept" } : {}) } });
    for (const expr of c.rules) out.push({ rule: { family, table, chain: c.name, expr } });
  }
  return JSON.stringify({ nftables: out });
}

// Default-deny host firewall: only loopback, tailscale and container bridges, plus Tailscale's UDP port.
const hostFw = rs([
  {
    name: "input",
    hook: "input",
    policy: "drop",
    rules: [
      [ct({ set: ["established", "related"] }), { accept: null }],
      [ct("invalid"), { drop: null }],
      [iif("lo"), { accept: null }],
      [iif("tailscale0"), { accept: null }],
      [iif({ set: ["br-*", "docker0"] }), { accept: null }],
      [m({ meta: { key: "l4proto" } }, "udp"), dport("udp", 41641), { accept: null }],
      [{ limit: { rate: 10, per: "minute" } }, { log: { prefix: "drop: " } }],
    ],
  },
  // Docker's iptables-nft INPUT (policy accept, no rules of its own) must not reopen anything.
  { family: "ip", table: "filter", name: "INPUT", hook: "input", rules: [] },
]);

// Cloud image style: jump to tailscale's chain, ESTABLISHED via xt conntrack, ssh with NEW, then REJECT.
const iptablesStyle = rs([
  {
    family: "ip",
    table: "filter",
    name: "INPUT",
    hook: "input",
    rules: [
      [{ counter: { packets: 1, bytes: 1 } }, { jump: { target: "ts-input" } }],
      [{ xt: { type: "match", name: "conntrack" } }, { accept: null }],
      [ipProto("icmp"), { accept: null }],
      [iif("lo"), { accept: null }],
      [ipProto("tcp"), { xt: { type: "match", name: "conntrack" } }, dport("tcp", 22), { accept: null }],
      [{ xt: { type: "target", name: "REJECT" } }],
    ],
  },
  {
    family: "ip",
    table: "filter",
    name: "ts-input",
    rules: [
      [iif("tailscale0"), { accept: null }],
      [iif("tailscale0", "!="), saddr, { drop: null }],
      [iif("tailscale0", "!="), ipProto("udp"), dport("udp", 41641), { accept: null }],
    ],
  },
]);

describe("nft evaluation", () => {
  it("default-deny host firewall filters everything but its explicit openings", () => {
    const r = parseRuleset(hostFw)!;
    expect(r.base).toHaveLength(2);
    expect(probe(r, "tcp", 22, "ip")).toBe("filtered");
    expect(probe(r, "tcp", 6769, "ip6")).toBe("filtered");
    expect(probe(r, "udp", 41641, "ip")).toBe("open");
    expect(defaultDeny(r)).toBe(true);
  });

  it("iptables-nft pattern: jump, xt conntrack, NEW+port accept, final REJECT", () => {
    const r = parseRuleset(iptablesStyle)!;
    expect(probe(r, "tcp", 22, "ip")).toBe("open");
    expect(probe(r, "tcp", 111, "ip")).toBe("filtered");
    expect(probe(r, "udp", 111, "ip")).toBe("filtered");
    expect(probe(r, "udp", 41641, "ip")).toBe("open");
    // No ip6 chain at all → nothing filters IPv6.
    expect(probe(r, "tcp", 111, "ip6")).toBe("open");
    expect(defaultDeny(r)).toBe(true);
  });

  it("sets, ranges, ct state new, goto/return, unknown conditions", () => {
    const r = parseRuleset(
      rs([
        {
          name: "input",
          hook: "input",
          policy: "drop",
          rules: [
            [dport("tcp", { set: [80, 443, { range: [8000, 8010] }] }), ct("new"), { accept: null }],
            [{ jump: { target: "sub" } }],
            [{ weird: {} }, dport("tcp", 9000), { accept: null }],
            [m({ meta: { key: "mark" } }, 1), { drop: null }],
            [dport("tcp", 9100), { accept: null }],
          ],
        },
        { name: "sub", rules: [[dport("tcp", 5000), { return: null }], [dport("tcp", 5001), { accept: null }]] },
      ]),
    )!;
    expect(["tcp/80", "tcp/443", "tcp/8005", "tcp/8011"].map((x) => probe(r, "tcp", Number(x.split("/")[1]), "ip"))).toEqual(["open", "open", "open", "filtered"]);
    expect(probe(r, "tcp", 5000, "ip")).toBe("filtered");
    expect(probe(r, "tcp", 5001, "ip")).toBe("open");
    // unknown expression on an accept → assume it matches (open); unknown match before a drop → ignored.
    expect(probe(r, "tcp", 9000, "ip")).toBe("open");
    expect(probe(r, "tcp", 9100, "ip")).toBe("open");
    expect(probe(r, "udp", 80, "ip")).toBe("filtered");
  });

  it("garbage is not a ruleset", () => {
    expect(parseRuleset("not json")).toBeNull();
    expect(parseRuleset('{"x":1}')).toBeNull();
  });
});

describe("report integration", () => {
  const text = (nft: string, ipv6 = 0, listen = "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 128 [::]:6769 [::]:*\ntcp LISTEN 0 128 0.0.0.0:111 0.0.0.0:*") =>
    `@@tiphys-audit 1 report\n@@section meta\nhostname atlas\nroot 1\nipv6Global ${ipv6}\n@@section listen\n${listen}\n@@section nft\n${nft}\n@@section services\nnftables inactive disabled\n@@end\n`;

  it("filtered listeners are not exposure findings; firewall present", () => {
    const r = parseReport(text(hostFw));
    expect(r.firewall).toEqual({ source: "nft", defaultDeny: true, inputChains: 2 });
    expect(r.listen!.map((l) => l.firewall)).toEqual(["filtered", "filtered", "filtered"]);
    const f = evaluate(r, { role: "server", allowedPorts: [] });
    expect(f.filter((x) => x.rule === "port.exposed" || x.rule === "firewall.none")).toEqual([]);
  });

  it("IPv6 counts only with a global IPv6 address", () => {
    const noV6 = parseReport(text(iptablesStyle, 0));
    expect(noV6.listen!.map((l) => `${l.port}:${l.firewall}`)).toEqual(["22:open", "6769:filtered", "111:filtered"]);
    const withV6 = parseReport(text(iptablesStyle, 1));
    expect(withV6.listen!.map((l) => `${l.port}:${l.firewall}`)).toEqual(["22:open", "6769:open", "111:filtered"]);
    const f = evaluate(noV6, { role: "server", allowedPorts: [] });
    expect(f.filter((x) => x.rule === "port.exposed").map((x) => x.id)).toEqual(["port.exposed:tcp/22"]);
  });

  it("without root the firewall is unknown and exposure says so", () => {
    const r = parseReport(text("@@unavailable root"));
    expect(r.firewall).toBeNull();
    const f = evaluate(r, { role: "desktop", allowedPorts: [] });
    expect(f.find((x) => x.id === "port.exposed:tcp/22")!.params.firewall).toBe("unknown");
    expect(f.some((x) => x.rule === "firewall.none")).toBe(true);
  });
});
