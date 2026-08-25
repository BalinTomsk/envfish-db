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

- 2026-08-25: **New `dbo.sp_lake_fish_upsert_batch(@lake_id, @fish)` — batch upsert of assigned
  species.** (`script02_Proc.sql`.) The write counterpart of `dbo.fn_lake_fishing_json`, backing the
  new docapi `PATCH /api/v1/river/fish/{guid}` (`JdbcRiverFishCommandRepository`). `@fish` is a JSON
  array (`[{"fishId","link","trustLevel","year","status"}, …]`) mirroring the fields the "Add" form on
  `Editor/EditLakeFish.aspx` writes (`AddFishToLake`: `link`, `probability`/`probability_source_type`
  from `trustLevel` 0-4, `last_catch` year-only, `status` conservation bitmask). Loops the batch with a
  local cursor (small per-lake batches, clarity over set-based JSON tricks) and, per fish, picks one of
  five actions: **`inserted`** (not yet assigned to this lake), **`updated`** (assigned but its `link`
  is empty/NULL — the only case an existing row is touched), **`skipped`** (assigned **with** a
  non-empty `link` — deliberately left alone so this batch endpoint can never silently clobber
  already-sourced data), **`unknown_fish`** (well-formed guid, not in `dbo.fish`), **`invalid_fish_id`**
  (missing/not a guid at all). Returns one result per input item, in order,
  `[{"fishId","fishName","action"}, …]`; unknown `@lake_id` ⇒ `NULL` (same not-found contract as
  `fn_lake_fishing_json`/`fn_lake_view_json`). Plain single-row `INSERT`s (not `BULK INSERT`), so
  `TR_insLakes_Fish` fires normally and `lake.isFish` stays correct without any extra handling. New
  object — no signature change to anything existing. `unit_test@LakeFishUpsertBatch.sql` (8 tests:
  insert, fill-empty-link, skip-sourced-fish, unknown fish, invalid fish id, unknown lake, mixed batch
  order, isFish trigger) passes via `autorun.bat` (full suite 505 PASS / 2 pre-existing FAIL, both in
  `unit_test@FishCodeLatinJson.sql`, unrelated). **Built and tested locally; not yet applied to prod.**

- 2026-08-24: **New `dbo.fn_river_unfished_json(@country, @state, @river)` — next un-processed water
  body as JSON.** (`script02_Funct.sql`.) A scalar function returning the next water body of a type in a
  state with no fish assigned (`isFish = 0`) and not flagged No Fish (`noFish = 0`):
  `TOP 1 … FROM dbo.vw_lake WHERE @state IN (source_state, mouth_state) AND locType = @river … ORDER BY
  lake_name`, plus `throwing` = `STRING_AGG(CGNDB, ',')` of the `dbo.Tributaries side = 2` ("Throw")
  rows joined to `dbo.Lake`, all wrapped with `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES`.
  `@country` is echoed only (the query filters by state). **Duplicates the frontend
  `Resources/wbUnFish.aspx` query for the docapi `RiverController` / `JdbcRiverQueryRepository`**
  (`GET /api/v1/river/unfished`). New object — no signature change to anything existing, no deploy-order
  dependency. `unit_test@RiverUnfished.sql` (4 tests: found + throwing, found + empty throwing,
  isFish=1 skipped, noFish=1 skipped) passes via `autorun.bat` (full suite 497 PASS / 5 pre-existing
  FAIL, none river). **Applied to prod 2026-08-24** via `sqlcmd` (verified `CA/NL/2` → "Adies River").
- 2026-08-24: **New `dbo.fn_map_fish_list_nearest_station` — sport species (length > 10 cm) at the
  single closest `WaterStation`.** (`script02_Funct.sql`.) Registered (non-trial)
  `Forecast/Planning.aspx` visitors see up to 10 extra locally-caught species appended after their
  region's top-15 (`AppendNearestStationSpecies` in `Planning.aspx.cs`), deduplicated against what
  the top-15 already offered. "Closest" is the nearest station by squared lat/lon distance — a
  planar approximation, adequate at map scale — found via a `TOP 1 … ORDER BY` scalar subquery; no
  true single-nearest-station lookup for fish species existed in this schema before. Filters:
  sport-fish bit (`fish_Type & 1`), `fish_zoo.fish_max_length > 10`, and the subquery's own
  `w2.country = @country` scoping (a geographically closer station in the other country is never
  selected — see TEST 4). New `unit_test@MapFishListNearestStation.sql`, 4 tests, all pass via
  `autorun.bat`: nearer-of-two-stations wins, size filter boundary (exactly 10 cm is excluded —
  the predicate is strictly `> 10`), sport-fish filter, and country scoping under a
  closer-but-wrong-country station. Full suite **493 PASS / 2 FAIL**, same 2 pre-existing failures
  in `unit_test@FishCodeLatinJson.sql`, unrelated. Signature-only addition — no existing object
  changed, so no deploy-order dependency on anything else. **Applied directly to production**
  before this changelog entry/commit; this syncs the source.

