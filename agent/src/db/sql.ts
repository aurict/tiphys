// Engine-independent SQL helpers of the database console (PLAN.md §13.2): a small lexer that finds the statements and
// words of a text per dialect (quotes, comments, PostgreSQL dollar quotes, MySQL executable comments), the read and
// write statement allowlists with a function denylist, identifier quoting, result cell conversion with the size caps
// and column kinds for charts. Imports nothing.

/** Connection engines. "mysql" and "mariadb" share the MySQL driver and dialect (the server flavor is detected). */
export type Engine = "postgres" | "sqlite" | "mysql" | "mariadb";
/** SQL dialect of the lexer and the allowlists. */
export type Dialect = "postgres" | "sqlite" | "mysql";
export const dialectOf = (e: Engine): Dialect => (e === "mariadb" ? "mysql" : e);

export const LIMITS = {
  defaultRows: 500,
  maxRows: 5000,
  cellBytes: 4096,
  /** All cells of one result together; past it the result is cut like a row limit (truncated: true). */
  resultBytes: 8 * 1024 * 1024,
  defaultTimeoutMs: 15_000,
  maxTimeoutMs: 60_000,
  maxSqlChars: 100_000,
  maxParams: 100,
  /** CSV export: rows, bytes of CSV text, and the whole export's wall clock. */
  exportRows: 100_000,
  exportBytes: 50 * 1024 * 1024,
  exportWallMs: 5 * 60_000,
  /** Write preview: sample rows returned (PostgreSQL DML through RETURNING *). */
  writeSampleRows: 20,
} as const;

/** A word outside strings and comments: unquoted keywords/identifiers (lower case) and quoted identifiers. */
export interface Word {
  w: string;
  quoted: boolean;
  /** Parenthesis depth. */
  depth: number;
  /** The previous token was a ")" that closed back to this depth. */
  afterClose: boolean;
  /** Followed by "." (a schema or table qualifier). */
  dot?: boolean;
}

export interface Lexed {
  text: string;
  words: Word[];
  /** MySQL/MariaDB executable comment (/*! … *\/, /*M! … *\/) or optimizer hint (/*+ … *\/): run or applied by the server. */
  execComment: boolean;
  /** PostgreSQL U&"…" / U&'…' (Unicode escapes): the words inside can't be compared with the denylist, so it is refused. */
  unicodeEscape?: boolean;
}

const WORD_START = /[A-Za-z_\u0080-￿]/;
const WORD_CHAR = /[A-Za-z0-9_$\u0080-￿]/;

/**
 * Splits a text into statements and the words of each (strings and comments skipped). Follows the dialect's rules:
 * PostgreSQL nested block comments, dollar quotes and E'…' backslash strings; MySQL backslash escapes in '…' and "…",
 * `…` identifiers, # comments and "-- " (dash dash space); SQLite "…", `…`, […] identifiers. The agent pins the
 * server settings these rules assume (PostgreSQL standard_conforming_strings=on; MySQL sql_mode without
 * NO_BACKSLASH_ESCAPES and ANSI_QUOTES). Unterminated quotes or comments run to the end of the text.
 */
