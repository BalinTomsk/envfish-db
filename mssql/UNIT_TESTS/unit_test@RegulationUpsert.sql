SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_regulation_upsert -- upsert-by-identity write side of Editor/LakeRegulation.aspx
  (docapi PATCH /api/v1/regulation), covering all three scopes the ASPX "regulation dialog" supports:
  province/state-wide, zone-wide, and water-body-specific.

  TEST 1 - water-body + fish rule inserts, reports scope waterBody, and TR_regulations auto-adds lake_fish
  TEST 2 - zone-wide rule (no lake) inserts and reports scope zone
  TEST 3 - province/state-wide rule (no lake, no zone) inserts and reports scope region
  TEST 4 - resubmitting the same identity UPDATES the existing row instead of duplicating it
  TEST 5 - zoneId and lakeId together is rejected as mutually exclusive
  TEST 6 - unknown lakeId is rejected, no row created
  TEST 7 - unknown fishId is rejected, no row created
  TEST 8 - malformed JSON body is handled gracefully, not a raw SQL error
  TEST 9 - missing year is rejected
  TEST 10 - a whole-country rule (state omitted) inserts and reports scope region
  TEST 11 - two countries can each have their own whole-country rule for the same year (no collision)
*/
PRINT 'Unit tests for dbo.sp_regulation_upsert';
GO
-- ============================================================================
-- TEST 1: water-body + fish rule inserts; TR_regulations auto-adds lake_fish
-- ============================================================================
BEGIN TRAN RU_Test1
    declare @test_name sysname = N'RU_Test1 [sp_regulation_upsert] : water-body+fish rule inserts, adds lake_fish'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results1 nvarchar(max);
DECLARE @RowCount1 int, @LakeFishCount1 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake1   uniqueidentifier = NEWID();
DECLARE @Family1 uniqueidentifier = NEWID();
DECLARE @Fish1   uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'ut-lake-ru1');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family1, N'ut-family-ru1', 920201, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish1, N'Salmon-ru1', N'Salmo ut-ru1', @Family1, SYSUTCDATETIME(), SYSUTCDATETIME());

DECLARE @Body1 nvarchar(max) = N'{"state":"ZZ","year":2026,"lakeId":"' + CONVERT(varchar(36), @Lake1) +
    N'","fishId":"' + CONVERT(varchar(36), @Fish1) +
    N'","sport":4,"code":8,"link":"http://ut/ru1","text":"Schedule I item 1."}';

