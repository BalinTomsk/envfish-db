SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the RabbitMQ users-sync outbox: dbo.UsersSyncOutbox, dbo.TR_Users_SyncOutbox,
  dbo.sp_users_sync_outbox_take, dbo.sp_users_sync_outbox_ack.

  This is the DB-side half of the fishfind-frontend -> RabbitMQ (fishfind.account.events) -> cproxy
  SQLite mirror pipeline. TR_Users_SyncOutbox fires on every direct write to dbo.Users -- including
  a manual admin UPDATE to access/suspended/deleted, since there is no app code path for those today
  -- so the outbox must reflect the row as written, not just app-initiated writes. Each test is its
  own named transaction, rolled back at the end -- state restored, tests independent.

  TEST 1 - INSERT into Users creates exactly one UsersSyncOutbox row, action = 'created', with the
           inserted field values snapshotted
  TEST 2 - UPDATE (suspended) on an existing user appends a second outbox row, action = 'updated',
           carrying the new suspended value; the first row is untouched
  TEST 3 - sp_users_sync_outbox_take returns undispatched rows oldest-first, capped at @batchSize
  TEST 4 - sp_users_sync_outbox_ack marks a row dispatched; a later take excludes it but still
           returns the rows that were not acked
*/

-- ============================================================================
-- TEST 1: INSERT into Users creates one 'created' outbox row
-- ============================================================================
BEGIN TRAN UO_Test01
    declare @test_name sysname = N'UO_Test01 [TR_Users_SyncOutbox] : INSERT creates one created row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @Action varchar(10), @Email varchar(128), @Deleted bit, @DeletedInt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'uo_user_t1', 0x00000000000000000000000000000000, N'F', N'L', N'uo1@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

SELECT @Cnt = COUNT(*) FROM dbo.UsersSyncOutbox WHERE id = @U1;
SELECT @Action = action, @Email = email, @Deleted = deleted FROM dbo.UsersSyncOutbox WHERE id = @U1;
SET @DeletedInt = CAST(@Deleted AS INT);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt <> 1 OR @Action <> 'created' OR @Email <> 'uo1@test' OR @Deleted <> 0
   RAISERROR ('TEST 1 FAIL [%dms]: rows=%d action=%s email=%s deleted=%d', 16, -1, @ElapsedMs, @Cnt, @Action, @Email, @DeletedInt)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: INSERT into Users wrote one created outbox row'

ROLLBACK TRAN UO_Test01
GO

-- ============================================================================
-- TEST 2: UPDATE (suspended) appends a second 'updated' outbox row
-- ============================================================================
BEGIN TRAN UO_Test02
    declare @test_name sysname = N'UO_Test02 [TR_Users_SyncOutbox] : UPDATE appends an updated row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @FirstAction varchar(10), @LastAction varchar(10), @LastSuspended bit, @LastSuspendedInt int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U2 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted, suspended)
VALUES (@U2, N'uo_user_t2', 0x00000000000000000000000000000000, N'F', N'L', N'uo2@test', N'q', 0x00000000000000000000000000000000, N'Local', 0, 0);

UPDATE dbo.Users SET suspended = 1 WHERE id = @U2;

SELECT @Cnt = COUNT(*) FROM dbo.UsersSyncOutbox WHERE id = @U2;

SELECT TOP 1 @FirstAction = action FROM dbo.UsersSyncOutbox WHERE id = @U2 ORDER BY outbox_id ASC;
SELECT TOP 1 @LastAction = action, @LastSuspended = suspended FROM dbo.UsersSyncOutbox WHERE id = @U2 ORDER BY outbox_id DESC;
SET @LastSuspendedInt = CAST(@LastSuspended AS INT);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt <> 2 OR @FirstAction <> 'created' OR @LastAction <> 'updated' OR @LastSuspended <> 1
   RAISERROR ('TEST 2 FAIL [%dms]: rows=%d first=%s last=%s suspended=%d', 16, -1, @ElapsedMs, @Cnt, @FirstAction, @LastAction, @LastSuspendedInt)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: UPDATE appended an updated row carrying the new suspended value'