- 2026-08-24: **New `dbo.fish_region_top` — hand-curated freshwater top-15 per US state / Canadian
  province, backing `Forecast/Planning.aspx`'s "Select desire fish" combobox.** (`script01_createTable.sql`,
  `script02_Funct.sql`, `script09_fish_data.sql`.) New `dbo.fish_region_top` (945 rows: 63 regions —
  50 US states, 13 CA provinces/territories — x 15 ranks), keyed on `(country, state, top_rank)`,
  FK `fish_id` → `dbo.fish` **`ON DELETE SET NULL`** (not CASCADE — retiring a catalogue species
  must not renumber a region's list; the row survives with its name and just stops resolving).
  Read path: `dbo.fn_map_fish_list_bystate(@country, @state)` / `_trial(@country, @state)`, both a
  **plain filtered read of the table** — no proximity/lat-lon join, both filtered to the freshwater
  bit of `dbo.fish.water_type`. (An earlier design joined the region list onto
  `dbo.fn_map_fish_list_bylatlon` so every offered species was guaranteed a nearby forecastable
  station; dropped once "every region must show its 15" became the actual requirement — the
  intersection cut most regions down to 2–6 species wherever station coverage was thin.)
  **The seed is hand-curated, not sourced from `Top15_Fish_Canada_USA.xlsx`.** The workbook mixed
  salt/freshwater species for every coastal or island region and named several entries as a group
  rather than a species ("Cisco", "Grouper", "Sculpin", "Bullhead", "Snapper", "Rockfish",
  "Sunfish" — each covering multiple catalogue rows, so none of them could resolve to one), which
  left many regions short once filtered to freshwater-only — Hawaii had **zero** resolvable
  freshwater species, Florida 4, Rhode Island 6. Every region's 15 were picked by hand from real
  regional freshwater angling knowledge; every one of the ~67 distinct species names used was
  **pre-validated against a live copy of `dbo.fish`** (exact name match + freshwater bit set)
  *before* being written into the seed, so it resolves **945/945** with **zero** within-region
  duplicates — the workbook-sourced predecessor had several (e.g. "Rainbow Trout" and "Steelhead"
  both resolving to `Trout, Rainbow` in the same region, producing two identical combobox entries).
  `common_name` is set equal to `fish_name` for every row — the workbook's separate
  common-name/catalogue-name split is gone along with the workbook as a source.
  New `UNIT_TESTS/unit_test@MapFishListByState.sql` (5 tests: ranked-order return, a non-freshwater
  fixture row excluded even though resolved and ranked, an unresolved `fish_id NULL` row never
  offered, `(country, state)` scoping — the same two-letter code under both countries stays
  separate and an unknown region returns zero rows rather than erroring, and the trial variant
  matching the registered one row-for-row under the current freshwater-only design). All 5 pass via
  `autorun.bat`; full suite **489 PASS / 2 FAIL**, both pre-existing failures in
  `unit_test@FishCodeLatinJson.sql`, unrelated to this change.
  **Gotcha that cost a rebuild:** the table's `FOREIGN KEY … REFERENCES dbo.fish` cannot sit next to
  the table's own `CREATE TABLE` (same forward-reference problem `FK_fish_code_fish` already
  documents nearby) — `dbo.fish_region_top` is created late in `script01_createTable.sql`, so its
  FK has to be added even later, **after** `dbo.fish` exists; a first attempt placed it right next
  to `FK_fish_code_fish` (declared early, right after `PK_fish`) and broke every fresh build with
  *"Cannot find the object 'dbo.fish_region_top'"*, since the table didn't exist yet at that point
  in the concatenated script. Fixed by moving the `ALTER TABLE … ADD CONSTRAINT` to immediately
  after the table's own indexes, further down the file.
  **Frontend (fishfind-frontend):** `Forecast/Planning.aspx.cs` `LoadInitialFishes` calls
  `FillFishListByState` first, falling back to the old proximity-based `FillFishList` only when the
  visitor's state is unknown or the region has no rows — see that repo's `CLAUDE.md`.
  **Already applied directly to production** via a self-gating transaction (smoke test required
  exactly 945 rows / 63 regions / 945 resolved / 0 regions off 15 / 0 non-freshwater rows, rolling
  back otherwise) **before** these `scriptNN_*.sql` sources were updated to match — this changelog
  entry and commit bring the repo back in sync with what prod is actually running. A fresh build
  from `ffi2.sql` now reproduces the same 945-row dataset.

- 2026-08-20: **An empty water reading no longer makes the cache look fresh, and the forecast map now
  requires water AND weather AND fish.** (`script01_createTable.sql`, `script02_Funct.sql`.)
  Reported as "MLI 11446980 has no weather" — it has weather; what it has is **no water readings**.
  All 16 of its `dbo.WaterData` rows in 30 days are entirely NULL, and no row for it has **ever** held
  a measurement. Roughly **127 of 8,546** reporting US stations are in that state.
  **Fix 1 — `dbo.TR_insWaterData`.** The cache merge is `ISNULL(src.x, trg.x)`, which is right for a
  PARTIAL reading (USGS publishes different parameters at different times, so a reading carrying
  discharge but not temperature should keep the recent temperature). But an **entirely empty** reading
  is not a partial reading, it is *no* reading — and it still advanced `CurrentWaterState.stamp`. The
  row then claimed to be current while carrying a value of unknown age: 11446980 shows
  `temperature = 9.0` sourced from nothing. It also disabled every age-out keyed on `stamp` —
  `spTotalUpdateProbability` clears readings older than 7 days, a predicate that could **never** fire
  for exactly the stations needing it. The CTE now feeds the MERGE only from readings that carry at
  least one measurement; `-999` is the source's "no reading" marker for discharge and does not count.
  `MAX(id)` is taken **over the rows with data**, so a batch whose newest row is empty falls back to
  the newest row that has readings rather than losing the station.
  **Fix 2 — `dbo.fn_map_location` + `dbo.fn_map_location_trial`.** These are the FORECAST map's
  station points (`Forecast/Planning.aspx.cs` → `FishTracker.Forecast.MapFrame.LoadMapLocation`) —
  **not `vMapView`, which is the Editor's map** (`Editor/ViewMap.aspx.cs`) and was nearly changed by
  mistake. The rule is now water AND weather AND fish. *Fish* was already enforced and is per species
  via `fish_location`. *Water* was `EXISTS (SELECT 1 FROM dbo.WaterData WHERE mli = …)` — merely "a row
  ever arrived", which the empty-row gauges satisfy — and is now a reading within 15 days that actually
  carries a value. *Weather* was not a condition at all, so a station with no forecast still got a pin;
  it now needs a `weather_Forecast` row for today or later. Both variants changed together so a trial
  user does not see a different set of pins from a paying one.
  New `unit_test@MapLocation.sql` (4 tests) and `unit_test@WaterDataTrigger.sql` TEST 4–5. **Confirmed
  FAILING first**: map TEST 2 → `a station with no forecast must not be plotted, got 1 rows`, TEST 3 →
  `water rows carrying no measurement must not count as water, got 1 rows`; trigger TEST 4 →
  `stamp=2026-08-20` when the last real reading was 10 days earlier. Then **484 PASS**. TEST 5 (partial
  reading still merges, preserves and moves `stamp`) and map TEST 1/4 are the no-regression baselines.
  Two failures remain in `unit_test@FishCodeLatinJson.sql` — **pre-existing, verified failing on a
  clean tree**, unrelated. **Not applied to prod.**
  **Measured impact before deciding:** across the station table the all-three rule is 11,507 → 3,557
  (CA 2,217 → 1,471, US 9,290 → 2,086). The dominant term is fish — **7,710** stations have no species
  assigned — and **371 of those have an orphan `lakeId`** pointing at a lake row that does not exist
  (8 CA, 363 US). Those are broken linkage rather than genuinely fishless water and will now disappear
  from the map; worth its own cleanup, it does not change the rule. Also outstanding: **29
  `CurrentWaterState` rows carry no measurement at all** (6 still looking fresh), which this fix stops
  growing but does not clear, and prod's `spTotalUpdateProbability` is still missing the 7-day age-out
  the scripts carry.
