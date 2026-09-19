# Meadow group: data layer, schema, and migrations

This folder holds the data-access stack: Stricture (schema DDL + compiler),
Meadow (ORM + query), the `meadow-connection-*` database connectors,
meadow-endpoints (auto-CRUD), and `meadow-migrationmanager`. The one thing to
get right every time you touch a Retold app's schema is the migration workflow
below. Read this before editing any `*.ddl` or adding a column.

## The golden rules

1. **The DDL is the single source of truth.** `data_model/<App>.ddl` (Stricture
   MicroDDL) describes every table and column. Everything else under
   `data_model/compiled/` is generated from it and is committed (the runtime
   loads `<App>-Extended.json` without needing `stricture` installed at deploy).
2. **Postgres everywhere. No SQLite escape hatch.** Run dev on dockerized
   Postgres, not `--sqlite`. Running SQLite locally while deploying to Postgres
   ships bugs that pass on every dev machine and break on deploy (Decimal maps to
   SQLite REAL vs Postgres DECIMAL; `Numeric` is 64-bit in SQLite but INT32 in
   Postgres; etc.). Plansheet deleted its SQLite path for exactly this and its
   server refuses to boot rather than fall back. Match dev to prod.
3. **Never hand-roll ordered SQL, `ALTER TABLE` hedges, or a homegrown migration
   runner.** If you find yourself adding `ALTER TABLE ... ADD COLUMN` statements
   to app code (the "stable-prod hedge" anti-pattern), stop: that is what the
   tools below exist to replace.

## The layers (how schema reaches a database)

```
<App>.ddl  --npm run schema:compile-->  compiled/<App>-Extended.json
                                          |
   fresh DB:   createTables (CREATE TABLE IF NOT EXISTS) at server boot
   populated:  bin/migrate-schema-sync-pg.js  (additive ADD COLUMN IF NOT EXISTS)
   destructive: meadow-migrationmanager (diff two DDLs -> delta SQL, by hand)
   deploy:     pdt/rdt db:sync = pg_dump backup -> migrate-schema-sync-pg -> verify
```

- **`createTables`** (in the app server's schema step, and in `meadow-connection-*`)
  issues `CREATE TABLE IF NOT EXISTS` for every model table. It builds a fresh DB
  completely, and it NEVER alters an existing table. So a new table reaches a live
  DB on the next boot; a new **column** on an existing table does not.
- **`bin/migrate-schema-sync-pg.js`** is the additive column applier. Each app has
  its own copy (see plansheet's as the template). It reads the compiled
  `-Extended.json`, introspects `information_schema.columns` on the live DB, and
  issues `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for any missing model column.
  Additive only (never drops or retypes), idempotent, safe on prod data. NOT-NULL
  columns get a DEFAULT so the ALTER backfills existing rows. `--report` shows
  what it would add and changes nothing. It is columns only, not indexes/tables.
- **`meadow-migrationmanager`** (the `meadow-migration` CLI) is the by-hand tool
  for the changes the additive sync cannot express: rename, drop, retype. It
  compiles two DDL versions, diffs them, and generates delta SQL. Use the `diff`
  output as the authority for WHAT changed. Quirks of the installed version:
  - The CLI reads all positional args as ONE string, so quote them:
    `meadow-migration add-schema "prev /tmp/prev.ddl"` (unquoted reports
    "both arguments are required").
  - `generate-script` ignores `-t/-o`; it prints MySQL to stdout. Translate to
    Postgres by hand (backticks -> double quotes) and redirect yourself.
  - It emits `ADD CONSTRAINT ... FOREIGN KEY` for a new FK column, but
    `createTables` creates no FKs on these schemas; add the column only, or a
    migrated DB differs from a freshly built one.
  Run migrations deliberately against the target; nothing is auto-applied at boot.
- **`pdt` / `rdt` (`plansheet-deploy-tool` / `retold-deploy-tool`) `db:sync`
  (alias `db:migrate`)** orchestrates deploy-time: `pg_dump | gzip` backup, then
  runs `migrate-schema-sync-pg.js` inside a throwaway app container, then verifies
  a known column exists. `rdt deploy` lifts its execution from plansheet-deploy-tool.

## The common case: add a column or table

```bash
# 1. Edit the DDL (the source of truth)
$EDITOR data_model/<App>.ddl

# 2. Regenerate the compiled model the runtime loads
npm run schema:compile

# 3. Verify on a fresh Postgres DB (createTables builds the full schema)
#    (dev-serve / dev:clean drops + recreates the dev DB fresh)

# 4. Commit the DDL and the regenerated compiled/ together as one change.
```

A fresh DB is done after step 3. A **populated** DB gets:
- a new **table** from `createTables` on the next boot;
- a new **column** from `bin/migrate-schema-sync-pg.js` (which `pdt db:sync` runs
  on deploy; run it by hand with `--report` first against any DB the deploy tool
  is not driving).

Verify against the target, not the log: a green line is not proof. Check
`information_schema.columns` for a column, `pg_tables` for a table.

## MicroDDL type cheat sheet (Stricture token -> Meadow DataType -> SQL)

```
!Table              declare table            >desc  table comment
@IDName             ID        SERIAL/INTEGER PK AUTOINCREMENT
%GUIDName 36        GUID      VARCHAR(size)
$StringCol 128      String    VARCHAR(size)
*TextCol            Text      TEXT
#NumericCol         Numeric   INTEGER   (Postgres INT32 -- overflows > 2.1 GB / 2^31!)
.DecimalCol 20,0    Decimal   DECIMAL(20,0) on PG (exact 64-bit+), REAL on SQLite
&DateCol            DateTime  TIMESTAMP
^BoolCol            Boolean   SMALLINT (meadow stores booleans as SMALLINT)
{JSONCol            JSON      TEXT/LONGTEXT
#IDFK -> IDOther    ForeignKey INTEGER + reference
```

Note the `#Numeric` trap: it is a 32-bit INT on Postgres/MySQL, so it overflows
above ~2.1 GB. For a byte count or any value that can exceed 2^31, use
`.Decimal N,0` (e.g. sluice's `StoredFile.SizeBytes` is `.SizeBytes 20,0` because
a real stored file is 5.4 GB). SQLite maps Decimal to REAL, exact for values
under 2^53 (~9 PB), so file sizes round-trip fine; on Postgres it is exact.

Meadow recognizes these audit column names specially: `CreateDate`, `UpdateDate`,
`DeleteDate`, `CreatingIDUser`, `UpdatingIDUser`, `DeletingIDUser`, `Deleted`.

Full reference: https://github.com/stevenvelozo/stricture

## Indexes

`createTables` (via each connector's `getIndexDefinitionsFromSchema`) auto-creates
indexes for GUID columns (unique) and ForeignKey columns, plus any column marked
`Indexed: true` / `Indexed: 'unique'` in the model. Declare hot-path indexes in
the DDL so a fresh DB gets them. The additive column sync does NOT add indexes to
a populated DB; add those deliberately (a one-time `CREATE INDEX IF NOT EXISTS`,
or via meadow-migrationmanager) when evolving a live database.

## The base already provides this

Retold apps extend `retold-application-foundation-server` (its main class file is
`Retold-Application-Server.js` -- this is the "retold-application-server" base).
It gives you `provisionDatabaseSchema`/`createTables` from the compiled model,
multi-customer tenancy (`Retold-Tenancy`), auth, blob storage, and
meadow-endpoints auto-CRUD. Lean on it; do not reimplement schema provisioning,
tenancy, or CRUD in an app.
