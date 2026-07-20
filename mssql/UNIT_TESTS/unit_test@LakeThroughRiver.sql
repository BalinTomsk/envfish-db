SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lake_through_river(@lake):
    the single watercourse (river/stream/creek/canal) recorded as flowing THROUGH the given
    lake/pond/reservoir (Tributaries side=2, Main_Lake_id = watercourse, Lake_id = lake).
    A through-watercourse is the water entering and leaving the lake, so it IS the lake's
    source and mouth point.

  Caller:
    - FishTracker.Editor.EditLakeLink.ButtonSubmit_Click (auto-fill of an empty Source/Mouth point).

  Also covers the reverse lookup dbo.fn_river_through_lakes(@river): the lakes/ponds/reservoirs a
  given watercourse flows through (caller: FishTracker.Resources.wfRiverViewer.BuildThroughLakesNote,
  the "Lake through" line on the river view).

  TEST 1 - a lake with exactly one through-river returns that river's id
  TEST 2 - a lake with no through-watercourse returns NULL
  TEST 3 - a lake with two distinct through-rivers is ambiguous and returns NULL
  TEST 4 - fn_river_through_lakes lists the two lakes a river flows through
  TEST 5 - fn_river_through_lakes returns no rows for a river with no through-lakes
*/
PRINT 'Unit tests for fn_lake_through_river (through-watercourse of a lake)';
GO
-- ============================================================================
-- TEST 1: a lake with exactly one through-river returns that river's id
-- ============================================================================
BEGIN TRAN LTR_Test1
    declare @test_name sysname = N'LTR_Test1 [fn_lake_through_river] : single through-river'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Result1 uniqueidentifier;
DECLARE @River1 uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake1 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 1, N'ut-lake-ltr1');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River1, 2, N'ut-river-ltr1');
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@River1, @Lake1, 2);

-- 2. execute unit test
SET @Result1 = dbo.fn_lake_through_river(@Lake1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Result1 IS NULL OR @Result1 <> @River1
   RAISERROR ('TEST 1 FAIL [%dms]: expected the through-river id', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: single through-river id returned'

ROLLBACK TRAN LTR_Test1
GO
-- ============================================================================
-- TEST 2: a lake with no through-watercourse returns NULL
-- ============================================================================
BEGIN TRAN LTR_Test2
    declare @test_name sysname = N'LTR_Test2 [fn_lake_through_river] : no through-watercourse'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Result2 uniqueidentifier = NEWID();   -- sentinel; must come back NULL
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake2 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 1, N'ut-lake-ltr2');

-- 2. execute unit test
SET @Result2 = dbo.fn_lake_through_river(@Lake2);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Result2 IS NOT NULL
   RAISERROR ('TEST 2 FAIL [%dms]: expected NULL for a lake with no through-watercourse', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: NULL returned when nothing flows through'

ROLLBACK TRAN LTR_Test2
GO
-- ============================================================================
-- TEST 3: a lake with two distinct through-rivers is ambiguous and returns NULL
-- ============================================================================
BEGIN TRAN LTR_Test3
    declare @test_name sysname = N'LTR_Test3 [fn_lake_through_river] : two through-rivers -> ambiguous'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Result3 uniqueidentifier = NEWID();   -- sentinel; must come back NULL
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake3   uniqueidentifier = NEWID();
DECLARE @River3a uniqueidentifier = NEWID();
DECLARE @River3b uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 8192, N'ut-reservoir-ltr3');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River3a, 2, N'ut-river-ltr3a');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River3b, 64, N'ut-creek-ltr3b');
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@River3a, @Lake3, 2);
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@River3b, @Lake3, 2);

-- 2. execute unit test
SET @Result3 = dbo.fn_lake_through_river(@Lake3);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Result3 IS NOT NULL
   RAISERROR ('TEST 3 FAIL [%dms]: expected NULL for an ambiguous two-river lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: NULL returned for the ambiguous case'

ROLLBACK TRAN LTR_Test3
GO
-- ============================================================================
-- TEST 4: fn_river_through_lakes lists the two lakes a river flows through
-- ============================================================================
BEGIN TRAN LTR_Test4
    declare @test_name sysname = N'LTR_Test4 [fn_river_through_lakes] : two through-lakes listed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt4 int, @Named4 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @River4 uniqueidentifier = NEWID();
DECLARE @Lake4a uniqueidentifier = NEWID();
DECLARE @Lake4b uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River4, 2, N'ut-river-ltr4');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4a, 1, N'ut-lake-ltr4a');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4b, 8, N'ut-pond-ltr4b');
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@River4, @Lake4a, 2);
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@River4, @Lake4b, 2);

-- 2. execute unit test
SELECT @Cnt4 = COUNT(*), @Named4 = COUNT(lake_name) FROM dbo.fn_river_through_lakes(@River4);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Cnt4 IS NULL OR @Cnt4 <> 2 OR @Named4 <> 2
   RAISERROR ('TEST 4 FAIL [%dms]: expected 2 named through-lakes for the river', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: both through-lakes listed with names'

ROLLBACK TRAN LTR_Test4
GO
-- ============================================================================
-- TEST 5: fn_river_through_lakes returns no rows for a river with no through-lakes
-- ============================================================================
BEGIN TRAN LTR_Test5
    declare @test_name sysname = N'LTR_Test5 [fn_river_through_lakes] : no through-lakes -> empty'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt5 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @River5 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River5, 64, N'ut-creek-ltr5');

-- 2. execute unit test
SELECT @Cnt5 = COUNT(*) FROM dbo.fn_river_through_lakes(@River5);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Cnt5 IS NULL OR @Cnt5 <> 0
   RAISERROR ('TEST 5 FAIL [%dms]: expected 0 rows for a creek with no through-lakes', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty result for a creek with no through-lakes'

ROLLBACK TRAN LTR_Test5
GO
