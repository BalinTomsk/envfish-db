SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_lake_fish_upsert_batch -- batch upsert of lake_fish rows for one water body,
  the write counterpart of dbo.fn_lake_fishing_json (docapi PATCH /api/v1/river/fish/{guid}).

  TEST 1 - new fish (not yet assigned) -> INSERT, action 'inserted', fields stored correctly
  TEST 2 - existing fish with an EMPTY link -> UPDATE, action 'updated'
  TEST 3 - existing fish with a NON-EMPTY link -> left alone, action 'skipped'
  TEST 4 - well-formed guid not in dbo.fish -> action 'unknown_fish', no row created
  TEST 5 - fishId missing/not a guid -> action 'invalid_fish_id'
  TEST 6 - unknown lake_id -> results IS NULL
  TEST 7 - a single call can mix insert + skip in the same batch, one result per input, in order
  TEST 8 - INSERT fires TR_insLakes_Fish (lake.isFish flips 0 -> 1)
*/
PRINT 'Unit tests for dbo.sp_lake_fish_upsert_batch';
GO
-- ============================================================================
-- TEST 1: new fish -> INSERT, action 'inserted'
-- ============================================================================
BEGIN TRAN LFU_Test1
    declare @test_name sysname = N'LFU_Test1 [sp_lake_fish_upsert_batch] : inserts a new species'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results1 nvarchar(max);
DECLARE @Action1 varchar(20);
DECLARE @RowLink nvarchar(max);
DECLARE @RowProbability tinyint;
DECLARE @RowSourceType tinyint;
DECLARE @RowStatus tinyint;
DECLARE @RowYear int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake1     uniqueidentifier = NEWID();
DECLARE @Family1   uniqueidentifier = NEWID();
DECLARE @Fish1     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 1, N'ut-lake-lfu1');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family1, N'ut-family-lfu1', 910101, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish1, N'Carp-lfu1', N'Cyprinus ut-lfu1', @Family1, SYSUTCDATETIME(), SYSUTCDATETIME());

DECLARE @Body1 nvarchar(max) = N'[{"fishId":"' + CONVERT(varchar(36), @Fish1) + N'","link":"http://ut/lfu1","trustLevel":1,"year":2024,"status":2}]';

-- 2. execute unit test (single call -- a second call would find the row already sourced and skip it)
DECLARE @t1 TABLE (results nvarchar(max));
INSERT INTO @t1 EXEC dbo.sp_lake_fish_upsert_batch @Lake1, @Body1;
SELECT @Results1 = results FROM @t1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

SELECT @Action1 = JSON_VALUE(value, '$.action') FROM OPENJSON(@Results1) WHERE JSON_VALUE(value, '$.action') IS NOT NULL;
SELECT @RowLink = link, @RowProbability = probability, @RowSourceType = probability_source_type,
       @RowStatus = status, @RowYear = YEAR(last_catch)
FROM dbo.lake_fish WHERE lake_id = @Lake1 AND fish_id = @Fish1;

-- 3. result verification
IF @Action1 <> 'inserted' OR @RowLink <> N'http://ut/lfu1' OR @RowProbability <> 80
   OR @RowSourceType <> 1 OR @RowStatus <> 2 OR @RowYear <> 2024
   RAISERROR ('TEST 1 FAIL [%dms]: expected inserted row with link/probability/status/year set from the batch', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: new fish inserted with the given fields'

ROLLBACK TRAN LFU_Test1
GO
-- ============================================================================
-- TEST 2: existing fish with an EMPTY link -> UPDATE, action 'updated'
-- ============================================================================
BEGIN TRAN LFU_Test2
    declare @test_name sysname = N'LFU_Test2 [sp_lake_fish_upsert_batch] : fills in a fish missing its link'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Action2 varchar(20);
DECLARE @RowLink2 nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test: fish already assigned, link empty ('')
DECLARE @Lake2     uniqueidentifier = NEWID();
DECLARE @Family2   uniqueidentifier = NEWID();
DECLARE @Fish2     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 1, N'ut-lake-lfu2');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family2, N'ut-family-lfu2', 910102, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish2, N'Pike-lfu2', N'Esox ut-lfu2', @Family2, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, probability, probability_source_type, status, lake_fish_id)
VALUES (@Lake2, @Fish2, SYSUTCDATETIME(), N'', 10, 4, 0, NEWID());

DECLARE @Body2 nvarchar(max) = N'[{"fishId":"' + CONVERT(varchar(36), @Fish2) + N'","link":"http://ut/lfu2-filled","trustLevel":0,"status":1}]';

