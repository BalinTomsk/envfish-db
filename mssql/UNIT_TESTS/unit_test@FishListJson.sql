SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_fish_list_json (the whole species catalogue as one JSON array).

  Caller: FishTracker.WebService.TFishService.Page_Load -- ~/WebService/Fish/Default.aspx, the
  public read-only species endpoint. It writes the returned string straight to the response body,
  so the function owns the entire contract: a well-formed array, never NULL, exactly two members
  per element ("name" and "latin"), one element per row of dbo.fish.

  Uses the real dbo.fish table (and the real seeded catalogue for the whole-table assertions).
  Each test runs in its own named transaction, rolled back at the end of its own GO batch -
  database state fully restored.

  TEST 1 - the array carries one element per dbo.fish row, with exactly the members name + latin
  TEST 2 - a species inserted in this transaction comes back with its exact name/latin pair
  TEST 3 - elements are ordered ascending by common name
  TEST 4 - a name holding JSON-hostile characters is escaped, so the document stays parseable
           and round-trips to the stored value unchanged
  TEST 5 - an empty catalogue yields the literal '[]', not NULL
  TEST 6 - @water_type = 1 keeps every species carrying the Freshwater bit, including the
           combined values (5, 9, 3) that a water_type = 1 equality test would silently drop,
           and excludes saltwater-only / 0 / NULL
  TEST 7 - a multi-bit mask requires ALL of its bits, not any of them
  TEST 8 - @water_type = 0 and NULL both mean "no filter" and agree with each other
  TEST 9 - the filtered document keeps the shape and ordering contract of the unfiltered one
  TEST 10 - searching a common name returns that species, latin name readable at element [0]
  TEST 11 - the search also covers the latin name, is case-insensitive, and matches substrings
  TEST 12 - LIKE metacharacters (%, _, [) in the term are searched as literals, not wildcards
  TEST 13 - an exact common-name hit is ordered ahead of longer partial matches
  TEST 14 - search ANDs with the water filter; no hits is [], a blank term means no search
*/

-- ===================================================================================
-- TEST 1: shape of the document -- element count matches the table, and no element
--         carries anything besides "name" and "latin" (the endpoint is a fixed
--         two-field contract; an extra column leaking in would be a breaking change).
-- ===================================================================================
BEGIN TRAN Test01FishListShape
    DECLARE @test_name sysname = N'Test01FishListShape [fn_fish_list_json] : one element per fish, two members each'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @isJson int, @elements int, @rows int, @badMembers int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_fish_list_json(NULL, NULL);

SET @isJson = ISJSON(@json);
SELECT @rows = COUNT(*) FROM dbo.fish;
SELECT @elements = COUNT(*) FROM OPENJSON(@json);

-- every element must expose the two expected members and nothing else
SELECT @badMembers = COUNT(*)
FROM OPENJSON(@json) e
CROSS APPLY (SELECT COUNT(*) AS memberCount,
                    SUM(CASE WHEN m.[key] IN (N'name', N'latin') THEN 1 ELSE 0 END) AS knownCount
             FROM OPENJSON(e.value) m) k
WHERE k.memberCount <> 2 OR k.knownCount <> 2;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @isJson = 1 AND @elements = @rows AND @rows > 0 AND @badMembers = 0
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_fish_list_json returned one name/latin element per fish row';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: isjson=%d elements=%d rows=%d badMembers=%d', 16, -1, @ElapsedMs, @isJson, @elements, @rows, @badMembers);

ROLLBACK TRAN Test01FishListShape
GO

-- ===================================================================================
-- TEST 2: a species added to the catalogue is published by the endpoint, name paired
--         with its own latin name (not another row's).
-- ===================================================================================
BEGIN TRAN Test02FishListNewSpecies
    DECLARE @test_name sysname = N'Test02FishListNewSpecies [fn_fish_list_json] : inserted species returned with its latin name'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @latin nvarchar(64), @hits int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin)
VALUES (NEWID(), 'UT FLJ Needlefish', 'Ut flj strongylura');

SET @json = dbo.fn_fish_list_json(NULL, NULL);

SELECT @hits = COUNT(*), @latin = MAX(JSON_VALUE(e.value, '$.latin'))
FROM OPENJSON(@json) e
WHERE JSON_VALUE(e.value, '$.name') = N'UT FLJ Needlefish';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @hits = 1 AND @latin = N'Ut flj strongylura'
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the inserted species is published once with its own latin name';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected 1 element with latin=Ut flj strongylura, got hits=%d latin=%s', 16, -1, @ElapsedMs, @hits, @latin);