export function lex(sql: string, engine: Engine): Lexed[] {
  const d = dialectOf(engine);
  const out: Lexed[] = [];
  let start = 0;
  let meaningful = false;
  let words: Word[] = [];
  let exec = false;
  let uesc = false;
  let depth = 0;
  let afterClose = false;
  let i = 0;
  const n = sql.length;
  const push = (end: number) => {
    if (meaningful) out.push({ text: sql.slice(start, end), words, execComment: exec, ...(uesc ? { unicodeEscape: true } : {}) });
    start = end + 1;
    meaningful = false;
    words = [];
    exec = false;
    uesc = false;
    depth = 0;
    afterClose = false;
  };
  const word = (w: string, quoted: boolean, end: number) => {
    let k = end;
    while (k < n && /\s/.test(sql[k]!)) k++;
    words.push({ w: w.toLowerCase(), quoted, depth, afterClose, ...(sql[k] === "." ? { dot: true } : {}) });
    afterClose = false;
  };
  while (i < n) {
    const c = sql[i]!;
    const next = sql[i + 1];
    if (c === "-" && next === "-" && (d !== "mysql" || i + 2 >= n || /[\s\x00-\x1f]/.test(sql[i + 2]!))) {
      const e = sql.indexOf("\n", i + 2);
      i = e < 0 ? n : e + 1;
      continue;
    }
    if (d === "mysql" && c === "#") {
      const e = sql.indexOf("\n", i + 1);
      i = e < 0 ? n : e + 1;
      continue;
    }
    if (c === "/" && next === "*") {
      if (d === "mysql" && /^\/\*(!|M!|\+)/.test(sql.slice(i, i + 4))) {
        exec = true;
        meaningful = true;
      }
      // PostgreSQL block comments nest; the others don't.
      let depthC = 1;
      i += 2;
      while (i < n && depthC > 0) {
        if (sql[i] === "*" && sql[i + 1] === "/") {
          depthC--;
          i += 2;
        } else if (d === "postgres" && sql[i] === "/" && sql[i + 1] === "*") {
          depthC++;
          i += 2;
        } else i++;
      }
      continue;
    }
    if (c === ";") {
      push(i);
      i++;
      continue;
    }
    if (/\s/.test(c)) {
      i++;
      continue;
    }
    meaningful = true;
    if (c === "'") {
      // PostgreSQL: E'…' takes backslash escapes; MySQL: every string does.
      const prev = sql[i - 1];
      const escapes = d === "mysql" || (d === "postgres" && (prev === "E" || prev === "e") && !WORD_CHAR.test(sql[i - 2] ?? ""));
      i = skipQuoted(sql, i, "'", escapes);
      afterClose = false;
      continue;
    }
    if (c === '"') {
      const e = skipQuoted(sql, i, '"', d === "mysql");
      // A MySQL "…" is a string; it still counts for the function denylist (quoted=true never matches a keyword).
      word(sql.slice(i + 1, e - 1).replace(/""/g, '"'), true, e);
      i = e;
      continue;
    }
    if (c === "`" && d !== "postgres") {
      const e = skipQuoted(sql, i, "`", false);
      word(sql.slice(i + 1, e - 1).replace(/``/g, "`"), true, e);
      i = e;
      continue;
    }
    if (d === "sqlite" && c === "[") {
      const e = sql.indexOf("]", i + 1);
      word(sql.slice(i + 1, e < 0 ? n : e), true, e < 0 ? n : e + 1);
      i = e < 0 ? n : e + 1;
      continue;
    }
    if (d === "postgres" && c === "$") {
      const m = /^\$([A-Za-z_\u0080-￿][A-Za-z0-9_\u0080-￿]*)?\$/.exec(sql.slice(i, i + 130));
      // A $n parameter or a $ inside an identifier is not a dollar quote.
      if (m && !/[A-Za-z0-9_$]/.test(sql[i - 1] ?? "")) {
        const tag = m[0];
        const e = sql.indexOf(tag, i + tag.length);
        i = e < 0 ? n : e + tag.length;
        afterClose = false;
        continue;
      }
    }
    if (c === "(") {
      depth++;
      afterClose = false;
      i++;
      continue;
    }
    if (c === ")") {
      depth = Math.max(0, depth - 1);
      afterClose = true;
      i++;
      continue;
    }
    if (/[0-9]/.test(c)) {
      // Numbers (1e5, 0x1F): not words.
      let j = i + 1;
      while (j < n && /[A-Za-z0-9_.]/.test(sql[j]!)) j++;
      i = j;
      afterClose = false;
      continue;
    }
    if (WORD_START.test(c)) {
      let j = i + 1;
      while (j < n && WORD_CHAR.test(sql[j]!)) j++;
      if (d === "postgres" && j === i + 1 && (c === "u" || c === "U") && sql[j] === "&" && (sql[j + 1] === '"' || sql[j + 1] === "'")) uesc = true;
      word(sql.slice(i, j), false, j);
      i = j;
      continue;
    }
    afterClose = false;
    i++;
  }
  push(n);
  return out;
}

/** The text of each non-empty statement (comments kept, trailing `;` dropped). */
export function statements(sql: string, engine: Engine): string[] {
  return lex(sql, engine).map((s) => s.text);
}

function skipQuoted(sql: string, i: number, q: string, backslash: boolean): number {
  let j = i + 1;
  while (j < sql.length) {
    const ch = sql[j]!;
    if (backslash && ch === "\\") {
      j += 2;
      continue;
    }
    if (ch === q) {
      if (sql[j + 1] === q) {
        j += 2;
        continue;
      }
      return j + 1;
    }
    j++;
  }
  return sql.length;
}

/** The first keyword of a statement, lower case ("" when it starts with a quoted name or has no words). */
export function firstKeyword(stmt: string, engine: Engine = "postgres"): string {
  const w = lex(stmt, engine)[0]?.words[0];
  return w && !w.quoted ? w.w : "";
}

