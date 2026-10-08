SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: Lake.CGNDM, the second CGNDB key, handled everywhere CGNDB is. CGNDB keeps one record per
  province, so a water body in two provinces has two keys (Reindeer Lake: GAWWT in MB, HAINF in SK);
  CGNDB holds one, CGNDM the other (edited side by side on Editor/LakeEditor.aspx).

  TEST  1 - vw_lake exposes CGNDM
  TEST  2 - SearchLakeList returns CGNDM for the found water body
  TEST  3 - fn_river_list returns CGNDM
  TEST  4 - fn_river_unfished_json returns CGNDM; "throwing" lists a Throw lake known only by CGNDM
  TEST  5 - fn_fish_water_bodies_json: a CGNDM-only water body counts as Canadian and carries CGNDM
  TEST  6 - fn_lake_canadian_ids_json: a CGNDM-only water body counts as Canadian
  TEST  7 - fn_lake_view_info: CGNDM attribute in the viewer XML
  TEST  8 - fn_lake_inflows_json: tributaries carry CGNDM
  TEST  9 - fn_lake_view_json: cgndm
  TEST 10 - sp_lake_description_update: cgndm is patchable
  TEST 11 - sp_MergeLakes: the target keeps its CGNDB and takes the source's CGNDB as CGNDM
  TEST 12 - sp_MergeLakes: a target with no codes takes the source's CGNDB and CGNDM
*/
PRINT 'Unit tests for CGNDM (second CGNDB key) in every CGNDB reader';
GO
-- ============================================================================ TEST 1
BEGIN TRAN CGM_Test1
    declare @test_name sysname = N'CGM_Test1 [vw_lake] : CGNDM'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @rst varchar(8);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (@L, 1, N'ut-cgm1-lake', 'CGMAA', 'CGMAB');
SELECT @rst = RTRIM(CGNDM) FROM dbo.vw_lake WHERE lake_id = @L;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @rst IS NULL OR @rst <> 'CGMAB' RAISERROR ('TEST 1 FAIL [%dms]: vw_lake must expose CGNDM', 16, -1, @ElapsedMs)
ELSE print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: vw_lake exposes CGNDM'
ROLLBACK TRAN CGM_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN CGM_Test2
    declare @test_name sysname = N'CGM_Test2 [SearchLakeList] : CGNDM column'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @rst varchar(8);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (NEWID(), 1, N'ut-cgm2-lake', 'CGMBA', 'CGMBB');
SELECT @rst = RTRIM(CGNDM) FROM dbo.SearchLakeList(N'CGMBB');
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @rst IS NULL OR @rst <> 'CGMBB' RAISERROR ('TEST 2 FAIL [%dms]: SearchLakeList must return CGNDM', 16, -1, @ElapsedMs)
ELSE print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: SearchLakeList returns CGNDM'
ROLLBACK TRAN CGM_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN CGM_Test3
    declare @test_name sysname = N'CGM_Test3 [fn_river_list] : CGNDM'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @rst varchar(8);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDM, isFish, isWell, noFish) VALUES (@L, 2, N'ut-cgm3-river', 'CGMCB', 0, 0, 0);
UPDATE dbo.Tributaries SET State = 'ZZ', Country = 'CA', location = NULL WHERE main_lake_id = @L AND side IN (16, 32);
SELECT @rst = RTRIM(CGNDM) FROM dbo.fn_river_list('ZZ', 'CA', 2, N'$', 0, 0, 0) WHERE lake_id = @L;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @rst IS NULL OR @rst <> 'CGMCB' RAISERROR ('TEST 3 FAIL [%dms]: fn_river_list must return CGNDM', 16, -1, @ElapsedMs)
ELSE print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_river_list returns CGNDM'
ROLLBACK TRAN CGM_Test3
GO
-- ============================================================================ TEST 4
BEGIN TRAN CGM_Test4
    declare @test_name sysname = N'CGM_Test4 [fn_river_unfished_json] : CGNDM + throwing'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID(), @T1 uniqueidentifier = NEWID(), @T2 uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM, isFish, noFish) VALUES (@L, 2, N'ut-cgm4-river', 'CGMDA', 'CGMDB', 0, 0);
