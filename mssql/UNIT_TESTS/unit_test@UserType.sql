SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for account types, a bitmask: dbo.UserType (1 registered, 2 paid, 4 scientist, 8 editor, 16 ai_agent,
  32 admin), dbo.Users.userType, CH_Users_userType_bits, CH_Users_userType_admin, dbo.sp_user_type_set,
  dbo.fn_user_type_list, dbo.fn_user_type_get, and the mask TR_Users_SyncOutbox snapshots for cproxy.

  Each test inserts a minimal Users fixture inside its own named transaction and rolls it back.

  TEST 1 - six power-of-two types are seeded (sum 63); a new account is 1 (registered)
  TEST 2 - a combination (paid + scientist) is stored as-is; access is kept
  TEST 3 - admin brings paid + scientist + editor and access 255; dropping admin returns access to 0
  TEST 4 - the CHECKs refuse 0, an undefined bit, 255 without admin, and admin without its three features
  TEST 5 - sp_user_type_set refuses 0, an undefined bit, an unknown account and an admin demoting themselves
  TEST 6 - the sync outbox carries the mask; sp_users_sync_outbox_take returns it
  TEST 7 - fn_user_type_get gives mask, codes and names in display order; a deleted account has no row
*/

-- ============================================================================
-- TEST 1: bits seeded, new account defaults to registered (1)
-- ============================================================================
BEGIN TRAN UT_Test01
    declare @test_name sysname = N'UT_Test01 [UserType] : seeded bits and default'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Codes varchar(200), @Sum int, @Type int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SELECT @Codes = STRING_AGG(code, ',') WITHIN GROUP (ORDER BY sort), @Sum = SUM(bit) FROM dbo.fn_user_type_list();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'ut_user_t1', 0x00000000000000000000000000000000, N'F', N'L', N'ut1@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);
SELECT @Type = userType FROM dbo.Users WHERE id = @U1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@Codes, '') <> 'admin,registered,paid,scientist,editor,ai_agent' OR ISNULL(@Sum, 0) <> 63 OR ISNULL(@Type, 0) <> 1
   RAISERROR ('TEST 1 FAIL [%dms]: expected six bits summing to 63 and a new account of 1', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: six bits, new account registered'

ROLLBACK TRAN UT_Test01
GO

-- ============================================================================
-- TEST 2: a combination is stored as-is, access kept
-- ============================================================================
BEGIN TRAN UT_Test02
    declare @test_name sysname = N'UT_Test02 [sp_user_type_set] : paid + scientist'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Type int, @Access int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted, access)
