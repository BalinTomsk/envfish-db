SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_fish_water_bodies_json(@fish_id, @country, @state, @loc_type, @min_probability, @limit):
    the water bodies where one fish species is recorded, filtered by country/state, water-body type and
    minimum probability, each water body counted ONCE. Served by docapi's MCP tool
    find_water_bodies_by_fish via JdbcFishQueryRepository.waterBodies.

  Fixture notes: every fixture sits in country 'ZZ' so seed data never matches; the fish and family are
  created per test; names carry the token 'utfwb'. Inserting a lake creates its source (16) and mouth (32)
  Tributaries rows by trigger, so fixtures UPDATE those rows rather than inserting their own.

  TEST 1 - three probability rows on one lake   -> counted once, probability = the highest
  TEST 2 - state filter                          -> only the matching state
  TEST 3 - type bitmask                          -> river only; river|creek includes the creek
  TEST 4 - minimum probability                   -> a lake whose best row is below it is excluded
  TEST 5 - limit                                 -> items capped, total still counts every match, order prob desc
  TEST 6 - state taken from the mouth when the source has none
  TEST 7 - NULL fish                             -> total 0, items []
*/
PRINT 'Unit tests for fn_fish_water_bodies_json (water bodies by species)';
GO
-- ============================================================================
-- TEST 1: several probability rows on one water body are counted once
-- ============================================================================
BEGIN TRAN FWB_Test1
    declare @test_name sysname = N'FWB_Test1 [fn_fish_water_bodies_json] : one entry per water body'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'ut-family-fwb1', 900301, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@F, N'Utfwb-fish1', N'Utfwb one', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utfwb One River');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @L AND side = 16;
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id) VALUES (@L, @F, SYSUTCDATETIME(), 0,   NEWID());
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id) VALUES (@L, @F, SYSUTCDATETIME(), 90,  NEWID());
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id) VALUES (@L, @F, SYSUTCDATETIME(), 100, NEWID());

SET @json = dbo.fn_fish_water_bodies_json(@F, 'ZZ', NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '1'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.items')) <> 1
  OR JSON_VALUE(@json, '$.items[0].probability') <> '100'
  OR JSON_VALUE(@json, '$.items[0].lakeName')    <> N'Utfwb One River'
  OR JSON_VALUE(@json, '$.items[0].state')       <> 'QQ'
   RAISERROR ('TEST 1 FAIL [%dms]: one lake, once, at its best probability', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: 3 rows -> 1 lake at probability 100'

ROLLBACK TRAN FWB_Test1
GO
-- ============================================================================
-- TEST 2: state filter
-- ============================================================================
BEGIN TRAN FWB_Test2
    declare @test_name sysname = N'FWB_Test2 [fn_fish_water_bodies_json] : state filter'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'ut-family-fwb2', 900302, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@F, N'Utfwb-fish2', N'Utfwb two', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@A, 2, N'Utfwb QQ River'), (@B, 2, N'Utfwb RR River');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @A AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'RR' WHERE Main_Lake_id = @B AND side = 16;
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id)
VALUES (@A, @F, SYSUTCDATETIME(), 100, NEWID()), (@B, @F, SYSUTCDATETIME(), 100, NEWID());

SET @json = dbo.fn_fish_water_bodies_json(@F, 'zz', 'qq', NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '1'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.items[0].lakeId')) <> @A
   RAISERROR ('TEST 2 FAIL [%dms]: only the QQ river may match (codes case-insensitive)', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: state filter keeps only that state'

ROLLBACK TRAN FWB_Test2
GO
-- ============================================================================
-- TEST 3: water-body type bitmask
-- ============================================================================
BEGIN TRAN FWB_Test3
    declare @test_name sysname = N'FWB_Test3 [fn_fish_water_bodies_json] : type bitmask'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json1 nvarchar(max), @json2 nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
DECLARE @Lk uniqueidentifier = NEWID(), @Rv uniqueidentifier = NEWID(), @Ck uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'ut-family-fwb3', 900303, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@F, N'Utfwb-fish3', N'Utfwb three', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lk, 1, N'Utfwb Lake'), (@Rv, 2, N'Utfwb River'), (@Ck, 64, N'Utfwb Creek');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @Lk AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @Rv AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @Ck AND side = 16;
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id)
VALUES (@Lk, @F, SYSUTCDATETIME(), 100, NEWID()), (@Rv, @F, SYSUTCDATETIME(), 100, NEWID()), (@Ck, @F, SYSUTCDATETIME(), 100, NEWID());

