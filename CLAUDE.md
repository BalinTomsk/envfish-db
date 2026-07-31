# CLAUDE.md — Database (all services)

Guidance for Claude Code when changing the database for **any** Fish Find service.
This folder holds the SQL Server schema (`mssql/`) and the MySQL variant (`mysql/`).
Everything below is about `mssql/` unless stated otherwise.

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

## Changelog

- 2026-07-31: **`dbo.sp_news_import(@json)` — create a news article from an `fn_news_json` interchange
  document** (`script02_Proc.sql`; idempotent `IF EXISTS(... type='P') DROP … GO CREATE`). Shreds the
  exact JSON shape `dbo.fn_news_json` emits (title, author, author/source links, source, video link,
  the 3 paragraphs, country, date, `lakeId`, `fish1/2/3Id`, and 3 base64 photos + author/alt) with
  `OPENJSON`, decodes the base64 photos back to `varbinary` via `xs:base64Binary`, resolves
  `lake_id`/`fish1..3` with `TRY_CONVERT` (bad text → null, never fails the insert), inserts the article
  **published** (`news_publish = 1`; absent date → now), and returns the new `news_id`. `news_title` is
  UNIQUE, so importing an existing title raises the duplicate-key error. Called by docapi
  (`JdbcNewsQueryRepository.importNews`, `POST /api/v1/news/import`); the matching export reuses the
  existing `dbo.fn_news_json`. `unit_test@NewsImport.sql` — 4 tests, each its own transaction (full doc
  mapped/published; base64 photo → original bytes; **fn_news_json export → sp_news_import round-trip**;
  minimal doc + defaults). All pass via `autorun.bat`. **Not yet applied to prod.**
- 2026-07-30: **`dbo.fn_news_json(@news_id)` — export a news article as one self-contained JSON
  object** (`script02_Funct.sql`; scalar, idempotent `IF EXISTS(...xtype='FN') DROP…GO CREATE`).
  Returns, via `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES`, every field needed to
  re-create the article on `~/Editor/AddNews.aspx`: title, author, author/source links, source, video
  link, the 3 paragraphs, country, date (yyyy-mm-dd, `CONVERT(...,23)`), `lake_id` + `fish1/2/3` GUIDs,
  and the **3 paragraph photos EMBEDDED as base64** — `FOR JSON` auto-encodes the `news_photo0/1/2`
  `varbinary` columns — with each photo's author/alt. NULLs are kept so the shape is stable; returns
  NULL for an unknown id. Same embed-as-base64 technique as `fn_default_latest_catch_json`, so the
  export is self-contained (no `HandlerImage.ashx` round trip). Called by `News.aspx.cs` (admin-only
  "Save JSON" link) and consumed by `AddNews.aspx` "Import from JSON". `unit_test@NewsJson.sql` — 4
  tests, each its own transaction (core fields; lake/fish GUIDs + null shape; base64 photo decodes back
  to the original bytes; unknown id → NULL). **Applied to prod 2026-07-30** (SqlClient txn +
  smoke-tested on the live Tyee article, 465 KB JSON with the base64 photo). Frontend side documented in
  `fishfind-frontend` `aspnet/Editor/CLAUDE.md` (2026-07-31 entry).
- 2026-07-30: **`dbo.fn_fish_image_gallery(@fish_id)` — list a fish's images for the editor gallery**
  (`script02_Funct.sql`; inline TVF, idempotent `IF EXISTS(...xtype='IF') DROP…GO CREATE`). Returns
  `(fish_image_id, fish_image_gender, fish_image_juvenile)` for every image of the fish; the caller
  orders by `fish_image_id DESC`. Created to replace a direct `SELECT … FROM dbo.fish_image` query in
  `FishTracker.Editor.FishGeneral.BuildFishGallery` (`~/Editor/FishGeneral.aspx.cs`) so app code goes
  through a function, not a raw table (per the "no direct table access" rule above).
  `unit_test@FishImageGallery.sql` — 3 tests, each its own transaction (all images with correct
  gender/juvenile flags; fish with no images → empty; only the requested fish's images, no cross-fish
  leak). **Applied to prod 2026-07-30** (SqlClient txn + verified against a real fish, 6 rows).
- 2026-07-30: **`unit_test@FishViewNews.sql` — coverage for the existing `dbo.fn_fish_view_news`**
  (no schema change). 4 tests, each isolated in its own `BEGIN TRAN…ROLLBACK TRAN…GO` block with its
  own fixture (slot-1 news returned with title/source; slots 2 & 3 also matched; unpublished excluded
  and unrelated fish empty; capped at 10 rows, newest by `news_stamp` kept). All pass via `autorun.bat`.
