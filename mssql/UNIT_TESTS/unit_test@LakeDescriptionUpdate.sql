SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_lake_description_update -- JSON merge-patch of the editable fields on the
  LakeEditor.aspx "General" tab (docapi PATCH /api/v1/river/description/{guid}).

  TEST 1 - a normal patch updates only the given fields, others untouched
  TEST 2 - omitted fields are left alone (true partial patch, not a full overwrite)
  TEST 3 - an explicit JSON null clears a field
  TEST 4 - lakeName/source/mouth in the body are reported "protected" and never written
  TEST 5 - noFish=true is BLOCKED while the lake has assigned species
  TEST 6 - noFish=true is applied when the lake has no assigned species
  TEST 7 - unknown lake_id -> results IS NULL
  TEST 8 - malformed JSON body is handled gracefully, not a raw SQL error
*/
PRINT 'Unit tests for dbo.sp_lake_description_update';
GO
-- ============================================================================
-- TEST 1: a normal patch updates only the given fields
-- ============================================================================
BEGIN TRAN LDU_Test1
    declare @test_name sysname = N'LDU_Test1 [sp_lake_description_update] : updates the given fields'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results1 nvarchar(max);
DECLARE @RowLink nvarchar(max), @RowDescript nvarchar(max), @RowReviewed bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake1 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, link, descript, reviewed)
VALUES (@Lake1, 1, N'ut-lake-ldu1', N'http://ut/ldu1-old', N'old description', 0);

DECLARE @Body1 nvarchar(max) = N'{"link":"http://ut/ldu1-new","description":"new description","reviewed":true}';

DECLARE @t1 TABLE (results nvarchar(max));
INSERT INTO @t1 EXEC dbo.sp_lake_description_update @Lake1, @Body1;
SELECT @Results1 = results FROM @t1;
SELECT @RowLink = link, @RowDescript = descript, @RowReviewed = reviewed FROM dbo.Lake WHERE Lake_id = @Lake1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowLink <> N'http://ut/ldu1-new' OR @RowDescript <> N'new description' OR @RowReviewed <> 1
   OR JSON_VALUE(@Results1, '$.updated[0].field') IS NULL
   RAISERROR ('TEST 1 FAIL [%dms]: expected link/description/reviewed updated', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: given fields updated'

ROLLBACK TRAN LDU_Test1
GO
-- ============================================================================
-- TEST 2: omitted fields are left alone
-- ============================================================================
BEGIN TRAN LDU_Test2
    declare @test_name sysname = N'LDU_Test2 [sp_lake_description_update] : omitted fields untouched'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @RowAltName nvarchar(64), @RowCGNDB char(5);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake2 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, alt_name, CGNDB)
VALUES (@Lake2, 1, N'ut-lake-ldu2', N'Original Alt Name', N'AAAAA');

DECLARE @Body2 nvarchar(max) = N'{"description":"only this changes"}';

DECLARE @t2 TABLE (results nvarchar(max));
INSERT INTO @t2 EXEC dbo.sp_lake_description_update @Lake2, @Body2;
SELECT @RowAltName = alt_name, @RowCGNDB = CGNDB FROM dbo.Lake WHERE Lake_id = @Lake2;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowAltName <> N'Original Alt Name' OR @RowCGNDB <> N'AAAAA'
   RAISERROR ('TEST 2 FAIL [%dms]: expected altName/CGNDB to survive an unrelated patch', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fields not named in the patch were left alone'

ROLLBACK TRAN LDU_Test2
GO
-- ============================================================================
-- TEST 3: an explicit JSON null clears a field
-- ============================================================================
BEGIN TRAN LDU_Test3
    declare @test_name sysname = N'LDU_Test3 [sp_lake_description_update] : explicit null clears a field'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @RowAltName3 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake3 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, alt_name)
VALUES (@Lake3, 1, N'ut-lake-ldu3', N'Will Be Cleared');

DECLARE @Body3 nvarchar(max) = N'{"altName":null}';

DECLARE @t3 TABLE (results nvarchar(max));
INSERT INTO @t3 EXEC dbo.sp_lake_description_update @Lake3, @Body3;
SELECT @RowAltName3 = alt_name FROM dbo.Lake WHERE Lake_id = @Lake3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowAltName3 IS NOT NULL
   RAISERROR ('TEST 3 FAIL [%dms]: expected altName cleared to NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: explicit null cleared the field'

ROLLBACK TRAN LDU_Test3
GO
-- ============================================================================
-- TEST 4: lakeName/source/mouth are reported protected, never written
-- ============================================================================
BEGIN TRAN LDU_Test4
    declare @test_name sysname = N'LDU_Test4 [sp_lake_description_update] : identity/linkage fields are protected'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results4 nvarchar(max);
DECLARE @RowName4 nvarchar(64);
DECLARE @ProtectedCount int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake4 uniqueidentifier = NEWID();
DECLARE @OtherLake4 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 1, N'ut-lake-ldu4-original');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@OtherLake4, 1, N'ut-lake-ldu4-other');

DECLARE @Body4 nvarchar(max) = N'{"lakeName":"hijacked name","source":"' +
    CONVERT(varchar(36), @OtherLake4) + N'","mouth":"' + CONVERT(varchar(36), @OtherLake4) + N'"}';