-- 2. execute unit test
DECLARE @t2 TABLE (results nvarchar(max));
INSERT INTO @t2 EXEC dbo.sp_lake_fish_upsert_batch @Lake2, @Body2;
SELECT @Action2 = JSON_VALUE(results, '$[0].action') FROM @t2;
SELECT @RowLink2 = link FROM dbo.lake_fish WHERE lake_id = @Lake2 AND fish_id = @Fish2;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Action2 <> 'updated' OR @RowLink2 <> N'http://ut/lfu2-filled'
   RAISERROR ('TEST 2 FAIL [%dms]: expected the empty-link row to be updated with the new link', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty-link row filled in and updated'

ROLLBACK TRAN LFU_Test2
GO
-- ============================================================================
-- TEST 3: existing fish with a NON-EMPTY link -> left alone, action 'skipped'
-- ============================================================================
BEGIN TRAN LFU_Test3
    declare @test_name sysname = N'LFU_Test3 [sp_lake_fish_upsert_batch] : never overwrites an already-sourced fish'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Action3 varchar(20);
DECLARE @RowLink3 nvarchar(max);
DECLARE @RowStatus3 tinyint;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test: fish already assigned WITH a real link
DECLARE @Lake3     uniqueidentifier = NEWID();
DECLARE @Family3   uniqueidentifier = NEWID();
DECLARE @Fish3     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 1, N'ut-lake-lfu3');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family3, N'ut-family-lfu3', 910103, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish3, N'Bass-lfu3', N'Micropterus ut-lfu3', @Family3, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, probability, probability_source_type, status, lake_fish_id)
VALUES (@Lake3, @Fish3, SYSUTCDATETIME(), N'http://ut/lfu3-original', 100, 0, 0, NEWID());

-- try to clobber it with a different link and status
DECLARE @Body3 nvarchar(max) = N'[{"fishId":"' + CONVERT(varchar(36), @Fish3) + N'","link":"http://ut/lfu3-hijack","trustLevel":3,"status":2}]';

-- 2. execute unit test
DECLARE @t3 TABLE (results nvarchar(max));
INSERT INTO @t3 EXEC dbo.sp_lake_fish_upsert_batch @Lake3, @Body3;
SELECT @Action3 = JSON_VALUE(results, '$[0].action') FROM @t3;
SELECT @RowLink3 = link, @RowStatus3 = status FROM dbo.lake_fish WHERE lake_id = @Lake3 AND fish_id = @Fish3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Action3 <> 'skipped' OR @RowLink3 <> N'http://ut/lfu3-original' OR @RowStatus3 <> 0
   RAISERROR ('TEST 3 FAIL [%dms]: expected the already-sourced row to be left completely untouched', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: already-sourced fish skipped, original row unchanged'

ROLLBACK TRAN LFU_Test3
GO
-- ============================================================================
-- TEST 4: well-formed guid not in dbo.fish -> action 'unknown_fish'
-- ============================================================================
BEGIN TRAN LFU_Test4
    declare @test_name sysname = N'LFU_Test4 [sp_lake_fish_upsert_batch] : unknown fish guid'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Action4 varchar(20);
DECLARE @RowCount4 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake4 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 1, N'ut-lake-lfu4');
DECLARE @GhostFish uniqueidentifier = NEWID();  -- never inserted into dbo.fish

DECLARE @Body4 nvarchar(max) = N'[{"fishId":"' + CONVERT(varchar(36), @GhostFish) + N'","link":"http://ut/lfu4"}]';

DECLARE @t4 TABLE (results nvarchar(max));
INSERT INTO @t4 EXEC dbo.sp_lake_fish_upsert_batch @Lake4, @Body4;
SELECT @Action4 = JSON_VALUE(results, '$[0].action') FROM @t4;
SELECT @RowCount4 = COUNT(*) FROM dbo.lake_fish WHERE lake_id = @Lake4;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Action4 <> 'unknown_fish' OR @RowCount4 <> 0
   RAISERROR ('TEST 4 FAIL [%dms]: expected unknown_fish and no row created', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unrecognized fish guid reported as unknown_fish, nothing inserted'

ROLLBACK TRAN LFU_Test4
GO
-- ============================================================================
-- TEST 5: fishId missing/not a guid -> action 'invalid_fish_id'
-- ============================================================================
BEGIN TRAN LFU_Test5
    declare @test_name sysname = N'LFU_Test5 [sp_lake_fish_upsert_batch] : malformed fishId'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Action5 varchar(20);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake5 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake5, 1, N'ut-lake-lfu5');

DECLARE @Body5 nvarchar(max) = N'[{"fishId":"not-a-guid","link":"http://ut/lfu5"}]';