/**
 * Statement kinds the read-only path accepts. Reads run; DML goes to the database, whose read-only transaction (or
 * read-only SQLite handle) refuses it. Everything else is refused here: COPY … TO PROGRAM, LOAD, DO, CALL, SET,
 * VACUUM INTO, ATTACH, LOAD DATA, HANDLER… are not stopped by a read-only transaction when the role is privileged.
 */
const READ: Record<Dialect, Set<string>> = {
  postgres: new Set(["select", "with", "values", "table", "explain", "show"]),
  sqlite: new Set(["select", "with", "values", "explain"]),
  mysql: new Set(["select", "with", "values", "table", "explain", "describe", "desc", "show"]),
};
const DML: Record<Dialect, Set<string>> = {
  postgres: new Set(["insert", "update", "delete", "merge"]),
  sqlite: new Set(["insert", "update", "delete", "replace"]),
  mysql: new Set(["insert", "update", "delete", "replace"]),
};

/**
 * Names refused anywhere in a statement (read and write), quoted or not: functions that touch the server's files or
 * programs, run SQL text or other connections, or administer the server. Defence in depth: the primary guard is a
 * dedicated low-privilege role; this list can't know user-defined functions.
 */
const DENY_PG = new Set([
  "pg_read_file", "pg_read_binary_file", "pg_stat_file", "pg_ls_dir", "pg_ls_logdir", "pg_ls_waldir", "pg_ls_tmpdir",
  "pg_ls_archive_statusdir", "pg_ls_logicalsnapdir", "pg_ls_logicalmapdir", "pg_ls_replslotdir", "pg_logdir_ls",
  "pg_file_write", "pg_file_rename", "pg_file_unlink", "pg_file_sync",
  "lo_import", "lo_export", "lo_from_bytea", "lo_put", "lo_create", "lo_creat", "lo_unlink", "lo_open", "lo_truncate", "lowrite",
  "query_to_xml", "query_to_xmlschema", "query_to_xml_and_xmlschema",
  // Run SQL text given as a string (ts_stat, ts_rewrite's query form, tablefunc, xml2) or change the session's role
  // and settings (set_config('role', …) would undo the read role's SET LOCAL ROLE).
  "ts_stat", "ts_rewrite", "crosstab", "crosstab2", "crosstab3", "crosstab4", "connectby", "xpath_table", "set_config",
  "pg_stat_statements_reset",
  "pg_terminate_backend", "pg_cancel_backend", "pg_reload_conf", "pg_rotate_logfile", "pg_promote", "pg_switch_wal",
  "pg_create_restore_point", "pg_drop_replication_slot", "pg_create_physical_replication_slot", "pg_create_logical_replication_slot",
]);
const DENY_MYSQL = new Set(["load_file", "outfile", "dumpfile", "sys_exec", "sys_eval"]);
const denied = (d: Dialect, w: string) => (d === "postgres" ? DENY_PG.has(w) || w.startsWith("dblink") || w.startsWith("pg_replication_origin") || w.startsWith("pg_stat_reset") : d === "mysql" ? DENY_MYSQL.has(w) : false);

type Refusal = { ok: false; code: "agent.db.emptyStatement" | "agent.db.multipleStatements" | "agent.db.statementNotAllowed" | "agent.db.ddlNotPreviewable" | "agent.db.systemSchema"; keyword?: string; count?: number; schema?: string };

/** MySQL/MariaDB system schemas: some of their tables are MyISAM/Aria/CSV, so a write preview there can't be rolled back. */
export const MYSQL_SYSTEM_SCHEMAS = ["mysql", "sys", "performance_schema", "information_schema"] as const;
export type StatementCheck = { ok: true } | Refusal;

const notAllowed = (keyword: string): Refusal => ({ ok: false, code: "agent.db.statementNotAllowed", keyword: keyword.slice(0, 64) });

/** One statement, its words checked against the denylist and MySQL's executable comments. */
function single(sql: string, engine: Engine): Refusal | Lexed {
  const list = lex(sql, engine);
  if (list.length === 0) return { ok: false, code: "agent.db.emptyStatement" };
  if (list.length > 1) return { ok: false, code: "agent.db.multipleStatements", count: list.length };
  const s = list[0]!;
  if (s.execComment) return notAllowed("/*!");
  if (s.unicodeEscape) return notAllowed("u&");
  const d = dialectOf(engine);
  const bad = s.words.find((w) => denied(d, w.w));
  if (bad) return notAllowed(bad.w);
  return s;
}

