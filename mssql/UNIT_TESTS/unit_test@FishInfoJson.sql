SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_fish_info_json(@fish_id): everything known about one species, without images.
  Served by docapi's MCP tool get_fish via JdbcFishQueryRepository.info.

  Fixture notes: the fish and family are created per test; names carry the token 'utfij'. Inserting a fish
  creates its habitat rule (periodStart = periodEnd = -1) and a default spawn rule by trigger, so fixtures
  UPDATE those rules rather than inserting their own.

  TEST 1 - general fields, family, decoded bitmasks
  TEST 2 - habitat rule and its intervals
  TEST 3 - zoology, spawn and food
  TEST 4 - codes, top ranks, catch curves, predators/prey, records, documents
  TEST 5 - no image data in the document
  TEST 6 - unknown or NULL fish -> NULL
  TEST 7 - a bare fish (name only) -> empty arrays, no error
*/
PRINT 'Unit tests for fn_fish_info_json (one species, no images)';
GO
-- ============================================================================
-- TEST 1: general fields, family, decoded bitmasks
-- ============================================================================
BEGIN TRAN FIJ_Test1
    declare @test_name sysname = N'FIJ_Test1 [fn_fish_info_json] : general'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, link, created) VALUES (@Fam, N'Utfij family', 900401, 'https://fam.example', SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, alt_Name, descrip, uses
                    , fish_distribution_area, aep, fish_home_range, fish_Type, water_type, fish_ability
                    , fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utfij-fish1', N'Utfij one', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 'Utfij alt', N'A test fish.', N'Food'
      , N'Ontario', 'UTFJ', 2.5, 5, 3, 1, 1, 0);

SET @json = dbo.fn_fish_info_json(@F);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.name'), '')    <> N'Utfij-fish1'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.fishId')) <> @F
  OR JSON_VALUE(@json, '$.latin')                <> N'Utfij one'
  OR JSON_VALUE(@json, '$.altNames')             <> N'Utfij alt'
  OR JSON_VALUE(@json, '$.family.name')          <> N'Utfij family'
  OR JSON_VALUE(@json, '$.distributionArea')     <> N'Ontario'
  OR JSON_VALUE(@json, '$.aepCode')              <> N'UTFJ'
  OR JSON_VALUE(@json, '$.homeRange')            <> '2.50'
  OR JSON_VALUE(@json, '$.moonSensitive')        <> 'true'
  OR JSON_VALUE(@json, '$.types[0]')             <> 'Sport'
  OR JSON_VALUE(@json, '$.types[1]')             <> 'Invading'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.waterTypes')) <> 2
  OR JSON_VALUE(@json, '$.abilities[0]')         <> 'Moon Sensitive'
   RAISERROR ('TEST 1 FAIL [%dms]: general fields', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: names, family, decoded bitmasks'

ROLLBACK TRAN FIJ_Test1
GO
-- ============================================================================
-- TEST 2: habitat rule and its intervals
-- ============================================================================
BEGIN TRAN FIJ_Test2
    declare @test_name sysname = N'FIJ_Test2 [fn_fish_info_json] : habitat'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @R uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utfij family2', 900402, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utfij-fish2', N'Utfij two', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
UPDATE dbo.fish_Rule SET habitat = 3, feedsOver = 6 WHERE fish_Id = @F AND periodStart = -1 AND periodEnd = -1;
SELECT @R = id FROM dbo.fish_Rule WHERE fish_Id = @F AND periodStart = -1 AND periodEnd = -1;
INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_high, ri_max)
VALUES (@R, 17, NULL, 15, 23, NULL), (@R, 3, 1, NULL, NULL, 15), (@R, 9, 6.6999998092651367, NULL, NULL, NULL), (@R, 25, NULL, NULL, NULL, NULL);

SET @json = dbo.fn_fish_info_json(@F);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.habitat.waterBodies[0]'), '') <> 'Lake'
  OR JSON_VALUE(@json, '$.habitat.waterBodies[1]')        <> 'River'
  OR JSON_VALUE(@json, '$.habitat.feedsOver[0]')          <> 'Gravel'
  OR JSON_VALUE(@json, '$.habitat.conditions.temperature.low')  <> '15.00'
  OR JSON_VALUE(@json, '$.habitat.conditions.temperature.high') <> '23.00'
  OR JSON_VALUE(@json, '$.habitat.conditions.depth.max')  <> '15.00'
  OR JSON_VALUE(@json, '$.habitat.conditions.ph.min')     <> '6.70'
  OR JSON_QUERY(@json, '$.habitat.conditions.turbidity') IS NOT NULL
   RAISERROR ('TEST 2 FAIL [%dms]: habitat rule and intervals', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: habitat, rounded, empty dropped'

ROLLBACK TRAN FIJ_Test2
GO
-- ============================================================================
-- TEST 3: zoology, spawn and food
-- ============================================================================
BEGIN TRAN FIJ_Test3
    declare @test_name sysname = N'FIJ_Test3 [fn_fish_info_json] : zoology, spawn, food'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @S uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utfij family3', 900403, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern
                    , food_habitat, terrestrial_insects, crustaceans, terrestrial_animals, food_Type, node_food_habitat)