- 2026-08-13: **`dbo.sp_ows_meteo_canonical` — ONE shredder for every weather provider, replacing
  per-provider T-SQL parsing.** (`script02_Proc.sql`, `script01_createTable.sql`.) The weather workers
  now convert each provider's document to a **canonical envelope** before storing it in
  `dbo.ows_meteo.ows`, so the database no longer has to know which provider produced a payload.
  **Why this replaces the old approach:** each provider previously needed its own T-SQL parser
  (`sp_ows_meteo` for The Weather Company's `$.daypart[]`, `sp_ows_meteo_open` for Open-Meteo and — from
  2026-08-12 — Visual Crossing, and *nothing* for four others), unit conversion lived in SQL, and a
  payload no parser understood produced **no rows and no error**. It cannot error: the shredder runs
  inside `TR_ows_meteo`, where raising would abort the worker's `UPDATE` and discard the payload it just
  fetched. Conversion and provider quirks now live in C#/Java where they are unit-testable **and can
  throw**. Envelope `fishfind.weather.forecast/v1`: `schema`, `provider`, `providerType`, `mli`,
  `fetchedUtc`, `days[]` (one object per forecast day, already metric and already reduced), and
  **`raw`** — the provider's original document, embedded so a stored payload can still be inspected and
  replayed, which is exactly what made the Visual Crossing diagnosis possible. Embedding it avoids an
  `ALTER TABLE` on a replicated table. `days[]` members map **1:1** onto `weather_Forecast`, so the
  procedure is `OPENJSON … WITH … MERGE` and nothing else. An **unknown schema version is a no-op, never
  a guess**, so a worker deployed ahead of the database cannot have its payload half-parsed.
  `TR_ows_meteo` now checks `$.schema` **first** and falls back to the legacy per-provider branches,
  which stay until neither service emits raw — the two services deploy independently and thousands of
  stored rows still hold raw documents. Also in this change: `ows_meteo.type` becomes **provenance per
  provider** rather than a routing key (`1` TWC v3, `2` Open-Meteo, `4` Visual Crossing, `5` weather.gov,
  `6` Environment Canada, `7` Weather Underground observations, `8` Google Weather); the trigger routes
  `2` **and `4`** to `sp_ows_meteo_open`, and types 5–8 are deliberately unrouted because they carry
  observations, not forecasts. New `unit_test@OwsMeteoCanonical.sql` (3 tests: envelope shredded with
  every column mapped; legacy raw payload still shredded during rollout; unknown version writes nothing
  and does not throw) and `unit_test@OwsMeteoOpen.sql` TEST 4–5 for the type routing. **Confirmed
  FAILING first** in both files (canonical TEST 1 → `got 0`; routing TEST 4 → `got rows=0`), then
  **431 PASS / 0 FAIL**. **Fully applied to prod 2026-08-13**, in two steps: first the type-4 routing
  (live trigger confirmed byte-equal to the pre-change script, then a rolled-back type-4 update on
  13068500 produced 7 rows), then `sp_ows_meteo_canonical` **before** the trigger that calls it, in one
  committed transaction guarded by an assertion that prod was still in the expected intermediate state.
  Smoke-tested live on 13068500 in a **rolled-back** transaction, both paths in one go: a canonical
  envelope produced 1 row at `tmHigh` 29.44 °C, and the station's own stored **raw** payload still
  produced 7 — so the rollout window is safe in both directions. 0 leftovers (station back to 7 rows,
  12,025-char payload). **The database is now ready for the workers**; nothing changes until one of them
  starts emitting the envelope.

