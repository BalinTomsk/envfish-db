SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_river_unfished_json(@country, @state, @river):
    the next un-processed water body of a given type in a state — no fish assigned (isFish = 0) and
    not flagged No Fish (noFish = 0) — as a single JSON object. Duplicates the frontend
    Resources/wbUnFish.aspx endpoint; served natively by docapi's RiverController
    (GET /api/v1/river/unfished) via JdbcRiverQueryRepository.

  Fixture notes:
    - Inserting a lake auto-creates its self-referential source (side=16) and mouth (side=32)
      Tributaries placeholders; vw_lake derives source_state from the side=16 row. So each test sets
      that placeholder's state to a fake 'ZZ' (no real seed data), making the TOP 1 ... ORDER BY
      lake_name deterministic inside its rolled-back transaction.
    - CGNDB is char(5), so codes are 5 chars.

  TEST 1 - a matching un-fished river with two "Throw" tributaries -> found, correct fields + throwing
  TEST 2 - a matching un-fished stream with no Throw tributaries   -> found, throwing = ''
  TEST 3 - a river that HAS fish (isFish = 1)                      -> found = false, fields null
  TEST 4 - a river flagged No Fish (noFish = 1)                    -> found = false
*/
PRINT 'Unit tests for fn_river_unfished_json (next un-processed water body)';
GO
-- ============================================================================
-- TEST 1: un-fished river with two Throw tributaries -> found + throwing list
-- ============================================================================
BEGIN TRAN RUJ_Test1
    declare @test_name sysname = N'RUJ_Test1 [fn_river_unfished_json] : found + throwing'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data
DECLARE @L uniqueidentifier = NEWID(), @T1 uniqueidentifier = NEWID(), @T2 uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, isFish, noFish) VALUES (@L, 2, N'ut-ruj1-river', 'RUJMN', 0, 0);
UPDATE dbo.Tributaries SET state = 'ZZ', country = 'CA' WHERE main_lake_id = @L AND side = 16;
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@T1, 1, N'ut-ruj1-thr-a', 'RUJTA');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@T2, 1, N'ut-ruj1-thr-b', 'RUJTB');
INSERT INTO dbo.Tributaries (main_lake_id, lake_id, side) VALUES (@L, @T1, 2);
INSERT INTO dbo.Tributaries (main_lake_id, lake_id, side) VALUES (@L, @T2, 2);

-- 2. execute
SET @json = dbo.fn_river_unfished_json('CA', 'ZZ', 2);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify
IF   JSON_VALUE(@json, '$.found')     <> 'true'
  OR JSON_VALUE(@json, '$.lake_name') <> N'ut-ruj1-river'
  OR JSON_VALUE(@json, '$.CGNDB')     <> 'RUJMN'
  OR JSON_VALUE(@json, '$.state')     <> 'ZZ'
  OR JSON_VALUE(@json, '$.throwing')  <> 'RUJTA,RUJTB'
   RAISERROR ('TEST 1 FAIL [%dms]: expected found river with throwing RUJTA,RUJTB', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: found river + throwing list returned'

ROLLBACK TRAN RUJ_Test1
GO
-- ============================================================================
-- TEST 2: un-fished stream with no Throw tributaries -> found, throwing = ''
-- ============================================================================
BEGIN TRAN RUJ_Test2
    declare @test_name sysname = N'RUJ_Test2 [fn_river_unfished_json] : found, empty throwing'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, isFish, noFish) VALUES (@L, 4, N'ut-ruj2-stream', 0, 0);
UPDATE dbo.Tributaries SET state = 'ZZ', country = 'CA' WHERE main_lake_id = @L AND side = 16;

-- 2. execute (river = 4 = stream)
SET @json = dbo.fn_river_unfished_json('CA', 'ZZ', 4);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify
IF   JSON_VALUE(@json, '$.found')    <> 'true'
  OR JSON_VALUE(@json, '$.throwing') <> ''
   RAISERROR ('TEST 2 FAIL [%dms]: expected found with empty throwing', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: found river, throwing empty'

ROLLBACK TRAN RUJ_Test2
GO
-- ============================================================================
-- TEST 3: a river that HAS fish (isFish = 1) is skipped -> found = false, fields null
-- ============================================================================
BEGIN TRAN RUJ_Test3
    declare @test_name sysname = N'RUJ_Test3 [fn_river_unfished_json] : isFish=1 skipped'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data (river has fish -> must not be returned)
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, isFish, noFish) VALUES (@L, 2, N'ut-ruj3-river', 1, 0);
UPDATE dbo.Tributaries SET state = 'ZZ', country = 'CA' WHERE main_lake_id = @L AND side = 16;

-- 2. execute
SET @json = dbo.fn_river_unfished_json('CA', 'ZZ', 2);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify
IF   JSON_VALUE(@json, '$.found') <> 'false'
  OR JSON_VALUE(@json, '$.lake_name') IS NOT NULL
   RAISERROR ('TEST 3 FAIL [%dms]: expected found=false for a river that has fish', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fished river skipped (found=false)'

ROLLBACK TRAN RUJ_Test3
GO
-- ============================================================================
-- TEST 4: a river flagged No Fish (noFish = 1) is skipped -> found = false
-- ============================================================================
BEGIN TRAN RUJ_Test4
    declare @test_name sysname = N'RUJ_Test4 [fn_river_unfished_json] : noFish=1 skipped'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data (river flagged No Fish -> must not be returned)
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, isFish, noFish) VALUES (@L, 2, N'ut-ruj4-river', 0, 1);
UPDATE dbo.Tributaries SET state = 'ZZ', country = 'CA' WHERE main_lake_id = @L AND side = 16;

-- 2. execute
SET @json = dbo.fn_river_unfished_json('CA', 'ZZ', 2);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify
IF JSON_VALUE(@json, '$.found') <> 'false'
   RAISERROR ('TEST 4 FAIL [%dms]: expected found=false for a No-Fish river', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: No-Fish river skipped (found=false)'

ROLLBACK TRAN RUJ_Test4
GO
