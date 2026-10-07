SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_river_search_json(@name, @guid, @cgndb, @state_id, @mli, @limit):
    water-body lookup by part of a name, either GUID (lake_id / secondary_id), either CGNDB code
    (CGNDB / CGNDM), the provincial/state id (state_id) or a linked WaterStation MLI; every
    supplied criterion must match. Served by
    docapi's RiverController (GET /api/v1/river/search) via JdbcRiverQueryRepository.

  Fixture notes: names carry the unique token 'utrsq' so seed data never matches; CGNDB is char(5).

  TEST 1 - part of a name                          -> the one fixture lake, fields populated
  TEST 2 - guid = secondary_id                     -> that lake
  TEST 3 - cgndb = CGNDM (secondary code)          -> that lake
  TEST 4 - mli of a linked station                 -> that lake, mli array lists its stations
  TEST 5 - name + a CGNDB of another lake (AND)    -> []
  TEST 6 - no criteria at all                      -> []
  TEST 7 - exact name, then prefix, then substring -> ranked in that order
  TEST 8 - state_id (provincial/state id)          -> that lake, stateId in the item
  TEST 9 - state_id + name of another lake (AND)   -> []
*/
PRINT 'Unit tests for fn_river_search_json (river search)';
GO
-- ============================================================================
-- TEST 1: part of a name
-- ============================================================================
BEGIN TRAN RSQ_Test1
    declare @test_name sysname = N'RSQ_Test1 [fn_river_search_json] : part of name'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM, state_id) VALUES (@L, 2, N'Utrsq One River', 'RSQAA', 'RSQAB', 'RSQ-1');

SET @json = dbo.fn_river_search_json(N'rsq one', NULL, NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR JSON_VALUE(@json, '$[0].lakeName') <> N'Utrsq One River'
  OR JSON_VALUE(@json, '$[0].CGNDB')    <> 'RSQAA'
  OR JSON_VALUE(@json, '$[0].CGNDM')    <> 'RSQAB'
  OR JSON_VALUE(@json, '$[0].stateId')  <> 'RSQ-1'
  OR JSON_VALUE(@json, '$[0].locType')  <> '2'
   RAISERROR ('TEST 1 FAIL [%dms]: name part must find the one lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: part of name found the lake'

ROLLBACK TRAN RSQ_Test1
GO
-- ============================================================================
-- TEST 2: guid matches secondary_id
-- ============================================================================
BEGIN TRAN RSQ_Test2
    declare @test_name sysname = N'RSQ_Test2 [fn_river_search_json] : secondary guid'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, secondary_id) VALUES (@L, 2, N'Utrsq Two River', @S);

SET @json = dbo.fn_river_search_json(NULL, @S, NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0].lakeId'))      <> @L
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0].secondaryId')) <> @S
   RAISERROR ('TEST 2 FAIL [%dms]: secondary guid must find the lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: secondary guid found the lake'

ROLLBACK TRAN RSQ_Test2
GO
-- ============================================================================
-- TEST 3: cgndb matches CGNDM
-- ============================================================================
BEGIN TRAN RSQ_Test3
    declare @test_name sysname = N'RSQ_Test3 [fn_river_search_json] : CGNDM code'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB, CGNDM) VALUES (@L, 2, N'Utrsq Three River', 'RSQCA', 'RSQCB');

SET @json = dbo.fn_river_search_json(NULL, NULL, 'rsqcb', NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0].lakeId')) <> @L
   RAISERROR ('TEST 3 FAIL [%dms]: CGNDM code must find the lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CGNDM code found the lake'

ROLLBACK TRAN RSQ_Test3
GO
-- ============================================================================
-- TEST 4: mli of a linked station
-- ============================================================================
BEGIN TRAN RSQ_Test4
    declare @test_name sysname = N'RSQ_Test4 [fn_river_search_json] : station MLI'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 2, N'Utrsq Four River');
INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES ('UT_RSQ_M1', 45.1, -75.1, 'CA', N'ut rsq station 1', 2, N'UT RSQ 1', N'', 991001, @L, N'Utrsq Four River', 1),
       ('UT_RSQ_M2', 45.2, -75.2, 'CA', N'ut rsq station 2', 2, N'UT RSQ 2', N'', 991002, @L, N'Utrsq Four River', 1);

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, 'UT_RSQ_M2', NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0].lakeId')) <> @L
  OR JSON_VALUE(@json, '$[0].mli[0]') <> 'UT_RSQ_M1'
  OR JSON_VALUE(@json, '$[0].mli[1]') <> 'UT_RSQ_M2'
   RAISERROR ('TEST 4 FAIL [%dms]: MLI must find the lake with both stations', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: MLI found the lake and its stations'

ROLLBACK TRAN RSQ_Test4
GO
-- ============================================================================
-- TEST 5: name + CGNDB of another lake -> no match (criteria are ANDed)
-- ============================================================================
BEGIN TRAN RSQ_Test5
    declare @test_name sysname = N'RSQ_Test5 [fn_river_search_json] : criteria ANDed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (NEWID(), 2, N'Utrsq Five River', 'RSQEA');
INSERT INTO dbo.lake (lake_id, locType, lake_name, CGNDB) VALUES (NEWID(), 2, N'Other Five River', 'RSQEB');

SET @json = dbo.fn_river_search_json(N'utrsq five', NULL, 'RSQEB', NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NULL OR @json <> N'[]'
   RAISERROR ('TEST 5 FAIL [%dms]: name and CGNDB of different lakes must match nothing', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: criteria are ANDed'

ROLLBACK TRAN RSQ_Test5
GO
-- ============================================================================
-- TEST 6: no criteria -> []
-- ============================================================================
BEGIN TRAN RSQ_Test6
    declare @test_name sysname = N'RSQ_Test6 [fn_river_search_json] : no criteria'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_river_search_json(N'  ', NULL, '', NULL, NULL, 10);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NULL OR @json <> N'[]'
   RAISERROR ('TEST 6 FAIL [%dms]: blank criteria must return []', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: blank criteria return []'

ROLLBACK TRAN RSQ_Test6
GO
-- ============================================================================
-- TEST 7: ranking - exact name, then prefix, then substring
-- ============================================================================
BEGIN TRAN RSQ_Test7
    declare @test_name sysname = N'RSQ_Test7 [fn_river_search_json] : ranking'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (NEWID(), 2, N'Aaa Utrsqseven Creek');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (NEWID(), 2, N'Utrsqseven River');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (NEWID(), 2, N'Utrsqseven');

SET @json = dbo.fn_river_search_json(N'Utrsqseven', NULL, NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   JSON_VALUE(@json, '$[0].lakeName') <> N'Utrsqseven'
  OR JSON_VALUE(@json, '$[1].lakeName') <> N'Utrsqseven River'
  OR JSON_VALUE(@json, '$[2].lakeName') <> N'Aaa Utrsqseven Creek'
   RAISERROR ('TEST 7 FAIL [%dms]: expected exact, prefix, substring order', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: exact, prefix, substring order'

ROLLBACK TRAN RSQ_Test7
GO
-- ============================================================================
-- TEST 8: state_id (provincial/state id)
-- ============================================================================
BEGIN TRAN RSQ_Test8
    declare @test_name sysname = N'RSQ_Test8 [fn_river_search_json] : state id'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, state_id) VALUES (@L, 1, N'Utrsq Eight Lake', '99887766');
INSERT INTO dbo.lake (lake_id, locType, lake_name, state_id) VALUES (NEWID(), 1, N'Utrsq Eight Other Lake', '99887767');

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, N' 99887766 ', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0].lakeId')) <> @L
  OR JSON_VALUE(@json, '$[0].stateId') <> '99887766'
   RAISERROR ('TEST 8 FAIL [%dms]: state id must find the one lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: state id found the lake'

ROLLBACK TRAN RSQ_Test8
GO
-- ============================================================================
-- TEST 9: state_id AND a name of another lake -> nothing
-- ============================================================================
BEGIN TRAN RSQ_Test9
    declare @test_name sysname = N'RSQ_Test9 [fn_river_search_json] : state id AND name'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, state_id) VALUES (NEWID(), 1, N'Utrsq Nine Lake', '99887768');
INSERT INTO dbo.lake (lake_id, locType, lake_name)           VALUES (NEWID(), 1, N'Utrsq Nine Other Lake');

SET @json = dbo.fn_river_search_json(N'Utrsq Nine Other', NULL, NULL, '99887768', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NULL OR @json <> N'[]'
   RAISERROR ('TEST 9 FAIL [%dms]: state id and another name must return []', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: state id and another name return []'

ROLLBACK TRAN RSQ_Test9
GO