VALUES (@F, N'Utfij-fish3', N'Utfij three', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 2, 4096, 4, 32, 17, N'Eats minnows');
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length, fish_avg_length, Longevity, natural_color, shape)
VALUES (@F, 104, 51, 30, 3, N'Elongate');
INSERT INTO dbo.fish_spawn (fish_id, fish_spawn_age_female, fish_spawn_age_male, fish_spawn_eggs_min, fish_spawn_eggs_max
                          , fish_spawn_description, fish_spawn_location, reproductive_strategy)
VALUES (@F, 4, 3, 50000, 600000, N'Broadcast spawner', N'Rocky shoals', N'Iteroparous');
DELETE FROM dbo.fish_Rule WHERE fish_Id = @F AND periodStart <> -1;
INSERT INTO dbo.fish_Rule (fish_Id, periodStart, periodEnd, habitat, spawnsOver) VALUES (@F, 3, 5, 2, 1);
SELECT @S = id FROM dbo.fish_Rule WHERE fish_Id = @F AND periodStart = 3;
INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_low, ri_high) VALUES (@S, 16, 6, 11);

SET @json = dbo.fn_fish_info_json(@F);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.zoology.maxLengthCm'), '') <> '104.00'
  OR JSON_VALUE(@json, '$.zoology.longevityYears')        <> '30'
  OR JSON_VALUE(@json, '$.zoology.colors[1]')        <> 'yellow'
  OR JSON_VALUE(@json, '$.zoology.shape')            <> N'Elongate'
  OR JSON_VALUE(@json, '$.spawn.eggsMax')            <> '600000'
  OR JSON_VALUE(@json, '$.spawn.reproductiveStrategy') <> N'Iteroparous'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.spawn.periods')) <> 1
  OR JSON_VALUE(@json, '$.spawn.periods[0].monthStart') <> '3'
  OR JSON_VALUE(@json, '$.spawn.periods[0].habitat[0]') <> 'River'
  OR JSON_VALUE(@json, '$.spawn.periods[0].spawnsOver[0]') <> 'Rock'
  OR JSON_VALUE(@json, '$.spawn.periods[0].conditions.temperature.high') <> '11.00'
  OR JSON_VALUE(@json, '$.food.habits[0]')           <> 'Predator'
  OR JSON_VALUE(@json, '$.food.types[1]')            <> 'Small Fish'
  OR JSON_VALUE(@json, '$.food.insects[0]')          <> 'Mayfly'
  OR JSON_VALUE(@json, '$.food.crustaceans[0]')      <> 'Crayfish'
  OR JSON_VALUE(@json, '$.food.animals[0]')          <> 'Worms'
  OR JSON_VALUE(@json, '$.food.note')                <> N'Eats minnows'
   RAISERROR ('TEST 3 FAIL [%dms]: zoology, spawn and food', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: zoology, spawn periods, food'

ROLLBACK TRAN FIJ_Test3
GO
-- ============================================================================
-- TEST 4: codes, top ranks, catch curves, predators/prey, records, documents
-- ============================================================================
BEGIN TRAN FIJ_Test4
    declare @test_name sysname = N'FIJ_Test4 [fn_fish_info_json] : related lists'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @P uniqueidentifier = NEWID(), @Q uniqueidentifier = NEWID();
DECLARE @Fam uniqueidentifier = NEWID(), @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utfij family4', 900404, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utfij-fish4', N'Utfij four', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0)
     , (@P, N'Utfij-pike', N'Utfij predator', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0)
     , (@Q, N'Utfij-minnow', N'Utfij prey', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES (@F, 'ZZ', 'QQ', 'UTF');
INSERT INTO dbo.fish_region_top (country, state, top_rank, common_name, fish_name, fish_id) VALUES ('CA', 'Q9', 3, 'Utfij common', 'Utfij-fish4', @F);
INSERT INTO dbo.fish_catch_probability (fish_id, month, probability) VALUES (@F, 1, 5), (@F, 7, 380);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, day, probability) VALUES (@F, 1, 88), (@F, 14, 92);
INSERT INTO dbo.fish_predator (fish_id, predator_id, age_year) VALUES (@F, @P, 2), (@Q, @F, NULL);
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utfij Lake');
INSERT INTO dbo.fish_record (fish_id, lake_id, stamp, angler, weight, length, lure) VALUES (@F, @L, '2020-06-01', N'A. Angler', 9.5, 90, 'jig');
INSERT INTO dbo.fish_document (fish_id, fish_document_pic, fish_document_label) VALUES (@F, 0x255044462D, N'Utfij guide');

