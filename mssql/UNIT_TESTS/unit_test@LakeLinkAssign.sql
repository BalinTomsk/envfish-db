SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_lake_link_assign -- re-points a water body's source (side 16) or mouth
  (side 32) to another water body (docapi PATCH /api/v1/river/source|mouth/{guid}/point).

  TEST 1 - source assigned: Tributaries row + lake.source point at the new water body
  TEST 2 - mouth assigned: Tributaries row + lake.mouth point at the new water body
  TEST 3 - assigning the point already linked reports changed=false
  TEST 4 - unknown lake_id -> results IS NULL
  TEST 5 - unknown point -> error, link row unchanged
  TEST 6 - the water body itself as its point -> error
  TEST 7 - a legacy lake with no source row gets one, assigned
  TEST 8 - a side other than 16/32 -> error
*/
PRINT 'Unit tests for dbo.sp_lake_link_assign';
GO
-- ============================================================================
-- TEST 1: source assigned
-- ============================================================================
BEGIN TRAN LLA_Test1
    declare @test_name sysname = N'LLA_Test1 [sp_lake_link_assign] : source assigned'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max), @RowPoint uniqueidentifier, @LakeSource uniqueidentifier;
DECLARE @River uniqueidentifier = NEWID(), @Lake uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla1-river'), (@Lake, 1, N'ut-lla1-lake');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 16, @Lake;
SELECT @Results = results FROM @t;
SELECT @RowPoint = Lake_id FROM dbo.Tributaries WHERE Main_Lake_id = @River AND side = 16;
SELECT @LakeSource = source FROM dbo.Lake WHERE Lake_id = @River;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowPoint IS NULL OR @RowPoint <> @Lake OR @LakeSource IS NULL OR @LakeSource <> @Lake
   OR JSON_VALUE(@Results, '$.changed') <> 'true' OR JSON_VALUE(@Results, '$.pointName') <> N'ut-lla1-lake'
   OR JSON_VALUE(@Results, '$.error') IS NOT NULL
   RAISERROR ('TEST 1 FAIL [%dms]: source not assigned', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: source assigned'

ROLLBACK TRAN LLA_Test1
GO
-- ============================================================================
-- TEST 2: mouth assigned
-- ============================================================================
BEGIN TRAN LLA_Test2
    declare @test_name sysname = N'LLA_Test2 [sp_lake_link_assign] : mouth assigned'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max), @RowPoint uniqueidentifier, @LakeMouth uniqueidentifier;
DECLARE @River uniqueidentifier = NEWID(), @Main uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla2-creek'), (@Main, 2, N'ut-lla2-river');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 32, @Main;
SELECT @Results = results FROM @t;
SELECT @RowPoint = Lake_id FROM dbo.Tributaries WHERE Main_Lake_id = @River AND side = 32;
SELECT @LakeMouth = mouth FROM dbo.Lake WHERE Lake_id = @River;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowPoint IS NULL OR @RowPoint <> @Main OR @LakeMouth IS NULL OR @LakeMouth <> @Main
   OR JSON_VALUE(@Results, '$.changed') <> 'true' OR JSON_VALUE(@Results, '$.side') <> '32'
   RAISERROR ('TEST 2 FAIL [%dms]: mouth not assigned', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mouth assigned'

ROLLBACK TRAN LLA_Test2
GO
-- ============================================================================
-- TEST 3: the same point again -> changed=false
-- ============================================================================
BEGIN TRAN LLA_Test3
    declare @test_name sysname = N'LLA_Test3 [sp_lake_link_assign] : same point is a no-op'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max);
DECLARE @River uniqueidentifier = NEWID(), @Main uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla3-creek'), (@Main, 2, N'ut-lla3-river');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 32, @Main;
DELETE FROM @t;
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 32, @Main;
SELECT @Results = results FROM @t;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(JSON_VALUE(@Results, '$.changed'), '') <> 'false'
   OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@Results, '$.previousPointId')) <> @Main
   RAISERROR ('TEST 3 FAIL [%dms]: expected changed=false', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: same point reports changed=false'

ROLLBACK TRAN LLA_Test3
GO
-- ============================================================================
-- TEST 4: unknown lake -> NULL
-- ============================================================================
BEGIN TRAN LLA_Test4
    declare @test_name sysname = N'LLA_Test4 [sp_lake_link_assign] : unknown lake'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max) = N'unset', @Rows int;
