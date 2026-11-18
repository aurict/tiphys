// Host firewall evaluation from `nft -j list ruleset` (PLAN.md §15 S-1). Question answered: would a NEW connection
// from an arbitrary internet address, arriving on the external interface, to proto/port be accepted by every
// input-hook base chain? Conservative where the ruleset is unclear: an unknown condition on an accepting rule counts
// as matching (→ "open"), on a dropping rule as not matching. Rules restricted to source addresses don't match
// "anyone". iptables-nft rules (xt conntrack/REJECT) are understood well enough for the usual patterns.
// Docker-published ports are DNATed before INPUT and are not judged here.

export type Family = "ip" | "ip6";
export type Verdict = "accept" | "drop" | "continue";

interface Chain {
  family: string;
  table: string;
  name: string;
  hook?: string;
  policy?: string;
  rules: unknown[][];
}

export interface Ruleset {
  chains: Map<string, Chain>;
  base: Chain[];
}

const TRUSTED_IF = /^(lo|tailscale\d*|docker\d+|br-.*|veth.*|virbr\d+|cni\d+|flannel.*|cali.*|wg\d+)$/;

const key = (family: string, table: string, name: string) => `${family}|${table}|${name}`;

/** null when the text isn't an nft JSON ruleset. */
export function parseRuleset(text: string): Ruleset | null {
  let data: { nftables?: Array<Record<string, Record<string, unknown>>> };
  try {
    data = JSON.parse(text);
  } catch {
    return null;
  }
  if (!Array.isArray(data?.nftables)) return null;
  const chains = new Map<string, Chain>();
  for (const item of data.nftables) {
    const c = item.chain as { family?: string; table?: string; name?: string; hook?: string; policy?: string } | undefined;
    if (c?.family && c.table && c.name) chains.set(key(c.family, c.table, c.name), { family: c.family, table: c.table, name: c.name, hook: c.hook, policy: c.policy, rules: [] });
  }
  for (const item of data.nftables) {
    const r = item.rule as { family?: string; table?: string; chain?: string; expr?: unknown[] } | undefined;
    if (!r?.family || !r.table || !r.chain || !Array.isArray(r.expr)) continue;
    chains.get(key(r.family, r.table, r.chain))?.rules.push(r.expr);
  }
  const base = [...chains.values()].filter((c) => c.hook === "input" && ["ip", "ip6", "inet"].includes(c.family));
  return { chains, base };
}

type Cond = true | false | "unknown";

function values(right: unknown): unknown[] {
  if (right && typeof right === "object" && "set" in (right as object)) return (right as { set: unknown[] }).set;
  return [right];
}

function portIn(right: unknown, port: number): boolean | "unknown" {
  let unknown = false;
  for (const v of values(right)) {
    if (typeof v === "number" && v === port) return true;
    if (v && typeof v === "object" && "range" in (v as object)) {
      const [a, b] = (v as { range: [number, number] }).range;
      if (typeof a === "number" && typeof b === "number" && port >= a && port <= b) return true;
    } else if (typeof v !== "number") unknown = true;
  }
  return unknown ? "unknown" : false;
}

const neg = (c: Cond): Cond => (c === "unknown" ? c : !c);

/** Evaluates one match expression for the probe packet. */
function matchCond(m: { op?: string; left?: Record<string, Record<string, string>>; right?: unknown }, proto: "tcp" | "udp", port: number, family: Family): Cond {
  const op = m.op ?? "==";
  const left = m.left ?? {};
  const eq = op === "==" || op === "in";
  const ne = op === "!=";
  if (!eq && !ne) return "unknown";
  const apply = (c: Cond): Cond => (ne ? neg(c) : c);
  if (left.meta) {
    const k = left.meta.key;
    if (k === "iifname" || k === "iif") {
      // The probe arrives on an external interface: matches names that aren't trusted/internal ones.
      const names = values(m.right).map(String);
      return apply(names.some((n) => !TRUSTED_IF.test(n.replace(/\*$/, "x"))));
    }
    if (k === "l4proto") return apply(values(m.right).map(String).includes(proto));
    if (k === "nfproto") return apply(values(m.right).map(String).includes(family === "ip" ? "ipv4" : "ipv6"));
    return "unknown";
  }
  if (left.payload) {
    const { protocol, field } = left.payload as { protocol?: string; field?: string };
    if ((protocol === "ip" || protocol === "ip6") && (field === "protocol" || field === "nexthdr")) {
      return apply(values(m.right).map(String).includes(proto));
    }
    if ((protocol === "ip" || protocol === "ip6") && (field === "saddr" || field === "daddr")) {
      // Source-restricted rules don't apply to "anyone"; a daddr test is about which local address — assume match.
      return field === "saddr" ? false : true;
    }
    if (field === "dport" && (protocol === "tcp" || protocol === "udp" || protocol === "th")) {
      if (protocol !== "th" && protocol !== proto) return apply(false);
      return apply(portIn(m.right, port) as Cond);
    }
    if (field === "sport") return false;
    return "unknown";
  }
  if (left.ct) {
    if ((left.ct as { key?: string }).key === "state") {
      const states = values(m.right).flatMap((v) => (Array.isArray(v) ? v : [v])).map(String);
      return apply(states.includes("new"));
    }
    return "unknown";
  }
  if (left.fib) return true;
  return "unknown";
}