VALUES (@U1, N'ut_user_t2', 0x00000000000000000000000000000000, N'F', N'L', N'ut2@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 3);

CREATE TABLE #r2 (userType int, access int);
INSERT INTO #r2 EXEC dbo.sp_user_type_set @userId = @U1, @userType = 6;
SELECT @Type = userType, @Access = access FROM #r2;
DROP TABLE #r2;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@Type, 0) <> 6 OR ISNULL(@Access, -1) <> 3
   RAISERROR ('TEST 2 FAIL [%dms]: expected mask 6 with access 3 kept', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: paid + scientist stored, access kept'

ROLLBACK TRAN UT_Test02
GO

-- ============================================================================
-- TEST 3: admin brings paid + scientist + editor and 255; dropping it returns 0
-- ============================================================================
BEGIN TRAN UT_Test03
    declare @test_name sysname = N'UT_Test03 [sp_user_type_set] : admin implies 14 and 255'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @T1 int, @A1 int, @T2 int, @A2 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'ut_user_t3', 0x00000000000000000000000000000000, N'F', N'L', N'ut3@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r3 (userType int, access int);
INSERT INTO #r3 EXEC dbo.sp_user_type_set @userId = @U1, @userType = 33;   -- admin + registered only
SELECT @T1 = userType, @A1 = access FROM #r3;
DELETE FROM #r3;
INSERT INTO #r3 EXEC dbo.sp_user_type_set @userId = @U1, @userType = 3;    -- registered + paid
SELECT @T2 = userType, @A2 = access FROM #r3;
DROP TABLE #r3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@T1, 0) <> 47 OR ISNULL(@A1, -1) <> 255 OR ISNULL(@T2, 0) <> 3 OR ISNULL(@A2, -1) <> 0
   RAISERROR ('TEST 3 FAIL [%dms]: expected 47/255 as admin, then 3/0', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: admin is 47 with 255, then 3 with 0'

ROLLBACK TRAN UT_Test03
GO

-- ============================================================================
-- TEST 4: the CHECKs
-- ============================================================================
BEGIN TRAN UT_Test04
    declare @test_name sysname = N'UT_Test04 [CH_Users_userType_*] : direct writes refused'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @E1 int = 0, @E2 int = 0, @E3 int = 0, @E4 int = 0, @E5 int = 0, @Type int, @Access int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'ut_user_t4', 0x00000000000000000000000000000000, N'F', N'L', N'ut4@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

BEGIN TRY UPDATE dbo.Users SET userType = 0 WHERE id = @U1; END TRY BEGIN CATCH SET @E1 = ERROR_NUMBER(); END CATCH
BEGIN TRY UPDATE dbo.Users SET userType = 64 WHERE id = @U1; END TRY BEGIN CATCH SET @E2 = ERROR_NUMBER(); END CATCH
BEGIN TRY UPDATE dbo.Users SET access = 255 WHERE id = @U1; END TRY BEGIN CATCH SET @E3 = ERROR_NUMBER(); END CATCH
BEGIN TRY UPDATE dbo.Users SET userType = 33, access = 255 WHERE id = @U1; END TRY BEGIN CATCH SET @E4 = ERROR_NUMBER(); END CATCH
BEGIN TRY UPDATE dbo.Users SET userType = 47 WHERE id = @U1; END TRY BEGIN CATCH SET @E5 = ERROR_NUMBER(); END CATCH
SELECT @Type = userType, @Access = access FROM dbo.Users WHERE id = @U1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @E1 <> 547 OR @E2 <> 547 OR @E3 <> 547 OR @E4 <> 547 OR @E5 <> 547 OR ISNULL(@Type, 0) <> 1 OR ISNULL(@Access, -1) <> 0
   RAISERROR ('TEST 4 FAIL [%dms]: expected all five direct writes refused (547)', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: 0, bit 64, lone 255, bare admin, admin w/o 255 refused'

ROLLBACK TRAN UT_Test04
GO

-- ============================================================================
-- TEST 5: sp_user_type_set refusals
-- ============================================================================
BEGIN TRAN UT_Test05
    declare @test_name sysname = N'UT_Test05 [sp_user_type_set] : refusals'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @M1 nvarchar(200), @M2 nvarchar(200), @M3 nvarchar(200), @M4 nvarchar(200), @Type int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted, access, userType)
VALUES (@U1, N'ut_user_t5', 0x00000000000000000000000000000000, N'F', N'L', N'ut5@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 255, 47);

BEGIN TRY EXEC dbo.sp_user_type_set @userId = @U1, @userType = 0; END TRY BEGIN CATCH SET @M1 = ERROR_MESSAGE(); END CATCH
BEGIN TRY EXEC dbo.sp_user_type_set @userId = @U1, @userType = 65; END TRY BEGIN CATCH SET @M2 = ERROR_MESSAGE(); END CATCH
BEGIN TRY EXEC dbo.sp_user_type_set @userId = '00000000-0000-0000-0000-000000000001', @userType = 2; END TRY BEGIN CATCH SET @M3 = ERROR_MESSAGE(); END CATCH
BEGIN TRY EXEC dbo.sp_user_type_set @userId = @U1, @userType = 15, @changedBy = @U1; END TRY BEGIN CATCH SET @M4 = ERROR_MESSAGE(); END CATCH
SELECT @Type = userType FROM dbo.Users WHERE id = @U1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@M1, '') <> 'Unknown user type.' OR ISNULL(@M2, '') <> 'Unknown user type.' OR ISNULL(@M3, '') <> 'Unknown account.'
   OR ISNULL(@M4, '') NOT LIKE 'An admin cannot remove admin%' OR ISNULL(@Type, 0) <> 47
   RAISERROR ('TEST 5 FAIL [%dms]: expected four refusals and the admin kept', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: 0, bit 64, unknown account, self-demotion refused'

ROLLBACK TRAN UT_Test05
GO

-- ============================================================================
-- TEST 6: the sync outbox carries the mask
-- ============================================================================
BEGIN TRAN UT_Test06
    declare @test_name sysname = N'UT_Test06 [TR_Users_SyncOutbox] : outbox carries userType'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Created int, @Updated int, @Taken int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'ut_user_t6', 0x00000000000000000000000000000000, N'F', N'L', N'ut6@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);
CREATE TABLE #s6 (userType int, access int);
INSERT INTO #s6 EXEC dbo.sp_user_type_set @userId = @U1, @userType = 5;   -- registered + scientist
DROP TABLE #s6;

SELECT @Created = userType FROM dbo.UsersSyncOutbox WHERE id = @U1 AND action = 'created';
SELECT TOP 1 @Updated = userType FROM dbo.UsersSyncOutbox WHERE id = @U1 AND action = 'updated' ORDER BY outbox_id DESC;

UPDATE dbo.UsersSyncOutbox SET dispatched_utc = SYSUTCDATETIME() WHERE id <> @U1 AND dispatched_utc IS NULL;
CREATE TABLE #r6 (outbox_id bigint, action varchar(10), id uniqueidentifier, UsersId bigint, userName varchar(64), email varchar(128)
    , lastVisit datetime2, access int, suspended bit, authType varchar(16), deleted bit, deletedUtc datetime2
    , prime bigint, prime_expired date, userType int, created_utc datetime2);
INSERT INTO #r6 EXEC dbo.sp_users_sync_outbox_take @batchSize = 10;
SELECT TOP 1 @Taken = userType FROM #r6 WHERE id = @U1 ORDER BY outbox_id DESC;
DROP TABLE #r6;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@Created, 0) <> 1 OR ISNULL(@Updated, 0) <> 5 OR ISNULL(@Taken, 0) <> 5
   RAISERROR ('TEST 6 FAIL [%dms]: expected 1 then 5 in the outbox', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: outbox carries mask 1 then 5'

ROLLBACK TRAN UT_Test06
GO

-- ============================================================================
-- TEST 7: fn_user_type_get
-- ============================================================================
BEGIN TRAN UT_Test07
    declare @test_name sysname = N'UT_Test07 [fn_user_type_get] : mask, codes, names'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Mask int, @Codes varchar(200), @Names nvarchar(400), @Agent varchar(200), @Deleted int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID(), @U2 uniqueidentifier = NEWID(), @U3 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted, access, userType)
VALUES (@U1, N'ut_zq_admin', 0x00000000000000000000000000000000, N'F', N'L', N'ut7a@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 255, 47)
     , (@U2, N'ut_zq_agent', 0x00000000000000000000000000000000, N'F', N'L', N'ut7b@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 0, 16)
     , (@U3, N'ut_zq_gone',  0x00000000000000000000000000000000, N'F', N'L', N'ut7c@test', N'q', 0x00000000000000000000000000000000, N'Local', 1, 0, 16);

SELECT @Mask = mask, @Codes = codes, @Names = names FROM dbo.fn_user_type_get(@U1);
SELECT @Agent = codes FROM dbo.fn_user_type_get(@U2);
SELECT @Deleted = COUNT(*) FROM dbo.fn_user_type_get(@U3);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@Mask, 0) <> 47 OR ISNULL(@Codes, '') <> 'admin,registered,paid,scientist,editor'
   OR ISNULL(@Names, N'') <> N'Admin, Registered user, Paid user, Scientist, Editor'
   OR ISNULL(@Agent, '') <> 'ai_agent' OR @Deleted <> 0
   RAISERROR ('TEST 7 FAIL [%dms]: expected 47 decoded in order, ai_agent alone, deleted hidden', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mask decoded in order, deleted account hidden'

ROLLBACK TRAN UT_Test07
GO