export function checkReadStatement(sql: string, engine: Engine): StatementCheck {
  const s = single(sql, engine);
  if ("ok" in s) return s;
  const d = dialectOf(engine);
  const first = s.words[0];
  const kw = first && !first.quoted ? first.w : "";
  if (DML[d].has(kw)) return { ok: true };
  if (!READ[d].has(kw)) return notAllowed(kw);
  // MySQL: SELECT … INTO OUTFILE/DUMPFILE writes server files whatever the transaction; INTO @var is refused too.
  if (d === "mysql" && s.words.some((w) => !w.quoted && w.w === "into")) return notAllowed("into");
  return { ok: true };
}

export type WriteCheck = { ok: true; kind: "dml" | "ddl"; verb: string; returning: boolean } | Refusal;

/** For WITH …: the statement keyword after the CTE list (first top-level DML/SELECT word right after a ")"). */
function mainOfWith(words: Word[]): string {
  const w = words.find((x, i) => i > 0 && x.depth === 0 && x.afterClose && !x.quoted && ["select", "insert", "update", "delete", "merge", "values", "table"].includes(x.w));
  return w?.w ?? "";
}

/** Words allowed after `CREATE ROLE|USER <name>` (PostgreSQL): no privilege attributes, only pg_read_all_data membership. */
const ROLE_WORDS = new Set([
  "with", "login", "nologin", "password", "encrypted", "null", "nosuperuser", "nocreatedb", "nocreaterole", "noreplication",
  "nobypassrls", "inherit", "noinherit", "connection", "limit", "valid", "until", "in", "role", "pg_read_all_data",
]);
const CREATE_MODIFIERS = new Set(["or", "replace", "temp", "temporary", "unlogged", "unique", "materialized", "recursive", "global", "local"]);
const PG_DDL_OBJECTS: Record<string, Set<string>> = {
  create: new Set(["table", "index", "view", "role", "user"]),
  alter: new Set(["table", "index", "view"]),
  drop: new Set(["table", "index", "view"]),
};
const MYSQL_DDL = new Set(["create", "alter", "drop", "rename", "truncate", "grant", "revoke"]);

/**
 * Write mode allowlist (D-3). PostgreSQL: INSERT/UPDATE/DELETE/MERGE (also after WITH), CREATE/ALTER/DROP of
 * TABLE/INDEX/VIEW (incl. materialized views), and CREATE ROLE|USER with only safe attributes (the read-only role
 * helper). Never COPY, DO, CALL, SET, ALTER SYSTEM, functions/procedures/triggers/extensions (no CREATE FUNCTION in any
 * language), GRANT, or the denylisted functions. MySQL/MariaDB: INSERT/UPDATE/DELETE/REPLACE (also after WITH); DDL
 * commits implicitly, so it can't be previewed (agent.db.ddlNotPreviewable). SQLite has no write mode.
 */
export function checkWriteStatement(sql: string, engine: Engine): WriteCheck {
  const s = single(sql, engine);
  if ("ok" in s) return s;
  const d = dialectOf(engine);
  if (d === "sqlite") return notAllowed("sqlite");
  const words = s.words;
  if (d === "mysql") {
    const sys = words.find((w) => w.dot && (MYSQL_SYSTEM_SCHEMAS as readonly string[]).includes(w.w));
    if (sys) return { ok: false, code: "agent.db.systemSchema", schema: sys.w };
  }
  const first = words[0];
  const kw = first && !first.quoted ? first.w : "";
  const returning = d === "postgres" && words.some((w) => w.depth === 0 && !w.quoted && w.w === "returning");
  const dml = d === "postgres" ? ["insert", "update", "delete", "merge"] : ["insert", "update", "delete", "replace"];
  if (dml.includes(kw)) return { ok: true, kind: "dml", verb: kw, returning };
  if (kw === "with") {
    const main = mainOfWith(words);
    if (dml.includes(main)) return { ok: true, kind: "dml", verb: main, returning };
    return notAllowed(`with ${main}`.trim());
  }
  if (d === "mysql") {
    if (MYSQL_DDL.has(kw)) return { ok: false, code: "agent.db.ddlNotPreviewable", keyword: kw };
    return notAllowed(kw);
  }
  const objects = PG_DDL_OBJECTS[kw];
  if (!objects) return notAllowed(kw);
  let i = 1;
  if (kw === "create") while (i < words.length && !words[i]!.quoted && CREATE_MODIFIERS.has(words[i]!.w)) i++;
  else if (words[i]?.w === "materialized" && !words[i]!.quoted) i++;
  const obj = words[i];
  if (!obj || obj.quoted || !objects.has(obj.w)) return notAllowed(`${kw} ${obj && !obj.quoted ? obj.w : ""}`.trim());
  if (obj.w === "role" || obj.w === "user") {
    // CREATE ROLE <name> …: every later word must be a safe attribute.
    const bad = words.slice(i + 2).find((w) => w.quoted || !ROLE_WORDS.has(w.w));
    if (i !== 1 || bad) return notAllowed(`create role${bad && !bad.quoted ? ` ${bad.w}` : ""}`);
  }
  return { ok: true, kind: "ddl", verb: `${kw} ${obj.w}`, returning: false };
}

