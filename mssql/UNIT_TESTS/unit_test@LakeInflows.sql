SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lake_inflows_json(@lake_id, @limit): the water bodies that flow INTO one water
  body. Served by docapi's RiverController (GET /api/v1/river/tributaries/{guid}) and the MCP tool
  get_water_body_tributaries (McpToolCatalog), both via JdbcRiverQueryRepository.tributaries.

  An inflow is either a Tributaries row whose Lake_id is the water body with side 32 (the other water
  body's MOUTH is here, read through dbo.fn_SubTributary), or a side-4 row the water body owns (an
  "Inflow" recorded on a lake by sp_add_tributary). Each inflow is listed once.

  Fixture notes: names carry the unique token 'utinf' so seed data never matches. TR_Lake_INS gives
  every new lake self source (16) and mouth (32) rows, so a fixture re-points those, as the editor does;
  the main water body's own self mouth row is the 'self row' TEST 2 must not list.

  TEST 1 - two rivers whose mouth is the main river  -> total 2, name order, fields populated
  TEST 2 - a source row, a self row, another mouth   -> none of them listed
  TEST 3 - side-4 inflow on a lake, plus its mouth   -> listed once, as link 'mouth'
  TEST 4 - limit 1 of 2                              -> 1 item, total still 2
  TEST 5 - water body with no inflows                -> total 0, tributaries []
  TEST 6 - unknown water body                        -> NULL
*/
PRINT 'Unit tests for fn_lake_inflows_json (water-body inflows)';
GO
-- ============================================================================
-- TEST 1: two rivers whose mouth is the main river
-- ============================================================================
BEGIN TRAN INF_Test1
    declare @test_name sysname = N'INF_Test1 [fn_lake_inflows_json] : two mouths'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @M uniqueidentifier = NEWID(), @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@M, 2, N'Utinf Main River');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (@B, 2, N'Utinf Beta River', 'INFBB');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@A, 64, N'Utinf Alpha Creek');
UPDATE dbo.Tributaries SET Lake_id = @M, lat = 43.7, lon = -79.5, Country = 'CA', State = 'ON' WHERE Main_Lake_id = @B AND side = 32;
UPDATE dbo.Tributaries SET Lake_id = @M, lat = 43.6, lon = -79.4, Country = 'CA', State = 'ON' WHERE Main_Lake_id = @A AND side = 32;

SET @json = dbo.fn_lake_inflows_json(@M, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   JSON_VALUE(@json, '$.total') <> '2'
  OR JSON_VALUE(@json, '$.lakeName') <> N'Utinf Main River'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.tributaries[0].lakeId')) <> @A
  OR JSON_VALUE(@json, '$.tributaries[0].locType') <> '64'
  OR JSON_VALUE(@json, '$.tributaries[0].link')    <> 'mouth'
  OR JSON_VALUE(@json, '$.tributaries[0].state')   <> 'ON'
  OR JSON_VALUE(@json, '$.tributaries[1].lakeName') <> N'Utinf Beta River'
  OR JSON_VALUE(@json, '$.tributaries[1].CGNDB')    <> 'INFBB'
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.tributaries[1].lat')) <> 43.7
   RAISERROR ('TEST 1 FAIL [%dms]: both mouths must be listed in name order', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: both mouths listed in name order'

ROLLBACK TRAN INF_Test1
GO
-- ============================================================================
-- TEST 2: a source row, a self row and another river's mouth are not inflows
-- ============================================================================
BEGIN TRAN INF_Test2
    declare @test_name sysname = N'INF_Test2 [fn_lake_inflows_json] : non-inflows'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @M uniqueidentifier = NEWID(), @O uniqueidentifier = NEWID(), @X uniqueidentifier = NEWID()
      , @Y uniqueidentifier = NEWID(), @T uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@M, 1, N'Utinf Main Lake');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@O, 2, N'Utinf Outflow River');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@X, 2, N'Utinf Elsewhere River');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Y, 2, N'Utinf Other River');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@T, 2, N'Utinf True River');