DECLARE @Main uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Main, 2, N'ut-lla4-river');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign '00000000-0000-0000-0000-0000000000a4', 16, @Main;
SELECT @Rows = COUNT(*) FROM @t;
SELECT @Results = results FROM @t;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Rows <> 1 OR @Results IS NOT NULL
   RAISERROR ('TEST 4 FAIL [%dms]: expected one NULL result', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown lake returns NULL'

ROLLBACK TRAN LLA_Test4
GO
-- ============================================================================
-- TEST 5: unknown point -> error, row unchanged
-- ============================================================================
BEGIN TRAN LLA_Test5
    declare @test_name sysname = N'LLA_Test5 [sp_lake_link_assign] : unknown point'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max), @RowPoint uniqueidentifier;
DECLARE @River uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla5-creek');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 16, '00000000-0000-0000-0000-0000000000a5';
SELECT @Results = results FROM @t;
SELECT @RowPoint = Lake_id FROM dbo.Tributaries WHERE Main_Lake_id = @River AND side = 16;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(JSON_VALUE(@Results, '$.error'), '') <> 'pointNotFound' OR @RowPoint <> @River
   RAISERROR ('TEST 5 FAIL [%dms]: expected pointNotFound, row unchanged', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown point refused'

ROLLBACK TRAN LLA_Test5
GO
-- ============================================================================
-- TEST 6: the water body itself -> error
-- ============================================================================
BEGIN TRAN LLA_Test6
    declare @test_name sysname = N'LLA_Test6 [sp_lake_link_assign] : self point'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max);
DECLARE @River uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla6-creek');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 32, @River;
SELECT @Results = results FROM @t;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(JSON_VALUE(@Results, '$.error'), '') <> 'selfPoint'
   RAISERROR ('TEST 6 FAIL [%dms]: expected selfPoint', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: self point refused'

ROLLBACK TRAN LLA_Test6
GO
-- ============================================================================
-- TEST 7: no source row yet -> created and assigned
-- ============================================================================
BEGIN TRAN LLA_Test7
    declare @test_name sysname = N'LLA_Test7 [sp_lake_link_assign] : missing row created'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max), @RowPoint uniqueidentifier, @Rows int;
DECLARE @River uniqueidentifier = NEWID(), @Lake uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla7-creek'), (@Lake, 1, N'ut-lla7-lake');
DELETE FROM dbo.Tributaries WHERE Main_Lake_id = @River AND side = 16;

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 16, @Lake;
SELECT @Results = results FROM @t;
SELECT @Rows = COUNT(*), @RowPoint = MAX(CONVERT(varchar(36), Lake_id))
FROM dbo.Tributaries WHERE Main_Lake_id = @River AND side = 16;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Rows <> 1 OR @RowPoint <> @Lake OR ISNULL(JSON_VALUE(@Results, '$.changed'), '') <> 'true'
   RAISERROR ('TEST 7 FAIL [%dms]: expected one source row on the lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: missing source row created'

ROLLBACK TRAN LLA_Test7
GO
-- ============================================================================
-- TEST 8: invalid side -> error
-- ============================================================================
BEGIN TRAN LLA_Test8
    declare @test_name sysname = N'LLA_Test8 [sp_lake_link_assign] : invalid side'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Results nvarchar(max);
DECLARE @River uniqueidentifier = NEWID(), @Lake uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@River, 2, N'ut-lla8-creek'), (@Lake, 1, N'ut-lla8-lake');

DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_link_assign @River, 4, @Lake;
SELECT @Results = results FROM @t;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(JSON_VALUE(@Results, '$.error'), '') <> 'invalidSide'
   RAISERROR ('TEST 8 FAIL [%dms]: expected invalidSide', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: side other than 16/32 refused'

ROLLBACK TRAN LLA_Test8
GO