ROLLBACK TRAN Test02FishListNewSpecies
GO

-- ===================================================================================
-- TEST 3: ordering. The endpoint publishes the list ready to render, so the array is
--         sorted by common name -- the caller does not re-sort.
-- ===================================================================================
BEGIN TRAN Test03FishListOrdered
    DECLARE @test_name sysname = N'Test03FishListOrdered [fn_fish_list_json] : elements ordered by common name'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @outOfOrder int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_fish_list_json(NULL, NULL);

SELECT @outOfOrder = COUNT(*)
FROM (
    SELECT JSON_VALUE(e.value, '$.name') AS name,
           LAG(JSON_VALUE(e.value, '$.name')) OVER (ORDER BY CAST(e.[key] AS int)) AS prev
    FROM OPENJSON(@json) e
) q
WHERE q.prev IS NOT NULL AND q.name < q.prev;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @outOfOrder = 0
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the array is ordered ascending by common name';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: %d element(s) sort before their predecessor', 16, -1, @ElapsedMs, @outOfOrder);

ROLLBACK TRAN Test03FishListOrdered
GO

-- ===================================================================================
-- TEST 4: escaping. fish_name / fish_latin are free text typed on Editor/FishEditor.aspx,
--         so a double quote or a backslash can reach the catalogue. FOR JSON escapes both;
--         this pins that down, because an unescaped quote would corrupt the whole document
--         (not just its own element) for every consumer of the endpoint.
-- ===================================================================================
BEGIN TRAN Test04FishListEscaping
    DECLARE @test_name sysname = N'Test04FishListEscaping [fn_fish_list_json] : quotes and backslashes escaped'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @isJson int, @back nvarchar(64), @stored varchar(32);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @stored = 'UT FLJ ' + CHAR(34) + 'Pike' + CHAR(34) + CHAR(92) + 'Perch';

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin)
VALUES (NEWID(), @stored, 'Ut flj esox escapatus');

SET @json = dbo.fn_fish_list_json(NULL, NULL);

SET @isJson = ISJSON(@json);

SELECT @back = JSON_VALUE(e.value, '$.name')
FROM OPENJSON(@json) e
WHERE JSON_VALUE(e.value, '$.latin') = N'Ut flj esox escapatus';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @isJson = 1 AND @back = @stored
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: quotes and backslashes survive as escapes, document still parseable';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: isjson=%d round-tripped name=%s', 16, -1, @ElapsedMs, @isJson, @back);

ROLLBACK TRAN Test04FishListEscaping
GO

-- ===================================================================================
-- TEST 5: an empty catalogue must still be a usable document. FOR JSON returns NULL for
--         no rows, and the caller writes the result verbatim to the response body, so a
--         NULL would ship an empty body instead of a parseable array -- hence the ISNULL
--         guard. dbo.fish is referenced by many foreign keys that carry no ON DELETE
--         CASCADE, so they are switched off for the length of this transaction and
--         switched back on before the rollback (the same technique as
--         unit_test@ForecastPlotJson.sql TEST 2).
-- ===================================================================================
BEGIN TRAN Test05FishListEmptyCatalogue
    DECLARE @test_name sysname = N'Test05FishListEmptyCatalogue [fn_fish_list_json] : empty catalogue yields []'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @off nvarchar(MAX) = N'', @on nvarchar(MAX) = N'';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SELECT @off = @off + N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                   + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' NOCHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';',
       @on  = @on  + N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                   + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' CHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';'
FROM sys.foreign_keys fk
WHERE fk.referenced_object_id = OBJECT_ID('dbo.fish');

EXEC sp_executesql @off;

DELETE FROM dbo.fish;

SET @json = dbo.fn_fish_list_json(NULL, NULL);

EXEC sp_executesql @on;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json = N'[]'
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: an empty catalogue returns [] rather than NULL';
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: expected [], got %s', 16, -1, @ElapsedMs, @json);

ROLLBACK TRAN Test05FishListEmptyCatalogue
GO

-- ===================================================================================
-- FIXTURES for TEST 6-9: dbo.fish.water_type is a BITMASK, so freshwater species are not
-- only the ones stored as exactly 1. On the live database 637 rows hold water_type = 1 but
-- 756 carry the Freshwater bit; the other 119 are combinations such as 5 (Fresh+Clear),
-- 9 (Fresh+Low velocity) and 3 (Fresh+Salt, the diadromous species). These tests exist to
-- stop the filter regressing to an equality test, which is what dbo.fn_map_fish_list_bylatlon
-- does today.
-- ===================================================================================