UPDATE dbo.Tributaries SET state = 'ZZ', country = 'CA' WHERE main_lake_id = @L AND side = 16;
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@T1, 1, N'ut-cgm4-thr-a', 'CGMDC');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDM) VALUES (@T2, 1, N'ut-cgm4-thr-b', 'CGMDD');
INSERT INTO dbo.Tributaries (main_lake_id, lake_id, side) VALUES (@L, @T1, 2);
INSERT INTO dbo.Tributaries (main_lake_id, lake_id, side) VALUES (@L, @T2, 2);
SET @json = dbo.fn_river_unfished_json('CA', 'ZZ', 2);
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF   JSON_VALUE(@json, '$.CGNDB') <> 'CGMDA' OR JSON_VALUE(@json, '$.CGNDM') IS NULL OR JSON_VALUE(@json, '$.CGNDM') <> 'CGMDB'
  OR JSON_VALUE(@json, '$.throwing') <> 'CGMDC,CGMDD'
   RAISERROR ('TEST 4 FAIL [%dms]: expected CGNDM and throwing CGMDC,CGMDD', 16, -1, @ElapsedMs)
ELSE print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CGNDM returned, throwing lists a CGNDM-only lake'
ROLLBACK TRAN CGM_Test4
GO
-- ============================================================================ TEST 5
BEGIN TRAN CGM_Test5
    declare @test_name sysname = N'CGM_Test5 [fn_fish_water_bodies_json] : CGNDM-only is Canadian'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID(), @F uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDM) VALUES (@L, 1, N'ut-cgm5-lake', 'CGMEB');
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, probability) VALUES (@L, @F, 100);
SET @json = dbo.fn_fish_water_bodies_json(@F, 'CA', NULL, NULL, NULL, 200);
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM OPENJSON(@json, '$.items') WITH (lakeId uniqueidentifier, CGNDM varchar(8)) WHERE lakeId = @L AND CGNDM = 'CGMEB')
   RAISERROR ('TEST 5 FAIL [%dms]: a CGNDM-only water body must count as Canadian and carry CGNDM', 16, -1, @ElapsedMs)
ELSE print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CGNDM-only water body listed for CA with CGNDM'
ROLLBACK TRAN CGM_Test5
GO
-- ============================================================================ TEST 6
BEGIN TRAN CGM_Test6
    declare @test_name sysname = N'CGM_Test6 [fn_lake_canadian_ids_json] : CGNDM-only is Canadian'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDM) VALUES (@L, 1, N'ut-cgm6-lake', 'CGMFB');
UPDATE dbo.Tributaries SET Country = 'US' WHERE main_lake_id = @L;
SET @json = dbo.fn_lake_canadian_ids_json(N'["' + CONVERT(nvarchar(36), @L) + N'"]');
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM OPENJSON(@json) WHERE TRY_CONVERT(uniqueidentifier, value) = @L)
   RAISERROR ('TEST 6 FAIL [%dms]: a CGNDM-only water body must count as Canadian', 16, -1, @ElapsedMs)
ELSE print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CGNDM-only water body counts as Canadian'
ROLLBACK TRAN CGM_Test6
GO
-- ============================================================================ TEST 7
BEGIN TRAN CGM_Test7
    declare @test_name sysname = N'CGM_Test7 [fn_lake_view_info] : CGNDM attribute'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @rst varchar(8);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (@L, 1, N'ut-cgm7-lake', 'CGMGA', 'CGMGB');
DECLARE @doc xml = (SELECT TOP 1 CAST(doc AS xml) FROM dbo.fn_lake_view_info(@L));
SET @rst = @doc.value('(//lake/@CGNDM)[1]', 'varchar(8)');
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @rst IS NULL OR @rst <> 'CGMGB' RAISERROR ('TEST 7 FAIL [%dms]: viewer XML must carry CGNDM', 16, -1, @ElapsedMs)
ELSE print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: viewer XML carries CGNDM'
ROLLBACK TRAN CGM_Test7
GO
-- ============================================================================ TEST 8
BEGIN TRAN CGM_Test8
    declare @test_name sysname = N'CGM_Test8 [fn_lake_inflows_json] : CGNDM'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @M uniqueidentifier = NEWID(), @A uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@M, 2, N'Utcgm Main River');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (@A, 2, N'Utcgm Alpha River', 'CGMHA', 'CGMHB');
