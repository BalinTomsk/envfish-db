SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for saved spots: dbo.user_spot, dbo.sp_user_spot_save, dbo.sp_user_spot_delete,
  dbo.fn_user_spot_list_json. Each test is its own named transaction, rolled back at the end.

  TEST 1 - save inserts, a second save with the same id updates; the list shows it with its water body
  TEST 2 - another account can neither change nor delete it, nor see it in its list
  TEST 3 - bad name or coordinates are refused; an unknown lake id is stored as NULL
  TEST 4 - delete removes the owner's spot; an empty account's list is []
*/

-- ============================================================================
-- TEST 1: insert, update, list
-- ============================================================================
BEGIN TRAN US_Test1
    declare @test_name sysname = N'US_Test1 [sp_user_spot_save / fn_user_spot_list_json] : insert, update, list'
DECLARE @tStart datetime2, @ElapsedMs int, @R1 int, @R2 int, @J nvarchar(max), @N int, @Name nvarchar(128), @LakeName nvarchar(200);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Lake1 uniqueidentifier = (SELECT TOP 1 lake_id FROM dbo.vw_lake WHERE lake_name IS NOT NULL);
DECLARE @Me1 uniqueidentifier = NEWID(), @Spot1 uniqueidentifier = NEWID();

-- 2. execute unit test

EXEC dbo.sp_user_spot_save @id=@Spot1, @userid=@Me1, @name=N' Dock ', @lat=43.45, @lon=-80.49, @lake_id=@Lake1, @result=@R1 OUTPUT;
EXEC dbo.sp_user_spot_save @id=@Spot1, @userid=@Me1, @name=N'North dock', @lat=43.46, @lon=-80.49, @lake_id=@Lake1, @note=N'Pike in May', @result=@R2 OUTPUT;
SET @J = dbo.fn_user_spot_list_json(@Me1);
SELECT @N = COUNT(*) FROM OPENJSON(@J);
SELECT @Name = JSON_VALUE(@J, '$[0].name'), @LakeName = JSON_VALUE(@J, '$[0].lakeName');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @R1 <> 1 OR @R2 <> 2 OR @N <> 1 OR @Name <> N'North dock' OR @LakeName IS NULL
   RAISERROR ('TEST 1 FAIL [%dms]: expected insert then update of one listed spot', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: insert, update, list'

ROLLBACK TRAN US_Test1
GO

-- ============================================================================
-- TEST 2: another account cannot touch or see it
-- ============================================================================
BEGIN TRAN US_Test2
    declare @test_name sysname = N'US_Test2 [sp_user_spot_save / delete] : owner only'
DECLARE @tStart datetime2, @ElapsedMs int, @R int, @D int, @N int, @Name nvarchar(128);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Me2 uniqueidentifier = NEWID(), @Other2 uniqueidentifier = NEWID(), @Spot2 uniqueidentifier = NEWID();
EXEC dbo.sp_user_spot_save @id=@Spot2, @userid=@Me2, @name=N'Mine', @lat=1, @lon=1;

-- 2. execute unit test

EXEC dbo.sp_user_spot_save @id=@Spot2, @userid=@Other2, @name=N'Stolen', @lat=2, @lon=2, @result=@R OUTPUT;
EXEC dbo.sp_user_spot_delete @id=@Spot2, @userid=@Other2, @deleted=@D OUTPUT;
SELECT @N = COUNT(*) FROM OPENJSON(dbo.fn_user_spot_list_json(@Other2));
SELECT @Name = user_spot_name FROM dbo.user_spot WHERE user_spot_id = @Spot2;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @R <> 0 OR @D <> 0 OR @N <> 0 OR @Name <> N'Mine'
   RAISERROR ('TEST 2 FAIL [%dms]: another account changed, deleted or saw the spot', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: owner only'

ROLLBACK TRAN US_Test2
GO

-- ============================================================================
-- TEST 3: bad input refused; unknown lake stored as NULL
-- ============================================================================
BEGIN TRAN US_Test3
    declare @test_name sysname = N'US_Test3 [sp_user_spot_save] : validation'
DECLARE @tStart datetime2, @ElapsedMs int, @R1 int, @R2 int, @R3 int, @Lake uniqueidentifier, @Rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Me3 uniqueidentifier = NEWID(), @Spot3 uniqueidentifier = NEWID();

-- 2. execute unit test

EXEC dbo.sp_user_spot_save @id=@Spot3, @userid=@Me3, @name=N'   ', @lat=1, @lon=1, @result=@R1 OUTPUT;
EXEC dbo.sp_user_spot_save @id=@Spot3, @userid=@Me3, @name=N'X', @lat=91, @lon=1, @result=@R2 OUTPUT;
EXEC dbo.sp_user_spot_save @id=@Spot3, @userid=@Me3, @name=N'X', @lat=1, @lon=1, @lake_id=@Spot3, @result=@R3 OUTPUT;
SELECT @Lake = user_spot_lake_id FROM dbo.user_spot WHERE user_spot_id = @Spot3;
SELECT @Rows = COUNT(*) FROM dbo.user_spot WHERE user_spot_userid = @Me3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @R1 <> -2 OR @R2 <> -2 OR @R3 <> 1 OR @Lake IS NOT NULL OR @Rows <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: expected -2, -2, then 1 with a NULL lake', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bad input refused, unknown lake NULL'

ROLLBACK TRAN US_Test3
GO

-- ============================================================================
-- TEST 4: delete; empty list is []
-- ============================================================================
BEGIN TRAN US_Test4
    declare @test_name sysname = N'US_Test4 [sp_user_spot_delete / fn_user_spot_list_json] : delete, empty'
DECLARE @tStart datetime2, @ElapsedMs int, @D int, @J nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Me4 uniqueidentifier = NEWID(), @Spot4 uniqueidentifier = NEWID();
EXEC dbo.sp_user_spot_save @id=@Spot4, @userid=@Me4, @name=N'Gone soon', @lat=1, @lon=1;

-- 2. execute unit test

EXEC dbo.sp_user_spot_delete @id=@Spot4, @userid=@Me4, @deleted=@D OUTPUT;
SET @J = dbo.fn_user_spot_list_json(@Me4);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @D <> 1 OR @J <> N'[]'
   RAISERROR ('TEST 4 FAIL [%dms]: expected the spot deleted and an empty list', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: delete, empty list is []'

ROLLBACK TRAN US_Test4
GO