- 2026-08-12: **Fix: `dbo.sp_ows_meteo_open` silently discarded every Visual Crossing document, so
  collected stations showed no weather.** (`script02_Proc.sql`.) `dbo.TR_ows_meteo` routes
  `ows_meteo.type = 2` here, but **the weather worker stores more than one provider's document under
  that one type**: Open-Meteo (`$.hourly.time` + `$.daily.time`), Visual Crossing (`$.days[]`), and a
  Weather Underground personal-station document (`$.observations[]`). The procedure only understood
  Open-Meteo, so a Visual Crossing document made every CTE return nothing, the `MERGE` had an empty
  source, and **nothing was written with no error at all** — an empty parse is indistinguishable from
  success. Reported via **MLI 13068500** (`BLACKFOOT RIVER NR BLACKFOOT`): supported, `backoffstate 0`,
  16 fish on its water body, water data current, **in `vwWeatherForecastToDay`**, `ows_meteo` holding a
  12 KB payload — and zero `weather_Forecast` rows. Proved by running the live procedure against that
  station's own stored payload in a **rolled-back** prod transaction: 0 rows before, 0 after, no error.
  Fixed by adding a Visual Crossing branch (an early-exit **before** the Open-Meteo block, which is
  left byte-identical). **Units are the trap**: Open-Meteo is metric and every consumer
  (`fn_station_weather_today`, `fn_plot_weather`) expects metric, while Visual Crossing serves **US
  units** — so °F → °C, mph → km/h, inches → mm; `pressure` is mb = hPa and is not converted. Also:
  the horizon is clipped to **today..today+6** to match the Open-Meteo branch (the document runs 15
  days and its first day is often *yesterday* in the station's time zone); daily rainfall is **split
  evenly** across `gpfDay`/`gpfNight` because a daily document has no hourly resolution and the sum is
  what consumers use; `tm` is set to `'00:00:00'` rather than NULL **deliberately** — `fnWeatherForecast`
  selects `WHERE tm IS NULL`, so a NULL would make these rows visible to a caller no other forecast row
  reaches; and the provider's `icon` is mapped onto the same weather codes the Open-Meteo branch emits
  so the `om_*.png` namespace stays single (all 5 icon values occurring on prod are covered —
  `partly-cloudy-day`, `clear-day`, `rain`, `cloudy`, `wind` — with an explicit `om_na.png` fallback).
  **The Weather Underground shape is still a deliberate no-op**: it carries *current observations*, not
  a forecast, so nothing in it could honestly become a `weather_Forecast` row. **Raising was rejected**
  — this runs inside `TR_ows_meteo`, so an error would abort the worker's `UPDATE` and throw away the
  payload it just fetched. Those stations need the *worker* fixed (stop stamping every provider
  `type = 2`), which is `efcs-backend`, not this repo.
  New `unit_test@OwsMeteoOpen.sql` — 3 tests driving the **real path** (they `UPDATE dbo.ows_meteo` and
  let the trigger dispatch, so routing is covered): Visual Crossing shredded with the conversions
  pinned down; Open-Meteo unchanged; unrecognised shape writes nothing and does not throw. **Confirmed
  FAILING first** (TEST 1 → `expected 2 forecast rows from the days[] document, got 0`, with 2 and 3
  passing as baselines), then **423 PASS / 0 FAIL** suite-wide (`crcstate` updated). Additionally
  verified against the **real prod payload** for 13068500 in a rolled-back local transaction: 7 rows,
  85 °F → 29.44 °C, 12.8 mph → 20.6 km/h, yesterday correctly dropped. **Applied to prod 2026-08-12**
  (one committed `CREATE OR ALTER`; the live copy was confirmed byte-equal to the pre-change script
  first — note SQL Server stores `CREATE OR ALTER PROCEDURE` as `CREATE   PROCEDURE`, which a naive
  drift check reports as a difference). Smoke-tested live against 13068500's own stored payload in a
  **rolled-back** transaction: 7 rows, correct conversions, 0 leftovers.
  **Census of what is actually stored under `type = 2`** (measured, not sampled — an earlier note here
  said "1,350 Weather Underground" and that was wrong: it came from labelling the whole
  not-Open-Meteo/not-Visual-Crossing bucket after reading ONE payload):
  Open-Meteo **1,029 US + 549 CA**, weather.gov/NWS GeoJSON (`@context,geometry,properties`) **592 US**,
  Visual Crossing **315 US**, Weather Underground observations (`$.observations[]`) **259 US**,
  MSC/Environment-Canada SWOB GeoJSON (`features,links,numberMatched`) **243 CA**, and a
  current-conditions shape (`airPressure,cloudCover,currentConditionsHistory`) **40 US**. The counts
  move between runs because the collector overwrites `ows` on every pass. **Only Open-Meteo and
  Visual Crossing are forecasts**; the rest are observations or a different provider's document, and
  none can honestly become `weather_Forecast` rows — they need the worker to stop stamping every
  provider `type = 2`.
- 2026-08-11: **Retired `dbo.fn_forecast_plot` — the orphan left behind by the entry below.**
  (`script02_Funct.sql`.) The pre-JSON ancestor of `dbo.fn_forecast_plot_json`: it returned the plot's
  series as `(id, line, type)` **rows** for the caller to stitch together. Production-only, never in
  these scripts, and **orphaned** — nothing in the database references it (verified against every
  module's *text*, not just the dependency graph, so dynamic SQL is covered) and nothing in any
  repository does either. Its own header named `FishTracker.Forecast.Plot.GetJsonPlot` as the caller;
  that method still exists in `Forecast/Plot.aspx.cs` but has called `fn_forecast_plot_json` since
  2026-08-04. **Unlike `fn_web_service_plot_json` it was NOT broken** — it resolved and ran — so this
  is removal of dead code, not a fix, and the bar for it was higher: the checks above are what
  justified it. **Its 65-line body was the only copy in existence, so it is preserved verbatim as a
  commented block above the `DROP` rather than destroyed** — uncomment to restore if the row-wise form
  is ever wanted. Added to `unit_test@SchemaReferences.sql` TEST 8. **Applied to prod 2026-08-11**
  (one committed transaction). Verified after: only `fn_forecast_plot_json` remains of that family, it
  still returns a real document, and `WebService/Plot` + `Forecast/Plot.aspx` (with real place/fish
  ids) + `Forecast/Planning.aspx` are all HTTP 200, no new `LogException` rows. **420 PASS / 0 FAIL.**
- 2026-08-11: **Retired `dbo.fn_web_service_plot_json` + `dbo.fn_web_service_plot_json2` — the last
  broken reference on prod.** (`script02_Funct.sql`.) Both were 2015 objects living **only on
  production**; neither was ever in these scripts, so a fresh build never had them and only prod was
  affected. `fn_web_service_plot_json` concatenated the `line` column of `dbo.fn_web_service_plot`, a
  function that exists in no database — calling it live raised **`Invalid object name
  'dbo.fn_web_service_plot'`**, which is the proof it was dead rather than merely suspicious. That TVF
  was **renamed `dbo.fn_forecast_plot` in 2020** and the wrapper never followed. Repointing it would
  have revived nothing: no caller in the database and none in any repository, and the live JSON
  endpoint (`Forecast/Plot.aspx.cs`, `WebService/Plot/Default.aspx.cs`) calls
  **`dbo.fn_forecast_plot_json`**, which is self-contained and does **not** go through
  `fn_forecast_plot`. `fn_web_service_plot_json2` was scaffolding — it returned a hard-coded
  jQuery-callback test string. Both are now `IF EXISTS … DROP` guards in `script02_Funct.sql` (the
  pattern used for the other retirements) and are added to `unit_test@SchemaReferences.sql` TEST 8.
  **`dbo.fn_forecast_plot` (the 2020 rename) is also prod-only and now has no caller either, but it
  resolves and is not broken, so it was deliberately left alone.**
  **Applied to prod 2026-08-11** (one committed SqlClient transaction, both drops). **Prod's dangling
  -reference list is now a single Microsoft-owned entry** (`sp_upgraddiagrams → dtproperties`, part of
  database-diagram support) — every reference in our own code resolves. Verified after: the functions
  are gone, `fn_forecast_plot_json` still returns a real document, and `WebService/Plot` +
  `Forecast/Planning.aspx` + the homepage are all HTTP 200. **420 PASS / 0 FAIL** locally, unchanged.
- 2026-08-11: **Fix: `dbo.sp_push_us_water_data` re-registered every measurement on every push —
  `dbo.UScode` held 9,694 rows for 279 distinct pairs.** (`script02_Proc.sql`.) The catalogue check was
  `IF NOT EXISTS (SELECT * FROM UScode WHERE name like @name AND unit LIKE @unit)`, and `LIKE` is the
  wrong operator for a lookup in **three** ways. The dominant one: USGS measurement names routinely
  contain brackets — `Total nitrogen [nitrate + nitrite + ammonia + organic-N]` — and under `LIKE`
  that group is a **character class matching ONE character**, so the row could never match itself.
  Measured on prod: `WHERE name LIKE @name` returned **0** rows for a name `=` matched **5,409**
  times, and **8,808 of 9,694** rows carry a name containing `_`, `%` or `[`. Second, `unit LIKE NULL`
  is UNKNOWN, never true, so unitless measurements re-inserted forever (**613** such rows). Third, and
  the opposite failure — `_`/`%` in an *incoming* name match OTHER stored names, so a genuinely new
  measurement is silently **skipped and never registered** (the test proves this direction too: the
  near-miss name came back `1 and 0`). Now an exact match with a NULL-safe unit comparison
  (`unit = @unit OR (unit IS NULL AND @unit IS NULL)`). New `unit_test@PushUsWaterData.sql` — 3 tests,
  each its own transaction, one per failure mode; **confirmed FAILING first** (2 rows / 2 rows /
  `1 and 0`).
  **The predicate alone is only forward-looking**, so the table is now also constrained:
  **`UK_UScode_name_unit UNIQUE (name, unit)`** in `script01_createTable.sql` — SQL Server treats
  NULLs as equal in a UNIQUE constraint, which is exactly the wanted behaviour for the unitless case.
  TEST 4 covers it (duplicate rejected for both a real unit and a NULL unit, a distinct unit still
  accepted), also confirmed FAILING first. **420 PASS / 0 FAIL** suite-wide (was 416).
  **The constraint creates a race the proc did not have**: two collectors pushing the same *new*
  measurement at once, one loses on the insert — and that would abort the whole `BEGIN TRY`, silently
  costing the **readings** below it. The `INSERT` therefore has its **own inner `TRY/CATCH`** that
  swallows the violation (the row exists either way). Not directly unit-testable — it needs
  concurrency — so it is written to be obviously inert on the normal path.
  **Applied to prod 2026-08-11**, one committed SqlClient transaction: redeploy the proc → dedupe →
  add the constraint (that order; constraining first would fail on the existing data). Dedupe was a
  `ROW_NUMBER() OVER (PARTITION BY name, unit)` delete of `rn > 1`, since the heap has no key:
  **9,694 → 279 rows, 9,415 deleted**, distinct pairs unchanged at 279. Full table backed up
  immediately beforehand. The race guard was added right after and the proc redeployed a second time.
  Verified live: constraint present, `name like @name` gone from the live definition, and a
  **rolled-back** push of the same bracketed series three times plus an unitless series twice left
  exactly 1 catalogue row each with the reading stored (0 leftovers); site 200, no new `LogException`.
- 2026-08-11: **Fix: five objects that shipped procedures/functions REFERENCE were missing from the
  schema scripts — a fresh build could not run them.** Same class of gap as `GetDatePeriod` /
  `fn_get_float_as_string` (2026-08-05): SQL Server defers name resolution, so the module *compiles*
  and the build reports no error; it fails only when called. Found by listing
  `sys.sql_expression_dependencies` rows with `referenced_id IS NULL` after a from-scratch build.
  **Restored verbatim from production** (`script01_createTable.sql` / `script02_Funct.sql`):
  `dbo.UScode` (measurement catalogue written by **`sp_push_us_water_data`, called live by
  waterservice `WaterDataRepository`**; created **empty** — the 9,684 rows on prod are content, not
  seed data), `dbo.fn_Parser` (comma splitter — **placed BEFORE `fn_first_item` in the file**, which
  is its only caller), `dbo.UNIX_TIMESTAMP_TO_DATETIME` and `dbo.fn_direction_by_degree`. The last
  two now have **no caller** (see the retirements below) and are kept only so these scripts still
  reproduce production; `unit_test@SchemaReferences.sql` is what justifies them.
  **Three objects were RETIRED instead, because nothing could make them work:**
  (1) `dbo.sp_weather_station` inserted into a table `dbo.Weather_station` that exists in no
  database — not in a fresh build, not on prod — so every call has always ended in its own `CATCH`;
  no caller in any repo. (2) `dbo.sp_weather_forecast16` (the OpenWeatherMap 16-day writer) called
  `dbo.fn_direction_by_win_degree`, which likewise exists nowhere, **and** its `INSERT` omitted three
  **NOT NULL** columns of `weather_Forecast` (`link`, `gpfDay`, `gpfNight`), so it could not have
  inserted a row even with the name fixed — true on prod as well; no caller, and the live path is
  `ows_meteo` / `sp_ows_meteo` → `fn_plot_weather` / `fn_station_weather_today`. An **older copy in
  `scriptA100_fillForecast.sql`** (still writing the long-gone `maxWin`/`degree`/`direction`/
  `weather_temperature` columns) went with it. (3) `dbo.Parking_Spot`, a legacy roadside-access
  listing superseded by `dbo.Spot`, never present in these scripts; its only reader was the
  `DELETE FROM Parking_Spot` inside **`sp_del_river`** (called live from
  `Editor/LakeEditor.aspx.cs:542`), which was removed with it. Each retirement **keeps its
  `IF EXISTS … DROP`** so an existing database sheds the object.
  New `unit_test@SchemaReferences.sql` — 8 tests, each its own transaction. **TEST 1 is the guard for
  the whole class** (no module may reference a missing object; triggers, caller-dependent `EXEC`s and
  the CLR `ToString` excluded, with why) and **TEST 8 guards the retirements** (none of the four names
  may reappear). **Confirmed FAILING first** at every stage — first all 7 original tests failed with
  TEST 1 naming the exact 7 dangling references, then TEST 8 failed naming `Parking_Spot,
  sp_weather_forecast16` before they were removed — then **416 PASS / 0 FAIL** suite-wide via
  `autorun.bat` (was 408; `crcstate` updated by `averify.py` itself).
  **Applied to prod 2026-08-11**, one committed SqlClient transaction, 7 batches in this order:
  redeploy `sp_del_river`, redeploy `sp_MergeLakes`, drop `sp_weather_forecast16`, drop
  `sp_weather_station`, `DROP TABLE dbo.Parking_Spot` (349 rows; `FK_Parking_Spot` went with it).
  **The two procedures had to stop referencing the table before it could go**, hence the ordering.
  **`sp_MergeLakes` was NOT overwritten blind — prod's copy turned out to be NEWER than the script's**
  and carried a line the script had never captured: `update fish_spot SET lake_id = @toLake …`.
  Redeploying the script version as it stood would have silently dropped that. The line was added to
  `script02_Proc.sql` first (and the neighbouring `update spot` un-mangled from `END    update spot`),
  so what shipped is prod's behaviour minus the `Parking_Spot` line only. **Always diff a live module
  against the script before redeploying it** — this repo's copy is not automatically the newer one.
  Row backup of `Parking_Spot` taken immediately before the drop and kept outside the repo (the table
  can be recreated from the retirement note in `script01_createTable.sql`).
  Verified after commit: all four objects absent, both procedures compile and resolve `Spot` +
  `fish_Spot`, prod's dangling-reference list down to two **pre-existing** entries this change did not
  touch (`fn_web_service_plot_json → fn_web_service_plot`, a prod-only function absent from these
  scripts, and the Microsoft `sp_upgraddiagrams → dtproperties`); `sp_del_river` and `sp_MergeLakes`
  smoke-tested live in a **rolled-back** transaction (0 leftovers); Default/News/RscRiverList/Login
  all HTTP 200; no new `dbo.LogException` rows.
- 2026-08-11: **Build scripts: `build.cmd` reported success after a completely failed build.**
  `dbcreator.cmd` ran `sqlcmd` without **`-b`**, so every error was ignored and the exit code was
  always 0 — `build.cmd` printed the date and returned 0 after 500+ errors, and `autorun.bat`'s
  `if errorlevel 1 (echo ERROR: dbcreator.cmd failed)` could never fire. Added `-b` (stop on first
  error, non-zero exit), gave `build.cmd` errorlevel checks on both steps with a message naming the
  usual cause (the scripts build a **fresh** database — they cannot be re-applied over an existing
  `ffi`, per [Idempotency](#idempotency-which-scripts-are-safe-to-re-run)), and it now **keeps
  `ffi2.sql` on failure** so the failing statement can be found. Also fixed two long-standing typos in
  `generate_db_script_ffi2.cmd`: a stray `%` in the output name (`"%ffi2.sql"`, which only worked
  because cmd strips a lone `%`) and a trailing space inside `"script09_fish_data.sql "`.
  Verified both paths (fresh → exit 0 / 0 errors; existing `ffi` → aborts at the first error, exit 1,
  no rows touched) and re-ran the full suite through the shared `dbcreator.cmd`.
- 2026-08-10: **Fix: all 6 tests in `unit_test@LakeState.sql` were INVISIBLE in the run report.**
  (No schema change — test file only.) The file printed success as `PRINT 'PASSED ' + @test_name`, and
  `averify.py` **strips every line containing the literal `PASSED`** when building `cleaned.txt` (that
  filter exists to drop sqlcmd noise). So the `Lake_State` CHECK-constraint coverage ran and passed on
  every single run while contributing **zero** lines to the report — it was the only file in the suite
  contributing 0 PASS lines, and a regression in those constraints would have been silent. This is the
  exact trap documented under [Structure unit tests](#structure-unit-tests); the file predated the rule.
  Converted to `TEST n PASS [Nms]: …`, numbering matched to the existing `TestLS1`–`TestLS6` transaction
  names / `@test_name` values, with the standard
  `DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())` timing (the file had **none**).
  **The FAIL branches were a second instance of the same class of bug**: `RAISERROR ('FAILED: %s …')`
  survives the filter, but carries no test number and doesn't match the documented form — now
  `TEST n FAIL [%dms]: …`. Two latent defects fixed while there: (a) assertions were
  `IF @result1 <> 1 RAISERROR ELSE PRINT`, but `@result1` is NULL whenever the `CATCH` fired, so the
  comparison was NULL and **neither branch ran** — a genuinely broken test printed nothing rather than
  failing; now `IF <success> PRINT ELSE RAISERROR` with `@result1 int = -1` / `@threw int = 0`
  initialised at declaration. (b) `@threw` had to stop being `bit`: **`bit` is not a legal `RAISERROR`
  substitution type**, and substitution args must be plain variables or literals — an inline
  `ISNULL(@result1,-1)` fails to compile with `Incorrect syntax near 'ISNULL'`. Suite went
  **402 → 408 PASS / 0 FAIL** via `autorun.bat`, the delta being exactly these 6 and no other output
  change (`crcstate` updated). **No prod DDL — nothing here touches the database.**
- 2026-08-10: **Fix: the build read the UTF-8 schema scripts in the ANSI code page, corrupting every
  non-ASCII literal.** (`mssql/dbcreator.cmd`, `mssql/UNIT_TESTS/scriptrunlocal.bat`.) All
  `scriptNN_*.sql` sources are **UTF-8 without a BOM**, but both files invoked `SQLCMD` with no `-f`,
  so it fell back to the ANSI code page: `é` (`0xC3 0xA9`) arrived as `Ã©`, em dashes as `â€"`, and so
  on. **6 object definitions** were affected in every build — most visibly the French water-body words
  in `dbo.ProduceWBVariant`. Nothing errored (the text is merely wrong in the database), so this was
  true of **every unit-test run** and would have been true of any prod rebuilt from the scripts. Fixed
  by adding **`-f 65001`** to both `sqlcmd` invocations; that also makes the harness's output UTF-8,
  which is what `averify.py` already assumes when it reads `result.txt`. Every source file was checked
  as valid UTF-8 with no BOM first, so nothing flips from working to broken by being read correctly.
  **Scope of the damage, precisely:** the corrupted French words sit in `ProduceWBVariant`'s final
  "strip stray water-body-type words" `DELETE`, which is a **redundant safety net** — `GetWaterType` →
  `GetValidPart` already resolve those words against `dbo.water_body.fr`, whose seed data is
  *unaffected* because `script08_Data.sql` spells every accent as `nchar(233)`/`nchar(201)`/`nchar(251)`
  rather than typing the character. **That escaping is this same bug, worked around by hand long ago**;
  with `-f 65001` it is no longer necessary (leave it, it is harmless and code-page proof). No
  behavioural difference could be reproduced through `ProduceWBVariant` — the observable damage is the
  definition text itself. New `unit_test@ScriptEncoding.sql` — 3 tests (no object definition carries
  the UTF-8-read-as-ANSI signature, checked across `sys.sql_modules`; the French literals in
  `ProduceWBVariant` decode correctly; and as a control the `nchar()`-escaped seed data still resolves
  to its `locType`). **Every literal in that test file is ASCII with accents built via `NCHAR()`** so
  the assertions mean the same thing whichever code page the file is itself read in — written any
  other way a corrupted expectation would silently match a corrupted definition and pass. Confirmed
  **FAILING first** (TEST 1 reported 6 corrupted definitions naming `fn_clean_river_name`, TEST 2 found
  the mojibake, TEST 3 passed as the control), then **426 PASS / 0 FAIL** suite-wide via `autorun.bat`
  (`crcstate` updated). **Nothing was applied to prod** — prod's definitions are correct (it was never
  built through this path); this only fixes what a rebuild would produce.
- 2026-08-10: **Fix: `dbo.vwWeatherForecastToDay` permanently stranded any station whose weather
  collection had lapsed — and the schema script had drifted from prod.** (`script01_createView.sql`.)
  The weather worker's work list required `dbo.ows_meteo.stamp` to fall inside a 15-day window,
  commented "only if water data exists". **`ows_meteo.stamp` is not a water-data fact**: the row is
  seeded by `trg_WaterStation_AI_ows_meteo` and thereafter `stamp` is written *only by the weather
  worker itself* (`WeatherDataRepository`: `UPDATE dbo.ows_meteo SET …, stamp = GETDATE()`). So the
  predicate meant "we collected weather here recently" — self-referential, and inverted for a work
  list: once a station fell out of the window **nothing could ever move its stamp again**, so it was
  excluded forever while its water data kept flowing. Measured on prod: **46 CA + 12 US** fish-bearing
  stations frozen out, 57 of them stamped `2021-03-01` (one at `1975-01-01`) with `ows IS NULL`, and
  **43 of the CA ones carrying perfectly current water data**. Fixed by dropping the predicate so
  **fish presence alone decides**; the now-unused `LEFT JOIN dbo.ows_meteo` went with it (`mli` is
  uniquely indexed there, so the join never affected cardinality). Deliberately **not** re-expressed
  as `EXISTS (dbo.WaterData)` — that reading of the old comment would DROP 81 CA + 157 US stations
  that are collected today but hold no `WaterData` rows. `unit_test@WeatherForecastToDay.sql` — 4
  tests, each its own transaction (stale `ows_meteo` no longer excludes; actively collected station
  still listed; fish but no water data → still listed; water data but no fish → excluded). Confirmed
  **FAILING first** (TEST 1 → 0 rows), then **402 PASS / 0 FAIL** suite-wide via `autorun.bat`
  (`crcstate` updated). **Prod already had this fix applied live; the schema script did not** — so a
  fresh build still carried the bug and would have reintroduced it on the next deploy. The script now
  matches `OBJECT_DEFINITION` on prod **verbatim** (verified line-by-line), and this entry is the
  missing record of that change. **No prod DDL was run for this entry.**
  **Caveat for the collectors — recovering the stations pushed CA past its per-pass cap.**
  `WeatherService.Data.WeatherStationRepository` caps one pass at `DefaultStationLimit = 1400` (CA)
  and `UsWeatherGovStationLimit = 900` (US). The fix took CA eligible from **1464 → 1510** (US
  2212 → 2224), so **1510 > 1400** and a single cycle can no longer cover every CA station. This is
  not a stall: the view's `ORDER BY NEWID()` rotates the selection, so the recovered stations fill in
  over a couple of cycles instead of instantly. Raise `DefaultStationLimit` if same-cycle coverage is
  required.
- 2026-08-10: **Fix: `dbo.TR_insWaterData` broke ingestion for every BRAND-NEW water station.**
  (`script01_createTable.sql`.) The trigger MERGEs each new `dbo.WaterData` reading into
  `dbo.CurrentWaterState` (the "latest reading per station" cache). `CurrentWaterState.sid` is
  `bigint NOT NULL`, and the `WHEN MATCHED` branch set it — but the `WHEN NOT MATCHED` insert column
  list **omitted `sid`**, so the very first reading for a station that had no cache row yet died with
  `Cannot insert the value NULL into column 'sid' … column does not allow nulls`. Invisible in normal
  operation precisely because every long-standing station already has a `CurrentWaterState` row and
  therefore takes the MATCHED path; it only bites when a station is onboarded, which is exactly when
  a silent ingestion failure is hardest to notice. The `cte` already selected `w.sid` from
  `dbo.WaterStation`, so the fix is to carry it into the insert. New
  `unit_test@WaterDataTrigger.sql` — 3 tests, each its own transaction (new station gets a state row
  carrying `WaterStation.sid`; the inserted row maps the measurements the MATCHED branch does, ph
  stored `/10` and the source's `-999` "no reading" discharge nulled; existing state row still
  updated in place with sid re-stamped, the no-regression baseline). **Confirmed FAILING first** —
  TEST 1 and 2 raised the exact NULL-`sid` error while TEST 3 passed — then all green: **398 PASS /
  0 FAIL** suite-wide via `autorun.bat` (`crcstate` updated). Side effect: the workaround seeds in
  `unit_test@WeatherForecastToDay.sql` (which pre-inserted a `CurrentWaterState` row purely to reach
  the MATCHED path) are no longer needed and were removed. **Applied to prod 2026-08-10** (one
  committed SqlClient txn, DDL extracted verbatim from `script01_createTable.sql` and GO-split into
  2 batches: conditional `DROP TRIGGER` + `CREATE TRIGGER`). The live definition was byte-identical
  to the pre-fix source beforehand, so no prod drift was overwritten. Exposure at the time: **all
  11,720 stations already had a `CurrentWaterState` row**, i.e. nothing was broken yet and the
  MATCHED-only path meant the change could not disturb existing data — the defect was purely latent,
  waiting for the next onboarded station. Smoke-tested live in **rolled-back** transactions (nothing
  persisted, verified 0 leftovers): a brand-new station with no cache row got its first reading
  (1 row, `sid` = the station's, ph 71 → 7.1, temp 17), and a real station (`01010000`) still updated
  in place with its `sid` preserved. **Prod schema drift found while doing this** (fresh builds
  differ, so scripted inserts against prod need care): `CurrentWaterState.sid` is `int` not `bigint`;
  `WaterStation.sid` is an **IDENTITY** column; `WaterStation.id` has **no `NEWSEQUENTIALID()`
  default**. None of these affect the fix — `WaterStation.sid` is `int`, so `src.sid` fits either way.
- 2026-08-05: **`dbo.fn_forecast_plot_json` gained a `lakename` member — plus two long-missing
  functions restored to the schema scripts.** (`script02_Funct.sql`.) The plot document already
  carried `lakeid` but not the water body's name, so `Forecast/Plot.aspx` could only name the
  *station*. `lakename` is `lake.lake_name` for the station's `lakeid`, `"` replaced by `''` exactly
  as `place` already does, and `COALESCE`d to `''` — **an empty name is the contract for "no lake
  row"**, which is real: prod has **514 of 11,720** stations whose `lakeId` matches no `lake` row
  (the live database carries **no foreign keys at all on `dbo.WaterStation`**, unlike a fresh build,
  which has `FK_WaterStation_Lake`). The caller keys the link off a non-empty name, so a name always
  implies a resolvable `LakeId`.
  **`dbo.GetDatePeriod` and `dbo.fn_get_float_as_string` were missing from the schema scripts
  entirely** while existing on prod — both are called by `fn_forecast_plot_json`, so it failed at
  runtime in any freshly built database and had **never been coverable by a unit test**. Their prod
  definitions were copied in verbatim (so they were *not* re-applied to prod — no drift introduced).
  Watch the recursive CTE in `GetDatePeriod`: default `MAXRECURSION` caps it at 100 days.
  New `unit_test@ForecastPlotJson.sql` — 3 tests, each its own transaction (name returned next to
  `lakeid` and `place`; **orphan `lakeid` → empty name in a still-valid document**, which disables
  `FK_WaterStation_Lake` inside the transaction to reproduce production; a `"` in the lake name
  escaped so the concatenated document still parses). Confirmed failing first against the live
  pre-change function (`JSON_VALUE(…,'$.lakename')` → NULL), then **386 PASS / 0 FAIL** suite-wide
  via `autorun.bat` (`crcstate` updated). **Applied to prod 2026-08-05** (SqlClient txn, DDL from
  `script02_Funct.sql` GO-split into 2 batches; smoke-tested live and end-to-end through
  `Forecast/Plot.aspx` inside the `Planning.aspx` iframe). Frontend side in `fishfind-frontend`
  `aspnet/Forecast/CLAUDE.md`.
- 2026-08-04: **Fix: `dbo.IsIpBanned` banned an IP FOREVER — bans now expire (date-scoped).**
  (`script02_Funct.sql`.) The function matched **any** `baned = 1` row for the IP with no date
  predicate, so one bad day blocked an address permanently. Live impact: **10,503 addresses** were
  holding ban rows, some from tripping the *daily* 100-page quota months earlier, and the developer
  **loopback address was permanently locked out of the local site** (the dev site runs against the
  prod DB, so it banned itself; symptom is an opaque 404 from `Global.asax.cs`, easily mistaken for
  a broken web server). A second amplifier: the site's own malformed self-links (e.g.
  `/http:/localhost:32543/Resources/wfFishViewer.aspx`, `/Resources/&quot;/Resources/…`) generate
  missing-`.aspx` hits, and 3 of those trip `MissingPageBanThreshold` — so the site could
  permanently ban real visitors via its own broken markup. Now only rows whose `activityDate` falls
  inside a retention window count; a persistent abuser keeps earning fresh daily rows and stays
  blocked continuously, while an IP that stops is released automatically. Window is tunable without
  a redeploy via **`global_configuration('ip_ban_window_days')`** (seeded `30` in `script08_Data.sql`,
  guarded by `IF NOT EXISTS` so it never overwrites an operator-tuned value; missing/unparsable → 30,
  `0` → today's bans only). UTC throughout, matching `DF_SessionHandler_startSess` and
  `spRegisterPageHit`; `activityDate` is PERSISTED and already INCLUDEd in
  `IX_SessionHandler_Baned_Ip4`, so the extra predicate stays a single index seek — **no index
  change**. `unit_test@SessionHandler.sql` TEST 22–25 (stale ban released; in-window ban still
  blocks; window boundary — oldest in-window day blocks, one day older does not; window read from
  `global_configuration`). **Confirmed FAILING first** (22/24/25 failed, 23 passed as the
  no-regression baseline), then all green: **383 PASS / 0 FAIL** suite-wide via `autorun.bat`
  (`crcstate` updated). **Applied to prod 2026-08-04** (SqlClient txn, DDL taken from
  `script02_Funct.sql` GO-split into 2 batches, + the config seed): **3,693 IPs released by expiry,
  665 still blocked** inside the window; spot-checked a stale row (last ban 2026-07-04 → now
  `IsIpBanned = 0`) and a recent one (still `1`); live site smoke-tested 200 on Default/News/Login/
  RscRiverList — the function is on the per-request path, so a bad deploy here breaks every page.
  **Frontend counterpart** (separate repo, `Global.asax.cs`): loopback/private IPs are now exempt
  from the whole rate-limit/ban stack, so local development can no longer ban itself.
- 2026-08-02: **`dbo.fn_news_search(@q)` — search published news across text + mentioned fish names**
  (`script02_Funct.sql`; inline TVF, idempotent `IF EXISTS(...xtype='IF') DROP…GO CREATE`). Returns up
  to **100** published articles, newest first, matching `@q` over one concatenation of the headline,
  source, the 3 paragraphs (`news_paragraph0/1/2`), the 3 photo alts, and the common/latin/alt names of
  the up-to-3 fishes the article mentions (news `LEFT JOIN fish ×3`) — so "walleye" finds an article
  tagged with walleye even when the headline doesn't say it. Columns: `news_id`, `a1/fish1/l1 …
  a3/fish3/l3`, `news_title`, `news_source`, `news_paragraph0/1/2`, `news_photo_alt0/1/2`, `stamp`
  (yyyy-mm-dd), `country`. **Published-only** (never leak a draft, same rule as `fn_news_doc`);
  `@q` matched as `LIKE N'%'+@q+N'%' ESCAPE '\'` — the **caller escapes** `% _ [`; NULL/empty `@q` →
  latest 100. Called by docapi (`JdbcNewsQueryRepository.search`, `GET /api/v1/news/search?q=`).
  `unit_test@NewsSearch.sql` — 4 tests (match by headline; **match by a mentioned fish name**;
  unpublished draft hidden; NULL term → latest published, ≤100). All pass via `autorun.bat`
  (`crcstate` updated). **Applied to prod 2026-08-02** (SqlClient txn; smoke-tested live —
  `fn_news_search(NULL)`→100, `fn_news_search('fish')`→100, and via docapi 1.3.0 `/api/v1/news/search`).
- 2026-08-02: **`dbo.sp_news_doc_add(@json)` / `dbo.sp_news_doc_update(@news_id, @json)` — generic news
  document write path** (`script02_Proc.sql`; idempotent `IF EXISTS(... type='P') DROP … GO CREATE`).
  These complete the news CRUD for **docapi**: the read side (`fn_news_doc`, `fn_news_list`,
  `fn_default_news_ids`/`fn_default_news_json`, `fn_news_json`) and the interchange `sp_news_import`
  already existed; these two are the plain `POST /api/v1/news` (`NewsDocumentRepository.addDocument`)
  and `PUT /api/v1/news/{id}` (`.updateDocument`). Both shred the **`fn_news_doc` document shape** with
  `OPENJSON` (title, author, author/source links, video link, credit, photo_alt, paragraph0..2, country,
  date, lake_id, a base64 lead photo, and `fishes:[{id}]` — up to 3), so a client can GET → edit → POST/PUT.
  `add` inserts **published** (`news_publish = 1`, absent date → now) and returns the new `news_id`;
  `news_title` is UNIQUE so a dup title raises. `update` is PUT-replace, but **preserves** the publish
  date and the (potentially large) lead photo when the body omits them — every other field is written
  as NULL if absent. Base64 photo decode via `xs:base64Binary`, ids via `TRY_CONVERT` (bad text → null),
  mirroring `sp_news_import`. `unit_test@NewsDoc.sql` extended with TEST 5–8 (add round-trips via
  `fn_news_doc`; base64 photo + 2 fishes stored; titleless doc rejected; update replaces fields and keeps
  the photo). Full suite green via `autorun.bat` (`crcstate` updated). **Applied to prod 2026-08-02**
  (SqlClient txn, alongside `fn_news_search`; `sp_news_import` / `fn_news_doc` were already live).
- 2026-08-01: **`dbo.fn_station_weather_today(@sid)` — today's weather at ONE monitoring station**
  (`script02_Funct.sql`; inline TVF, idempotent `IF EXISTS(...xtype='IF') DROP…GO CREATE`). Returns at
  most one row — `dt`, `conditions`/`conditions_long`/`icon`, `air_temp`, `temp_high`/`temp_low`,
  `humidity`, `wind_speed`/`wind_direction`/`wind_degree`, `precip_chance` (pop %), `precip_amount`
  (mm) — and **zero rows when that station has no forecast for today**. The zero-row case is the
  contract: `dbo.weather_Forecast` is only collected for stations whose water data is recent (see
  `dbo.vwWeatherForecastToDay`), so **~3.7k of 11.7k stations have weather at all**, and the caller
  must be able to tell "no data" from a real calm reading. **Deliberately NOT built on
  `dbo.fn_plot_weather`**, which pads every missing day with a ZERO-FILLED placeholder row (0°, 0 %,
  `''` text) for the Highcharts series — correct for a chart, but on a page it renders as a real
  reading. Joined on the FK (`weather_Forecast.link = WaterStation.id`) rather than `mli`; both are
  unique per station, but `link` is the declared relationship. The unique index is `(link, dt, tm)`,
  so a day may hold several collection times — `TOP 1 … ORDER BY tm DESC` takes the latest.
  Called by `FishTracker Resources/wfRiverViewWeather.aspx.cs` (`BuildWeatherTable`, from
  `BuildStationCard`) — the weather table under each station card on the Weather tab.
  `unit_test@StationWeatherToday.sql` — 4 tests, each its own transaction (today's row with every
  field mapped; **past/future-only station → 0 rows, asserted alongside `fn_plot_weather` returning
  exactly 1 zero-filled row for the same day, so the reason this function exists is itself under
  test**; per-station isolation + unknown sid; latest `tm` of the day wins). All pass via
  `autorun.bat` (371 PASS / 0 FAIL suite-wide; `crcstate` updated). **Applied to prod 2026-08-01**
  (DDL taken straight from `script02_Funct.sql`, GO-split into 2 batches, one committed SqlClient
  txn; smoke-tested live: **3,690** stations return a row for today, station 07KF015 returns
  `Clear / 16 / 24.6 / 11.2 / 82 % / 10.9 S`, and the reported station 267240 correctly returns 0).
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
