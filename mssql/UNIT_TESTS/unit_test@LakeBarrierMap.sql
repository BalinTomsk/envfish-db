SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lake_barrier_map(@lake_id): the dams (dbo.lake_dam) and waterfalls (dbo.lake_waterfall) of one water body with the angle of the
  short symbol the river viewer map draws for each (Resources/wfRiverViewer.aspx.cs GetBarrierPoints).
  bar_deg is a CSS clockwise rotation of a horizontal bar, 0..179: across the river centre line, along a lake outline.

  TEST 1 - dam on an east-west river line           -> bar across the river (90)
  TEST 2 - dam on the north edge of a lake outline  -> bar along the shore (0)
  TEST 3 - dam of a water body without a shape      -> listed, bar_deg NULL, other water bodies' dams left out
  TEST 4 - dam exactly on the river line (the usual CHN case; ShortestLineTo is EMPTY there) -> still 90
  TEST 5 - a dam and a waterfall on one river       -> two rows told apart by barrier, the waterfall across too (90)
*/
PRINT 'Unit tests for fn_lake_barrier_map (dam bars and waterfall waves on the river viewer map)';
GO
-- ============================================================================
-- TEST 1: river line -> bar across it
-- ============================================================================
BEGIN TRAN LBM_Test1
    declare @test_name sysname = N'LBM_Test1 [fn_lake_barrier_map] : river line'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @deg int, @kind varchar(8);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlbm River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@L, geography::STGeomFromText('LINESTRING(-66.30 46.10, -66.20 46.10, -66.10 46.10)', 4326), 1);
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lake_dam_name, lat, lon, link_method)
VALUES (NEWID(), @L, N'Utlbm Dam', 46.1001, -66.2, 'manual');
SELECT @deg = bar_deg, @kind = kind FROM dbo.fn_lake_barrier_map(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @deg IS NULL OR @deg <> 90 OR @kind <> 'line'
   RAISERROR ('TEST 1 FAIL [%dms]: dam on an east-west river must get a 90 deg bar', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: river line -> bar across it (90)'

ROLLBACK TRAN LBM_Test1
GO
-- ============================================================================
-- TEST 2: lake outline -> bar along the shore
-- ============================================================================
BEGIN TRAN LBM_Test2
    declare @test_name sysname = N'LBM_Test2 [fn_lake_barrier_map] : lake outline'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @deg int, @kind varchar(8);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utlbm Lake');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@L, geography::STGeomFromText('POLYGON((-66.30 46.00, -66.10 46.00, -66.10 46.10, -66.30 46.10, -66.30 46.00))', 4326), 2);
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lat, lon, link_method)
VALUES (NEWID(), @L, 46.1002, -66.2, 'chn_polygon');
SELECT @deg = bar_deg, @kind = kind FROM dbo.fn_lake_barrier_map(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @deg IS NULL OR @deg <> 0 OR @kind <> 'outline'
   RAISERROR ('TEST 2 FAIL [%dms]: dam on a north shore must get a 0 deg bar', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lake outline -> bar along the shore (0)'

ROLLBACK TRAN LBM_Test2
GO
-- ============================================================================
-- TEST 3: no shape -> listed with NULL bar; other water bodies left out
-- ============================================================================
BEGIN TRAN LBM_Test3
    declare @test_name sysname = N'LBM_Test3 [fn_lake_barrier_map] : no shape'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @n int, @nulls int;
DECLARE @L uniqueidentifier = NEWID(), @Other uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlbm Bare River'), (@Other, 2, N'Utlbm Other');
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lat, lon, link_method)
VALUES (NEWID(), @L, 45.5, -64.5, 'manual'), (NEWID(), @Other, 45.6, -64.6, 'manual');
SELECT @n = COUNT(*), @nulls = SUM(CASE WHEN bar_deg IS NULL THEN 1 ELSE 0 END) FROM dbo.fn_lake_barrier_map(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n IS NULL OR @n <> 1 OR @nulls <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: own dam only, with a NULL bar when no shape', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no shape -> own dam, bar_deg NULL'

ROLLBACK TRAN LBM_Test3
GO
-- ============================================================================
-- TEST 4: dam exactly on the line -> still oriented
-- ============================================================================
BEGIN TRAN LBM_Test4
    declare @test_name sysname = N'LBM_Test4 [fn_lake_barrier_map] : on the line'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @deg int;
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlbm On River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@L, geography::STGeomFromText('LINESTRING(-66.30 46.10, -66.20 46.10, -66.10 46.10)', 4326), 1);
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lat, lon, link_method)
VALUES (NEWID(), @L, 46.10, -66.20, 'chn_network');
SELECT @deg = bar_deg FROM dbo.fn_lake_barrier_map(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @deg IS NULL OR @deg <> 90
   RAISERROR ('TEST 4 FAIL [%dms]: dam lying on the river line must get a 90 deg bar', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: dam on the line -> bar across it (90)'

ROLLBACK TRAN LBM_Test4
GO
-- ============================================================================
-- TEST 5: dam + waterfall -> both listed, told apart, both oriented
-- ============================================================================
BEGIN TRAN LBM_Test5
    declare @test_name sysname = N'LBM_Test5 [fn_lake_barrier_map] : waterfall'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @n int, @wdeg int, @wname nvarchar(128), @dams int;
DECLARE @L uniqueidentifier = NEWID(), @W uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlbm Falls River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@L, geography::STGeomFromText('LINESTRING(-66.30 46.10, -66.20 46.10, -66.10 46.10)', 4326), 1);
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lat, lon, link_method)
VALUES (NEWID(), @L, 46.10, -66.25, 'chn_network');
INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lake_id, lake_waterfall_name, lake_waterfall_type, lat, lon, link_method)
VALUES (@W, @L, N'Utlbm Falls', N'Falls', 46.10, -66.15, 'chn_network');
SELECT @n = COUNT(*), @dams = SUM(CASE WHEN barrier = 'dam' THEN 1 ELSE 0 END) FROM dbo.fn_lake_barrier_map(@L);
SELECT @wdeg = bar_deg, @wname = name FROM dbo.fn_lake_barrier_map(@L) WHERE barrier = 'waterfall' AND id = @W;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n IS NULL OR @n <> 2 OR @dams <> 1 OR @wdeg IS NULL OR @wdeg <> 90 OR @wname <> N'Utlbm Falls'
   RAISERROR ('TEST 5 FAIL [%dms]: dam + waterfall listed apart, waterfall at 90 deg', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: dam + waterfall, waterfall across (90)'

ROLLBACK TRAN LBM_Test5
GO