type RuleResult = { verdict: "accept" | "drop" } | { jump: string; goto: boolean } | { verdict: "continue" };

function evalRule(expr: unknown[], proto: "tcp" | "udp", port: number, family: Family): RuleResult {
  const hasDport = expr.some((e) => {
    const m = (e as { match?: { left?: { payload?: { field?: string } } } }).match;
    return m?.left?.payload?.field === "dport";
  });
  let cond: Cond = true;
  let verdict: RuleResult | null = null;
  for (const e of expr as Array<Record<string, unknown>>) {
    if ("match" in e) {
      const c = matchCond(e.match as never, proto, port, family);
      if (c === false) return { verdict: "continue" };
      if (c === "unknown") cond = "unknown";
    } else if ("xt" in e) {
      const xt = e.xt as { type?: string; name?: string };
      if (xt.type === "target") {
        if (xt.name === "REJECT" || xt.name === "DROP") verdict = { verdict: "drop" };
        else if (xt.name === "ACCEPT") verdict = { verdict: "accept" };
      } else if (xt.name === "conntrack" || xt.name === "state") {
        // iptables -m conntrack/-m state: with a port it's the "NEW + port" pattern, alone it's ESTABLISHED,RELATED.
        if (!hasDport) return { verdict: "continue" };
      } else if (xt.name !== "comment" && xt.name !== "addrtype") cond = "unknown";
    } else if ("accept" in e) verdict = { verdict: "accept" };
    else if ("drop" in e || "reject" in e) verdict = { verdict: "drop" };
    else if ("jump" in e) verdict = { jump: String((e.jump as { target: string }).target), goto: false };
    else if ("goto" in e) verdict = { jump: String((e.goto as { target: string }).target), goto: true };
    else if ("return" in e) verdict = { verdict: "continue" };
    else if ("counter" in e || "log" in e || "limit" in e || "comment" in e) continue;
    else if ("vmap" in e || "queue" in e) verdict = { verdict: "continue" };
  }
  if (!verdict) return { verdict: "continue" };
  if (cond === "unknown") {
    // Unknown condition: assume it matches if that opens the port, not if it would close it.
    if ("verdict" in verdict && verdict.verdict === "drop") return { verdict: "continue" };
    if ("jump" in verdict) return verdict;
  }
  return verdict;
}

function evalChain(rs: Ruleset, chain: Chain, proto: "tcp" | "udp", port: number, family: Family, depth: number): Verdict {
  if (depth > 8) return "accept";
  for (const expr of chain.rules) {
    const r = evalRule(expr, proto, port, family);
    if ("jump" in r) {
      const sub = rs.chains.get(key(chain.family, chain.table, r.jump));
      const v = sub ? evalChain(rs, sub, proto, port, family, depth + 1) : "accept";
      if (v !== "continue") return v;
      if (r.goto) return "continue";
      continue;
    }
    if (r.verdict !== "continue") return r.verdict;
  }
  return "continue";
}

/** "open" when every applicable input base chain accepts the probe; "filtered" when one drops it. */
export function probe(rs: Ruleset, proto: "tcp" | "udp", port: number, family: Family): "open" | "filtered" {
  for (const c of rs.base) {
    if (c.family !== family && c.family !== "inet") continue;
    let v = evalChain(rs, c, proto, port, family, 0);
    if (v === "continue") v = c.policy === "drop" ? "drop" : "accept";
    if (v === "drop") return "filtered";
  }
  return "open";
}

/** Default-deny: an arbitrary high port is filtered on IPv4. */
export function defaultDeny(rs: Ruleset): boolean {
  return probe(rs, "tcp", 61_999, "ip") === "filtered" && probe(rs, "udp", 61_999, "ip") === "filtered";
}
