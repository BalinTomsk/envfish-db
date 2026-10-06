SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the self-service MCP keys of a registered user: dbo.user_mcp_key,
  dbo.sp_user_mcp_key_issue, dbo.sp_user_mcp_key_revoke, dbo.fn_user_mcp_key_list.

  Backs the "MCP" tab of Account/Profile.aspx (fishfind-frontend): the page generates a token, stores
  only its SHA-256 here, and lists / revokes the user's keys. Owners must be real dbo.Users rows
  (FK_user_mcp_key_users), so each test inserts a minimal Users fixture. Each test is its own named
  transaction, rolled back at the end -- state restored, tests independent.

  TEST 1 - issue records one live key; fn_user_mcp_key_list returns it with its label
  TEST 2 - a malformed hash or an empty label is refused ('bad_request') and nothing is stored
  TEST 3 - a hash already on file is refused ('duplicate'), even when that key was revoked
  TEST 4 - one live key per user: a second is refused ('limit'); revoke or expiry frees the slot
  TEST 5 - revoke removes the key from the list; revoking it again is 'not_found'
  TEST 6 - another user cannot revoke a key that is not theirs
  TEST 7 - an unknown ('no_user') or suspended ('suspended') account gets no key
*/

-- ============================================================================
-- TEST 1: issue records one live key, listed with its label
-- ============================================================================
BEGIN TRAN MK_Test01
    declare @test_name sysname = N'MK_Test01 [sp_user_mcp_key_issue] : issues one live key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Status varchar(20), @Cnt int, @Label nvarchar(64), @KeyId uniqueidentifier, @ListedId uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'mk_user_t1', 0x00000000000000000000000000000000, N'F', N'L', N'mk1@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r1 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
INSERT INTO #r1 EXEC dbo.sp_user_mcp_key_issue @userid = @U1, @label = N' home laptop ',
     @sha256 = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
