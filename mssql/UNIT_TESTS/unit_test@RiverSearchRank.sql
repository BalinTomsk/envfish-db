SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_river_search_json's region, type, sort and paging arguments
  (@country, @state, @loc_type, @sort, @offset), which let one call answer "the longest river in
  Maine". Served by docapi's RiverController (GET /api/v1/river/search) and MCP search_water_bodies
  via JdbcRiverQueryRepository.search. Name/key matching: unit_test@RiverSearch.sql.

  Fixture notes: every fixture sits in country 'ZZ' (states 'QQ'/'RR') so seed data never matches;
  names carry the token 'utrsr'. Inserting a lake creates its source (16) and mouth (32) Tributaries
  rows by trigger, so fixtures UPDATE those rows. Lake_Shape type 1 is the river centre line.

  TEST 1  - state alone (lower case)          -> source OR mouth in it, no name needed
  TEST 2  - country alone                     -> every state of it
  TEST 3  - type bitmask                      -> river|creek, not the lake
  TEST 4  - type alone, no name/key/region    -> total 0
  TEST 5  - length_desc                       -> NULL and 0 excluded, longest first, length in item
  TEST 6  - length_asc, equal km              -> tie broken by the centre line in metres (lengthM)
  TEST 7  - area_desc                         -> largest surface first, NULL excluded
  TEST 8  - depth_desc                        -> deepest first, 0 excluded
  TEST 9  - offset + limit                    -> one page, total counts every match, offset echoed
  TEST 10 - unknown sort                      -> name order
*/
PRINT 'Unit tests for fn_river_search_json (region, type, sort, paging)';
GO
-- ============================================================================
-- TEST 1: state alone matches the source OR the mouth
-- ============================================================================
BEGIN TRAN RSR_Test1
    declare @test_name sysname = N'RSR_Test1 [fn_river_search_json] : state alone'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@A, 2, N'Utrsr1 A River'), (@B, 2, N'Utrsr1 B River'), (@C, 2, N'Utrsr1 C River');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @A AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'RR' WHERE Main_Lake_id = @B AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @C AND side = 32;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, NULL, 'qq', NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr1 A River'
  OR JSON_VALUE(@json, '$.items[1].lakeName') <> N'Utrsr1 C River'
   RAISERROR ('TEST 1 FAIL [%dms]: state must match source or mouth', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: state matched source and mouth'

ROLLBACK TRAN RSR_Test1
GO
-- ============================================================================
-- TEST 2: country alone
-- ============================================================================
BEGIN TRAN RSR_Test2
    declare @test_name sysname = N'RSR_Test2 [fn_river_search_json] : country alone'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@A, 2, N'Utrsr2 A River'), (@B, 2, N'Utrsr2 B River');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @A AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'RR' WHERE Main_Lake_id = @B AND side = 32;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'zz', NULL, NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.items')) <> 2
   RAISERROR ('TEST 2 FAIL [%dms]: country must match every state of it', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: country matched both states'

ROLLBACK TRAN RSR_Test2
GO
-- ============================================================================
-- TEST 3: type bitmask
-- ============================================================================
BEGIN TRAN RSR_Test3
    declare @test_name sysname = N'RSR_Test3 [fn_river_search_json] : type bitmask'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@A, 2, N'Utrsr3 A River'), (@B, 64, N'Utrsr3 B Creek'), (@C, 1, N'Utrsr3 C Lake');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B, @C) AND side = 16;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'ZZ', 'QQ', 66, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr3 A River'
  OR JSON_VALUE(@json, '$.items[1].lakeName') <> N'Utrsr3 B Creek'
   RAISERROR ('TEST 3 FAIL [%dms]: type 66 must keep river and creek only', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: type 66 kept river and creek'

ROLLBACK TRAN RSR_Test3
GO
-- ============================================================================
-- TEST 4: type alone is not a search
-- ============================================================================
BEGIN TRAN RSR_Test4
    declare @test_name sysname = N'RSR_Test4 [fn_river_search_json] : type alone'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (NEWID(), 2, N'Utrsr4 River');

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, NULL, NULL, 2, 'length_desc', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '0'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.items')) <> 0
   RAISERROR ('TEST 4 FAIL [%dms]: type alone must return total 0', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: type alone returned total 0'

ROLLBACK TRAN RSR_Test4
GO
-- ============================================================================
-- TEST 5: length_desc
-- ============================================================================
BEGIN TRAN RSR_Test5
    declare @test_name sysname = N'RSR_Test5 [fn_river_search_json] : length_desc'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID(), @D uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, length)
VALUES (@A, 2, N'Utrsr5 A River', 50), (@B, 2, N'Utrsr5 B River', 120), (@C, 2, N'Utrsr5 C River', NULL), (@D, 2, N'Utrsr5 D River', 0);
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B, @C, @D) AND side = 16;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'ZZ', 'QQ', 2, 'length_desc', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr5 B River'
  OR JSON_VALUE(@json, '$.items[0].length')   <> '120'
  OR JSON_VALUE(@json, '$.items[1].lakeName') <> N'Utrsr5 A River'
   RAISERROR ('TEST 5 FAIL [%dms]: longest first, NULL and 0 excluded', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: longest first, NULL and 0 excluded'

ROLLBACK TRAN RSR_Test5
GO
-- ============================================================================
-- TEST 6: length_asc - equal km broken by the centre line in metres
-- ============================================================================
BEGIN TRAN RSR_Test6
    declare @test_name sysname = N'RSR_Test6 [fn_river_search_json] : length_asc tie'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, length)