/** Quotes an identifier the engine's way ("…" with "" doubling; MySQL `…` with `` doubling). The name must already be known to exist. */
export function quoteIdent(name: string, engine: Engine = "postgres"): string {
  if (name.includes("\0")) throw new Error("NUL in identifier");
  if (dialectOf(engine) === "mysql") return `\`${name.replace(/`/g, "``")}\``;
  return `"${name.replace(/"/g, '""')}"`;
}

/** Result cell: JSON-safe value. Bytes become "<n bayt>", long text is cut at cellBytes (UTF-8) with "…". */
export function toCell(v: unknown, cellBytes: number = LIMITS.cellBytes): { value: string | number | boolean | null; cut: boolean; bytes: number } {
  if (v === null || v === undefined) return { value: null, cut: false, bytes: 4 };
  if (typeof v === "boolean") return { value: v, cut: false, bytes: 5 };
  if (typeof v === "number") return Number.isFinite(v) ? { value: v, cut: false, bytes: 16 } : capText(String(v), cellBytes);
  if (typeof v === "bigint") {
    return v >= BigInt(Number.MIN_SAFE_INTEGER) && v <= BigInt(Number.MAX_SAFE_INTEGER) ? { value: Number(v), cut: false, bytes: 16 } : capText(v.toString(), cellBytes);
  }
  if (v instanceof Uint8Array) return { value: `<${v.byteLength} bayt>`, cut: false, bytes: 16 };
  if (v instanceof Date) return capText(Number.isNaN(v.getTime()) ? String(v) : v.toISOString(), cellBytes);
  if (typeof v === "string") return capText(v, cellBytes);
  let text: string;
  try {
    text = JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x instanceof Uint8Array || (x && x.type === "Buffer" && Array.isArray(x.data)) ? `<${x.byteLength ?? x.data.length} bayt>` : x)) ?? String(v);
  } catch {
    text = String(v);
  }
  return capText(text, cellBytes);
}

function capText(s: string, max: number): { value: string; cut: boolean; bytes: number } {
  const bytes = Buffer.byteLength(s);
  if (bytes <= max) return { value: s, cut: false, bytes };
  // Cut at a UTF-8 character boundary.
  const buf = Buffer.from(s).subarray(0, max);
  let end = buf.length;
  while (end > 0 && (buf[end]! & 0xc0) === 0x80) end--;
  if (end > 0 && buf[end - 1]! >= 0xc0) end--;
  return { value: buf.subarray(0, end).toString() + "…", cut: true, bytes: max };
}

export interface RowsResult {
  columns: Array<{ name: string; type: string | null }>;
  rows: Array<Array<string | number | boolean | null>>;
  rowCount: number;
  truncated: boolean;
  /** Cells cut at cellBytes. */
  cellsTruncated: number;
}

/** Receives a streamed result (CSV export): the columns once, then each raw row until it returns false. */
export interface RowSink {
  columns(cols: RowsResult["columns"]): void;
  row(values: unknown[]): boolean | Promise<boolean>;
}

/** What one write-mode run did: affected rows (null for DDL), sample rows (PostgreSQL DML), and whether it committed. */
export interface WriteOutcome {
  count: number | null;
  sample?: { columns: RowsResult["columns"]; rows: RowsResult["rows"]; cellsTruncated: number };
  /** The session user is a superuser (PostgreSQL rolsuper; MySQL SUPER or FILE privilege). */
  superuser: boolean;
  committed: boolean;
}

/** Collects converted rows, stopping at the row limit or the total byte budget. Returns false once full. */
export class RowCollector {
  rows: RowsResult["rows"] = [];
  truncated = false;
  cellsTruncated = 0;
  #bytes = 0;
  #limit: number;
  #budget: number;
  #cellBytes: number;