UPDATE dbo.Tributaries SET Lake_id = @M WHERE Main_Lake_id = @O AND side = 16;   -- starts here: outflow
UPDATE dbo.Tributaries SET Lake_id = @Y WHERE Main_Lake_id = @X AND side = 32;   -- ends somewhere else
UPDATE dbo.Tributaries SET Lake_id = @M WHERE Main_Lake_id = @T AND side = 32;   -- the one real inflow

SET @json = dbo.fn_lake_inflows_json(@M, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   JSON_VALUE(@json, '$.total') <> '1'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.tributaries[0].lakeId')) <> @T
   RAISERROR ('TEST 2 FAIL [%dms]: only the real inflow may be listed', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: source, self, elsewhere rows ignored'

ROLLBACK TRAN INF_Test2
GO
-- ============================================================================
-- TEST 3: side-4 inflow recorded on a lake; with and without the river's mouth row
-- ============================================================================
BEGIN TRAN INF_Test3
    declare @test_name sysname = N'INF_Test3 [fn_lake_inflows_json] : side-4 inflow'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @M uniqueidentifier = NEWID(), @R uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@M, 1, N'Utinf Inflow Lake');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@R, 2, N'Utinf Both River');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@S, 2, N'Utinf Side River');
UPDATE dbo.Tributaries SET Lake_id = @M WHERE Main_Lake_id = @R AND side = 32;   -- R's mouth is the lake
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@M, @R, 4);    -- and the lake says so
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@M, @S, 4);    -- only the lake says so

SET @json = dbo.fn_lake_inflows_json(@M, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   JSON_VALUE(@json, '$.total') <> '2'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.tributaries[0].lakeId')) <> @R
  OR JSON_VALUE(@json, '$.tributaries[0].link') <> 'mouth'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.tributaries[1].lakeId')) <> @S
  OR JSON_VALUE(@json, '$.tributaries[1].link') <> 'inflow'
   RAISERROR ('TEST 3 FAIL [%dms]: side-4 inflows must be listed once each', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: side-4 inflows listed once each'

ROLLBACK TRAN INF_Test3
GO
-- ============================================================================
-- TEST 4: limit cuts the list, total still counts every inflow
-- ============================================================================
BEGIN TRAN INF_Test4
    declare @test_name sysname = N'INF_Test4 [fn_lake_inflows_json] : limit'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @M uniqueidentifier = NEWID(), @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@M, 2, N'Utinf Limit River');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@A, 2, N'Utinf Limit A');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@B, 2, N'Utinf Limit B');
UPDATE dbo.Tributaries SET Lake_id = @M WHERE Main_Lake_id = @A AND side = 32;
UPDATE dbo.Tributaries SET Lake_id = @M WHERE Main_Lake_id = @B AND side = 32;

SET @json = dbo.fn_lake_inflows_json(@M, 1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   JSON_VALUE(@json, '$.total') <> '2'
  OR JSON_VALUE(@json, '$.limit') <> '1'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.tributaries')) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.tributaries[0].lakeId')) <> @A
   RAISERROR ('TEST 4 FAIL [%dms]: limit 1 must return 1 item of total 2', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: limit 1 returned 1 item of total 2'

ROLLBACK TRAN INF_Test4
GO
-- ============================================================================
-- TEST 5: a water body with no inflows
-- ============================================================================
BEGIN TRAN INF_Test5
    declare @test_name sysname = N'INF_Test5 [fn_lake_inflows_json] : none'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @M uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@M, 2, N'Utinf Lonely River');

SET @json = dbo.fn_lake_inflows_json(@M, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   @json IS NULL
  OR JSON_VALUE(@json, '$.total') <> '0'
  OR JSON_QUERY(@json, '$.tributaries') <> N'[]'
   RAISERROR ('TEST 5 FAIL [%dms]: no inflows must give total 0 and []', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no inflows gave total 0 and []'

ROLLBACK TRAN INF_Test5
GO
-- ============================================================================
-- TEST 6: unknown water body
-- ============================================================================
BEGIN TRAN INF_Test6
    declare @test_name sysname = N'INF_Test6 [fn_lake_inflows_json] : unknown'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'sentinel';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_lake_inflows_json(NEWID(), NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NOT NULL
   RAISERROR ('TEST 6 FAIL [%dms]: an unknown water body must give NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: an unknown water body gave NULL'

ROLLBACK TRAN INF_Test6
GO