SET @json = dbo.fn_fish_info_json(@F);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.codes[0].code'), '') <> 'UTF'
  OR JSON_VALUE(@json, '$.codes[0].state')         <> 'QQ'
  OR JSON_VALUE(@json, '$.topRanks[0].rank')       <> '3'
  OR JSON_VALUE(@json, '$.topRanks[0].commonName') <> 'Utfij common'
  OR JSON_VALUE(@json, '$.catchByMonth[1].month')  <> '7'
  OR JSON_VALUE(@json, '$.catchByMonth[1].index')  <> '380'
  OR JSON_VALUE(@json, '$.catchByMoonDay[1].probability') <> '92'
  OR JSON_VALUE(@json, '$.predators[0].name')      <> N'Utfij-pike'
  OR JSON_VALUE(@json, '$.predators[0].ageYear')   <> '2'
  OR JSON_VALUE(@json, '$.prey[0].name')           <> N'Utfij-minnow'
  OR JSON_VALUE(@json, '$.records[0].lakeName')    <> N'Utfij Lake'
  OR JSON_VALUE(@json, '$.records[0].weightLb')      <> '9.50'
  OR JSON_VALUE(@json, '$.records[0].date')        <> '2020-06-01'
  OR JSON_VALUE(@json, '$.documents[0].label')     <> N'Utfij guide'
  OR JSON_VALUE(@json, '$.documents[0].pic') IS NOT NULL
   RAISERROR ('TEST 4 FAIL [%dms]: related lists', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: codes, curves, predators, records'

ROLLBACK TRAN FIJ_Test4
GO
-- ============================================================================
-- TEST 5: no image data anywhere in the document
-- ============================================================================
BEGIN TRAN FIJ_Test5
    declare @test_name sysname = N'FIJ_Test5 [fn_fish_info_json] : no images'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utfij family5', 900405, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern, img)
VALUES (@F, N'Utfij-fish5', N'Utfij five', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 0x89504E47);
INSERT INTO dbo.fish_image (fish_id, fish_image_pic, fish_image_source, fish_image_author, fish_image_link, fish_image_hash, fish_image_label)
VALUES (@F, 0x89504E47, N'src', N'author', N'link', 0x00, N'Utfij image');
INSERT INTO dbo.fish_zoo (fish_id, fish_zoo_image, shape) VALUES (@F, SCOPE_IDENTITY(), N'Round');

SET @json = dbo.fn_fish_info_json(@F);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.zoology.shape'), '') <> N'Round'
  OR @json LIKE '%img%' OR @json LIKE '%image%' OR @json LIKE '%iVBOR%' OR @json LIKE '%Utfij image%'
   RAISERROR ('TEST 5 FAIL [%dms]: an image leaked into the document', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no image, image id or label'

ROLLBACK TRAN FIJ_Test5
GO
-- ============================================================================
-- TEST 6: unknown or NULL fish -> NULL
-- ============================================================================
BEGIN TRAN FIJ_Test6
    declare @test_name sysname = N'FIJ_Test6 [fn_fish_info_json] : unknown fish'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json1 nvarchar(max) = N'x', @json2 nvarchar(max) = N'x';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json1 = dbo.fn_fish_info_json(NEWID());
SET @json2 = dbo.fn_fish_info_json(NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json1 IS NOT NULL OR @json2 IS NOT NULL
   RAISERROR ('TEST 6 FAIL [%dms]: unknown/NULL fish must give NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown or NULL fish -> NULL'

ROLLBACK TRAN FIJ_Test6
GO
-- ============================================================================
-- TEST 7: a bare fish -> empty arrays, no error
-- ============================================================================
BEGIN TRAN FIJ_Test7
    declare @test_name sysname = N'FIJ_Test7 [fn_fish_info_json] : bare fish'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @F uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utfij family7', 900407, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utfij-fish7', N'Utfij seven', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);

SET @json = dbo.fn_fish_info_json(@F);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(JSON_VALUE(@json, '$.name'), '') <> N'Utfij-fish7'
  OR ISJSON(@json) = 0
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.codes'))    <> 0
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.records'))  <> 0
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.types'))    <> 0
  OR JSON_QUERY(@json, '$.catchByMonth') IS NULL
   RAISERROR ('TEST 7 FAIL [%dms]: a bare fish must give empty lists', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bare fish -> empty lists'

ROLLBACK TRAN FIJ_Test7
GO