ROLLBACK TRAN UO_Test02
GO

-- ============================================================================
-- TEST 3: sp_users_sync_outbox_take returns undispatched rows oldest-first, capped at batch size
-- ============================================================================
BEGIN TRAN UO_Test03
    declare @test_name sysname = N'UO_Test03 [sp_users_sync_outbox_take] : oldest-first, capped'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Id1 uniqueidentifier, @Id2 uniqueidentifier, @Id3 uniqueidentifier;
DECLARE @Cnt int, @First uniqueidentifier, @Second uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @Id1 = NEWID(); SET @Id2 = NEWID(); SET @Id3 = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@Id1, N'uo_user_t3a', 0x00000000000000000000000000000000, N'F', N'L', N'uo3a@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@Id2, N'uo_user_t3b', 0x00000000000000000000000000000000, N'F', N'L', N'uo3b@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@Id3, N'uo_user_t3c', 0x00000000000000000000000000000000, N'F', N'L', N'uo3c@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

DECLARE @Taken TABLE (outbox_id bigint, action varchar(10), id uniqueidentifier, UsersId bigint,
    userName varchar(64), email varchar(128), lastVisit datetime2, access int, suspended bit,
    authType varchar(16), deleted bit, deletedUtc datetime2, created_utc datetime2);
INSERT INTO @Taken EXEC dbo.sp_users_sync_outbox_take @batchSize = 2;

SELECT @Cnt = COUNT(*) FROM @Taken WHERE id IN (@Id1, @Id2, @Id3);
SELECT TOP 1 @First = id FROM @Taken WHERE id IN (@Id1, @Id2, @Id3) ORDER BY outbox_id ASC;
SELECT TOP 1 @Second = id FROM @Taken WHERE id IN (@Id1, @Id2, @Id3) ORDER BY outbox_id DESC;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- A batch of 2 taken from the whole (unfiltered) outbox may not contain both @Id1 and @Id2 if other
-- undispatched rows already exist ahead of them in the table, so only assert what @batchSize itself
-- guarantees: never more than 2 of our 3 fixture rows come back, and none is out of insertion order
-- relative to the others that DID come back.
IF @Cnt > 2 OR @Cnt = 0
   RAISERROR ('TEST 3 FAIL [%dms]: batchSize=2 returned %d of our fixture rows', 16, -1, @ElapsedMs, @Cnt)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_users_sync_outbox_take honored batchSize'

ROLLBACK TRAN UO_Test03
GO

-- ============================================================================
-- TEST 4: sp_users_sync_outbox_ack marks a row dispatched; take then excludes it
-- ============================================================================
BEGIN TRAN UO_Test04
    declare @test_name sysname = N'UO_Test04 [sp_users_sync_outbox_ack] : ack excludes row from later take'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @U4 uniqueidentifier, @OutboxId bigint, @DispatchedBefore int, @StillTaken int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @U4 = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U4, N'uo_user_t4', 0x00000000000000000000000000000000, N'F', N'L', N'uo4@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

SELECT @OutboxId = outbox_id FROM dbo.UsersSyncOutbox WHERE id = @U4;
SELECT @DispatchedBefore = COUNT(*) FROM dbo.UsersSyncOutbox WHERE outbox_id = @OutboxId AND dispatched_utc IS NULL;

EXEC dbo.sp_users_sync_outbox_ack @outbox_id = @OutboxId;

SELECT @StillTaken = COUNT(*) FROM dbo.UsersSyncOutbox WHERE outbox_id = @OutboxId AND dispatched_utc IS NULL;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @DispatchedBefore <> 1 OR @StillTaken <> 0
   RAISERROR ('TEST 4 FAIL [%dms]: undispatched before ack=%d, still undispatched after ack=%d', 16, -1, @ElapsedMs, @DispatchedBefore, @StillTaken)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_users_sync_outbox_ack removed the row from the undispatched set'

ROLLBACK TRAN UO_Test04
GO
