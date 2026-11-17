// §13 review S1: PostgreSQL read path denylist bypasses (U& identifiers/strings, SQL text run by functions, set_config)
// and the read guard (readRole via SET LOCAL ROLE, superuser reads refused unless acknowledged).
import { describe, expect, it } from "vitest";
import { readGuard } from "../src/db/pg.ts";
import { checkReadStatement, checkWriteStatement } from "../src/db/sql.ts";

const refused = (sql: string) => expect(checkReadStatement(sql, "postgres"), sql).toMatchObject({ ok: false, code: "agent.db.statementNotAllowed" });

describe("S1 denylist", () => {
  it("refuses Unicode-escaped identifiers and strings", () => {
    refused(String.raw`SELECT U&"pg_read_fil\0065"('/etc/passwd')`);
    refused(String.raw`SELECT u&"x" FROM t`);
    refused(String.raw`SELECT U&'\0041'`);
    expect(checkWriteStatement(String.raw`UPDATE t SET a = U&'\0041'`, "postgres")).toMatchObject({ ok: false });
    // A column u followed by the & operator is still fine.
    expect(checkReadStatement(`SELECT u & 1 FROM t`, "postgres")).toEqual({ ok: true });
  });

  it("refuses functions that run SQL text, also hidden in dollar quotes, quoted or schema-qualified", () => {
    refused(`SELECT * FROM ts_stat($q$SELECT to_tsvector(pg_read_file('/etc/passwd'))$q$)`);
    refused(`SELECT ts_rewrite('a'::tsquery, 'SELECT ''a''::tsquery, ''b''::tsquery')`);
    refused(`SELECT * FROM pg_catalog."TS_STAT"('SELECT 1')`);
    refused(`SELECT query_to_xml('select 1', true, true, '')`);
    refused(`SELECT * FROM crosstab('select 1')`);
    refused(`SELECT pg_catalog.set_config('role', 'postgres', true)`);
    refused(`SELECT "pg_read_file"('x')`);
    refused(`SELECT pg_catalog.pg_read_file('x')`);
    refused(`SELECT dblink_exec('x', 'y')`);
    refused(`SELECT pg_stat_reset()`);
    expect(checkReadStatement(`SELECT $q$pg_read_file$q$ AS s`, "postgres")).toEqual({ ok: true });
  });
});

function fakeClient(o: { sessionSuper: boolean; roleSuper?: boolean }) {
  const sent: string[] = [];
  let role: string | undefined;
  return {
    sent,
    async query(q: { text: string }) {
      sent.push(q.text);
      if (q.text.startsWith("SET LOCAL ROLE")) {
        role = q.text;
        return { rows: [] };
      }
      const su = q.text.includes("current_user") && role ? o.roleSuper === true : o.sessionSuper;
      return { rows: [{ su }] };
    },
  };
}

describe("S1 read guard", () => {
  const ep = { host: "h", port: 1, user: "postgres", database: "d" };
  it("superuser login without readRole: refused until allowSuperuserReads", async () => {
    await expect(readGuard(fakeClient({ sessionSuper: true }) as never, ep)).rejects.toMatchObject({ code: "agent.db.superuserReadsDisabled", status: 403 });
    await expect(readGuard(fakeClient({ sessionSuper: true }) as never, { ...ep, allowSuperuserReads: true })).resolves.toBeUndefined();
    await expect(readGuard(fakeClient({ sessionSuper: false }) as never, ep)).resolves.toBeUndefined();
  });
  it("readRole: SET LOCAL ROLE (quoted), refused when that role is a superuser", async () => {
    const c = fakeClient({ sessionSuper: true, roleSuper: false });
    await readGuard(c as never, { ...ep, readRole: 'ro"x' });
    expect(c.sent[0]).toBe(`SET LOCAL ROLE "ro""x"`);
    await expect(readGuard(fakeClient({ sessionSuper: true, roleSuper: true }) as never, { ...ep, readRole: "admin" })).rejects.toMatchObject({ code: "agent.db.superuserReadsDisabled" });
  });
});
