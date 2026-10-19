/*
  Unit tests for mouthRoad in dbo.fn_lake_view_json (docapi GET /api/v1/river/description/{guid},
  MCP tool get_water_body; admin "Save JSON" View tab): the nearest named road to the mouth,
  dbo.Tributaries.road of the side-32 row (NRN / TIGER, <= 10 km; roads_import, 2026-10-19).

  Real tables only. Each test is its own named transaction, rolled back in its own GO batch.

  SET QUOTED_IDENTIFIER ON is required: dbo.lake carries a filtered index, so an INSERT fails with
  Msg 1934 otherwise (same as unit_test@LakeJson.sql).
*/
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------- TEST 1: mouth road is returned
BEGIN TRAN TestLakeMouthRoad1
    DECLARE @test_name sysname = N'TestLakeMouthRoad1 [fn_lake_view_json] : mouthRoad from side 32';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 2, N'UT Mouth Road Creek');
UPDATE dbo.Tributaries SET road = N'UT Mouth Rd' WHERE Main_Lake_id = @Lake AND side = 32;
UPDATE dbo.Tributaries SET road = N'UT Source Rd' WHERE Main_Lake_id = @Lake AND side = 16;
DECLARE @json nvarchar(max) = dbo.fn_lake_view_json(@Lake);
IF JSON_VALUE(@json, '$.mouthRoad') = N'UT Mouth Rd' SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mouthRoad is the side-32 road';
ELSE RAISERROR('TEST 1 FAIL [%dms]: mouthRoad must be the side-32 road', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeMouthRoad1
GO
-- ---------------------------------------------------------------------------- TEST 2: no road -> mouthRoad null, key kept
BEGIN TRAN TestLakeMouthRoad2
    DECLARE @test_name sysname = N'TestLakeMouthRoad2 [fn_lake_view_json] : no road gives null';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 2, N'UT No Road Creek');
UPDATE dbo.Tributaries SET road = N'UT Source Rd' WHERE Main_Lake_id = @Lake AND side = 16;
DECLARE @json nvarchar(max) = dbo.fn_lake_view_json(@Lake);
IF EXISTS (SELECT 1 FROM OPENJSON(@json) WHERE [key] = 'mouthRoad' AND [type] = 0) SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no mouth road gives mouthRoad null';
ELSE RAISERROR('TEST 2 FAIL [%dms]: mouthRoad must be present and null', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeMouthRoad2
GO
