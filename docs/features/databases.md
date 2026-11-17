# Database console

Browse, query and carefully change your databases from the phone without giving the phone any database password.
The agent holds the credentials, finds database containers for you, shows the schema, previews tables, runs
**read-only** queries with strict limits, keeps saved queries with chart hints, exports CSV, and has a **write mode**
that always shows how many rows a statement would change before you confirm it.

Engines: PostgreSQL, MySQL/MariaDB and SQLite (SQLite is read-only). Phases: D-1 connections, discovery, schema,
preview, read-only queries; D-2 saved queries, charts, CSV export, MySQL/MariaDB; D-3 write mode; D-4 backup restore tests.

API reference: [../agent/api.md#databases](../agent/api.md#databases). Configuration: feature flag `databases`
(default off) and the [`databases`](../agent/configuration.md#databases) section.

## Setup

1. Turn on `databases` and restart the agent.
2. In the app, open **Discover**: the agent lists running containers whose image is a database (postgres, postgis,
   timescaledb, mysql, percona, mariadb, redis) with the version tag, networks, ports and the **names** of their
   environment variables. Values are never shown. Redis is listed but not supported.
3. Add a connection: pick the container (or enter a host/port, or a SQLite file path), a read credential and,
   optionally, a separate write credential.
4. **Test** it: you get the server version (and for MySQL whether it is MySQL or MariaDB), the user, whether it is a
   superuser (MySQL: has `SUPER` or `FILE`) and whether the session is read-only.

## Credentials

- **A read-only role (recommended).** The agent can write the SQL for you: **Read-only role** on a connection calls
  `GET /v1/db/connections/:id/readonly-role-sql` and returns the statements with a fresh random password. On
  PostgreSQL (14+) it is one statement you can review and run through the write mode:

  ```sql
  CREATE ROLE "tiphys_ro" LOGIN PASSWORD '…' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    CONNECTION LIMIT 5 IN ROLE pg_read_all_data;
  ```

  On MySQL/MariaDB the account statements (`CREATE USER`, `GRANT SELECT, SHOW VIEW ON <db>.*`) commit implicitly, so
  the write mode can't preview them: run them with the `mysql`/`mariadb` client. Then store the new user and password
  as the connection's read credential.
- **A write credential (optional).** The write mode uses `writeCredential` when set, otherwise the read credential
  (and says so: `readCredentialUsed`). A read-only role as read credential plus an application role as write
  credential is the safest split.
- **From the container's environment** (`fromContainerEnv`). The agent reads the image's variables with
  `docker inspect` each time it connects and stores nothing: `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`, or for
  MySQL/MariaDB root with `MARIADB_ROOT_PASSWORD`/`MYSQL_ROOT_PASSWORD` (else `*_USER` + `*_PASSWORD`) and
  `*_DATABASE`. That user is normally a superuser, so the connection is marked with a warning: only the
  transaction-level protections below apply. `*_PASSWORD_FILE` secrets and random root passwords can't be read.

Passwords live only in the agent's `agent.json` (mode `0600`). The API never returns them (`hasPassword` only); an
edit without a password keeps the stored one, unless the target changes (then a password must be entered again so an
old password is never sent to a new address). Driver error messages are passed through the agent's redaction before
they reach the phone, and requests are never logged.

## Read-only, in layers

Every query is checked by the agent and then constrained by the database:

1. **One statement, a read kind.** The agent splits the text with a lexer that knows the dialect (PostgreSQL dollar
   quotes and nested comments; MySQL backslash escapes, `#` and `-- ` comments, backtick names; SQLite `[…]` names)
   and accepts a single statement starting with `SELECT`, `WITH`, `VALUES`, `TABLE`, `EXPLAIN`, `SHOW` (MySQL also
   `DESCRIBE`). `INSERT`, `UPDATE`, `DELETE`, `MERGE`/`REPLACE` are passed on so the database refuses them. Everything
   else (`COPY`, `DO`, `CALL`, `LOAD`, `LOAD DATA`, `SET`, `HANDLER`, DDL, `ATTACH`, `VACUUM INTO`, `PRAGMA` …) is
   refused. This matters for privileged users: a read-only transaction does not stop `COPY … TO PROGRAM` (verified)
   or MySQL `SELECT … INTO OUTFILE`.
2. **Refused names.** Anywhere in a statement (also in the write mode): MySQL `INTO` in reads, `OUTFILE`,
   `DUMPFILE`, `LOAD_FILE`, executable comments and optimizer hints (`/*! … */`, `/*M! … */`, `/*+ … */` — the server
   runs or applies them, e.g. `SET_VAR(max_execution_time=0)`); PostgreSQL functions that read or write server files,
   run programs or other connections, run SQL text or administer the server (`pg_read_file`, `pg_ls_dir`, `lo_import`,
   `lo_export`, `dblink…`, `query_to_xml`, `pg_terminate_backend`, `pg_reload_conf` …), quoted or not. This list is
   defence in depth: it can't know user-defined functions, which is why a dedicated role is recommended.
3. **Server settings the lexer relies on are pinned.** PostgreSQL sessions get `standard_conforming_strings=on`;
   MySQL sessions drop `NO_BACKSLASH_ESCAPES`, `ANSI_QUOTES` and `ANSI` from `sql_mode`. So the agent and the server
   read quotes the same way.
4. **PostgreSQL session and transaction.** `default_transaction_read_only=on`, each request in `BEGIN READ ONLY` with
   a `SET LOCAL statement_timeout`, the statement through a cursor (extended protocol: the server itself refuses a
   second statement), and always `ROLLBACK`.
5. **MySQL/MariaDB session and transaction.** No multi statements and no `LOAD DATA LOCAL` (client flags removed),
   `SET SESSION TRANSACTION READ ONLY` + `START TRANSACTION READ ONLY`, the statement as a server-side prepared
   statement (one statement, real parameters), a timeout (MariaDB `max_statement_time` for every statement; MySQL
   `MAX_EXECUTION_TIME` for SELECT), always rolled back. Past the timeout the agent drops the connection and sends
   `KILL QUERY`.
6. **SQLite.** The file is opened read-only with `query_only` in a separate process (killed at the timeout), with an
   authorizer that refuses `ATTACH`/`DETACH` and pragmas other than the catalog ones. The path must be inside
   `allowedRoots`.

## Saved queries and charts

Save a query under a connection with a name, parameters and a chart hint: `table`, `stat` (one number), `line` or
`bar` with an `x` column and up to 8 `y` columns. The SQL must pass the read allowlist when saved, and it only ever
runs through the read-only path. Running it returns the usual result plus each column's `kind` (`number`,
`datetime`, `boolean`, `text`) so the app can draw it; numbers that arrive as text (`int8`, `numeric`, `DECIMAL`) are
marked `number`. Saved queries live in `db-queries.json` next to `agent.json` (mode `0600`, at most 500).

## CSV export

Any read query or saved query can be exported as CSV (UTF-8 with BOM, header row, CRLF, RFC 4180 quoting). Text that
starts with `=`, `+`, `-`, `@`, a tab or CR gets a leading `'`, so a spreadsheet shows it as text instead of running
it as a formula; plain numbers such as `-12.5` stay as they are. Limits: 100 000 rows, 50 MB, 5 minutes; past a limit
the file just ends (the row count and a `truncated` flag come as HTTP trailers and in the audit log). 3 exports per
minute per device.

## Write mode

PostgreSQL and MySQL/MariaDB (not SQLite). Two steps, always:

1. **Preview.** The agent checks the statement against the write allowlist, then runs it with the write credential in
   a transaction and **rolls it back**. You get the number of affected rows and, for PostgreSQL `INSERT`/`UPDATE`/
   `DELETE`, up to 20 of the affected rows (as they would be after the change, through `RETURNING *`). Nothing is
   changed. You also get a preview token (120 s, this device only, single use) bound to the connection, the SQL and
   the row count.
2. **Commit** with the token and an explicit confirmation. The agent runs the same SQL again in a transaction. If it
   now affects a different number of rows (someone changed the data in between), it rolls back and answers
   `409 agent.db.countChanged` with both counts; otherwise it commits.

What the write mode accepts:

- **PostgreSQL:** `INSERT`, `UPDATE`, `DELETE`, `MERGE` (also after `WITH`); `CREATE`/`ALTER`/`DROP` of tables,
  indexes and (materialized) views — DDL runs inside the transaction too, so its preview leaves nothing behind; and
  `CREATE ROLE`/`CREATE USER` with only harmless attributes (for the read-only role). Never: `COPY` (to/from a program
  or file), `DO`, `CALL`, `SET`, `ALTER SYSTEM`, `ALTER ROLE`, `GRANT`/`REVOKE`, `TRUNCATE`, functions, procedures,
  triggers and extensions (no function definitions in any language — trusted or untrusted — since a function body is
  code the agent can't inspect), and the refused functions above. Statement and lock timeouts apply.
- **MySQL/MariaDB:** `INSERT`, `UPDATE`, `DELETE`, `REPLACE` (also after `WITH`). DDL and account statements commit
  implicitly in MySQL, so they can't be previewed and are refused (`agent.db.ddlNotPreviewable`). If any user table
  uses a non-transactional engine (MyISAM, Aria, MEMORY …) the write mode refuses altogether
  (`agent.db.nonTransactionalTables`): a preview on such a table could not be rolled back. The count is the number of
  matched rows.
- Always one statement.

Limits: 10 commits per 10 minutes per device (checked before the token is used, so a refused commit can be retried
with the same token while it is valid); previews count toward the 30 queries per minute.

Every commit attempt that ran is written to `db-writes.jsonl` next to `agent.json` (mode `0600`, kept as
`db-writes.jsonl.1` past 5 MB) **before** the COMMIT: time, device, connection, engine, the full SQL (a password
literal in `CREATE ROLE`/`CREATE USER` is masked), its hash, the row count and the outcome (`committed`,
`countChanged`, or `commitFailed` if the COMMIT itself failed). No result values. If the log can't be written the
transaction is rolled back.

## Limits

| Limit | Value |
| --- | --- |
| Rows | 500 by default, at most 5000 (`truncated: true` when there were more) |
| Cell | 4 KB of text (longer text ends in `…`); binary values show as `<n bayt>` |
| Result | 8 MB of cell data |
| Timeout | 15 s by default, at most 60 s (also for write previews and commits) |
| Concurrency | 2 calls at once per connection |
| Rate | 30 queries, previews, saved query runs and write previews per minute per device |
| CSV export | 100 000 rows, 50 MB, 5 min; 3 per minute per device |
| Writes | 10 commits per 10 minutes per device; preview token 120 s, single use |

## Schema and preview

The schema browser lists schemas (MySQL: databases), tables and views with columns (type, nullability, default,
primary key), indexes and the row estimate (PostgreSQL planner, MySQL `TABLE_ROWS`; SQLite has none). A table preview
only works for a table the catalog lists; the agent builds the query from the catalog's own names and quotes them
(`"…"`, MySQL `` `…` ``), so a crafted name can't inject SQL.

## Audit

Connection changes and tests are recorded with the connection id. Queries, saved query runs and exports are recorded
as `{conn, sqlSha256, rows}`; write previews as `{conn, sqlSha256, rows, preview: true}` and commits as
`{conn, sqlSha256, rows, write: true}`. Neither the SQL text nor any result value is written to the audit log; the
full SQL of writes is only in `db-writes.jsonl`.

## Backup restore tests

A backup you never restored is a hope. A restore test takes the **newest** dump matching a glob (for example
`~/backups/app/*.sql.gz`), restores it into a throwaway container and checks that it really contains data.

1. Free space is checked (at least twice the dump size).
2. `docker run -d --rm --network none --memory 1g --tmpfs <data dir> -e <random password> --name tiphys-restore-<id>-<rand> <image>`:
   no network, memory capped, data in RAM, nothing touches your real databases. The image must be an official
   `postgres:`, `mysql:` or `mariadb:` image with an explicit tag, and the **same major version** as the source (checked
   against the connection's container when `connectionId` is set).
3. The agent waits for the final server (`pg_isready` / `mysqladmin ping` over loopback).
4. The dump is streamed into `psql`, `pg_restore` (format `custom`) or `mysql` through `docker exec -i` (format `gz`
   is gunzipped by the agent). An error stops the restore.
5. Each sanity query (one number, e.g. `SELECT count(*) FROM users`, compared with `>`, `=`, `>=`, `<`, `<=`) runs in a
   read-only session.
6. The container is always removed (also on timeout and when the agent stops). Limit: 30 minutes, one test at a time.

Results (last 20 per test, with durations and failures) are stored on the agent. `db.restoreTest.ok` /
`db.restoreTest.failed` notifications go out for every run. Tests can run on a schedule (daily, weekly or every N
minutes) or manually. PostgreSQL dumps restore into the `postgres` database, so sanity queries see tables of a plain
`pg_dump`; a `pg_dumpall` file that connects to other databases is not supported. Dumps must be inside `allowedRoots`
or the directory of a `backups` file check.

## Requirements

- PostgreSQL: nothing extra (`pg` and `pg-cursor` are loaded only when the feature is on).
- MySQL/MariaDB: nothing extra (`mysql2` is loaded only when the feature is on). The write mode needs transactional
  tables (InnoDB).
- SQLite: Node.js with `node:sqlite` available without flags (22.13 or newer). On older Node the SQLite engine is
  reported as unavailable (`engines.sqlite: false`) and its calls fail with `agent.db.sqliteUnavailable`.
- Container targets: the agent must reach the container's IP (a Linux host can reach bridge-network IPs directly).
