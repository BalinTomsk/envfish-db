SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for follows: dbo.user_follow, dbo.sp_user_follow_set, dbo.fn_user_follow_list_json.
  Each test is its own named transaction, rolled back at the end.

  TEST 1 - follow a water body and a fish; a repeat changes nothing; the list shows both with their names
  TEST 2 - unfollow removes it, and again is harmless; another account's list stays empty
  TEST 3 - a bad kind or a target that is not a lake / fish is refused
*/

-- ============================================================================
-- TEST 1: follow, repeat, list
-- ============================================================================
BEGIN TRAN UF_Test1
    declare @test_name sysname = N'UF_Test1 [sp_user_follow_set / fn_user_follow_list_json] : follow, list'
DECLARE @tStart datetime2, @ElapsedMs int, @R1 int, @R2 int, @R3 int, @J nvarchar(max), @NW int, @NF int, @Rows int,
        @LakeName nvarchar(200), @FishName nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Lake1 uniqueidentifier = (SELECT TOP 1 lake_id FROM dbo.vw_lake WHERE lake_name IS NOT NULL);
DECLARE @Fish1 uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish);
DECLARE @Me1 uniqueidentifier = NEWID();

-- 2. execute unit test

EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=1, @target=@Lake1, @follow=1, @result=@R1 OUTPUT;
EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=2, @target=@Fish1, @follow=1, @result=@R2 OUTPUT;
EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=1, @target=@Lake1, @follow=1, @result=@R3 OUTPUT;
SET @Rows = (SELECT COUNT(*) FROM dbo.user_follow WHERE user_follow_userid = @Me1);
SET @J = dbo.fn_user_follow_list_json(@Me1);
SELECT @NW = COUNT(*) FROM OPENJSON(@J, '$.waters');
SELECT @NF = COUNT(*) FROM OPENJSON(@J, '$.fish');
SELECT @LakeName = JSON_VALUE(@J, '$.waters[0].lakeName'), @FishName = JSON_VALUE(@J, '$.fish[0].fishName');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @R1 <> 1 OR @R2 <> 1 OR @R3 <> 1 OR @Rows <> 2 OR @NW <> 1 OR @NF <> 1 OR @LakeName IS NULL OR @FishName IS NULL
   RAISERROR ('TEST 1 FAIL [%dms]: expected one water body and one fish followed', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: follow, repeat, list'

ROLLBACK TRAN UF_Test1
GO

-- ============================================================================
-- TEST 2: unfollow; another account sees nothing
-- ============================================================================
BEGIN TRAN UF_Test2
    declare @test_name sysname = N'UF_Test2 [sp_user_follow_set] : unfollow, owner only'
DECLARE @tStart datetime2, @ElapsedMs int, @R1 int, @R2 int, @Other nvarchar(max), @Mine nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Lake1 uniqueidentifier = (SELECT TOP 1 lake_id FROM dbo.vw_lake WHERE lake_name IS NOT NULL);
DECLARE @Me1 uniqueidentifier = NEWID(), @Other1 uniqueidentifier = NEWID();
EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=1, @target=@Lake1, @follow=1;
SET @Other = dbo.fn_user_follow_list_json(@Other1);

-- 2. execute unit test

EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=1, @target=@Lake1, @follow=0, @result=@R1 OUTPUT;
EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=1, @target=@Lake1, @follow=0, @result=@R2 OUTPUT;
SET @Mine = dbo.fn_user_follow_list_json(@Me1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @R1 <> 0 OR @R2 <> 0 OR @Other <> N'{"waters":[],"fish":[]}' OR @Mine <> N'{"waters":[],"fish":[]}'
   RAISERROR ('TEST 2 FAIL [%dms]: expected unfollow and empty lists', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unfollow, owner only'

ROLLBACK TRAN UF_Test2
GO

-- ============================================================================
-- TEST 3: bad kind or unknown target
-- ============================================================================
BEGIN TRAN UF_Test3
    declare @test_name sysname = N'UF_Test3 [sp_user_follow_set] : refused input'
DECLARE @tStart datetime2, @ElapsedMs int, @R1 int, @R2 int, @R3 int, @Rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

DECLARE @Lake1 uniqueidentifier = (SELECT TOP 1 lake_id FROM dbo.vw_lake WHERE lake_name IS NOT NULL);
DECLARE @Me1 uniqueidentifier = NEWID();

-- 2. execute unit test

EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=3, @target=@Lake1, @follow=1, @result=@R1 OUTPUT;
EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=1, @target='00000000-0000-0000-0000-00000000000F', @follow=1, @result=@R2 OUTPUT;
EXEC dbo.sp_user_follow_set @userid=@Me1, @kind=2, @target=@Lake1, @follow=1, @result=@R3 OUTPUT;
SET @Rows = (SELECT COUNT(*) FROM dbo.user_follow WHERE user_follow_userid = @Me1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @R1 <> -2 OR @R2 <> -2 OR @R3 <> -2 OR @Rows <> 0
   RAISERROR ('TEST 3 FAIL [%dms]: expected bad kind and unknown targets refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bad kind, unknown target refused'

ROLLBACK TRAN UF_Test3
GO
