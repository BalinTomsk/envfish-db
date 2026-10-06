SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.lake_waterfall and dbo.lake_dam: waterfalls and dams, each optionally linked to the water
  body (dbo.Lake) it sits on. Loaded from CGNDB named features and the Canadian Hydrospatial Network (CHN)
  by chn_import/build_lake_barriers.sql; no reader yet (planned: docapi / MCP water-body tools).

  Fixture notes: CGNDB values start with 'Z' (char(5)) so they never collide with real codes.

  TEST 1 - a waterfall linked to a lake is stored with its link and a default stamp
  TEST 2 - an unlinked, unnamed waterfall (CHN-only) is allowed
  TEST 3 - deleting the lake (sp_del_river) keeps the waterfall and clears its link (ON DELETE SET NULL)
  TEST 4 - waterfall CHECKs: latitude out of range and an unknown link_method are refused
  TEST 5 - a linked waterfall must say how it was linked (link_method)
  TEST 6 - CGNDB, chn_feature_id and cabd_id are each unique per table
  TEST 7 - a dam linked to a lake survives the lake's deletion, unlinked
  TEST 8 - dam CHECKs: longitude out of range is refused
  TEST 9 - both tables are registered for replication in merge_table (level 2)
  TEST 10 - sp_MergeLakes moves both kinds of rows to the surviving water body
*/
PRINT 'Unit tests for lake_waterfall / lake_dam (barriers on water bodies)';
GO
-- ============================================================================
-- TEST 1: a waterfall linked to a lake
-- ============================================================================
BEGIN TRAN LWD_Test1
    declare @test_name sysname = N'LWD_Test1 [lake_waterfall] : linked insert'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @L uniqueidentifier = NEWID(), @W uniqueidentifier = NEWID();
DECLARE @lake uniqueidentifier, @method varchar(16), @stamp datetime2;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlwd River');
INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lake_id, lake_waterfall_name, lake_waterfall_type, CGNDB, lat, lon, province, link_method, link_distance_m)
VALUES (@W, @L, N'Utlwd Falls', N'Falls', 'ZLWD1', 46.5, -66.5, 'NB', 'chn_network', 12);

SELECT @lake = lake_id, @method = link_method, @stamp = lake_waterfall_stamp FROM dbo.lake_waterfall WHERE lake_waterfall_id = @W;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @lake IS NULL OR @lake <> @L OR @method <> 'chn_network' OR @stamp IS NULL
   RAISERROR ('TEST 1 FAIL [%dms]: linked waterfall must keep lake_id, link_method, stamp', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: linked waterfall stored with default stamp'

ROLLBACK TRAN LWD_Test1
GO
-- ============================================================================
-- TEST 2: an unlinked, unnamed waterfall (CHN feature only)
-- ============================================================================
BEGIN TRAN LWD_Test2
    declare @test_name sysname = N'LWD_Test2 [lake_waterfall] : unlinked unnamed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @W uniqueidentifier = NEWID(), @n int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake_waterfall (lake_waterfall_id, chn_feature_id, cabd_id, lat, lon, province)
VALUES (@W, @W, 'utlwd-cabd-2', 45.1, -64.2, 'NS');
SET @n = (SELECT COUNT(*) FROM dbo.lake_waterfall WHERE lake_waterfall_id = @W AND lake_id IS NULL AND lake_waterfall_name IS NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@n, 0) <> 1
   RAISERROR ('TEST 2 FAIL [%dms]: an unlinked, unnamed waterfall must be accepted', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unlinked unnamed waterfall accepted'

ROLLBACK TRAN LWD_Test2
GO
-- ============================================================================
-- TEST 3: deleting the lake keeps the waterfall, unlinked
-- ============================================================================
BEGIN TRAN LWD_Test3
    declare @test_name sysname = N'LWD_Test3 [lake_waterfall] : lake deleted'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @L uniqueidentifier = NEWID(), @W uniqueidentifier = NEWID(), @n int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlwd Doomed River');
INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lake_id, lake_waterfall_name, lat, lon, link_method)
VALUES (@W, @L, N'Utlwd Doomed Falls', 47.0, -67.0, 'name_near');
EXEC dbo.sp_del_river @L;   -- the app's delete path (Tributaries first, then Lake)
SET @n = (SELECT COUNT(*) FROM dbo.lake_waterfall WHERE lake_waterfall_id = @W AND lake_id IS NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@n, 0) <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: lake delete must keep the waterfall and clear lake_id', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lake delete keeps waterfall, unlinked'

ROLLBACK TRAN LWD_Test3
GO
-- ============================================================================
-- TEST 4: waterfall CHECK constraints
-- ============================================================================
BEGIN TRAN LWD_Test4
    declare @test_name sysname = N'LWD_Test4 [lake_waterfall] : checks'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @e1 int = 0, @e2 int = 0;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

BEGIN TRY
    INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lat, lon) VALUES (NEWID(), 91.0, -66.0);
