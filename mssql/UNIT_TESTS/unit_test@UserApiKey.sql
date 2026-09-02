SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the personal REST-API key of a registered user: dbo.user_api_key,
  dbo.sp_user_api_key_issue, dbo.sp_user_api_key_disable, dbo.sp_user_api_key_delete,
  dbo.fn_user_api_key_list, dbo.fn_user_api_key_user.

  Backs the "API access" section of Account/Profile.aspx (fishfind-frontend): a signed-in user
  issues a key, copies it, and can disable or delete it -- both of which must REVOKE it, i.e.
  fn_user_api_key_user (the resolver any REST service authenticates with) must stop returning the
  owner. Owners must be real dbo.Users rows (FK_user_api_key_users), so each test inserts a minimal
  Users fixture. Each test is its own named transaction, rolled back at the end -- state restored,
  tests independent.

  TEST 1 - sp_user_api_key_issue creates one live key; fn_user_api_key_list returns it, enabled,
           and the key value is a well-formed v7 GUID (version nibble 7, RFC 9562 variant)
  TEST 2 - fn_user_api_key_user resolves a fresh key to its owner
  TEST 3 - disabling revokes the key (resolver returns NULL) while the row stays listed, flagged
  TEST 4 - re-enabling restores it (resolver returns the owner again)
  TEST 5 - deleting revokes the key permanently: listing is empty and the resolver returns NULL
  TEST 6 - re-issuing revokes the previous key and leaves exactly one live key
  TEST 7 - another user can neither disable nor delete a key that is not theirs
  TEST 8 - a suspended or soft-deleted owner's key stops resolving
  TEST 9  - sp_user_api_key_issue refuses an unknown ('no_user') and a suspended ('suspended')
            account without creating a key
  TEST 10 - a fresh key's expires_utc is exactly 90 days after created_utc and is_expired = 0
  TEST 11 - a key past its 90-day expiry stops resolving (fn_user_api_key_user) and is listed
            with is_expired = 1, even though it was never explicitly disabled
*/

-- ============================================================================
-- TEST 1: issue creates one live key; the value is a v7 GUID
-- ============================================================================
BEGIN TRAN AK_Test01
    declare @test_name sysname = N'AK_Test01 [sp_user_api_key_issue] : issues one live v7 key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Status varchar(20), @Cnt int, @Key uniqueidentifier, @Disabled bit, @KeyTxt char(36);
DECLARE @Expired bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'ak_user_t1', 0x00000000000000000000000000000000, N'F', N'L', N'ak1@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k1 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k1 EXEC dbo.sp_user_api_key_issue @userid = @U1;
SELECT @Status = status FROM #k1;
DROP TABLE #k1;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_api_key_list(@U1);
SELECT @Key = api_key, @Disabled = is_disabled, @Expired = is_expired FROM dbo.fn_user_api_key_list(@U1);
SET @KeyTxt = CONVERT(char(36), @Key);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Status <> 'issued' OR @Cnt <> 1 OR @Key IS NULL OR @Disabled <> 0 OR @Expired <> 0
   OR SUBSTRING(@KeyTxt, 15, 1) <> '7' OR SUBSTRING(@KeyTxt, 20, 1) NOT IN ('8','9','A','B')
   RAISERROR ('TEST 1 FAIL [%dms]: status=%s live keys=%d key=%s', 16, -1, @ElapsedMs, @Status, @Cnt, @KeyTxt)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: one live, enabled, unexpired key issued as a v7 GUID'

ROLLBACK TRAN AK_Test01
GO

-- ============================================================================
-- TEST 2: fn_user_api_key_user resolves a fresh key to its owner
-- ============================================================================
BEGIN TRAN AK_Test02
    declare @test_name sysname = N'AK_Test02 [fn_user_api_key_user] : resolves a fresh key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Key uniqueidentifier, @Owner uniqueidentifier, @Unknown uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U2 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U2, N'ak_user_t2', 0x00000000000000000000000000000000, N'F', N'L', N'ak2@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k2 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k2 EXEC dbo.sp_user_api_key_issue @userid = @U2;
SELECT @Key = api_key FROM #k2;
DROP TABLE #k2;

