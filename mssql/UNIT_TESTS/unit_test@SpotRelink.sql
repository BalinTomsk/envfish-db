SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_spot_relink(@apply, @relinked OUT, @unassigned OUT): repairs dbo.Spot.lake_Id.
  The 376 Ontario fishing spots were loaded in 2014 with the lake chosen by NAME only, so "Trout Lake" spots hang on the
  Trout Lake in the Northwest Territories (230 of 321 rows sat more than 2 degrees from their lake, 50 point at a lake
  that no longer exists). The procedure moves a misplaced spot to the same-named lake that is really at its coordinates,
  and un-assigns (zero guid) the ones it cannot place. Readers: Resources/wfRiverViewer.aspx.cs (via fn_lake_view_info).

  TEST 1 - far from its lake, a same-named lake sits at the spot  -> moved to that lake
  TEST 2 - lake_Id of a lake that does not exist                  -> un-assigned
  TEST 3 - spot already next to its lake                          -> untouched
  TEST 4 - far from its lake, no same-named lake near the spot    -> un-assigned
  TEST 5 - 100 km from its lake (between near and far), no candidate -> untouched
  TEST 6 - @apply = 0                                             -> nothing written, but counted
  TEST 7 - run twice                                              -> second run changes nothing
  TEST 8 - two same-named candidates (10 km and 40 km)            -> the nearer one
*/
PRINT 'Unit tests for sp_spot_relink (Spot rows attached to a same-named lake far away)';
GO
-- ============================================================================
-- TEST 1: misplaced spot -> same-named lake at the spot
-- ============================================================================
BEGIN TRAN SR_Test1
    declare @test_name sysname = N'SR_Test1 [sp_spot_relink] : relink to same-named lake'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier, @expect uniqueidentifier;
DECLARE @NT uniqueidentifier = NEWID(), @ON uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@NT, 1, N'Utsprl Lake'), (@ON, 1, N'Utsprl Lake');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@NT, 62.0, -113.0, 'NT'), (@ON, 46.0, -80.0, 'ON')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.001, -80.001, @NT);

EXEC dbo.sp_spot_relink;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
SET @expect = @ON;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> @expect
   RAISERROR ('TEST 1 FAIL [%dms]: spot must move to the same-named lake at its coordinates', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spot moved to the same-named lake at its coordinates'

ROLLBACK TRAN SR_Test1
GO
-- ============================================================================
-- TEST 2: dangling lake_Id -> un-assigned
-- ============================================================================
BEGIN TRAN SR_Test2
    declare @test_name sysname = N'SR_Test2 [sp_spot_relink] : lake gone'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.0, -80.0, NEWID());

EXEC dbo.sp_spot_relink;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> '00000000-0000-0000-0000-000000000000'
   RAISERROR ('TEST 2 FAIL [%dms]: spot of a missing lake must be un-assigned (zero guid)', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spot of a missing lake un-assigned'

ROLLBACK TRAN SR_Test2
GO
-- ============================================================================
-- TEST 3: spot next to its lake -> untouched
-- ============================================================================
BEGIN TRAN SR_Test3
    declare @test_name sysname = N'SR_Test3 [sp_spot_relink] : correct spot'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @ON uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@ON, 1, N'Utsprl Lake');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@ON, 46.0, -80.0, 'ON')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.02, -80.02, @ON);

EXEC dbo.sp_spot_relink;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> @ON
   RAISERROR ('TEST 3 FAIL [%dms]: a spot next to its lake must not be touched', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spot next to its lake untouched'

ROLLBACK TRAN SR_Test3
GO
-- ============================================================================
-- TEST 4: far from its lake, nothing of that name near the spot -> un-assigned
-- ============================================================================
BEGIN TRAN SR_Test4
    declare @test_name sysname = N'SR_Test4 [sp_spot_relink] : far, no candidate'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @NT uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@NT, 1, N'Utsprl Solo');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@NT, 62.0, -113.0, 'NT')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.0, -80.0, @NT);