  constructor(limit: number, o: { cellBytes?: number; resultBytes?: number } = {}) {
    this.#limit = limit;
    this.#cellBytes = o.cellBytes ?? LIMITS.cellBytes;
    this.#budget = o.resultBytes ?? LIMITS.resultBytes;
  }

  add(raw: unknown[]): boolean {
    if (this.rows.length >= this.#limit || this.#bytes >= this.#budget) {
      this.truncated = true;
      return false;
    }
    const row = raw.map((v) => {
      const c = toCell(v, this.#cellBytes);
      if (c.cut) this.cellsTruncated++;
      this.#bytes += c.bytes;
      return c.value;
    });
    this.rows.push(row);
    return true;
  }
}

export interface SchemaColumn {
  name: string;
  type: string;
  nullable: boolean;
  default: string | null;
  primaryKey: boolean;
}

export interface SchemaTable {
  name: string;
  kind: "table" | "view" | "materializedView" | "foreignTable" | "partitionedTable";
  /** Planner estimate (PostgreSQL reltuples; null when never analyzed, and for SQLite). */
  estimatedRows: number | null;
  columns: SchemaColumn[];
  indexes: Array<{ name: string; unique: boolean; primary: boolean; definition: string | null }>;
}

export interface SchemaResult {
  schemas: Array<{ name: string; tables: SchemaTable[] }>;
  /** More tables or columns than the caps below (the rest is left out). */
  truncated: boolean;
}

export const SCHEMA_CAPS = { tables: 2000, columns: 30_000, indexes: 10_000 } as const;

type Key = { schema: string; table: string };

/** Nests flat catalog rows (tables, columns, indexes) into schemas → tables. */
export function buildSchema(
  tables: Array<Key & Pick<SchemaTable, "kind" | "estimatedRows">>,
  columns: Array<Key & SchemaColumn>,
  indexes: Array<Key & SchemaTable["indexes"][number]>,
  truncated: boolean,
): SchemaResult {
  const k = (s: string, t: string) => JSON.stringify([s, t]);
  const byKey = new Map<string, SchemaTable>();
  const schemas = new Map<string, SchemaTable[]>();
  for (const t of tables) {
    const entry: SchemaTable = { name: t.table, kind: t.kind, estimatedRows: t.estimatedRows, columns: [], indexes: [] };
    byKey.set(k(t.schema, t.table), entry);
    if (!schemas.has(t.schema)) schemas.set(t.schema, []);
    schemas.get(t.schema)!.push(entry);
  }
  for (const { schema, table, ...c } of columns) byKey.get(k(schema, table))?.columns.push(c);
  for (const { schema, table, ...i } of indexes) byKey.get(k(schema, table))?.indexes.push(i);
  return { schemas: [...schemas].map(([name, list]) => ({ name, tables: list })), truncated };
}

export type ColumnKind = "number" | "datetime" | "boolean" | "text";

const NUMBER_TYPES = new Set(["int2", "int4", "int8", "float4", "float8", "numeric", "oid", "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "float", "double", "year"]);
const DATETIME_TYPES = new Set(["date", "timestamp", "timestamptz", "datetime"]);
const NUMERIC_TEXT = /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
const DATETIME_TEXT = /^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}(?::?\d{2})?)?)?$/;

/**
 * Column kinds for charts (saved query results): from the driver type when it is clear, else from the values (all
 * non-null numbers or numeric text → number, ISO-like dates → datetime, booleans → boolean). Numbers that came as
 * text (int8, numeric, decimal) stay text in `rows`; the kind tells the app to parse them.
 */
export function columnKinds(columns: RowsResult["columns"], rows: RowsResult["rows"]): ColumnKind[] {
  return columns.map((c, i) => {
    const t = (c.type ?? "").toLowerCase();
    if (NUMBER_TYPES.has(t)) return "number";
    if (DATETIME_TYPES.has(t)) return "datetime";
    if (t === "bool" || t === "boolean") return "boolean";
    const values = rows.map((r) => r[i]).filter((v) => v !== null && v !== undefined);
    if (!values.length) return "text";
    if (values.every((v) => typeof v === "number" || (typeof v === "string" && NUMERIC_TEXT.test(v)))) return "number";
    if (values.every((v) => typeof v === "boolean")) return "boolean";
    if (values.every((v) => typeof v === "string" && DATETIME_TEXT.test(v))) return "datetime";
    return "text";
  });
}
