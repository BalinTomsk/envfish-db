SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lake_barriers_json(@lake_id): the waterfalls (dbo.lake_waterfall) and dams (dbo.lake_dam)
  linked to one water body. No caller yet; planned for docapi's water-body endpoints and MCP tools.

  Fixture notes: CGNDB values start with 'Z' (char(5)) so they never collide with real codes.

  TEST 1 - unknown water body                       -> NULL
  TEST 2 - water body with no waterfall or dam      -> both arrays present and empty
  TEST 3 - 2 waterfalls + 1 dam, plus rows of another water body
                                                    -> exactly its own rows, named first by name, all fields
  TEST 4 - an unnamed CHN dam                       -> listed, name is JSON null, ids/link carried
*/
PRINT 'Unit tests for fn_lake_barriers_json (waterfalls and dams of a water body)';
GO
-- ============================================================================
-- TEST 1: unknown water body
-- ============================================================================
BEGIN TRAN LBJ_Test1
    declare @test_name sysname = N'LBJ_Test1 [fn_lake_barriers_json] : unknown'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_lake_barriers_json(NEWID());

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NOT NULL
   RAISERROR ('TEST 1 FAIL [%dms]: an unknown water body must give NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown water body -> NULL'

ROLLBACK TRAN LBJ_Test1
GO
-- ============================================================================
-- TEST 2: no barriers -> empty arrays
-- ============================================================================
BEGIN TRAN LBJ_Test2
    declare @test_name sysname = N'LBJ_Test2 [fn_lake_barriers_json] : none'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utlbj Empty Lake');
SET @json = dbo.fn_lake_barriers_json(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISJSON(@json) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.guid')) <> @L
  OR JSON_VALUE(@json, '$.lakeName') <> N'Utlbj Empty Lake'
  OR JSON_QUERY(@json, '$.waterfalls') <> N'[]'
  OR JSON_QUERY(@json, '$.dams') <> N'[]'
   RAISERROR ('TEST 2 FAIL [%dms]: no barriers must give guid, name and two empty arrays', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no barriers -> two empty arrays'

ROLLBACK TRAN LBJ_Test2
GO
-- ============================================================================
-- TEST 3: own rows only, named first by name, all fields
-- ============================================================================
BEGIN TRAN LBJ_Test3
    declare @test_name sysname = N'LBJ_Test3 [fn_lake_barriers_json] : own rows'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID(), @Other uniqueidentifier = NEWID(), @D uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlbj River'), (@Other, 2, N'Utlbj Other River');
INSERT INTO dbo.lake_waterfall (lake_waterfall_id, lake_id, lake_waterfall_name, lake_waterfall_type, CGNDB, lat, lon, province, link_method, link_distance_m)
VALUES (NEWID(), @L, N'Utlbj Upper Falls', N'Falls', 'ZLBJ1', 46.2, -66.2, 'NB', 'chn_network', 4),
       (NEWID(), @L, N'Utlbj Lower Falls', N'Falls', 'ZLBJ2', 46.1, -66.1, 'NB', 'chn_polygon', 0),
       (NEWID(), @Other, N'Utlbj Foreign Falls', N'Falls', 'ZLBJ3', 46.3, -66.3, 'NB', 'chn_network', 9);
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lake_dam_name, lake_dam_type, CGNDB, cabd_id, lat, lon, province, link_method, link_distance_m)
VALUES (@D, @L, N'Utlbj Dam', N'Dam', 'ZLBJ4', 'utlbj-cabd-4', 46.15, -66.15, 'NB', 'name_near', 1200);
SET @json = dbo.fn_lake_barriers_json(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json, '$.waterfalls')) <> 2
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.dams')) <> 1
  OR JSON_VALUE(@json, '$.waterfalls[0].name') <> N'Utlbj Lower Falls'
  OR JSON_VALUE(@json, '$.waterfalls[1].name') <> N'Utlbj Upper Falls'
  OR JSON_VALUE(@json, '$.waterfalls[0].linkMethod') <> 'chn_polygon'
  OR JSON_VALUE(@json, '$.waterfalls[1].CGNDB') <> 'ZLBJ1'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.dams[0].id')) <> @D
  OR JSON_VALUE(@json, '$.dams[0].type') <> N'Dam'
  OR JSON_VALUE(@json, '$.dams[0].cabdId') <> 'utlbj-cabd-4'
  OR TRY_CONVERT(int, JSON_VALUE(@json, '$.dams[0].linkDistanceM')) <> 1200
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.dams[0].lat')) <> 46.15
  OR JSON_VALUE(@json, '$.dams[0].province') <> 'NB'
   RAISERROR ('TEST 3 FAIL [%dms]: own 2 falls (by name) + 1 dam, with all fields', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: own falls by name + dam, all fields'

ROLLBACK TRAN LBJ_Test3
GO
-- ============================================================================
-- TEST 4: an unnamed CHN dam is listed after named ones, name null
-- ============================================================================
BEGIN TRAN LBJ_Test4
    declare @test_name sysname = N'LBJ_Test4 [fn_lake_barriers_json] : unnamed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID(), @U uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlbj Dammed River');
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, chn_feature_id, cabd_id, lat, lon, province, link_method, link_distance_m)
VALUES (@U, @L, @U, 'utlbj-cabd-5', 45.5, -64.5, 'NS', 'chn_network', 11);
INSERT INTO dbo.lake_dam (lake_dam_id, lake_id, lake_dam_name, lat, lon, link_method)
VALUES (NEWID(), @L, N'Utlbj Named Dam', 45.6, -64.6, 'manual');
SET @json = dbo.fn_lake_barriers_json(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json, '$.dams')) <> 2
  OR JSON_VALUE(@json, '$.dams[0].name') <> N'Utlbj Named Dam'
  OR (SELECT [type] FROM OPENJSON(JSON_QUERY(@json, '$.dams[1]')) WHERE [key] = 'name') <> 0
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.dams[1].chnFeatureId')) <> @U
  OR JSON_VALUE(@json, '$.dams[1].cabdId') <> 'utlbj-cabd-5'
   RAISERROR ('TEST 4 FAIL [%dms]: unnamed dam must follow named, name null, ids kept', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unnamed dam listed last, name null'

ROLLBACK TRAN LBJ_Test4
GO