DECLARE @t5 TABLE (results nvarchar(max));
INSERT INTO @t5 EXEC dbo.sp_lake_fish_upsert_batch @Lake5, @Body5;
SELECT @Action5 = JSON_VALUE(results, '$[0].action') FROM @t5;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Action5 <> 'invalid_fish_id'
   RAISERROR ('TEST 5 FAIL [%dms]: expected invalid_fish_id for a non-guid fishId', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: malformed fishId reported as invalid_fish_id'

ROLLBACK TRAN LFU_Test5
GO
-- ============================================================================
-- TEST 6: unknown lake_id -> results IS NULL
-- ============================================================================
BEGIN TRAN LFU_Test6
    declare @test_name sysname = N'LFU_Test6 [sp_lake_fish_upsert_batch] : unknown lake_id'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results6 nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @GhostLake uniqueidentifier = NEWID();  -- never inserted into dbo.lake
DECLARE @Body6 nvarchar(max) = N'[]';

DECLARE @t6 TABLE (results nvarchar(max));
INSERT INTO @t6 EXEC dbo.sp_lake_fish_upsert_batch @GhostLake, @Body6;
SELECT @Results6 = results FROM @t6;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Results6 IS NOT NULL
   RAISERROR ('TEST 6 FAIL [%dms]: expected NULL results for an unknown lake_id', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown lake_id returned NULL results'

ROLLBACK TRAN LFU_Test6
GO
-- ============================================================================
-- TEST 7: one call mixes insert + skip, one result per input, in order
-- ============================================================================
BEGIN TRAN LFU_Test7
    declare @test_name sysname = N'LFU_Test7 [sp_lake_fish_upsert_batch] : mixed batch, one result per input in order'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Count7 int;
DECLARE @Results7 nvarchar(max);
DECLARE @Action7a varchar(20), @Action7b varchar(20);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake7     uniqueidentifier = NEWID();
DECLARE @Family7   uniqueidentifier = NEWID();
DECLARE @FishNew7  uniqueidentifier = NEWID();
DECLARE @FishOld7  uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake7, 1, N'ut-lake-lfu7');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family7, N'ut-family-lfu7', 910107, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@FishNew7, N'Walleye-lfu7', N'Sander ut-lfu7', @Family7, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@FishOld7, N'Perch-lfu7', N'Perca ut-lfu7', @Family7, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, probability, probability_source_type, status, lake_fish_id)
VALUES (@Lake7, @FishOld7, SYSUTCDATETIME(), N'http://ut/lfu7-already-sourced', 100, 0, 0, NEWID());

DECLARE @Body7 nvarchar(max) =
    N'[{"fishId":"' + CONVERT(varchar(36), @FishNew7) + N'","link":"http://ut/lfu7-new"},' +
    N' {"fishId":"' + CONVERT(varchar(36), @FishOld7) + N'","link":"http://ut/lfu7-try-overwrite"}]';

DECLARE @t7 TABLE (results nvarchar(max));
INSERT INTO @t7 EXEC dbo.sp_lake_fish_upsert_batch @Lake7, @Body7;
SELECT @Results7 = results FROM @t7;
SELECT @Count7 = COUNT(*) FROM OPENJSON(@Results7);
SELECT @Action7a = JSON_VALUE(@Results7, '$[0].action'), @Action7b = JSON_VALUE(@Results7, '$[1].action');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Count7 <> 2 OR @Action7a <> 'inserted' OR @Action7b <> 'skipped'
   RAISERROR ('TEST 7 FAIL [%dms]: expected 2 results in order, [inserted, skipped]', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mixed batch produced one ordered result per input'

ROLLBACK TRAN LFU_Test7
GO
-- ============================================================================
-- TEST 8: INSERT fires TR_insLakes_Fish (lake.isFish flips 0 -> 1)
-- ============================================================================
BEGIN TRAN LFU_Test8
    declare @test_name sysname = N'LFU_Test8 [sp_lake_fish_upsert_batch] : insert still fires the isFish trigger'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @IsFish8 bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake8     uniqueidentifier = NEWID();
DECLARE @Family8   uniqueidentifier = NEWID();
DECLARE @Fish8     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, isFish) VALUES (@Lake8, 1, N'ut-lake-lfu8', 0);
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family8, N'ut-family-lfu8', 910108, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish8, N'Muskie-lfu8', N'Esox ut-lfu8', @Family8, SYSUTCDATETIME(), SYSUTCDATETIME());

DECLARE @Body8 nvarchar(max) = N'[{"fishId":"' + CONVERT(varchar(36), @Fish8) + N'","link":"http://ut/lfu8"}]';

EXEC dbo.sp_lake_fish_upsert_batch @Lake8, @Body8;
SELECT @IsFish8 = isFish FROM dbo.lake WHERE lake_id = @Lake8;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @IsFish8 IS NULL OR @IsFish8 <> 1
   RAISERROR ('TEST 8 FAIL [%dms]: expected lake.isFish = 1 after the batch insert', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: isFish trigger fired on the batch-inserted row'

ROLLBACK TRAN LFU_Test8
GO
