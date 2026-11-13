SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_spot_link_by_name(@source, @max_km, @apply, @linked OUT): gives an un-assigned spot (lake_Id = zero guid)
  the water body its name says (spot name contains the lake name, lake point within @max_km, longest name then nearest).
  Spots come from dbo.sp_spot_upsert (see unit_test@SpotImport.sql). Readers of the result: Resources/wfRiverViewer.aspx.cs
  (via dbo.fn_lake_view_info 'fishspot').

  TEST 1 - spot named after a lake 3 km away        -> linked to that lake
  TEST 2 - same-named lake 30 km away (max 20)      -> not linked
  TEST 3 - two lakes whose names are both in the site name -> the longer name wins
  TEST 4 - @apply = 0 counts only; second run links nothing; legacy spot without a name untouched
*/
PRINT 'Unit tests for sp_spot_link_by_name (spots named after a lake)';
GO
-- ============================================================================
-- TEST 1: named after a lake 3 km away -> linked
-- ============================================================================
BEGIN TRAN SL_Test1
    declare @test_name sysname = N'SL_Test1 [sp_spot_link_by_name] : link'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier, @linked int;
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsimp Lake');
UPDATE t SET lat = 45.0, lon = -79.0, Country = 'CA', State = 'ON' FROM dbo.Tributaries t WHERE t.Main_Lake_id = @L AND t.side IN (16, 32);
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000007","name":"Utsimp Lake Access Point","lat":45.02,"lon":-79.0}]';
EXEC dbo.sp_spot_link_by_name @source = 'UTSI', @linked = @linked OUTPUT;
SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000007');
IF @got <> @L OR @linked <> 1 SET @got = NULL;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL
   RAISERROR ('TEST 1 FAIL [%dms]: a spot named after a lake 3 km away must be linked to it', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spot linked to the same-named lake nearby'

ROLLBACK TRAN SL_Test1
GO
-- ============================================================================
-- TEST 2: same-named lake too far -> not linked
-- ============================================================================
BEGIN TRAN SL_Test2
    declare @test_name sysname = N'SL_Test2 [sp_spot_link_by_name] : too far'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsimp Lake');
UPDATE t SET lat = 45.0, lon = -79.0, Country = 'CA', State = 'ON' FROM dbo.Tributaries t WHERE t.Main_Lake_id = @L AND t.side IN (16, 32);
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000008","name":"Utsimp Lake Access Point","lat":45.27,"lon":-79.0}]';   -- ~30 km north
EXEC dbo.sp_spot_link_by_name @source = 'UTSI', @max_km = 20;
SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000008');
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> '00000000-0000-0000-0000-000000000000'
   RAISERROR ('TEST 2 FAIL [%dms]: a same-named lake 30 km away must not be linked (max 20 km)', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lake 30 km away not linked'

ROLLBACK TRAN SL_Test2
GO
-- ============================================================================
-- TEST 3: longer lake name wins
-- ============================================================================
BEGIN TRAN SL_Test3
    declare @test_name sysname = N'SL_Test3 [sp_spot_link_by_name] : longest name'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@A, 1, N'Utsimp Lake'), (@B, 1, N'Utsimp Lake North');
UPDATE t SET lat = CASE WHEN t.Main_Lake_id = @A THEN 45.00 ELSE 45.10 END, lon = -79.0, Country = 'CA', State = 'ON'
  FROM dbo.Tributaries t WHERE t.Main_Lake_id IN (@A, @B) AND t.side IN (16, 32);
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000009","name":"Utsimp Lake North Access","lat":45.01,"lon":-79.0}]';   -- nearer to A, but the name says B
EXEC dbo.sp_spot_link_by_name @source = 'UTSI';
SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000009');
IF @got <> @B SET @got = NULL;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL
   RAISERROR ('TEST 3 FAIL [%dms]: with two lake names in the site name the longer one must win', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: longer lake name wins'

ROLLBACK TRAN SL_Test3
GO
-- ============================================================================
-- TEST 4: dry run, idempotence, legacy spot untouched
-- ============================================================================
BEGIN TRAN SL_Test4
    declare @test_name sysname = N'SL_Test4 [sp_spot_link_by_name] : dry run and rerun'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ok bit = 0, @dry int, @first int, @again int;
DECLARE @L uniqueidentifier = NEWID(), @legacy uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsimp Lake');
UPDATE t SET lat = 45.0, lon = -79.0, Country = 'CA', State = 'ON' FROM dbo.Tributaries t WHERE t.Main_Lake_id = @L AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@legacy, 45.01, -79.0, '00000000-0000-0000-0000-000000000000');   -- no name
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000010","name":"Utsimp Lake Access Point","lat":45.02,"lon":-79.0}]';

EXEC dbo.sp_spot_link_by_name @source = 'UTSI', @apply = 0, @linked = @dry OUTPUT;
SET @ok = CASE WHEN (SELECT lake_Id FROM dbo.Spot WHERE spot_source_id = '900000010') = '00000000-0000-0000-0000-000000000000' THEN 1 ELSE 0 END;
EXEC dbo.sp_spot_link_by_name @source = 'UTSI', @linked = @first OUTPUT;
EXEC dbo.sp_spot_link_by_name @source = 'UTSI', @linked = @again OUTPUT;
IF ISNULL(@dry, 0) <> 1 OR ISNULL(@first, 0) <> 1 OR ISNULL(@again, -1) <> 0 SET @ok = 0;
IF (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @legacy) <> '00000000-0000-0000-0000-000000000000' SET @ok = 0;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ok <> 1
   RAISERROR ('TEST 4 FAIL [%dms]: dry run writes nothing, a rerun links nothing, a spot without a name is untouched', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: dry run, rerun and legacy spot behave'

ROLLBACK TRAN SL_Test4
GO