VALUES (@A, 2, N'Utrsr6 A River', 1), (@B, 2, N'Utrsr6 B River', 1), (@C, 2, N'Utrsr6 C River', 3);
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B, @C) AND side = 16;
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@A, geography::STGeomFromText('LINESTRING(-70.5 45, -70.5 45.02)', 4326), 1);
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@B, geography::STGeomFromText('LINESTRING(-70.6 45, -70.6 45.01)', 4326), 1);

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'ZZ', 'QQ', NULL, 'length_asc', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '3'
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr6 B River'
  OR JSON_VALUE(@json, '$.items[1].lakeName') <> N'Utrsr6 A River'
  OR JSON_VALUE(@json, '$.items[2].lakeName') <> N'Utrsr6 C River'
  OR TRY_CONVERT(int, JSON_VALUE(@json, '$.items[0].lengthM')) NOT BETWEEN 1100 AND 1125
  OR JSON_VALUE(@json, '$.items[2].lengthM') IS NOT NULL
   RAISERROR ('TEST 6 FAIL [%dms]: equal km must be ordered by line metres', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: equal km ordered by line metres'

ROLLBACK TRAN RSR_Test6
GO
-- ============================================================================
-- TEST 7: area_desc
-- ============================================================================
BEGIN TRAN RSR_Test7
    declare @test_name sysname = N'RSR_Test7 [fn_river_search_json] : area_desc'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, surface)
VALUES (@A, 1, N'Utrsr7 A Lake', 5), (@B, 1, N'Utrsr7 B Lake', 20), (@C, 1, N'Utrsr7 C Lake', NULL);
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B, @C) AND side = 16;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, NULL, 'QQ', 1, 'area_desc', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr7 B Lake'
  OR JSON_VALUE(@json, '$.items[0].area')     <> '20'
   RAISERROR ('TEST 7 FAIL [%dms]: largest area first, NULL excluded', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: largest area first, NULL excluded'

ROLLBACK TRAN RSR_Test7
GO
-- ============================================================================
-- TEST 8: depth_desc
-- ============================================================================
BEGIN TRAN RSR_Test8
    declare @test_name sysname = N'RSR_Test8 [fn_river_search_json] : depth_desc'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, depth)
VALUES (@A, 1, N'Utrsr8 A Lake', 10), (@B, 1, N'Utrsr8 B Lake', 30), (@C, 1, N'Utrsr8 C Lake', 0);
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B, @C) AND side = 16;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'ZZ', NULL, NULL, 'depth_desc', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR JSON_VALUE(@json, '$.items[0].depth') <> '30'
  OR JSON_VALUE(@json, '$.items[1].depth') <> '10'
   RAISERROR ('TEST 8 FAIL [%dms]: deepest first, 0 excluded', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: deepest first, 0 excluded'

ROLLBACK TRAN RSR_Test8
GO
-- ============================================================================
-- TEST 9: offset + limit
-- ============================================================================
BEGIN TRAN RSR_Test9
    declare @test_name sysname = N'RSR_Test9 [fn_river_search_json] : offset and limit'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, length)
VALUES (@A, 2, N'Utrsr9 A River', 10), (@B, 2, N'Utrsr9 B River', 20), (@C, 2, N'Utrsr9 C River', 30);
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B, @C) AND side = 16;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'ZZ', 'QQ', NULL, 'length_desc', 1, 1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '')  <> '3'
  OR ISNULL(JSON_VALUE(@json, '$.offset'), '') <> '1'
  OR ISNULL(JSON_VALUE(@json, '$.limit'), '')  <> '1'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.items')) <> 1
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr9 B River'
   RAISERROR ('TEST 9 FAIL [%dms]: page 2 of 1 must be the second longest', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: offset 1 gave the second longest'

ROLLBACK TRAN RSR_Test9
GO
-- ============================================================================
-- TEST 10: unknown sort falls back to name order
-- ============================================================================
BEGIN TRAN RSR_Test10
    declare @test_name sysname = N'RSR_Test10 [fn_river_search_json] : unknown sort'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name, length)
VALUES (@A, 2, N'Utrsr10 A River', 10), (@B, 2, N'Utrsr10 B River', NULL);
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id IN (@A, @B) AND side = 16;

SET @json = dbo.fn_river_search_json(NULL, NULL, NULL, NULL, NULL, 'ZZ', 'QQ', NULL, 'bogus', NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '2'
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utrsr10 A River'
  OR JSON_VALUE(@json, '$.items[1].lakeName') <> N'Utrsr10 B River'
   RAISERROR ('TEST 10 FAIL [%dms]: unknown sort must keep name order', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown sort kept name order'

ROLLBACK TRAN RSR_Test10
GO