DECLARE @t1 TABLE (results nvarchar(max));
INSERT INTO @t1 EXEC dbo.sp_regulation_upsert @Body1;
SELECT @Results1 = results FROM @t1;
SELECT @RowCount1 = COUNT(*) FROM dbo.regulations WHERE Lake_id = @Lake1 AND fish_id = @Fish1 AND state = N'ZZ' AND reg_year = 2026;
SELECT @LakeFishCount1 = COUNT(*) FROM dbo.lake_fish WHERE lake_id = @Lake1 AND fish_id = @Fish1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount1 <> 1 OR @LakeFishCount1 <> 1
   OR JSON_VALUE(@Results1, '$.action') <> 'inserted' OR JSON_VALUE(@Results1, '$.scope') <> 'waterBody'
   RAISERROR ('TEST 1 FAIL [%dms]: expected 1 regulation row, 1 lake_fish row, action=inserted scope=waterBody', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: water-body+fish rule inserted and lake_fish auto-added'

ROLLBACK TRAN RU_Test1
GO
-- ============================================================================
-- TEST 2: zone-wide rule (no lake) inserts and reports scope zone
-- ============================================================================
BEGIN TRAN RU_Test2
    declare @test_name sysname = N'RU_Test2 [sp_regulation_upsert] : zone-wide rule inserts, scope zone'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results2 nvarchar(max);
DECLARE @RowCount2 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Body2 nvarchar(max) = N'{"state":"ZZ","year":2026,"zoneId":9901,"sport":2,"code":8,"text":"zone rule ru2"}';

DECLARE @t2 TABLE (results nvarchar(max));
INSERT INTO @t2 EXEC dbo.sp_regulation_upsert @Body2;
SELECT @Results2 = results FROM @t2;
SELECT @RowCount2 = COUNT(*) FROM dbo.regulations WHERE zone_id = 9901 AND state = N'ZZ' AND reg_year = 2026 AND Lake_id IS NULL;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount2 <> 1 OR JSON_VALUE(@Results2, '$.action') <> 'inserted' OR JSON_VALUE(@Results2, '$.scope') <> 'zone'
   RAISERROR ('TEST 2 FAIL [%dms]: expected 1 zone-wide regulation row, action=inserted scope=zone', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: zone-wide rule inserted'

ROLLBACK TRAN RU_Test2
GO
-- ============================================================================
-- TEST 3: province/state-wide rule (no lake, no zone) inserts and reports scope region
-- ============================================================================
BEGIN TRAN RU_Test3
    declare @test_name sysname = N'RU_Test3 [sp_regulation_upsert] : province-wide rule inserts, scope region'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results3 nvarchar(max);
DECLARE @RowCount3 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Body3 nvarchar(max) = N'{"state":"ZZ","year":2026,"sport":3,"code":8,"text":"province rule ru3"}';

DECLARE @t3 TABLE (results nvarchar(max));
INSERT INTO @t3 EXEC dbo.sp_regulation_upsert @Body3;
SELECT @Results3 = results FROM @t3;
SELECT @RowCount3 = COUNT(*) FROM dbo.regulations WHERE state = N'ZZ' AND reg_year = 2026 AND Lake_id IS NULL AND zone_id IS NULL AND fish_id IS NULL AND regulations_part = N'';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount3 <> 1 OR JSON_VALUE(@Results3, '$.action') <> 'inserted' OR JSON_VALUE(@Results3, '$.scope') <> 'region'
   RAISERROR ('TEST 3 FAIL [%dms]: expected 1 province-wide regulation row, action=inserted scope=region', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: province-wide rule inserted'

ROLLBACK TRAN RU_Test3
GO
-- ============================================================================
-- TEST 4: resubmitting the same identity UPDATES instead of duplicating
-- ============================================================================
BEGIN TRAN RU_Test4
    declare @test_name sysname = N'RU_Test4 [sp_regulation_upsert] : resubmit same identity upserts, no duplicate'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results4a nvarchar(max), @Results4b nvarchar(max);
DECLARE @RowCount4 int, @Sport4 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake4 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 2, N'ut-lake-ru4');

DECLARE @Body4a nvarchar(max) = N'{"state":"ZZ","year":2026,"lakeId":"' + CONVERT(varchar(36), @Lake4) + N'","sport":1,"code":8}';
DECLARE @Body4b nvarchar(max) = N'{"state":"ZZ","year":2026,"lakeId":"' + CONVERT(varchar(36), @Lake4) + N'","sport":5,"code":8}';

DECLARE @t4a TABLE (results nvarchar(max));
INSERT INTO @t4a EXEC dbo.sp_regulation_upsert @Body4a;
SELECT @Results4a = results FROM @t4a;

DECLARE @t4b TABLE (results nvarchar(max));
INSERT INTO @t4b EXEC dbo.sp_regulation_upsert @Body4b;
SELECT @Results4b = results FROM @t4b;

SELECT @RowCount4 = COUNT(*) FROM dbo.regulations WHERE Lake_id = @Lake4 AND state = N'ZZ' AND reg_year = 2026;
SELECT @Sport4 = regulations_sport FROM dbo.regulations WHERE Lake_id = @Lake4 AND state = N'ZZ' AND reg_year = 2026;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount4 <> 1 OR @Sport4 <> 5
   OR JSON_VALUE(@Results4a, '$.action') <> 'inserted' OR JSON_VALUE(@Results4b, '$.action') <> 'updated'
   OR JSON_VALUE(@Results4a, '$.id') <> JSON_VALUE(@Results4b, '$.id')
   RAISERROR ('TEST 4 FAIL [%dms]: expected 1 row, sport=5, first insert then update, same id both times', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: resubmitting the same identity updated the existing row'

ROLLBACK TRAN RU_Test4
GO
-- ============================================================================
-- TEST 5: zoneId and lakeId together is rejected
-- ============================================================================
BEGIN TRAN RU_Test5
    declare @test_name sysname = N'RU_Test5 [sp_regulation_upsert] : zoneId+lakeId mutually exclusive'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results5 nvarchar(max);
DECLARE @RowCount5 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake5 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake5, 2, N'ut-lake-ru5');

DECLARE @Body5 nvarchar(max) = N'{"state":"ZZ","year":2026,"lakeId":"' + CONVERT(varchar(36), @Lake5) + N'","zoneId":9905}';

DECLARE @t5 TABLE (results nvarchar(max));
INSERT INTO @t5 EXEC dbo.sp_regulation_upsert @Body5;
SELECT @Results5 = results FROM @t5;
SELECT @RowCount5 = COUNT(*) FROM dbo.regulations WHERE Lake_id = @Lake5;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount5 <> 0 OR JSON_VALUE(@Results5, '$.error') NOT LIKE '%mutually exclusive%'
   RAISERROR ('TEST 5 FAIL [%dms]: expected no row and a mutually-exclusive error', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: zoneId+lakeId together rejected, no row created'

ROLLBACK TRAN RU_Test5
GO
-- ============================================================================
-- TEST 6: unknown lakeId is rejected
-- ============================================================================
BEGIN TRAN RU_Test6
    declare @test_name sysname = N'RU_Test6 [sp_regulation_upsert] : unknown lakeId rejected'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results6 nvarchar(max);
DECLARE @RowCount6 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @GhostLake6 uniqueidentifier = NEWID();  -- never inserted into dbo.lake
DECLARE @Body6 nvarchar(max) = N'{"state":"ZZ","year":2026,"lakeId":"' + CONVERT(varchar(36), @GhostLake6) + N'"}';

DECLARE @t6 TABLE (results nvarchar(max));
INSERT INTO @t6 EXEC dbo.sp_regulation_upsert @Body6;
SELECT @Results6 = results FROM @t6;
SELECT @RowCount6 = COUNT(*) FROM dbo.regulations WHERE Lake_id = @GhostLake6;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount6 <> 0 OR JSON_VALUE(@Results6, '$.error') NOT LIKE '%lakeId not found%'
   RAISERROR ('TEST 6 FAIL [%dms]: expected no row and a lakeId-not-found error', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown lakeId rejected, no row created'

ROLLBACK TRAN RU_Test6
GO
-- ============================================================================
-- TEST 7: unknown fishId is rejected
-- ============================================================================
BEGIN TRAN RU_Test7
    declare @test_name sysname = N'RU_Test7 [sp_regulation_upsert] : unknown fishId rejected'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results7 nvarchar(max);
DECLARE @RowCount7 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @GhostFish7 uniqueidentifier = NEWID();  -- never inserted into dbo.fish
DECLARE @Body7 nvarchar(max) = N'{"state":"ZZ","year":2026,"fishId":"' + CONVERT(varchar(36), @GhostFish7) + N'"}';

DECLARE @t7 TABLE (results nvarchar(max));
INSERT INTO @t7 EXEC dbo.sp_regulation_upsert @Body7;
SELECT @Results7 = results FROM @t7;
SELECT @RowCount7 = COUNT(*) FROM dbo.regulations WHERE fish_id = @GhostFish7;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount7 <> 0 OR JSON_VALUE(@Results7, '$.error') NOT LIKE '%fishId not found%'
   RAISERROR ('TEST 7 FAIL [%dms]: expected no row and a fishId-not-found error', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown fishId rejected, no row created'

ROLLBACK TRAN RU_Test7
GO
-- ============================================================================
-- TEST 8: malformed JSON body is handled gracefully
-- ============================================================================
BEGIN TRAN RU_Test8
    declare @test_name sysname = N'RU_Test8 [sp_regulation_upsert] : malformed JSON body'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results8 nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @t8 TABLE (results nvarchar(max));
INSERT INTO @t8 EXEC dbo.sp_regulation_upsert N'{not valid json';
SELECT @Results8 = results FROM @t8;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Results8 IS NULL OR JSON_VALUE(@Results8, '$.error') NOT LIKE '%not well-formed JSON%'
   RAISERROR ('TEST 8 FAIL [%dms]: expected a graceful malformed-JSON error payload', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: malformed JSON handled gracefully'

ROLLBACK TRAN RU_Test8
GO
-- ============================================================================
-- TEST 9: missing year is rejected
-- ============================================================================
BEGIN TRAN RU_Test9
    declare @test_name sysname = N'RU_Test9 [sp_regulation_upsert] : missing year rejected'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results9 nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @t9 TABLE (results nvarchar(max));
INSERT INTO @t9 EXEC dbo.sp_regulation_upsert N'{"sport":4}';
SELECT @Results9 = results FROM @t9;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Results9 IS NULL OR JSON_VALUE(@Results9, '$.error') NOT LIKE '%year%required%'
   RAISERROR ('TEST 9 FAIL [%dms]: expected a year-required error', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: missing year rejected'

ROLLBACK TRAN RU_Test9
GO
-- ============================================================================
-- TEST 10: a whole-country rule (state omitted) inserts and reports scope region
-- ============================================================================
BEGIN TRAN RU_Test10
    declare @test_name sysname = N'RU_Test10 [sp_regulation_upsert] : whole-country rule, state omitted'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results10 nvarchar(max);
DECLARE @RowCount10 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Body10 nvarchar(max) = N'{"country":"ZZ","year":2026,"sport":6,"text":"whole-country rule ru10"}';

DECLARE @t10 TABLE (results nvarchar(max));
INSERT INTO @t10 EXEC dbo.sp_regulation_upsert @Body10;
SELECT @Results10 = results FROM @t10;
SELECT @RowCount10 = COUNT(*) FROM dbo.regulations WHERE country = N'ZZ' AND reg_year = 2026 AND state IS NULL AND zone_id IS NULL AND Lake_id IS NULL;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCount10 <> 1 OR JSON_VALUE(@Results10, '$.action') <> 'inserted' OR JSON_VALUE(@Results10, '$.scope') <> 'region'
   RAISERROR ('TEST 10 FAIL [%dms]: expected 1 whole-country row with state NULL, action=inserted scope=region', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: whole-country rule inserted with state left NULL'

ROLLBACK TRAN RU_Test10
GO
-- ============================================================================
-- TEST 11: two countries can each have their own whole-country rule, same year, no collision
-- ============================================================================
BEGIN TRAN RU_Test11
    declare @test_name sysname = N'RU_Test11 [sp_regulation_upsert] : two countries, whole-country rules do not collide'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results11a nvarchar(max), @Results11b nvarchar(max);
DECLARE @RowCountCA11 int, @RowCountUS11 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- distinct from any pre-existing seed data: use the same rare year/part combo as TEST 10 but real
-- country codes, since the point here is CA vs US never colliding under the new unique index.
DECLARE @Body11a nvarchar(max) = N'{"country":"CA","year":2091,"part":"ut-ru11","sport":1}';
DECLARE @Body11b nvarchar(max) = N'{"country":"US","year":2091,"part":"ut-ru11","sport":2}';

DECLARE @t11a TABLE (results nvarchar(max));
INSERT INTO @t11a EXEC dbo.sp_regulation_upsert @Body11a;
SELECT @Results11a = results FROM @t11a;

DECLARE @t11b TABLE (results nvarchar(max));
INSERT INTO @t11b EXEC dbo.sp_regulation_upsert @Body11b;
SELECT @Results11b = results FROM @t11b;

SELECT @RowCountCA11 = COUNT(*) FROM dbo.regulations WHERE country = N'CA' AND reg_year = 2091 AND regulations_part = N'ut-ru11' AND state IS NULL;
SELECT @RowCountUS11 = COUNT(*) FROM dbo.regulations WHERE country = N'US' AND reg_year = 2091 AND regulations_part = N'ut-ru11' AND state IS NULL;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowCountCA11 <> 1 OR @RowCountUS11 <> 1
   OR JSON_VALUE(@Results11a, '$.action') <> 'inserted' OR JSON_VALUE(@Results11b, '$.action') <> 'inserted'
   RAISERROR ('TEST 11 FAIL [%dms]: expected 1 CA row and 1 US row, both inserted (no unique-index collision)', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: two countries whole-country rules coexist for the same year'

ROLLBACK TRAN RU_Test11
GO