-- ===================================================================================
-- TEST 6: the freshwater mask keeps plain and combined freshwater, drops the rest
-- ===================================================================================
BEGIN TRAN Test06FishListFreshwaterMask
    DECLARE @test_name sysname = N'Test06FishListFreshwaterMask [fn_fish_list_json] : water_type bit 1 matched as a mask'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLJ W1 Plain',   'Ut flj w one',   1),      -- Freshwater
  (NEWID(), 'UT FLJ W3 Diadrom', 'Ut flj w three', 3),      -- Freshwater + Saltwater
  (NEWID(), 'UT FLJ W5 Clear',   'Ut flj w five',  5),      -- Freshwater + Clear water
  (NEWID(), 'UT FLJ W9 Slow',    'Ut flj w nine',  9),      -- Freshwater + Low velocity
  (NEWID(), 'UT FLJ W2 Salt',    'Ut flj w two',   2),      -- Saltwater only
  (NEWID(), 'UT FLJ W0 Zero',    'Ut flj w zero',  0),      -- nothing recorded
  (NEWID(), 'UT FLJ WN Null',    'Ut flj w null',  NULL);   -- nothing recorded

SET @json = dbo.fn_fish_list_json(1, NULL);

SELECT @kept = STRING_AGG(CAST(JSON_VALUE(e.value, '$.name') AS nvarchar(MAX)), ',')
                 WITHIN GROUP (ORDER BY JSON_VALUE(e.value, '$.name'))
FROM OPENJSON(@json) e
WHERE JSON_VALUE(e.value, '$.name') LIKE N'UT FLJ W%';