EXEC dbo.sp_spot_relink;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> '00000000-0000-0000-0000-000000000000'
   RAISERROR ('TEST 4 FAIL [%dms]: a spot far from its lake with no candidate must be un-assigned', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: far spot with no candidate un-assigned'

ROLLBACK TRAN SR_Test4
GO
-- ============================================================================
-- TEST 5: 100 km away (between near 55 km and far 220 km), no candidate -> untouched
-- ============================================================================
BEGIN TRAN SR_Test5
    declare @test_name sysname = N'SR_Test5 [sp_spot_relink] : middling distance'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @L uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsprl Mid');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@L, 46.9, -80.0, 'ON')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.0, -80.0, @L);

EXEC dbo.sp_spot_relink;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> @L
   RAISERROR ('TEST 5 FAIL [%dms]: a spot 100 km from its lake with no candidate must be left alone', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spot 100 km from its lake left alone'

ROLLBACK TRAN SR_Test5
GO
-- ============================================================================
-- TEST 6: @apply = 0 reports but writes nothing
-- ============================================================================
BEGIN TRAN SR_Test6
    declare @test_name sysname = N'SR_Test6 [sp_spot_relink] : dry run'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier, @relinked int;
DECLARE @NT uniqueidentifier = NEWID(), @ON uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@NT, 1, N'Utsprl Lake'), (@ON, 1, N'Utsprl Lake');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@NT, 62.0, -113.0, 'NT'), (@ON, 46.0, -80.0, 'ON')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.001, -80.001, @NT);

EXEC dbo.sp_spot_relink @apply = 0, @relinked = @relinked OUTPUT;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> @NT OR ISNULL(@relinked, 0) < 1
   RAISERROR ('TEST 6 FAIL [%dms]: dry run must leave the spot on its lake and still count it', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: dry run wrote nothing and counted the spot'

ROLLBACK TRAN SR_Test6
GO
-- ============================================================================
-- TEST 7: second run changes nothing
-- ============================================================================
BEGIN TRAN SR_Test7
    declare @test_name sysname = N'SR_Test7 [sp_spot_relink] : idempotent'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier, @again int, @second int;
DECLARE @NT uniqueidentifier = NEWID(), @ON uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@NT, 1, N'Utsprl Lake'), (@ON, 1, N'Utsprl Lake');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@NT, 62.0, -113.0, 'NT'), (@ON, 46.0, -80.0, 'ON')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.001, -80.001, @NT);

EXEC dbo.sp_spot_relink;
EXEC dbo.sp_spot_relink @relinked = @again OUTPUT, @unassigned = @second OUTPUT;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> @ON OR ISNULL(@again, -1) <> 0 OR ISNULL(@second, -1) <> 0
   RAISERROR ('TEST 7 FAIL [%dms]: a second run must change nothing', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: second run changed nothing'

ROLLBACK TRAN SR_Test7
GO
-- ============================================================================
-- TEST 8: two candidates -> the nearer
-- ============================================================================
BEGIN TRAN SR_Test8
    declare @test_name sysname = N'SR_Test8 [sp_spot_relink] : nearest candidate'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @got uniqueidentifier;
DECLARE @NT uniqueidentifier = NEWID(), @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@NT, 1, N'Utsprl Lake'), (@A, 1, N'Utsprl Lake'), (@B, 1, N'Utsprl Lake');
-- a new lake already has its (empty) source and mouth rows (sides 16 and 32): place them
UPDATE t SET lat = v.lat, lon = v.lon, Country = 'CA', State = v.st FROM dbo.Tributaries t
  JOIN (VALUES (@NT, 62.0, -113.0, 'NT'), (@A, 46.09, -80.0, 'ON'), (@B, 46.36, -80.0, 'ON')) v(id, lat, lon, st) ON t.Main_Lake_id = v.id AND t.side IN (16, 32);   -- ~40 km north
INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@S, 46.0, -80.0, @NT);

EXEC dbo.sp_spot_relink;

SET @got = (SELECT lake_Id FROM dbo.Spot WHERE spot_id = @S);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @got IS NULL OR @got <> @A
   RAISERROR ('TEST 8 FAIL [%dms]: with two candidates the nearer lake must win', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: nearer of two candidates chosen'

ROLLBACK TRAN SR_Test8
GO