SET @Owner   = dbo.fn_user_api_key_user(@Key);
SET @Unknown = dbo.fn_user_api_key_user(NEWID());   -- a key nobody was ever given

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Owner IS NULL OR @Owner <> @U2 OR @Unknown IS NOT NULL
   RAISERROR ('TEST 2 FAIL [%dms]: the key did not resolve to its owner (or an unknown key did)', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fresh key resolves to its owner, unknown key resolves to NULL'

ROLLBACK TRAN AK_Test02
GO

-- ============================================================================
-- TEST 3: disabling revokes the key but keeps it listed, flagged
-- ============================================================================
BEGIN TRAN AK_Test03
    declare @test_name sysname = N'AK_Test03 [sp_user_api_key_disable] : disable revokes the key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @Key uniqueidentifier, @Owner uniqueidentifier, @Cnt int, @Disabled bit, @Stamp datetime2;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U3 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U3, N'ak_user_t3', 0x00000000000000000000000000000000, N'F', N'L', N'ak3@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k3 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k3 EXEC dbo.sp_user_api_key_issue @userid = @U3;
SELECT @KeyId = key_id, @Key = api_key FROM #k3;
DROP TABLE #k3;

EXEC dbo.sp_user_api_key_disable @userid = @U3, @key_id = @KeyId, @disabled = 1;

SET @Owner = dbo.fn_user_api_key_user(@Key);
SELECT @Cnt = COUNT(*) FROM dbo.fn_user_api_key_list(@U3);
SELECT @Disabled = is_disabled, @Stamp = disabled_utc FROM dbo.fn_user_api_key_list(@U3);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Owner IS NOT NULL OR @Cnt <> 1 OR @Disabled <> 1 OR @Stamp IS NULL
   RAISERROR ('TEST 3 FAIL [%dms]: disabled key still resolves, or is no longer listed as disabled', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a disabled key stops resolving and stays listed as disabled'

ROLLBACK TRAN AK_Test03
GO

-- ============================================================================
-- TEST 4: re-enabling restores the key
-- ============================================================================
BEGIN TRAN AK_Test04
    declare @test_name sysname = N'AK_Test04 [sp_user_api_key_disable] : enable restores the key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @Key uniqueidentifier, @OwnerOff uniqueidentifier, @OwnerOn uniqueidentifier, @Disabled bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U4 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U4, N'ak_user_t4', 0x00000000000000000000000000000000, N'F', N'L', N'ak4@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k4 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k4 EXEC dbo.sp_user_api_key_issue @userid = @U4;
SELECT @KeyId = key_id, @Key = api_key FROM #k4;
DROP TABLE #k4;

EXEC dbo.sp_user_api_key_disable @userid = @U4, @key_id = @KeyId, @disabled = 1;
SET @OwnerOff = dbo.fn_user_api_key_user(@Key);

EXEC dbo.sp_user_api_key_disable @userid = @U4, @key_id = @KeyId, @disabled = 0;
SET @OwnerOn = dbo.fn_user_api_key_user(@Key);
SELECT @Disabled = is_disabled FROM dbo.fn_user_api_key_list(@U4);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @OwnerOff IS NOT NULL OR @OwnerOn IS NULL OR @OwnerOn <> @U4 OR @Disabled <> 0
   RAISERROR ('TEST 4 FAIL [%dms]: re-enabling did not restore the key', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a re-enabled key resolves to its owner again'

ROLLBACK TRAN AK_Test04
GO

-- ============================================================================
-- TEST 5: deleting revokes the key permanently
-- ============================================================================
BEGIN TRAN AK_Test05
    declare @test_name sysname = N'AK_Test05 [sp_user_api_key_delete] : delete revokes permanently'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @Key uniqueidentifier, @Owner uniqueidentifier, @Cnt int, @Rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U5 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U5, N'ak_user_t5', 0x00000000000000000000000000000000, N'F', N'L', N'ak5@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k5 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k5 EXEC dbo.sp_user_api_key_issue @userid = @U5;
SELECT @KeyId = key_id, @Key = api_key FROM #k5;
DROP TABLE #k5;

EXEC dbo.sp_user_api_key_delete @userid = @U5, @key_id = @KeyId;

SET @Owner = dbo.fn_user_api_key_user(@Key);
SELECT @Cnt  = COUNT(*) FROM dbo.fn_user_api_key_list(@U5);
-- the row itself is KEPT (history; the secret must never be handed out again)
SELECT @Rows = COUNT(*) FROM dbo.user_api_key WHERE user_api_key_id = @KeyId AND user_api_key_deleted IS NOT NULL;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Owner IS NOT NULL OR @Cnt <> 0 OR @Rows <> 1
   RAISERROR ('TEST 5 FAIL [%dms]: deleted key still resolves (%d listed, %d stamped rows)', 16, -1, @ElapsedMs, @Cnt, @Rows)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a deleted key stops resolving and stops being listed, row kept'

ROLLBACK TRAN AK_Test05
GO

-- ============================================================================
-- TEST 6: re-issuing revokes the previous key, leaving exactly one live key
-- ============================================================================
BEGIN TRAN AK_Test06
    declare @test_name sysname = N'AK_Test06 [sp_user_api_key_issue] : re-issue revokes the old key'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Key1 uniqueidentifier, @Key2 uniqueidentifier, @Owner1 uniqueidentifier, @Owner2 uniqueidentifier, @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U6 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U6, N'ak_user_t6', 0x00000000000000000000000000000000, N'F', N'L', N'ak6@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k6 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k6 EXEC dbo.sp_user_api_key_issue @userid = @U6;
SELECT @Key1 = api_key FROM #k6;
DELETE FROM #k6;

INSERT INTO #k6 EXEC dbo.sp_user_api_key_issue @userid = @U6;
SELECT @Key2 = api_key FROM #k6;
DROP TABLE #k6;

SET @Owner1 = dbo.fn_user_api_key_user(@Key1);
SET @Owner2 = dbo.fn_user_api_key_user(@Key2);
SELECT @Cnt = COUNT(*) FROM dbo.fn_user_api_key_list(@U6);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Key1 = @Key2 OR @Owner1 IS NOT NULL OR @Owner2 IS NULL OR @Owner2 <> @U6 OR @Cnt <> 1
   RAISERROR ('TEST 6 FAIL [%dms]: re-issue left %d live keys, or the old key still resolves', 16, -1, @ElapsedMs, @Cnt)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: re-issue revokes the previous key and leaves exactly one live key'

ROLLBACK TRAN AK_Test06
GO

-- ============================================================================
-- TEST 7: another user cannot disable or delete a key that is not theirs
-- ============================================================================
BEGIN TRAN AK_Test07
    declare @test_name sysname = N'AK_Test07 [sp_user_api_key_disable/delete] : owner-scoped'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyId uniqueidentifier, @Key uniqueidentifier, @Owner uniqueidentifier, @Disabled bit, @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U7  uniqueidentifier = NEWID();
DECLARE @Bad uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U7, N'ak_user_t7', 0x00000000000000000000000000000000, N'F', N'L', N'ak7@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k7 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k7 EXEC dbo.sp_user_api_key_issue @userid = @U7;
SELECT @KeyId = key_id, @Key = api_key FROM #k7;
DROP TABLE #k7;

-- the attacker knows the key id but is not its owner
EXEC dbo.sp_user_api_key_disable @userid = @Bad, @key_id = @KeyId, @disabled = 1;
EXEC dbo.sp_user_api_key_delete  @userid = @Bad, @key_id = @KeyId;

SET @Owner = dbo.fn_user_api_key_user(@Key);
SELECT @Cnt = COUNT(*) FROM dbo.fn_user_api_key_list(@U7);
SELECT @Disabled = is_disabled FROM dbo.fn_user_api_key_list(@U7);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Owner IS NULL OR @Owner <> @U7 OR @Cnt <> 1 OR @Disabled <> 0
   RAISERROR ('TEST 7 FAIL [%dms]: a non-owner was able to revoke another user''s key', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: disable/delete only ever touch the caller''s own key'

ROLLBACK TRAN AK_Test07
GO

-- ============================================================================
-- TEST 8: a suspended or soft-deleted owner's key stops resolving
-- ============================================================================
BEGIN TRAN AK_Test08
    declare @test_name sysname = N'AK_Test08 [fn_user_api_key_user] : suspended / deleted owner'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @KeyA uniqueidentifier, @KeyB uniqueidentifier, @OwnerA uniqueidentifier, @OwnerB uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U8a uniqueidentifier = NEWID();
DECLARE @U8b uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U8a, N'ak_user_t8a', 0x00000000000000000000000000000000, N'F', N'L', N'ak8a@test', N'q', 0x00000000000000000000000000000000, N'Local', 0),
       (@U8b, N'ak_user_t8b', 0x00000000000000000000000000000000, N'F', N'L', N'ak8b@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k8 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k8 EXEC dbo.sp_user_api_key_issue @userid = @U8a;
SELECT @KeyA = api_key FROM #k8;
DELETE FROM #k8;
INSERT INTO #k8 EXEC dbo.sp_user_api_key_issue @userid = @U8b;
SELECT @KeyB = api_key FROM #k8;
DROP TABLE #k8;

UPDATE dbo.Users SET suspended = 1 WHERE id = @U8a;                              -- banned
UPDATE dbo.Users SET deleted = 1, deletedUtc = SYSUTCDATETIME() WHERE id = @U8b; -- account deleted

SET @OwnerA = dbo.fn_user_api_key_user(@KeyA);
SET @OwnerB = dbo.fn_user_api_key_user(@KeyB);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @OwnerA IS NOT NULL OR @OwnerB IS NOT NULL
   RAISERROR ('TEST 8 FAIL [%dms]: a suspended or deleted account key still resolves', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: keys of suspended and soft-deleted accounts stop resolving'

ROLLBACK TRAN AK_Test08
GO

-- ============================================================================
-- TEST 9: issue refuses an unknown and a suspended account
-- ============================================================================
BEGIN TRAN AK_Test09
    declare @test_name sysname = N'AK_Test09 [sp_user_api_key_issue] : no_user / suspended'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @StNoUser varchar(20), @StSusp varchar(20), @Cnt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U9 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted, suspended)
VALUES (@U9, N'ak_user_t9', 0x00000000000000000000000000000000, N'F', N'L', N'ak9@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 1);

CREATE TABLE #k9 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                  created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                  is_disabled bit, is_expired bit);
INSERT INTO #k9 EXEC dbo.sp_user_api_key_issue @userid = @U9;       -- suspended account
SELECT @StSusp = status FROM #k9;
DELETE FROM #k9;

DECLARE @Nobody uniqueidentifier = NEWID();
INSERT INTO #k9 EXEC dbo.sp_user_api_key_issue @userid = @Nobody;   -- no such account
SELECT @StNoUser = status FROM #k9;
DROP TABLE #k9;

SELECT @Cnt = COUNT(*) FROM dbo.fn_user_api_key_list(@U9);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @StNoUser <> 'no_user' OR @StSusp <> 'suspended' OR @Cnt <> 0
   RAISERROR ('TEST 9 FAIL [%dms]: unknown=%s suspended=%s keys=%d', 16, -1, @ElapsedMs, @StNoUser, @StSusp, @Cnt)
ELSE
    print 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: issue refuses unknown and suspended accounts without creating a key'

ROLLBACK TRAN AK_Test09
GO

-- ============================================================================
-- TEST 10: a fresh key expires exactly 90 days after it was created
-- ============================================================================
BEGIN TRAN AK_Test10
    declare @test_name sysname = N'AK_Test10 [fn_user_api_key_list] : expires_utc = created_utc + 90d'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Created datetime2, @Expires datetime2, @DiffDays int, @Expired bit, @ExpiredInt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U10 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U10, N'ak_user_t10', 0x00000000000000000000000000000000, N'F', N'L', N'ak10@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k10 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                   created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                   is_disabled bit, is_expired bit);
INSERT INTO #k10 EXEC dbo.sp_user_api_key_issue @userid = @U10;
DROP TABLE #k10;

SELECT @Created = created_utc, @Expires = expires_utc, @Expired = is_expired
    FROM dbo.fn_user_api_key_list(@U10);
SET @DiffDays = DATEDIFF(day, @Created, @Expires);
SET @ExpiredInt = CAST(@Expired AS int);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Expires IS NULL OR @DiffDays <> 90 OR @Expired <> 0
   RAISERROR ('TEST 10 FAIL [%dms]: expires_utc is %d day(s) after created_utc (want 90), is_expired=%d', 16, -1, @ElapsedMs, @DiffDays, @ExpiredInt)
ELSE
    print 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: expires_utc is exactly 90 days after created_utc, not yet expired'

ROLLBACK TRAN AK_Test10
GO

-- ============================================================================
-- TEST 11: a key past its 90-day expiry stops resolving, even if never disabled
-- ============================================================================
BEGIN TRAN AK_Test11
    declare @test_name sysname = N'AK_Test11 [fn_user_api_key_user] : expired key stops resolving'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Key uniqueidentifier, @Owner uniqueidentifier, @Expired bit, @Disabled bit;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U11 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U11, N'ak_user_t11', 0x00000000000000000000000000000000, N'F', N'L', N'ak11@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

CREATE TABLE #k11 (status varchar(20), key_id uniqueidentifier, api_key uniqueidentifier,
                   created_utc datetime2, expires_utc datetime2, disabled_utc datetime2,
                   is_disabled bit, is_expired bit);
INSERT INTO #k11 EXEC dbo.sp_user_api_key_issue @userid = @U11;
SELECT @Key = api_key FROM #k11;
DROP TABLE #k11;

-- back-date the issue so the PERSISTED expires_utc (created_utc + 90d) falls in the past --
-- created_utc has no other dependents in this test, so this only moves the expiry, nothing else.
UPDATE dbo.user_api_key
    SET user_api_key_created = DATEADD(day, -91, SYSUTCDATETIME())
    WHERE user_api_key_userid = @U11;

SET @Owner = dbo.fn_user_api_key_user(@Key);
SELECT @Expired = is_expired, @Disabled = is_disabled FROM dbo.fn_user_api_key_list(@U11);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Owner IS NOT NULL OR @Expired <> 1 OR @Disabled <> 0
   RAISERROR ('TEST 11 FAIL [%dms]: an expired key still resolves, or is_expired/is_disabled is wrong', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: an expired key stops resolving and is flagged expired, without being disabled'

ROLLBACK TRAN AK_Test11
GO