SET @expected = N'UT FLJ W1 Plain,UT FLJ W3 Diadrom,UT FLJ W5 Clear,UT FLJ W9 Slow';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: freshwater mask kept plain and combined freshwater, dropped salt-only/0/NULL';
ELSE
    RAISERROR ('TEST 6 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test06FishListFreshwaterMask
GO

-- ===================================================================================
-- TEST 7: a multi-bit mask is an AND, not an OR. Asking for Freshwater + Clear water (5)
--         must not return a species that carries only one of the two.
-- ===================================================================================
BEGIN TRAN Test07FishListMultiBitMask
    DECLARE @test_name sysname = N'Test07FishListMultiBitMask [fn_fish_list_json] : multi-bit mask requires every bit'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLJ M1 FreshOnly', 'Ut flj m one',      1),   -- Freshwater only          -> no
  (NEWID(), 'UT FLJ M4 ClearOnly', 'Ut flj m four',     4),   -- Clear water only         -> no
  (NEWID(), 'UT FLJ M5 Both',      'Ut flj m five',     5),   -- Freshwater + Clear       -> yes
  (NEWID(), 'UT FLJ M13 Superset', 'Ut flj m onethree', 13);  -- Fresh + Clear + Low vel. -> yes

SET @json = dbo.fn_fish_list_json(5, NULL);

SELECT @kept = STRING_AGG(CAST(JSON_VALUE(e.value, '$.name') AS nvarchar(MAX)), ',')
                 WITHIN GROUP (ORDER BY JSON_VALUE(e.value, '$.name'))
FROM OPENJSON(@json) e
WHERE JSON_VALUE(e.value, '$.name') LIKE N'UT FLJ M%';

SET @expected = N'UT FLJ M13 Superset,UT FLJ M5 Both';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a multi-bit mask matched only rows carrying every requested bit';
ELSE
    RAISERROR ('TEST 7 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test07FishListMultiBitMask
GO

-- ===================================================================================
-- TEST 8: 0 and NULL are both "no filter". 0 falls out of the bitmask arithmetic for free
--         (x & 0 = 0 always), so this pins the behaviour down as intended rather than
--         accidental -- the endpoint never sends 0, but a future caller might.
-- ===================================================================================
BEGIN TRAN Test08FishListNoFilterSame
    DECLARE @test_name sysname = N'Test08FishListNoFilterSame [fn_fish_list_json] : 0 and NULL both mean no filter'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @jNull nvarchar(MAX), @jZero nvarchar(MAX), @rows int, @nullCount int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @jNull = dbo.fn_fish_list_json(NULL, NULL);
SET @jZero = dbo.fn_fish_list_json(0, NULL);

SELECT @rows = COUNT(*) FROM dbo.fish;
SELECT @nullCount = COUNT(*) FROM OPENJSON(@jNull);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @jNull = @jZero AND @nullCount = @rows AND @rows > 0
    PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mask 0 and NULL both returned the whole catalogue, byte for byte';
ELSE
    RAISERROR ('TEST 8 FAIL [%dms]: documents differ or count is wrong (elements=%d rows=%d)', 16, -1, @ElapsedMs, @nullCount, @rows);

ROLLBACK TRAN Test08FishListNoFilterSame
GO

-- ===================================================================================
-- TEST 9: filtering must not weaken the contract the endpoint publishes -- still valid
--         JSON, still exactly name+latin per element, still ordered, and a strict subset
--         of the unfiltered document.
-- ===================================================================================
BEGIN TRAN Test09FishListFilteredContract
    DECLARE @test_name sysname = N'Test09FishListFilteredContract [fn_fish_list_json] : filtered document keeps shape and ordering'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @all nvarchar(MAX);
DECLARE @isJson int, @elements int, @expected int, @badMembers int, @outOfOrder int, @notInAll int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- the seeded catalogue (script09_fish_data.sql) records no water_type at all, so this test
-- supplies its own freshwater rows rather than assume the build has any
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLJ C1 Fresh',  'Ut flj c one',   1),
  (NEWID(), 'UT FLJ C5 Fresh',  'Ut flj c five',  5),
  (NEWID(), 'UT FLJ C9 Fresh',  'Ut flj c nine',  9),
  (NEWID(), 'UT FLJ C2 Salt',   'Ut flj c two',   2),
  (NEWID(), 'UT FLJ CN Absent', 'Ut flj c null',  NULL);

SET @json = dbo.fn_fish_list_json(1, NULL);
SET @all  = dbo.fn_fish_list_json(NULL, NULL);

SET @isJson = ISJSON(@json);
SELECT @elements = COUNT(*) FROM OPENJSON(@json);
SELECT @expected = COUNT(*) FROM dbo.fish WHERE ( ISNULL(water_type, 0) & 1 ) = 1;

SELECT @badMembers = COUNT(*)
FROM OPENJSON(@json) e
CROSS APPLY (SELECT COUNT(*) AS memberCount,
                    SUM(CASE WHEN m.[key] IN (N'name', N'latin') THEN 1 ELSE 0 END) AS knownCount
             FROM OPENJSON(e.value) m) k
WHERE k.memberCount <> 2 OR k.knownCount <> 2;

SELECT @outOfOrder = COUNT(*)
FROM (
    SELECT JSON_VALUE(e.value, '$.name') AS name,
           LAG(JSON_VALUE(e.value, '$.name')) OVER (ORDER BY CAST(e.[key] AS int)) AS prev
    FROM OPENJSON(@json) e
) q
WHERE q.prev IS NOT NULL AND q.name < q.prev;

-- every filtered element must also appear in the unfiltered document
SELECT @notInAll = COUNT(*)
FROM OPENJSON(@json) e
WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(@all) a
                   WHERE JSON_VALUE(a.value, '$.name') = JSON_VALUE(e.value, '$.name'));

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @isJson = 1 AND @elements = @expected AND @elements > 0 AND @badMembers = 0 AND @outOfOrder = 0 AND @notInAll = 0
    PRINT 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the filtered document is a well-formed, ordered subset of the full one';
ELSE
    RAISERROR ('TEST 9 FAIL [%dms]: isjson=%d elements=%d expected=%d badMembers=%d outOfOrder=%d notInAll=%d', 16, -1, @ElapsedMs, @isJson, @elements, @expected, @badMembers, @outOfOrder, @notInAll);

ROLLBACK TRAN Test09FishListFilteredContract
GO

-- ===================================================================================
-- TEST 10: the headline case -- searching a common name returns that species, so the
--          caller reads the latin name out of element [0].
-- ===================================================================================
BEGIN TRAN Test10FishListSearchByName
    DECLARE @test_name sysname = N'Test10FishListSearchByName [fn_fish_list_json] : search by common name'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @hits int, @latin nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
VALUES (NEWID(), 'UT FLJ Burbot', 'Ut flj lota', 1);

SET @json = dbo.fn_fish_list_json(NULL, 'UT FLJ Burbot');

SELECT @hits = COUNT(*) FROM OPENJSON(@json);
SET @latin = JSON_VALUE(@json, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @hits = 1 AND @latin = N'Ut flj lota'
    PRINT 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: searching a common name returned that species and its latin name';
ELSE
    RAISERROR ('TEST 10 FAIL [%dms]: expected 1 hit with latin=Ut flj lota, got hits=%d latin=%s', 16, -1, @ElapsedMs, @hits, @latin);

ROLLBACK TRAN Test10FishListSearchByName
GO

-- ===================================================================================
-- TEST 11: the search covers the latin name too, and is case-insensitive in both
--          directions (the database collation is CI, which this pins down).
-- ===================================================================================
BEGIN TRAN Test11FishListSearchLatinCase
    DECLARE @test_name sysname = N'Test11FishListSearchLatinCase [fn_fish_list_json] : latin name and case-insensitivity'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @byLatin nvarchar(MAX), @byLower nvarchar(MAX), @byUpper nvarchar(MAX), @partial nvarchar(MAX);
DECLARE @nLatin int, @nLower int, @nUpper int, @nPartial int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
VALUES (NEWID(), 'UT FLJ Zander', 'Ut flj sander luc', 1);

SET @byLatin = dbo.fn_fish_list_json(NULL, 'Ut flj sander luc');   -- found by latin name
SET @byLower = dbo.fn_fish_list_json(NULL, 'ut flj zander');       -- lower case
SET @byUpper = dbo.fn_fish_list_json(NULL, 'UT FLJ ZANDER');       -- upper case
SET @partial = dbo.fn_fish_list_json(NULL, 'FLJ Zand');            -- substring, not a prefix

SELECT @nLatin   = COUNT(*) FROM OPENJSON(@byLatin) WHERE JSON_VALUE(value, '$.name') = N'UT FLJ Zander';
SELECT @nLower   = COUNT(*) FROM OPENJSON(@byLower) WHERE JSON_VALUE(value, '$.name') = N'UT FLJ Zander';
SELECT @nUpper   = COUNT(*) FROM OPENJSON(@byUpper) WHERE JSON_VALUE(value, '$.name') = N'UT FLJ Zander';
SELECT @nPartial = COUNT(*) FROM OPENJSON(@partial) WHERE JSON_VALUE(value, '$.name') = N'UT FLJ Zander';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @nLatin = 1 AND @nLower = 1 AND @nUpper = 1 AND @nPartial = 1
    PRINT 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: found by latin name, either case, and by an inner substring';
ELSE
    RAISERROR ('TEST 11 FAIL [%dms]: latin=%d lower=%d upper=%d partial=%d (each must be 1)', 16, -1, @ElapsedMs, @nLatin, @nLower, @nUpper, @nPartial);

ROLLBACK TRAN Test11FishListSearchLatinCase
GO

-- ===================================================================================
-- TEST 12: LIKE metacharacters in the search term are neutralized. Without escaping,
--          a term of '%' would return the WHOLE catalogue from what the caller believes
--          is a search -- the same class of bug as an unescaped quote, but silent.
-- ===================================================================================
BEGIN TRAN Test12FishListSearchWildcard
    DECLARE @test_name sysname = N'Test12FishListSearchWildcard [fn_fish_list_json] : LIKE wildcards treated as literals'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @pct nvarchar(MAX), @und nvarchar(MAX), @brk nvarchar(MAX);
DECLARE @nPct int, @nUnd int, @nBrk int, @rows int, @pctName nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLJ 100% Pike',  'Ut flj pct',    1),
  (NEWID(), 'UT FLJ Under_Bass', 'Ut flj und',    1),
  (NEWID(), 'UT FLJ [Bracket]',  'Ut flj brk',    1);

SELECT @rows = COUNT(*) FROM dbo.fish;

SET @pct = dbo.fn_fish_list_json(NULL, '%');        -- literal percent: only the 100% row
SET @und = dbo.fn_fish_list_json(NULL, 'Under_');   -- literal underscore
SET @brk = dbo.fn_fish_list_json(NULL, '[Bracket'); -- literal bracket

SELECT @nPct = COUNT(*) FROM OPENJSON(@pct);
SET @pctName = JSON_VALUE(@pct, '$[0].name');
SELECT @nUnd = COUNT(*) FROM OPENJSON(@und);
SELECT @nBrk = COUNT(*) FROM OPENJSON(@brk);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @nPct = 1 AND @pctName = N'UT FLJ 100% Pike' AND @nPct < @rows AND @nUnd = 1 AND @nBrk = 1
    PRINT 'TEST 12 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: %, _ and [ searched as literals, not as wildcards';
ELSE
    RAISERROR ('TEST 12 FAIL [%dms]: pct=%d (of %d rows, name=%s) underscore=%d bracket=%d', 16, -1, @ElapsedMs, @nPct, @rows, @pctName, @nUnd, @nBrk);

ROLLBACK TRAN Test12FishListSearchWildcard
GO

-- ===================================================================================
-- TEST 13: an exact common-name hit sorts first, ahead of longer names that merely
--          contain the term. The endpoint's whole point is that element [0] is the
--          species the caller asked for, so alphabetical order alone is not enough --
--          here 'UT FLJ Bass' would otherwise sort behind 'UT FLJ Bass, Largemouth'
--          only by luck, and behind 'UT FLJ Aaa Bass' certainly.
-- ===================================================================================
BEGIN TRAN Test13FishListSearchExactFirst
    DECLARE @test_name sysname = N'Test13FishListSearchExactFirst [fn_fish_list_json] : exact name ordered first'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @first nvarchar(64), @firstLatin nvarchar(64), @hits int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLJ Aaa Bass',   'Ut flj bass aaa',  1),
  (NEWID(), 'UT FLJ Bass',       'Ut flj bass real', 1),
  (NEWID(), 'UT FLJ Bass Large', 'Ut flj bass lg',   1);

SET @json = dbo.fn_fish_list_json(NULL, 'UT FLJ Bass');

SELECT @hits = COUNT(*) FROM OPENJSON(@json);
SET @first      = JSON_VALUE(@json, '$[0].name');
SET @firstLatin = JSON_VALUE(@json, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @hits = 3 AND @first = N'UT FLJ Bass' AND @firstLatin = N'Ut flj bass real'
    PRINT 'TEST 13 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the exact name sorted ahead of the two partial matches';
ELSE
    RAISERROR ('TEST 13 FAIL [%dms]: hits=%d first=%s latin=%s', 16, -1, @ElapsedMs, @hits, @first, @firstLatin);

ROLLBACK TRAN Test13FishListSearchExactFirst
GO

-- ===================================================================================
-- TEST 14: search and water-type filter are ANDed, a search with no hits is an empty
--          array (not an error, and not the whole catalogue), and a blank term means
--          "no search" the same way NULL does.
-- ===================================================================================
BEGIN TRAN Test14FishListSearchCombined
    DECLARE @test_name sysname = N'Test14FishListSearchCombined [fn_fish_list_json] : search ANDed with water filter'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @fresh nvarchar(MAX), @salt nvarchar(MAX), @miss nvarchar(MAX), @blank nvarchar(MAX), @all nvarchar(MAX);
DECLARE @nFresh int, @nSalt int, @nMiss int, @freshName nvarchar(64), @blankSame int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLJ Combo Fresh', 'Ut flj combo f', 1),
  (NEWID(), 'UT FLJ Combo Salt',  'Ut flj combo s', 2);

SET @fresh = dbo.fn_fish_list_json(1, 'UT FLJ Combo');      -- both match the term, one the mask
SET @salt  = dbo.fn_fish_list_json(2, 'UT FLJ Combo');
SET @miss  = dbo.fn_fish_list_json(NULL, 'UT FLJ NoSuchSpeciesAnywhere');
SET @blank = dbo.fn_fish_list_json(NULL, '   ');
SET @all   = dbo.fn_fish_list_json(NULL, NULL);

SELECT @nFresh = COUNT(*) FROM OPENJSON(@fresh);
SET @freshName = JSON_VALUE(@fresh, '$[0].name');
SELECT @nSalt = COUNT(*) FROM OPENJSON(@salt);
SELECT @nMiss = COUNT(*) FROM OPENJSON(@miss);
SET @blankSame = CASE WHEN @blank = @all THEN 1 ELSE 0 END;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @nFresh = 1 AND @freshName = N'UT FLJ Combo Fresh' AND @nSalt = 1
   AND @nMiss = 0 AND @miss = N'[]' AND @blankSame = 1
    PRINT 'TEST 14 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: filters ANDed, no-hit search returned [], blank term matched NULL';
ELSE
    RAISERROR ('TEST 14 FAIL [%dms]: fresh=%d (%s) salt=%d miss=%d blankEqualsAll=%d', 16, -1, @ElapsedMs, @nFresh, @freshName, @nSalt, @nMiss, @blankSame);

ROLLBACK TRAN Test14FishListSearchCombined
GO