SET @json1 = dbo.fn_fish_water_bodies_json(@F, 'ZZ', NULL, 2, NULL, NULL);
SET @json2 = dbo.fn_fish_water_bodies_json(@F, 'ZZ', NULL, 66, NULL, NULL);   -- river | creek

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json1, '$.total'), '') <> '1'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json1, '$.items[0].lakeId')) <> @Rv
  OR ISNULL(JSON_VALUE(@json2, '$.total'), '') <> '2'
   RAISERROR ('TEST 3 FAIL [%dms]: type 2 -> the river only; 66 -> river and creek', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: type bitmask selects rivers / creeks'

ROLLBACK TRAN FWB_Test3
GO
-- ============================================================================
-- TEST 4: minimum probability is applied to the best row of each water body
-- ============================================================================
BEGIN TRAN FWB_Test4
    declare @test_name sysname = N'FWB_Test4 [fn_fish_water_bodies_json] : minimum probability'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @Hi uniqueidentifier = NEWID(), @Lo uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'ut-family-fwb4', 900304, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@F, N'Utfwb-fish4', N'Utfwb four', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Hi, 2, N'Utfwb High River'), (@Lo, 2, N'Utfwb Low River');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @Hi AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @Lo AND side = 16;
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id)
VALUES (@Hi, @F, SYSUTCDATETIME(), 0, NEWID()), (@Hi, @F, SYSUTCDATETIME(), 90, NEWID()), (@Lo, @F, SYSUTCDATETIME(), 0, NEWID());

SET @json = dbo.fn_fish_water_bodies_json(@F, 'ZZ', NULL, NULL, 50, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '1'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.items[0].lakeId')) <> @Hi
  OR JSON_VALUE(@json, '$.items[0].probability') <> '90'
   RAISERROR ('TEST 4 FAIL [%dms]: min 50 keeps the river whose best row is 90 only', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: minimum probability uses the best row'

ROLLBACK TRAN FWB_Test4
GO
-- ============================================================================
-- TEST 5: limit caps the items, total still counts every match; order prob desc, then name
-- ============================================================================
BEGIN TRAN FWB_Test5
    declare @test_name sysname = N'FWB_Test5 [fn_fish_water_bodies_json] : limit and order'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'ut-family-fwb5', 900305, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@F, N'Utfwb-fish5', N'Utfwb five', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@A, 2, N'Utfwb Alpha'), (@B, 2, N'Utfwb Beta'), (@C, 2, N'Utfwb Gamma');
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @A AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @B AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @C AND side = 16;
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id)
VALUES (@A, @F, SYSUTCDATETIME(), 50, NEWID()), (@B, @F, SYSUTCDATETIME(), 100, NEWID()), (@C, @F, SYSUTCDATETIME(), 100, NEWID());

SET @json = dbo.fn_fish_water_bodies_json(@F, 'ZZ', NULL, NULL, NULL, 2);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '3'
  OR ISNULL(JSON_VALUE(@json, '$.limit'), '') <> '2'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.items')) <> 2
  OR JSON_VALUE(@json, '$.items[0].lakeName') <> N'Utfwb Beta'
  OR JSON_VALUE(@json, '$.items[1].lakeName') <> N'Utfwb Gamma'
   RAISERROR ('TEST 5 FAIL [%dms]: total 3, 2 items, 100s first by name', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: limit caps items, total counts all'

ROLLBACK TRAN FWB_Test5
GO
-- ============================================================================
-- TEST 6: state comes from the mouth when the source row has none
-- ============================================================================
BEGIN TRAN FWB_Test6
    declare @test_name sysname = N'FWB_Test6 [fn_fish_water_bodies_json] : state from mouth'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'ut-family-fwb6', 900306, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@F, N'Utfwb-fish6', N'Utfwb six', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utfwb Mouth River');
UPDATE dbo.Tributaries SET Country = NULL, State = NULL WHERE Main_Lake_id = @L AND side = 16;
UPDATE dbo.Tributaries SET Country = 'ZZ', State = 'QQ' WHERE Main_Lake_id = @L AND side = 32;
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, probability, lake_fish_id) VALUES (@L, @F, SYSUTCDATETIME(), 100, NEWID());

SET @json = dbo.fn_fish_water_bodies_json(@F, 'ZZ', 'QQ', NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '1'
  OR JSON_VALUE(@json, '$.items[0].country') <> 'ZZ'
   RAISERROR ('TEST 6 FAIL [%dms]: a mouth-only location must still match the state', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: state read from the mouth'

ROLLBACK TRAN FWB_Test6
GO
-- ============================================================================
-- TEST 7: NULL fish -> empty result, not an error
-- ============================================================================
BEGIN TRAN FWB_Test7
    declare @test_name sysname = N'FWB_Test7 [fn_fish_water_bodies_json] : null fish'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_fish_water_bodies_json(NULL, 'ZZ', NULL, NULL, NULL, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.total'), '') <> '0'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.items')) <> 0
   RAISERROR ('TEST 7 FAIL [%dms]: no fish -> total 0 and no items', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: null fish -> empty result'

ROLLBACK TRAN FWB_Test7
GO