UPDATE dbo.Tributaries SET Lake_id = @M, Country = 'CA', State = 'ON' WHERE Main_Lake_id = @A AND side = 32;
SET @json = dbo.fn_lake_inflows_json(@M, NULL);
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF JSON_VALUE(@json, '$.tributaries[0].CGNDM') IS NULL OR JSON_VALUE(@json, '$.tributaries[0].CGNDM') <> 'CGMHB'
   RAISERROR ('TEST 8 FAIL [%dms]: tributaries must carry CGNDM', 16, -1, @ElapsedMs)
ELSE print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: tributaries carry CGNDM'
ROLLBACK TRAN CGM_Test8
GO
-- ============================================================================ TEST 9
BEGIN TRAN CGM_Test9
    declare @test_name sysname = N'CGM_Test9 [fn_lake_view_json] : cgndm'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (@L, 1, N'ut-cgm9-lake', 'CGMIA', 'CGMIB');
SET @json = dbo.fn_lake_view_json(@L);
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF JSON_VALUE(@json, '$.cgndm') IS NULL OR RTRIM(JSON_VALUE(@json, '$.cgndm')) <> 'CGMIB'
   RAISERROR ('TEST 9 FAIL [%dms]: fn_lake_view_json must carry cgndm', 16, -1, @ElapsedMs)
ELSE print 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_view_json carries cgndm'
ROLLBACK TRAN CGM_Test9
GO
-- ============================================================================ TEST 10
BEGIN TRAN CGM_Test10
    declare @test_name sysname = N'CGM_Test10 [sp_lake_description_update] : cgndm'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @res nvarchar(max), @rst varchar(8);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@L, 1, N'ut-cgm10-lake', 'CGMJA');
DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_description_update @L, N'{"cgndm":"CGMJB"}';
SELECT @res = results FROM @t;
SELECT @rst = RTRIM(CGNDM) FROM dbo.lake WHERE lake_id = @L;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @rst IS NULL OR @rst <> 'CGMJB'
   OR NOT EXISTS (SELECT 1 FROM OPENJSON(@res, '$.updated') WITH (field nvarchar(50)) WHERE field = 'cgndm')
   RAISERROR ('TEST 10 FAIL [%dms]: cgndm must be patched and reported', 16, -1, @ElapsedMs)
ELSE print 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: cgndm patched and reported'
ROLLBACK TRAN CGM_Test10
GO
-- ============================================================================ TEST 11
BEGIN TRAN CGM_Test11
    declare @test_name sysname = N'CGM_Test11 [sp_MergeLakes] : two provinces'' keys'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @b varchar(8), @m varchar(8), @gone int;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @To uniqueidentifier = NEWID(), @From uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@To,   1, N'ut-cgm11-lake', 'CGMKA');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@From, 1, N'ut-cgm11-lake', 'CGMKB');
EXEC dbo.sp_MergeLakes @From, @To;
SELECT @b = RTRIM(CGNDB), @m = RTRIM(CGNDM) FROM dbo.lake WHERE lake_id = @To;
SELECT @gone = COUNT(*) FROM dbo.lake WHERE lake_id = @From;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @b IS NULL OR @b <> 'CGMKA' OR @m IS NULL OR @m <> 'CGMKB' OR @gone <> 0
   RAISERROR ('TEST 11 FAIL [%dms]: expected CGNDB CGMKA + CGNDM CGMKB on the target, source deleted', 16, -1, @ElapsedMs)
ELSE print 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: merge keeps CGNDB, takes the source key as CGNDM'
ROLLBACK TRAN CGM_Test11
GO
-- ============================================================================ TEST 12
BEGIN TRAN CGM_Test12
    declare @test_name sysname = N'CGM_Test12 [sp_MergeLakes] : empty target'
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @b varchar(8), @m varchar(8);
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @To uniqueidentifier = NEWID(), @From uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name)               VALUES (@To,   1, N'ut-cgm12-lake');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (@From, 1, N'ut-cgm12-lake', 'CGMLA', 'CGMLB');
EXEC dbo.sp_MergeLakes @From, @To;
SELECT @b = RTRIM(CGNDB), @m = RTRIM(CGNDM) FROM dbo.lake WHERE lake_id = @To;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @b IS NULL OR @b <> 'CGMLA' OR @m IS NULL OR @m <> 'CGMLB'
   RAISERROR ('TEST 12 FAIL [%dms]: expected CGNDB CGMLA + CGNDM CGMLB on the target', 16, -1, @ElapsedMs)
ELSE print 'TEST 12 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty target takes both keys'
ROLLBACK TRAN CGM_Test12
GO
