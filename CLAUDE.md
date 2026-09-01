# CLAUDE.md — Database (all services)

Guidance for Claude Code when changing the database for **any** Fish Find service.
This folder holds the SQL Server schema (`mssql/`) and the MySQL variant (`mysql/`).
Everything below is about `mssql/` unless stated otherwise — see
[MySQL (`mysql/`)](#mysql-mysql) near the end of this file for the MySQL-specific workflow.

## ⚠️ READ THIS FIRST — non-negotiable

**Read this entire `CLAUDE.md` before touching anything in this repo.**

**Test-first for every bug fix — no exceptions:**
1. **Write a unit test that reproduces the bug FIRST** and run it — it must **FAIL** against the
   current code. That failing test is your proof the bug is real and understood.
2. **Only then apply the fix.**
3. **Write/keep unit test(s) that VERIFY the fix** — they must **PASS** after the change.

A bug fix that ships without a failing-then-passing test is incomplete. This applies to **every
service and every change** here — see [Writing unit tests](#writing-unit-tests-mssqlunit_testsreadmemd)
and [Structure unit tests](#structure-unit-tests) for how, and `mssql\UNIT_TESTS\autorun.bat` to run them.

## Golden rule: never edit the generated file

- **Make all schema changes in the `scriptNN_xxxxxx.sql` source files** under `mssql/`.
- **`mssql/ffi2.sql` is GENERATED — do not hand-edit it  (will be created after running: envfish-db\mssql\UNIT_TESTS\autorun.bat ).** It is rebuilt from the
  `scriptNN` files by `mssql/generate_db_script_ffi2.cmd` and is the image consumed by
  the database unit tests. Any manual edit to `ffi2.sql` is overwritten on the next build.
 
## Important
- The database is distributed, meaning there are several nodes connected through peer-to-peer replication
- In most cases, the primary key is a GUID v7.
- The business logic must take the distributed database schema into account.
- When create/modify existing function always mention what service/module/class/method calling it.
- No any direct call to database table. app can use ot view or function or procedure for insert/select/execute operations
- If you see code that use direct access to database table - use the rule from above.
- do not allow to have duplicated db objects - make a single reusable db objects


## How `ffi2.sql` is generated

`generate_db_script_ffi2.cmd` concatenates these source files **in this order** into
`ffi2.sql`:

1. `script0.sql`              — DB/header preamble
2. `script01_createTable.sql` — tables, PKs, constraints, indexes
3. `script01_createView.sql`  — views
4. `script02_Funct.sql`       — scalar / table-valued functions
5. `script02_Proc.sql`        — stored procedures
6. `script08_Data.sql`        — seed/reference data
7. `script09_fish_data.sql`   — fish seed data
8. `script10_Data_limit.sql`  — rate-limit / misc data
9. `script20_Migration.sql`   — used for data syncronization between database nodes

Because concatenation is **append-only and ordered**, put each object in the right file
and respect dependencies (a proc that uses a new table must come after that table — i.e.
table goes in `script01_createTable.sql`, proc in `script02_Proc.sql`).

**Files NOT in the generated image** (editing them does not affect `ffi2.sql` or the unit
tests): `script01_createView.sql` IS included, but `script07_createLakeRiver.sql`,
`scriptA100_fillForecast.sql`, `fisheditor.sql`, `lakeeditor.sql`, and the `*_dump.sql`
files are standalone and are **not** concatenated. Don't rely on them for test coverage.

### Where each kind of change goes
- New / altered **table, index, constraint** → `script01_createTable.sql`
- New / altered **view** → `script01_createView.sql`
- New / altered **function** → `script02_Funct.sql`
- New / altered **stored procedure** → `script02_Proc.sql`
- **Seed / reference data** → `script08_Data.sql` (or `script09_fish_data.sql` for fish)
- **Moving DATA between databases / one-off backfills against a live DB** → `script20_Migration.sql`


**DDL belongs in the schema scripts, not the migration script.** `script20_Migration.sql` is for
*data* migration between databases. Do NOT put `CREATE TABLE` / `ALTER TABLE` / `CREATE PROCEDURE`
there — the table goes in `script01_createTable.sql`, the procedure in `script02_Proc.sql`, etc.
Those schema scripts already produce the final shape, so a fresh build needs nothing from the
migration script. Any one-off backfill placed in `script20` is transient: once it has been run
against the target database, remove it (it is not a permanent record of the schema).

Procs/functions use the idempotent `IF EXISTS (... ) DROP ... GO  CREATE ...` pattern —
follow it so the script is re-runnable.

### Idempotency (which scripts are safe to re-run)
- **`script01_createView.sql`, `script02_Funct.sql`, `script02_Proc.sql` are idempotent — they can
  be run any number of times against an existing database without errors and without applying or
  adding anything new on each run.** Every object drops-then-recreates itself (`IF EXISTS … DROP …
  GO CREATE …`), so re-running just refreshes the definitions. When editing these scripts, keep that
  property: each view/function/procedure must guard its `CREATE` with a matching drop.
- By contrast, `script01_createTable.sql`, `script08_Data.sql` / `script09_fish_data.sql`, and
  `script10_Data_limit.sql` are **not** re-runnable as-is (they `CREATE TABLE` / `INSERT` without
  guards) — they are meant for building a fresh database, not for re-applying to a live one.

## OAuth / external logins (`UserExternalLogin`)

OAuth identities live in their own table, **not** in `Users`. `dbo.UserExternalLogin` holds one row
per `(provider, providerUserId)` and FKs to `Users.id`; `Users.authType` is `'Local'` or `'OAuth'`.

- **Adding a provider** = widen the `CH_UEL_provider` CHECK constraint in `script01_createTable.sql`
  (`provider IN ('Google','Twitter','LinkedIn','Outlook','GitHub','Email', …)`). Wired up so far: **Google, Twitter, LinkedIn, Outlook, GitHub, Email** (magic link — one-time tokens in `EmailLoginToken`, see `script01_createTable.sql`).
- **`dbo.spOAuthLoginOrCreateUser`** (in `script02_Proc.sql`) is the single entry point the web app
  calls for **every** provider — keep its signature stable so no C# change is needed. It looks up by
  `(provider, providerUserId)`, else links to an existing `Users.email`, else creates the user, then
  inserts the `UserExternalLogin` link row.
- **Emailless providers:** every `Users` row needs a unique email, but some providers don't expose one
  (the **Twitter/X OAuth2 API has no email scope**). The web caller passes a **synthetic**
  `twitter_<id>@users.fishfind.info` address. The proc sets `userName` to the provider's
  **display name** (`@givenName` + `@familyName`, or the @handle for X) for **every** provider,
  including Google, falling back to the email only when no name is supplied. A returning login
  also **self-heals** a `userName` still stored as the email (legacy Google rows) to the display
  name. (Until 2026-06-13 Google was special-cased to keep the email as `userName`.)
- Cover any new provider in `mssql/UNIT_TESTS/unit_test@OAuthLogin.sql`.

## Cached flags on `dbo.lake` (`isFish` / `noFish`)

`dbo.lake.isFish` is a **derived cache** of "this water body has ≥ 1 `lake_fish` row", not a fact anyone
edits. It exists because the map/browse filters (`fn_map_*`, `SearchLakeList` → `RscRiverList`) filter
~196k rows on it and cannot afford an `EXISTS` per row. Two rules keep it honest:

- **Only triggers on `lake_fish` may write it** — `TR_insLakes_Fish` (INSERT → `isFish = 1`) and
  `TR_delLakes_Fish` (DELETE → `isFish = 0` when no rows remain). Never set it from a proc or from app
  code. **If you add a path that bulk-loads or bulk-deletes `lake_fish`, make sure the triggers still
  fire** (`INSERT … SELECT` does; `BULK INSERT`/`bcp` does **not** unless `FIRE_TRIGGERS` is specified,
  and `TRUNCATE TABLE` never does) — otherwise the flag silently drifts again.
- **Anything correctness-critical must read fish presence live**, not from the flag. `fn_lake_edit`
  returns `is_fish` as `EXISTS(SELECT 1 FROM lake_fish …)` because `Editor/LakeEditor.aspx` uses it to
  enable/disable a control, and a stale flag there locks an editor out of the page. Use the flag for
  *filtering*, use `EXISTS` for *deciding*.

`noFish` is a **different** thing despite the similar name: it is a human claim ("an editor verified
there are no fish here"), set from the No Fish checkbox. Invariant: **a water body with any assigned
species must have `noFish = 0`** — `TR_insLakes_Fish` clears it in the same pass that raises `isFish`.
Deleting the last species deliberately does **not** set `noFish` back to 1; removing a species is not
evidence the water is fishless. Both flags are covered by `unit_test@lake.sql` TEST 24–26.

Because `isFish` had no DELETE trigger until 2026-07-29, legacy nodes may hold drifted rows. The
realigning backfill has been applied and **removed again** from `script20_Migration.sql` (it was
transient, per the rule above that one-off backfills do not stay in the repo). A fresh build needs
nothing: the triggers keep both flags correct from the first row. If a node is ever found drifted, this
re-derives both flags from `lake_fish` and is idempotent:

```sql
UPDATE l SET isFish = 0 FROM dbo.lake l
 WHERE ISNULL(l.isFish,0) <> 0 AND NOT EXISTS (SELECT 1 FROM dbo.lake_fish f WHERE f.lake_id = l.lake_id);
UPDATE l SET isFish = 1 FROM dbo.lake l
 WHERE ISNULL(l.isFish,0)  = 0 AND     EXISTS (SELECT 1 FROM dbo.lake_fish f WHERE f.lake_id = l.lake_id);
UPDATE l SET noFish = 0 FROM dbo.lake l
 WHERE ISNULL(l.noFish,0) <> 0 AND     EXISTS (SELECT 1 FROM dbo.lake_fish f WHERE f.lake_id = l.lake_id);
```

Drift check (all three counts must be 0):

```sql
WITH q AS (SELECT ISNULL(l.isFish,0) AS isFish, ISNULL(l.noFish,0) AS noFish,
  CASE WHEN EXISTS(SELECT 1 FROM dbo.lake_fish f WHERE f.lake_id=l.lake_id) THEN 1 ELSE 0 END AS hasRows
  FROM dbo.lake l)
SELECT SUM(CASE WHEN isFish=1 AND hasRows=0 THEN 1 ELSE 0 END) AS isFish1_noRows,
       SUM(CASE WHEN isFish=0 AND hasRows=1 THEN 1 ELSE 0 END) AS isFish0_hasRows,
       SUM(CASE WHEN noFish=1 AND hasRows=1 THEN 1 ELSE 0 END) AS noFish1_hasRows FROM q;
```

## Running the database unit tests

1. `cd mssql\UNIT_TESTS`
2. Run `autorun.bat`. It will:
   - regenerate `ffi2.sql` (via `generate_db_script_ffi2.cmd`),
   - create a fresh temp database from it (`dbcreator.cmd`),
   - run every `unit_test@*.sql` in the folder (`autorunlocal.bat` → `scriptrunlocal.bat`),
   - verify output with `averify.py`,
   - drop the temp database.
3. **Check `mssql\UNIT_TESTS\cleaned.txt` for errors.**

**Reading `cleaned.txt`:** a clean run contains only
(a) test-file name headers (`unit_test@Foo.sql`),
(b) `Unit tests for …` banner lines, and
(c) `TEST n PASS [..ms]: …` lines.
Anything else is a failure — look for `FAIL`, SQL `Msg ####, Level ## …`, RAISERROR text,
or stack/exception lines. `cleaned.txt` is filtered (PASSED/row-count/warning/dash/blank
lines are stripped), so noise is already removed; treat any unexpected line as a real error.

`averify.py` also computes `md5(cleaned.txt)` and compares it to `[mail].crcstate` in
`config.ini`; on a mismatch it emails the configured recipient. So after **intentionally**
adding or changing tests (which legitimately changes the output), the stored `crcstate`
must be updated — otherwise every run keeps reporting a diff.

### Prerequisites
- `SQLCMD.EXE` on PATH, a reachable SQL Server (`config.ini → server`, default `localhost`,
  Windows auth `-E`), and `python` (uses `configparser`, runs on Py3).
- Settings live in `mssql/UNIT_TESTS/config.ini` (`[app]` server/script/dbmaker, `[mail]`).
- **`NoDefaultCurrentDirectoryInExePath` must be unset.** These batch files `call` each other by
  bare name (`call autorun.bat` → `generate_db_script_ffi2.cmd` → `dbcreator.cmd` → `autorunlocal.bat`),
  which relies on cmd searching the current directory. Some shells (incl. the Claude Code harness)
  set `NoDefaultCurrentDirectoryInExePath=1`, which disables that and makes every call fail with
  `'xxx' is not recognized`. Clear it for the run, e.g. from PowerShell:
  `cmd /c "set NoDefaultCurrentDirectoryInExePath=&& pushd mssql\UNIT_TESTS && call autorun.bat"`.
- The FishImage test prints `[Nms]` timings, so `cleaned.txt` changes every run and `averify.py`
  emails on each run — that crc churn is expected and not an error.

## Writing unit tests (`mssql/UNIT_TESTS/readme.md`)
- Use **real tables — no stubs**; you may use a table as a value/fixture.
- A test must **not leave the database in a changed state** when it finishes (clean up).
- unit test must use real tables - no stubs,  for some results unit test can use table as  avalue. you cam use local service and ffi database for testing without asking permission.   
- unit test should not change state of database when finished - actual initialization and call the method must be inside transaction
- Normal success output is a **single line** per assertion, e.g.
  `TEST 5 PASS: fn_fish_image_handler returned correct image binary`.
- normal output for successed unmit test only one line like: TEST 5 PASS: fn_fish_image_handler returned correct image binary
- Add new tests for new schema objects, then re-run `autorun.bat` and confirm `cleaned.txt`.

## Structure unit tests
Each test is its own named transaction, isolated from every other test in the file (one
test's fixtures/failure can't affect another's) and rolled back at the end of its own
`GO` batch. See `mssql/UNIT_TESTS/unit_test@CatchMemo.sql` for a full worked example with
16 tests in this shape.
**Always write unit tests before any bug fix to confirm the bug (the test must FAIL first), then
write unit tests to verify the fix (they must PASS).** See the top-of-file "READ THIS FIRST" rule.
If length of unit test file exeed 100K then split to 2 logical parts.
If execution time if unit test file exeed 1 sec then split to 2 logical parts.

```sql
BEGIN TRAN TestSpecificCase
    declare @test_name sysname = N'TestSpecificCase [fn_SpecificCaseModule] : Specific Case'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rst sysname;   -- declared before TRY so it still exists (as NULL) if CATCH fires
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

insert into UsedTable (column1, column2) values (999, N'TestSpecificCase');

declare @column1 uniqueidentifier = (select column1 from UsedTable where column2 = N'SpecificCaseValue')

-- 2. execute unit test

declare @doc xml = dbo.fn_SpecificCaseModule( @column1 );
SET @rst = @doc.value('(/root/node/text())[1]','varchar(100)')

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @rst IS NULL OR @rst <> N'TestSpecificCase'
   RAISERROR ('TEST 1 FAIL [%dms]: result must have name TestSpecificCase', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: result has the expected name'

ROLLBACK TRAN TestSpecificCase
GO
```

- **Success message must say `PASS`, never `PASSED`.** `averify.py` strips any line
  containing the literal word `PASSED` out of `cleaned.txt` (see below) — a test that prints
  `PASSED ...` on success is invisible in the report even when it's running and passing.
  Use the `TEST n PASS [Nms]: ...` / `TEST n FAIL [Nms]: ...` wording shown above so every
  passed test actually shows up.
- Number tests sequentially within the file and match that number in the transaction name
  (`TestNN` or a short mnemonic), the `@test_name`, and the `PASS`/`FAIL` message.



## Secrets
- `mssql/UNIT_TESTS/config.ini` contains **live SMTP credentials** under `[mail]`.
  Do **not** copy those values into other files, commits, or logs.

## Typical change checklist
1. Edit the correct `scriptNN_xxxxxx.sql` source file(s) — never `ffi2.sql`.
2. Add/extend a `unit_test@*.sql` covering the change.
3. Run `mssql\UNIT_TESTS\autorun.bat`.
4. Open `mssql\UNIT_TESTS\cleaned.txt` and confirm no error lines (only headers/banners/PASS).
5. If output legitimately changed, update `[mail].crcstate` in `config.ini`.


## MySQL (`mysql/`)

Guidance below is specific to `mysql/` and does not override the `mssql/` sections above — SQL
Server via `mssql/` remains the primary database for the app. MySQL currently backs **one table**
(`news`, migrated 2026-08-31) read by `News.aspx` (`fishfind-frontend`, via `MySqlNewsHelper`) and
by three `docapi` read endpoints (`GET /api/v1/news/{id}`, `/news/list`, `/news/default`, via
`MySqlNewsDocumentRepository`/`MySqlNewsQueryRepository` — see `efj-backend/service/docapi/CLAUDE.md`
→ "MySQL backing for news reads"); everything else still runs on `mssql/`. Unlike `mssql/`, this
MySQL database is **not** distributed / peer-to-peer replicated — it is one flat remote schema
hosted on Winhost (`my06.winhost.com`).

### Golden rule: same schema-source discipline as `mssql/`

**All DDL changes go in versioned `scriptNN_xxxxxx.sql` source files under `mysql/` — never apply
DDL directly to the live database without a matching, up-to-date script in this repo.** Mirror
`mssql/`'s naming convention as new object types are needed:

- `script01_createTable.sql` — tables, PKs, indexes (exists today — currently just `news`)
- `script01_createView.sql` — views (exists today — `v_news_list_rows` + the `v_news_default_*`
  chain backing `script02_Proc.sql`'s read procedures; see "Testing MySQL procedures" below for why
  that logic lives in views rather than inline)
- `script02_Funct.sql` — functions (create when first needed)
- `script02_Proc.sql` — stored procedures. `sp_news_list_for_grid`, `sp_news_latest_id_with_photo`,
  `sp_news_get_by_id`, `sp_news_count` are called from `MySqlNewsHelper.cs` (nothing in that helper
  hits the `news` table directly any more). `sp_news_doc_get`, `sp_news_list_json`, `sp_news_default`
  are called from `docapi`'s `MySqlNewsDocumentRepository`/`MySqlNewsQueryRepository` (same rule —
  see `efj-backend/service/docapi/CLAUDE.md` → "MySQL backing for news reads" for the JSON shapes and
  the CA-padding/home-page-assembly logic each mirrors from `mssql/`).
- `script08_Data.sql` — seed/reference data (create when first needed)

`mysql/generate_db_script_ffi2.cmd` + `mysql/dbcreator.cmd` (wired together by `mysql/build.cmd
<host> <user> <database>`) concatenate the scriptNN files into `mysql/ffi2.sql` and apply it with
the `mysql` CLI, mirroring the mssql build. **When you add a new `scriptNN_*.sql`, add it to
`generate_db_script_ffi2.cmd`'s `copy` line too**, in dependency order — otherwise it is silently
missing from every fresh build and from the unit-test database. The scriptNN files remain the single
source of truth for what should be live; `ffi2.sql` is generated and deleted by `build.cmd`, same
golden rule as `mssql/ffi2.sql`.

### Test-first still applies — adapted for MySQL

The [test-first rule](#-read-this-first--non-negotiable) at the top of this file is not
SQL-Server-specific — apply the same discipline to MySQL. There **is** a `mysql/UNIT_TESTS` harness
now (`autorun.bat`, same shape as `mssql/`'s: generate `ffi2.sql` → build a throwaway database →
run every `unit_test@*.sql` → `averify.py` → `cleaned.txt`), so write the failing test there first,
exactly as in `mssql/`. Its `config.ini` points at a local MySQL server, has **no `[mail]` section**
and never emails — exit code + `cleaned.txt` is the whole contract.

### Structure MySQL unit tests — one procedure per test

**Every test must be its own `CREATE PROCEDURE`, with its own `EXIT HANDLER FOR SQLEXCEPTION`, its
own transaction, and a `ROLLBACK` at the end** — then a flat list of `CALL`s runs them, and a final
block of `DROP PROCEDURE`s leaves the database as `ffi2.sql` produced it. This is the MySQL
equivalent of the mssql per-test `BEGIN TRAN` + `TRY/CATCH` + `ROLLBACK TRAN` pattern (see
[Structure unit tests](#structure-unit-tests)), and it is **not optional**: the mysql CLI in batch
mode has no `TRY/CATCH`, so without a per-test handler **one unexpected SQL error aborts the entire
script and silently skips every test after it** — a whole file can go dark while still looking like
a short clean run. The per-test handler turns that into one `FAIL` line and lets the rest continue.
See `mysql/UNIT_TESTS/unit_test@NewsMySQL.sql` for a worked example with 18 tests in this shape.
The same `TEST n PASS:` / `TEST n FAIL:` wording and sequential numbering rules as `mssql/` apply.

### Testing MySQL procedures — put the query in a view

**MySQL cannot capture a stored procedure's result set from calling SQL** — `INSERT INTO t CALL
proc()` is a syntax error and there is no cursor-over-`CALL`, so a procedure that returns rows is
otherwise impossible to assert on from a plain `SELECT`-based test. Therefore: **put a read
procedure's query in a view (`script01_createView.sql`) and make the procedure a thin wrapper over
it**, so the test can assert against the exact same SQL the procedure runs.

Two constraints when doing this:
- **A view cannot take a parameter or read a session variable** (`ERROR 1351: View's SELECT contains
  a variable or parameter`). Genuinely parameterized logic must stay inline in the procedure — split
  it so the *unparameterized* row source is a view (e.g. `v_news_list_rows`) and only the
  caller-dependent predicates stay in the procedure (e.g. `sp_news_list_json`'s country filter and
  CA padding).
- **Views are not exempt from the BLOB-at-scale hazard** below — a view composing `UNION ALL` /
  `GROUP BY` / a window function / `LIMIT` is materialized by MySQL's TEMPTABLE algorithm, the same
  category of operation as an explicit temp table. Keep `news_photo0`/`1`/`2` out of them except in
  a final few-row join.

**JSON assertion gotchas** (verified on MySQL 8.0.46 — both silently produce a passing-but-meaningless
test if you get them wrong):
- `JSON_EXTRACT(doc,'$.x')` over an `IF(...)` yields a JSON **INTEGER** `1`/`0`, not a JSON boolean —
  compare to `1`/`0`; `= TRUE` matches nothing.
- A **JSON null is not a SQL NULL**: `JSON_EXTRACT(doc,'$.photo') IS NOT NULL` is TRUE even when the
  value is JSON `null`. Use `JSON_TYPE(...) = 'NULL'` / `<> 'NULL'`.

**Always confirm a regression test actually catches its bug**: re-introduce the old broken
definition, watch the test FAIL, then restore the fix and watch it PASS. Both 2026-08-31 news bugs
were verified this way (the lead-rank bug reproduces as `TEST 17 FAIL: expected exactly 2 leads, got
4`; dropping the `has_photo0` triggers fails tests 10/12/15).

When touching the **live** database rather than the test harness:

1. **Reproduce the bug with a query first** — confirm it fails against the current live schema.
2. **Only then apply the fix.**
3. **Re-run the same query** to confirm it now behaves correctly.
4. Prefer wrapping exploratory/verification queries in a transaction
   (`START TRANSACTION; ... ; ROLLBACK;`) so nothing is left changed on a shared database —
   `news` uses `InnoDB`, which supports this.

### Applying a script

- Real connection details (host, database, user, password) live **only** in the frontend app's
  gitignored `connectionStrings.config` / MySQL helper class — never hardcode real credentials
  into this repo's `.sql` files or into this `CLAUDE.md`.
- Apply with the `mysql` CLI: `mysql -h <host> -u <user> -p <database> < mysql\scriptNN_xxxxxx.sql`.
- **After any DDL change, update the matching `mysql/scriptNN_*.sql` to match exactly what was
  applied live.** This repo is the source of truth for the MySQL schema, so letting it drift from
  the live table is the same class of bug as `mssql/ffi2.sql` drift — just without a build step to
  catch it, so it is on you to keep them in sync by hand.
- Deploying a MySQL DDL/data change to the **production** Winhost database is still a production
  deploy — get the user's explicit permission first, same as any other prod change (see
  `fishfind-frontend/CLAUDE.md` → "Deployment policy").

### Drift reconciled 2026-08-31

`mysql/script01_createTable.sql` was verified against the live production Winhost table
(`DESCRIBE news;` / `SHOW CREATE TABLE news;`) and updated to match exactly. The
2026-08-31 SQL-Server-to-MySQL migration had left the script out of sync with what was actually
deployed:

- `news_id` / `lake_id` / `fish1_id` / `fish2_id` / `fish3_id`: script had `BINARY(16)` (via
  `UUID_TO_BIN(UUID())`) — live is `CHAR(36)` with no default (the app supplies the GUID string
  itself; see `MySqlNewsHelper.cs`'s string-based `Guid.TryParse` usage).
- `news_author`: script had `VARCHAR(128) NOT NULL` — live is `VARCHAR(500)`, nullable.
- `news_photo0` / `news_photo1` / `news_photo2`: script had `MEDIUMBLOB` (16MB cap) — live is
  `LONGBLOB` (4GB cap).
- `news_stamp` / `stamp` defaults: script had `DEFAULT (UTC_TIMESTAMP(6))` — live is
  `DEFAULT CURRENT_TIMESTAMP(6)` (server local time, not UTC — a real behavioral difference).
- `UNIQUE KEY` on `id`: script named it `uq_news_id_auto` — live has it auto-named `id`.
- Table-level charset/collation: live pins `DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`
  explicitly — the script didn't specify one before.

**Verify against the live shape again (`DESCRIBE news;` / `SHOW CREATE TABLE news;`) before
writing new MySQL DDL against `news`** — there is still no automated schema-diff check for
`mysql/`, so drift like this can reappear silently whenever the live table is changed by hand.

### ⚠️ `news_photo0`/`news_photo1`/`news_photo2` (LONGBLOB) are dangerous at scale on live Winhost

**Never reference a `news` photo BLOB column in any query whose execution plan must materialize
more than one row** — a temp table (`CREATE TEMPORARY TABLE` + `INSERT ... SELECT`), a window
function, or anything else that buffers multiple rows. Confirmed live 2026-08-31: a bare
`news_photo0 IS NOT NULL` (no `LENGTH()`, no base64) in such a query hangs indefinitely on the live
Winhost host — reproduced identically across an `INSERT INTO temp_table SELECT` rewrite, a
temp-table-free window-function rewrite, and a plain multi-row `UPDATE ... WHERE news_photo0 IS
NOT NULL` (even with a `LIMIT`, once matching rows become sparse enough that the scan has to check
many candidates). Isolated via `SHOW FULL PROCESSLIST` to the exact statement (`State: executing`,
not a lock wait), so it's a genuine execution-time pathology on this host, not contention. **A
single-row lookup by primary key is unaffected** — `sp_news_doc_get` and `sp_news_default`'s final
per-item join read `news_photo0` directly and are fast, because they only ever touch one row.

### Cached flags on `news` (`has_photo0`)

`news.has_photo0` is a **derived cache** of `news_photo0 IS NOT NULL`, added 2026-08-31 for exactly
the reason above — the list/home-page queries need to know "does this row have a photo" across
*every* row, and touching the real column at that scale hangs. Same pattern as
[`dbo.lake.isFish`](#cached-flags-on-dbolake-isfish--nofish) (MSSQL), adapted for MySQL:

- **Only two `BEFORE INSERT`/`BEFORE UPDATE` triggers on `news` itself may write it**
  (`TR_news_has_photo0_ins`/`TR_news_has_photo0_upd`, `script01_createTable.sql`) — each sets
  `NEW.has_photo0` from `NEW.news_photo0` for the one row being written, the proven-safe single-row
  case. Never set it from a proc or app code.
- Added via `ALGORITHM=INSTANT` (MySQL 8.0.12+, InnoDB) — metadata-only, no table rebuild, no
  per-row blob read during the `ALTER` itself. Deliberately **not** a
  `GENERATED ALWAYS AS (news_photo0 IS NOT NULL) STORED` column: a stored generated column forces
  `ALGORITHM=COPY` (a full table rebuild reading every row's blob) for the `ALTER`, and a `VIRTUAL`
  one is computed at read time — still touching the blob per row on every list query, defeating the
  point.
- **Backfilling or re-deriving this at scale must go row-by-row by primary key**, never via a bulk
  `UPDATE ... WHERE news_photo0 IS NOT NULL` (see the warning above — confirmed to hang once the
  match set is large/sparse). The one-time 2026-08-31 backfill used a transient cursor-based
  procedure that iterated by `id` range (not by the flag, which never changes for a genuinely
  photo-less row and would loop forever re-selecting it) and issued one single-row
  `UPDATE news SET has_photo0 = (news_photo0 IS NOT NULL) WHERE news_id = ...` per row; it was
  dropped from both databases once the backfill was confirmed complete (transient tooling doesn't
  stay in the repo, same rule as `script20_Migration.sql` one-off backfills).
- `sp_news_list_json` and `sp_news_default`'s group-selection queries (`envfish-db/mysql/script02_Proc.sql`)
  read `has_photo0`, never `news_photo0`, for anything that scans more than one row.

## Changelog

Moved to [`CHANGELOG.md`](./CHANGELOG.md) (same directory) for readability.
Newest entries first there.