DECLARE @t4 TABLE (results nvarchar(max));
INSERT INTO @t4 EXEC dbo.sp_lake_description_update @Lake4, @Body4;
SELECT @Results4 = results FROM @t4;
SELECT @RowName4 = lake_name FROM dbo.Lake WHERE Lake_id = @Lake4;
SELECT @ProtectedCount = COUNT(*) FROM OPENJSON(JSON_QUERY(@Results4, '$.protectedFields'));

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowName4 <> N'ut-lake-ldu4-original' OR @ProtectedCount <> 3
   RAISERROR ('TEST 4 FAIL [%dms]: expected lake_name unchanged and 3 protected-field entries', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lakeName/source/mouth rejected as protected, name unchanged'

ROLLBACK TRAN LDU_Test4
GO
-- ============================================================================
-- TEST 5: noFish=true is BLOCKED while the lake has assigned species
-- ============================================================================
BEGIN TRAN LDU_Test5
    declare @test_name sysname = N'LDU_Test5 [sp_lake_description_update] : noFish blocked when species are assigned'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results5 nvarchar(max);
DECLARE @RowNoFish5 bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake5     uniqueidentifier = NEWID();
DECLARE @Family5   uniqueidentifier = NEWID();
DECLARE @Fish5     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, noFish) VALUES (@Lake5, 1, N'ut-lake-ldu5', 0);
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family5, N'ut-family-ldu5', 920105, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish5, N'Carp-ldu5', N'Cyprinus ut-ldu5', @Family5, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, lake_fish_id)
VALUES (@Lake5, @Fish5, SYSUTCDATETIME(), N'http://ut/ldu5', NEWID());

DECLARE @Body5 nvarchar(max) = N'{"noFish":true}';

DECLARE @t5 TABLE (results nvarchar(max));
INSERT INTO @t5 EXEC dbo.sp_lake_description_update @Lake5, @Body5;
SELECT @Results5 = results FROM @t5;
SELECT @RowNoFish5 = noFish FROM dbo.Lake WHERE Lake_id = @Lake5;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@RowNoFish5, 0) <> 0 OR JSON_VALUE(@Results5, '$.ignored[0].field') <> 'noFish'
   RAISERROR ('TEST 5 FAIL [%dms]: expected noFish left at 0 and reported ignored', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: noFish blocked while species are assigned'

ROLLBACK TRAN LDU_Test5
GO
-- ============================================================================
-- TEST 6: noFish=true is applied when the lake has NO assigned species
-- ============================================================================
BEGIN TRAN LDU_Test6
    declare @test_name sysname = N'LDU_Test6 [sp_lake_description_update] : noFish applied when no species assigned'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @RowNoFish6 bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake6 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, noFish) VALUES (@Lake6, 1, N'ut-lake-ldu6', 0);

DECLARE @Body6 nvarchar(max) = N'{"noFish":true}';

DECLARE @t6 TABLE (results nvarchar(max));
INSERT INTO @t6 EXEC dbo.sp_lake_description_update @Lake6, @Body6;
SELECT @RowNoFish6 = noFish FROM dbo.Lake WHERE Lake_id = @Lake6;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@RowNoFish6, 0) <> 1
   RAISERROR ('TEST 6 FAIL [%dms]: expected noFish = 1', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: noFish applied for a fishless lake'

ROLLBACK TRAN LDU_Test6
GO
-- ============================================================================
-- TEST 7: unknown lake_id -> results IS NULL
-- ============================================================================
BEGIN TRAN LDU_Test7
    declare @test_name sysname = N'LDU_Test7 [sp_lake_description_update] : unknown lake_id'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results7 nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @GhostLake7 uniqueidentifier = NEWID();  -- never inserted into dbo.lake

DECLARE @t7 TABLE (results nvarchar(max));
INSERT INTO @t7 EXEC dbo.sp_lake_description_update @GhostLake7, N'{"description":"x"}';
SELECT @Results7 = results FROM @t7;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Results7 IS NOT NULL
   RAISERROR ('TEST 7 FAIL [%dms]: expected NULL results for an unknown lake_id', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown lake_id returned NULL results'

ROLLBACK TRAN LDU_Test7
GO
-- ============================================================================
-- TEST 8: malformed JSON body is handled gracefully
-- ============================================================================
BEGIN TRAN LDU_Test8
    declare @test_name sysname = N'LDU_Test8 [sp_lake_description_update] : malformed JSON body'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results8 nvarchar(max);
DECLARE @RowDescript8 nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake8 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, descript) VALUES (@Lake8, 1, N'ut-lake-ldu8', N'untouched');

DECLARE @t8 TABLE (results nvarchar(max));
INSERT INTO @t8 EXEC dbo.sp_lake_description_update @Lake8, N'{not valid json';
SELECT @Results8 = results FROM @t8;
SELECT @RowDescript8 = descript FROM dbo.Lake WHERE Lake_id = @Lake8;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Results8 IS NULL OR @RowDescript8 <> N'untouched'
   RAISERROR ('TEST 8 FAIL [%dms]: expected a graceful results payload and no column changes', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: malformed JSON handled without touching the row'

ROLLBACK TRAN LDU_Test8
GO