END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH
BEGIN TRY
    INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lat, lon, link_method) VALUES (NEWID(), 46.0, -66.0, 'guess');
END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @e1 <> 547 OR @e2 <> 547
   RAISERROR ('TEST 4 FAIL [%dms]: bad latitude and unknown link_method must be refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bad latitude / link_method refused'

ROLLBACK TRAN LWD_Test4
GO
-- ============================================================================
-- TEST 5: a linked waterfall must carry link_method
-- ============================================================================
BEGIN TRAN LWD_Test5
    declare @test_name sysname = N'LWD_Test5 [lake_waterfall] : link without method'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @L uniqueidentifier = NEWID(), @e int = 0;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utlwd Lake');
BEGIN TRY
    INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lake_id, lat, lon) VALUES (NEWID(), @L, 46.0, -66.0);
END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @e <> 547
   RAISERROR ('TEST 5 FAIL [%dms]: lake_id without link_method must be refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: link without link_method refused'

ROLLBACK TRAN LWD_Test5
GO
-- ============================================================================
-- TEST 6: source ids are unique (CGNDB, chn_feature_id, cabd_id)
-- ============================================================================
BEGIN TRAN LWD_Test6
    declare @test_name sysname = N'LWD_Test6 [lake_waterfall, lake_dam] : unique source ids'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @e1 int = 0, @e2 int = 0, @e3 int = 0, @e4 int = 0;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake_waterfall (lake_waterfall_id, CGNDB, chn_feature_id, cabd_id, lat, lon) VALUES (NEWID(), 'ZLWD6', @F, 'utlwd-cabd-6', 46.0, -66.0);
BEGIN TRY INSERT INTO dbo.lake_waterfall (lake_waterfall_id, CGNDB, lat, lon) VALUES (NEWID(), 'ZLWD6', 46.0, -66.0); END TRY BEGIN CATCH SET @e1 = ERROR_NUMBER(); END CATCH
BEGIN TRY INSERT INTO dbo.lake_waterfall (lake_waterfall_id, chn_feature_id, lat, lon) VALUES (NEWID(), @F, 46.0, -66.0); END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
BEGIN TRY INSERT INTO dbo.lake_waterfall (lake_waterfall_id, cabd_id, lat, lon) VALUES (NEWID(), 'utlwd-cabd-6', 46.0, -66.0); END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
INSERT INTO dbo.lake_dam (lake_dam_id, CGNDB, lat, lon) VALUES (NEWID(), 'ZLWD7', 46.0, -66.0);
BEGIN TRY INSERT INTO dbo.lake_dam (lake_dam_id, CGNDB, lat, lon) VALUES (NEWID(), 'ZLWD7', 46.0, -66.0); END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @e1 NOT IN (2601, 2627) OR @e2 NOT IN (2601, 2627) OR @e3 NOT IN (2601, 2627) OR @e4 NOT IN (2601, 2627)
   RAISERROR ('TEST 6 FAIL [%dms]: duplicate CGNDB / CHN / CABD ids must be refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: duplicate source ids refused'

ROLLBACK TRAN LWD_Test6
GO
-- ============================================================================
-- TEST 7: a dam survives its lake's deletion, unlinked
-- ============================================================================
BEGIN TRAN LWD_Test7
    declare @test_name sysname = N'LWD_Test7 [lake_dam] : lake deleted'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @L uniqueidentifier = NEWID(), @D uniqueidentifier = NEWID(), @before int, @after int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 8192, N'Utlwd Reservoir');
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lake_dam_name, lake_dam_type, CGNDB, cabd_id, lat, lon, province, link_method, link_distance_m)
VALUES (@D, @L, N'Utlwd Dam', N'Dam', 'ZLWD8', 'utlwd-cabd-8', 46.2, -66.3, 'NB', 'chn_polygon', 0);
SET @before = (SELECT COUNT(*) FROM dbo.lake_dam WHERE lake_dam_id = @D AND lake_id = @L AND lake_dam_stamp IS NOT NULL);
EXEC dbo.sp_del_river @L;   -- the app's delete path (Tributaries first, then Lake)
SET @after = (SELECT COUNT(*) FROM dbo.lake_dam WHERE lake_dam_id = @D AND lake_id IS NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@before, 0) <> 1 OR ISNULL(@after, 0) <> 1
   RAISERROR ('TEST 7 FAIL [%dms]: dam must link, then survive lake delete unlinked', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: dam linked, kept unlinked on lake delete'

ROLLBACK TRAN LWD_Test7
GO
-- ============================================================================
-- TEST 8: dam CHECK constraints
-- ============================================================================
BEGIN TRAN LWD_Test8
    declare @test_name sysname = N'LWD_Test8 [lake_dam] : checks'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @e int = 0;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

BEGIN TRY
    INSERT INTO dbo.lake_dam (lake_dam_id, lat, lon) VALUES (NEWID(), 46.0, -181.0);
END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @e <> 547
   RAISERROR ('TEST 8 FAIL [%dms]: longitude out of range must be refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: dam longitude out of range refused'

ROLLBACK TRAN LWD_Test8
GO
-- ============================================================================
-- TEST 9: both tables replicate (merge_table, level 2, keyed and stamped)
-- ============================================================================
BEGIN TRAN LWD_Test9
    declare @test_name sysname = N'LWD_Test9 [merge_table] : registration'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @n int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @n = (SELECT COUNT(*) FROM dbo.merge_table
          WHERE (table_name = 'lake_waterfall' AND field_pk = 'lake_waterfall_id' AND field_stamp = 'lake_waterfall_stamp' AND level = 2 AND operation = 'IUD')
             OR (table_name = 'lake_dam'       AND field_pk = 'lake_dam_id'       AND field_stamp = 'lake_dam_stamp'       AND level = 2 AND operation = 'IUD'));

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@n, 0) <> 2
   RAISERROR ('TEST 9 FAIL [%dms]: both tables must be in merge_table at level 2', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: both tables registered for replication'

ROLLBACK TRAN LWD_Test9
GO
-- ============================================================================
-- TEST 10: sp_MergeLakes moves waterfalls and dams to the surviving water body
-- ============================================================================
BEGIN TRAN LWD_Test10
    declare @test_name sysname = N'LWD_Test10 [sp_MergeLakes] : barriers follow merge'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @From uniqueidentifier = NEWID(), @To uniqueidentifier = NEWID(), @W uniqueidentifier = NEWID(), @D uniqueidentifier = NEWID();
DECLARE @nW int, @nD int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@From, 2, N'Utlwd Duplicate River'), (@To, 2, N'Utlwd Kept River');
INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lake_id, lat, lon, link_method) VALUES (@W, @From, 46.0, -66.0, 'chn_network');
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lat, lon, link_method) VALUES (@D, @From, 46.1, -66.1, 'chn_network');
EXEC dbo.sp_MergeLakes @From, @To;
SET @nW = (SELECT COUNT(*) FROM dbo.lake_waterfall WHERE lake_waterfall_id = @W AND lake_id = @To);
SET @nD = (SELECT COUNT(*) FROM dbo.lake_dam WHERE lake_dam_id = @D AND lake_id = @To);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@nW, 0) <> 1 OR ISNULL(@nD, 0) <> 1
   RAISERROR ('TEST 10 FAIL [%dms]: merge must move waterfall and dam to the kept lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: merge moved waterfall and dam to kept lake'

ROLLBACK TRAN LWD_Test10
GO