SELECT @Status = status, @KeyId = key_id FROM #r1;
DROP TABLE #r1;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_mcp_key_list(@U1);
SELECT @Label = label, @ListedId = key_id FROM dbo.fn_user_mcp_key_list(@U1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@Status, '') <> 'issued' OR @Cnt <> 1 OR @Label <> N'home laptop' OR @ListedId <> @KeyId
   RAISERROR ('TEST 1 FAIL [%dms]: expected one live key labelled home laptop', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: one live key issued and listed'

ROLLBACK TRAN MK_Test01
GO

-- ============================================================================
-- TEST 2: malformed hash / empty label -> 'bad_request', nothing stored
-- ============================================================================
BEGIN TRAN MK_Test02
    declare @test_name sysname = N'MK_Test02 [sp_user_mcp_key_issue] : rejects bad input'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @S1 varchar(20), @S2 varchar(20), @S3 varchar(20), @S4 varchar(20), @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'mk_user_t2', 0x00000000000000000000000000000000, N'F', N'L', N'mk2@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r2 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
-- upper-case hex: the hash must be exactly what cproxy computes (lower-case), or it never matches
INSERT INTO #r2 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', '0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef';
SELECT @S1 = status FROM #r2; DELETE FROM #r2;
INSERT INTO #r2 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', '0123456789abcdef';
SELECT @S2 = status FROM #r2; DELETE FROM #r2;
INSERT INTO #r2 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', 'zz23456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
SELECT @S3 = status FROM #r2; DELETE FROM #r2;
INSERT INTO #r2 EXEC dbo.sp_user_mcp_key_issue @U1, N'   ', '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
SELECT @S4 = status FROM #r2;
DROP TABLE #r2;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_mcp_key_list(@U1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@S1,'') <> 'bad_request' OR ISNULL(@S2,'') <> 'bad_request' OR ISNULL(@S3,'') <> 'bad_request'
   OR ISNULL(@S4,'') <> 'bad_request' OR @Cnt <> 0
   RAISERROR ('TEST 2 FAIL [%dms]: bad hash or empty label was not refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bad hash and empty label refused'

ROLLBACK TRAN MK_Test02
GO

-- ============================================================================
-- TEST 3: a hash already on file -> 'duplicate', revoked rows included
-- ============================================================================
BEGIN TRAN MK_Test03
    declare @test_name sysname = N'MK_Test03 [sp_user_mcp_key_issue] : refuses a reused hash'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @S1 varchar(20), @S2 varchar(20);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID(), @U2 uniqueidentifier = NEWID();
DECLARE @H varchar(64) = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'mk_user_t3a', 0x00000000000000000000000000000000, N'F', N'L', N'mk3a@test', N'q', 0x00000000000000000000000000000000, N'Local', 0),
       (@U2, N'mk_user_t3b', 0x00000000000000000000000000000000, N'F', N'L', N'mk3b@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r3 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
INSERT INTO #r3 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', @H;
SELECT @KeyId = key_id FROM #r3; DELETE FROM #r3;
INSERT INTO #r3 EXEC dbo.sp_user_mcp_key_issue @U2, N'pc', @H;
SELECT @S1 = status FROM #r3; DELETE FROM #r3;

CREATE TABLE #v3 (status varchar(20));
INSERT INTO #v3 EXEC dbo.sp_user_mcp_key_revoke @U1, @KeyId;
DROP TABLE #v3;

INSERT INTO #r3 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', @H;
SELECT @S2 = status FROM #r3;
DROP TABLE #r3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @KeyId IS NULL OR ISNULL(@S1,'') <> 'duplicate' OR ISNULL(@S2,'') <> 'duplicate'
   RAISERROR ('TEST 3 FAIL [%dms]: a reused hash was not refused', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: reused hash refused, revoked or not'

ROLLBACK TRAN MK_Test03
GO

-- ============================================================================
-- TEST 4: one live key per user -> a second is 'limit'; revoke or expiry frees the slot
-- (single-key mode since 2026-10-02: Account/Profile.aspx shows one key or the create form)
-- ============================================================================
BEGIN TRAN MK_Test04
    declare @test_name sysname = N'MK_Test04 [sp_user_mcp_key_issue] : one live key at most'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @S1 varchar(20), @S2 varchar(20), @S3 varchar(20), @S4 varchar(20), @First uniqueidentifier, @Third uniqueidentifier, @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'mk_user_t4', 0x00000000000000000000000000000000, N'F', N'L', N'mk4@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r4 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
INSERT INTO #r4 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', '1111111111111111111111111111111111111111111111111111111111111111';
SELECT @S1 = status, @First = key_id FROM #r4; DELETE FROM #r4;

-- a second key while the first is live
INSERT INTO #r4 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', '2222222222222222222222222222222222222222222222222222222222222222';
SELECT @S2 = status FROM #r4; DELETE FROM #r4;

-- revoking the first frees the slot
CREATE TABLE #v4 (status varchar(20));
INSERT INTO #v4 EXEC dbo.sp_user_mcp_key_revoke @U1, @First;
DROP TABLE #v4;
INSERT INTO #r4 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', '3333333333333333333333333333333333333333333333333333333333333333';
SELECT @S3 = status, @Third = key_id FROM #r4; DELETE FROM #r4;

-- so does expiry (fixture: age the live key past user_mcp_key_expires)
UPDATE dbo.user_mcp_key SET user_mcp_key_expires = DATEADD(MINUTE, -1, SYSUTCDATETIME())
    WHERE user_mcp_key_id = @Third;
INSERT INTO #r4 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', '4444444444444444444444444444444444444444444444444444444444444444';
SELECT @S4 = status FROM #r4;
DROP TABLE #r4;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_mcp_key_list(@U1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@S1,'') <> 'issued' OR ISNULL(@S2,'') <> 'limit' OR ISNULL(@S3,'') <> 'issued'
   OR ISNULL(@S4,'') <> 'issued' OR ISNULL(@Cnt, -1) <> 1
   RAISERROR ('TEST 4 FAIL [%dms]: the one-live-key cap did not hold', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: second key refused; revoke or expiry frees it'

ROLLBACK TRAN MK_Test04
GO

-- ============================================================================
-- TEST 5: revoke removes the key from the list; a second revoke is 'not_found'
-- ============================================================================
BEGIN TRAN MK_Test05
    declare @test_name sysname = N'MK_Test05 [sp_user_mcp_key_revoke] : revokes a key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @V1 varchar(20), @V2 varchar(20), @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'mk_user_t5', 0x00000000000000000000000000000000, N'F', N'L', N'mk5@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r5 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
INSERT INTO #r5 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
SELECT @KeyId = key_id FROM #r5;
DROP TABLE #r5;

CREATE TABLE #v5 (status varchar(20));
INSERT INTO #v5 EXEC dbo.sp_user_mcp_key_revoke @U1, @KeyId;
SELECT @V1 = status FROM #v5; DELETE FROM #v5;
INSERT INTO #v5 EXEC dbo.sp_user_mcp_key_revoke @U1, @KeyId;
SELECT @V2 = status FROM #v5;
DROP TABLE #v5;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_mcp_key_list(@U1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@V1,'') <> 'revoked' OR ISNULL(@V2,'') <> 'not_found' OR @Cnt <> 0
   RAISERROR ('TEST 5 FAIL [%dms]: revoke did not remove the key exactly once', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: key revoked; second revoke not_found'

ROLLBACK TRAN MK_Test05
GO

-- ============================================================================
-- TEST 6: another user cannot revoke a key that is not theirs
-- ============================================================================
BEGIN TRAN MK_Test06
    declare @test_name sysname = N'MK_Test06 [sp_user_mcp_key_revoke] : owner only'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @V1 varchar(20), @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID(), @U2 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'mk_user_t6a', 0x00000000000000000000000000000000, N'F', N'L', N'mk6a@test', N'q', 0x00000000000000000000000000000000, N'Local', 0),
       (@U2, N'mk_user_t6b', 0x00000000000000000000000000000000, N'F', N'L', N'mk6b@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #r6 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
INSERT INTO #r6 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
SELECT @KeyId = key_id FROM #r6;
DROP TABLE #r6;

CREATE TABLE #v6 (status varchar(20));
INSERT INTO #v6 EXEC dbo.sp_user_mcp_key_revoke @U2, @KeyId;
SELECT @V1 = status FROM #v6;
DROP TABLE #v6;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_mcp_key_list(@U1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@V1,'') <> 'not_found' OR @Cnt <> 1
   RAISERROR ('TEST 6 FAIL [%dms]: another user revoked a key not theirs', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: only the owner can revoke'

ROLLBACK TRAN MK_Test06
GO

-- ============================================================================
-- TEST 7: unknown -> 'no_user', suspended -> 'suspended'; no key created
-- ============================================================================
BEGIN TRAN MK_Test07
    declare @test_name sysname = N'MK_Test07 [sp_user_mcp_key_issue] : refuses bad accounts'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @S1 varchar(20), @S2 varchar(20), @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted, suspended)
VALUES (@U1, N'mk_user_t7', 0x00000000000000000000000000000000, N'F', N'L', N'mk7@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 1);

CREATE TABLE #r7 (status varchar(20), key_id uniqueidentifier, label nvarchar(64), created_utc datetime2);
INSERT INTO #r7 EXEC dbo.sp_user_mcp_key_issue @U1, N'pc', 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
SELECT @S1 = status FROM #r7; DELETE FROM #r7;
INSERT INTO #r7 EXEC dbo.sp_user_mcp_key_issue NULL, N'pc', 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
SELECT @S2 = status FROM #r7;
DROP TABLE #r7;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_mcp_key_list(@U1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@S1,'') <> 'suspended' OR ISNULL(@S2,'') <> 'no_user' OR @Cnt <> 0
   RAISERROR ('TEST 7 FAIL [%dms]: a suspended or unknown account got a key', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: suspended and unknown refused'

ROLLBACK TRAN MK_Test07
GO
