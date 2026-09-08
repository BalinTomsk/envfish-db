SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the RabbitMQ user-prime sync outbox: dbo.UserPrimeSyncOutbox,
  dbo.TR_Users_Prime_SyncOutbox, dbo.sp_user_prime_sync_outbox_take,
  dbo.sp_user_prime_sync_outbox_ack.

  The dbo.Users_Prime half of the fishfind-frontend -> RabbitMQ (fishfind.account.events) -> cproxy
  SQLite mirror pipeline, alongside unit_test@UsersSyncOutbox.sql which covers the dbo.Users half.

  The property that matters most here is BATCHING: dbo.sp_user_prime_assign writes all 365 day
  primes in a single INSERT, and a T-SQL trigger is statement-level, so the trigger must emit ONE
  outbox row carrying a JSON array -- not 365 rows. Row-per-prime would put ~1.7M messages/min on
  the queue at the measured registration rate, so TEST 1 is a performance invariant, not a
  cosmetic one.

  The trigger has INSERT and DELETE arms only -- no UPDATE -- because dbo.Users_Prime is write-once
  per account (sp_user_prime_assign inserts under a NOT EXISTS guard and never rewrites).

  Each test is its own named transaction, rolled back at the end -- state restored, tests
  independent. Primes are seeded from a high base (9e9+) so they cannot collide with seed data or
  production values on UK_Users_Prime.

  TEST 1 - a 365-row INSERT into Users_Prime emits exactly ONE outbox row, action = 'created',
           day_count = 365 (the batching invariant)
  TEST 2 - the `primes` column is a real JSON array holding every (day, prime) pair, ordered by
           day_year, with the primes carried intact
  TEST 3 - DELETE of an account's prime rows appends one 'deleted' row listing the released days
  TEST 4 - hard-deleting the dbo.Users row cascades through FK_Users_Prime ON DELETE CASCADE and
           fires the trigger's DELETE arm (a cascade DOES fire the child's AFTER trigger)
  TEST 5 - sp_user_prime_sync_outbox_take returns undispatched rows oldest-first capped at
           @batchSize, and sp_user_prime_sync_outbox_ack excludes an acked row from a later take
  TEST 6 - a multi-account INSERT emits one row PER USER, not one merged row
  TEST 7 - a prime beyond 2^31 survives into the JSON payload intact (bigint, not int -- a
           truncated prime is a WRONG credential, not an approximate number)
*/

-- ============================================================================
-- TEST 1: a 365-row INSERT emits exactly one outbox row with day_count = 365
-- ============================================================================
BEGIN TRAN UPO_Test01
    declare @test_name sysname = N'UPO_Test01 [TR_Users_Prime_SyncOutbox] : 365 rows emit ONE outbox row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @Action varchar(10), @DayCount int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U1 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U1, N'upo_user_t1', 0x00000000000000000000000000000000, N'F', N'L', N'upo1@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

-- One statement, 365 rows -- exactly what dbo.sp_user_prime_assign does.
INSERT INTO dbo.Users_Prime (user_id, day_year, prime)
SELECT @U1, n.day_year, 9010000000 + n.day_year
FROM (SELECT TOP 365 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS day_year FROM sys.all_objects) n;

SELECT @Cnt = COUNT(*) FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U1;
SELECT @Action = action, @DayCount = day_count FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt <> 1 OR @Action <> 'created' OR @DayCount <> 365
   RAISERROR ('TEST 1 FAIL [%dms]: rows=%d action=%s day_count=%d (expected 1 / created / 365)', 16, -1, @ElapsedMs, @Cnt, @Action, @DayCount)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a 365-row INSERT emitted one created outbox row with day_count 365'

ROLLBACK TRAN UPO_Test01
GO

-- ============================================================================
-- TEST 2: `primes` is a real JSON array of every (day, prime) pair, day-ordered
-- ============================================================================
BEGIN TRAN UPO_Test02
    declare @test_name sysname = N'UPO_Test02 [TR_Users_Prime_SyncOutbox] : primes JSON array is complete and ordered'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Primes nvarchar(max), @ArrCount int, @FirstDay int, @FirstPrime bigint, @LastDay int, @LastPrime bigint;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U2 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U2, N'upo_user_t2', 0x00000000000000000000000000000000, N'F', N'L', N'upo2@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

INSERT INTO dbo.Users_Prime (user_id, day_year, prime)
SELECT @U2, n.day_year, 9020000000 + n.day_year
FROM (SELECT TOP 365 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS day_year FROM sys.all_objects) n;

SELECT @Primes = primes FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U2;

-- OPENJSON parses only well-formed JSON, so this doubles as a validity check on FOR JSON PATH's output.
SELECT @ArrCount = COUNT(*) FROM OPENJSON(@Primes);
SET @FirstDay   = CAST(JSON_VALUE(@Primes, '$[0].day')     AS int);
SET @FirstPrime = CAST(JSON_VALUE(@Primes, '$[0].prime')   AS bigint);
SET @LastDay    = CAST(JSON_VALUE(@Primes, '$[364].day')   AS int);
SET @LastPrime  = CAST(JSON_VALUE(@Primes, '$[364].prime') AS bigint);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ArrCount <> 365 OR @FirstDay <> 1 OR @FirstPrime <> 9020000001 OR @LastDay <> 365 OR @LastPrime <> 9020000365
   RAISERROR ('TEST 2 FAIL [%dms]: entries=%d first=(%d,%I64d) last=(%d,%I64d)', 16, -1, @ElapsedMs, @ArrCount, @FirstDay, @FirstPrime, @LastDay, @LastPrime)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: primes JSON holds all 365 pairs ordered by day_year'

ROLLBACK TRAN UPO_Test02
GO

-- ============================================================================
-- TEST 3: DELETE of prime rows appends one 'deleted' outbox row
-- ============================================================================
BEGIN TRAN UPO_Test03
    declare @test_name sysname = N'UPO_Test03 [TR_Users_Prime_SyncOutbox] : DELETE appends a deleted row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @LastAction varchar(10), @LastDayCount int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U3 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U3, N'upo_user_t3', 0x00000000000000000000000000000000, N'F', N'L', N'upo3@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

INSERT INTO dbo.Users_Prime (user_id, day_year, prime)
SELECT @U3, n.day_year, 9030000000 + n.day_year
FROM (SELECT TOP 10 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS day_year FROM sys.all_objects) n;

DELETE FROM dbo.Users_Prime WHERE user_id = @U3;

SELECT @Cnt = COUNT(*) FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U3;
SELECT TOP 1 @LastAction = action, @LastDayCount = day_count
FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U3 ORDER BY outbox_id DESC;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt <> 2 OR @LastAction <> 'deleted' OR @LastDayCount <> 10
   RAISERROR ('TEST 3 FAIL [%dms]: rows=%d last_action=%s last_day_count=%d (expected 2 / deleted / 10)', 16, -1, @ElapsedMs, @Cnt, @LastAction, @LastDayCount)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: DELETE appended one deleted row listing the released days'

ROLLBACK TRAN UPO_Test03
GO

-- ============================================================================
-- TEST 4: a cascade from deleting the Users row fires the DELETE arm
-- ============================================================================
BEGIN TRAN UPO_Test04
    declare @test_name sysname = N'UPO_Test04 [TR_Users_Prime_SyncOutbox] : ON DELETE CASCADE fires the trigger'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LastAction varchar(10), @LastDayCount int, @Remaining int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U4 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U4, N'upo_user_t4', 0x00000000000000000000000000000000, N'F', N'L', N'upo4@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

INSERT INTO dbo.Users_Prime (user_id, day_year, prime)
SELECT @U4, n.day_year, 9040000000 + n.day_year
FROM (SELECT TOP 7 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS day_year FROM sys.all_objects) n;

-- No DELETE arm on TR_Users_SyncOutbox, so the parent row's removal is itself unmirrored -- but
-- FK_Users_Prime is ON DELETE CASCADE, and a cascading delete DOES fire the child's AFTER trigger.
-- That is what keeps cproxy from serving primes for an account that no longer holds any.
DELETE FROM dbo.Users WHERE id = @U4;

SELECT @Remaining = COUNT(*) FROM dbo.Users_Prime WHERE user_id = @U4;
SELECT TOP 1 @LastAction = action, @LastDayCount = day_count
FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U4 ORDER BY outbox_id DESC;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Remaining <> 0 OR @LastAction <> 'deleted' OR @LastDayCount <> 7
   RAISERROR ('TEST 4 FAIL [%dms]: remaining=%d last_action=%s last_day_count=%d (expected 0 / deleted / 7)', 16, -1, @ElapsedMs, @Remaining, @LastAction, @LastDayCount)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: cascade delete of the Users row emitted a deleted outbox row'

ROLLBACK TRAN UPO_Test04
GO

-- ============================================================================
-- TEST 5: take returns oldest-first capped at @batchSize; ack excludes the row
-- ============================================================================
BEGIN TRAN UPO_Test05
    declare @test_name sysname = N'UPO_Test05 [sp_user_prime_sync_outbox_take/ack] : batching and ack'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Take1 int, @Take2 int, @FirstId bigint, @AckedStillThere int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U5 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U5, N'upo_user_t5', 0x00000000000000000000000000000000, N'F', N'L', N'upo5@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

-- Two statements -> two outbox rows for the same user.
INSERT INTO dbo.Users_Prime (user_id, day_year, prime) VALUES (@U5, 1, 9050000001);
INSERT INTO dbo.Users_Prime (user_id, day_year, prime) VALUES (@U5, 2, 9050000002);

-- INSERT ... EXEC binds POSITIONALLY: this table variable must mirror
-- sp_user_prime_sync_outbox_take's SELECT list column-for-column and in order, or the whole file
-- dies on a column-count error naming neither the proc nor the new column.
DECLARE @Taken TABLE (outbox_id bigint, action varchar(10), user_id uniqueidentifier,
                      day_count int, primes nvarchar(max), created_utc datetime2);

INSERT INTO @Taken EXEC dbo.sp_user_prime_sync_outbox_take @batchSize = 1;
SELECT @Take1 = COUNT(*), @FirstId = MIN(outbox_id) FROM @Taken;

EXEC dbo.sp_user_prime_sync_outbox_ack @outbox_id = @FirstId;

DELETE FROM @Taken;
INSERT INTO @Taken EXEC dbo.sp_user_prime_sync_outbox_take @batchSize = 25;
SELECT @Take2 = COUNT(*) FROM @Taken WHERE user_id = @U5;
SELECT @AckedStillThere = COUNT(*) FROM @Taken WHERE outbox_id = @FirstId;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Take1 <> 1 OR @Take2 <> 1 OR @AckedStillThere <> 0
   RAISERROR ('TEST 5 FAIL [%dms]: take1=%d take2=%d acked_still_returned=%d', 16, -1, @ElapsedMs, @Take1, @Take2, @AckedStillThere)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: take honours batchSize and ack removes the row from a later take'

ROLLBACK TRAN UPO_Test05
GO

-- ============================================================================
-- TEST 6: a multi-account INSERT emits one row per user, not one merged row
-- ============================================================================
BEGIN TRAN UPO_Test06
    declare @test_name sysname = N'UPO_Test06 [TR_Users_Prime_SyncOutbox] : grouped per user_id'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @RowsA int, @RowsB int, @CountA int, @CountB int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U6a uniqueidentifier = NEWID(), @U6b uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U6a, N'upo_user_t6a', 0x00000000000000000000000000000000, N'F', N'L', N'upo6a@test', N'q', 0x00000000000000000000000000000000, N'Local', 0),
       (@U6b, N'upo_user_t6b', 0x00000000000000000000000000000000, N'F', N'L', N'upo6b@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

-- ONE statement spanning two accounts, as a backfill pass would do.
INSERT INTO dbo.Users_Prime (user_id, day_year, prime) VALUES
    (@U6a, 1, 9060000001), (@U6a, 2, 9060000002), (@U6a, 3, 9060000003),
    (@U6b, 1, 9060000101), (@U6b, 2, 9060000102);

SELECT @RowsA = COUNT(*) FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U6a;
SELECT @RowsB = COUNT(*) FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U6b;
SELECT @CountA = day_count FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U6a;
SELECT @CountB = day_count FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U6b;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @RowsA <> 1 OR @RowsB <> 1 OR @CountA <> 3 OR @CountB <> 2
   RAISERROR ('TEST 6 FAIL [%dms]: rowsA=%d rowsB=%d countA=%d countB=%d (expected 1/1/3/2)', 16, -1, @ElapsedMs, @RowsA, @RowsB, @CountA, @CountB)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a two-account INSERT emitted one outbox row per user'

ROLLBACK TRAN UPO_Test06
GO

-- ============================================================================
-- TEST 7: a prime beyond 2^31 survives into the JSON payload intact
-- ============================================================================
BEGIN TRAN UPO_Test07
    declare @test_name sysname = N'UPO_Test07 [TR_Users_Prime_SyncOutbox] : bigint prime not truncated'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Primes nvarchar(max), @GotPrime bigint;
DECLARE @BigPrime bigint = 9876543210;   -- > 2^31 (2147483648)
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @U7 uniqueidentifier = NEWID();
INSERT INTO dbo.Users (id, userName, psw, firstName, lastName, email, question, answer, authType, deleted)
VALUES (@U7, N'upo_user_t7', 0x00000000000000000000000000000000, N'F', N'L', N'upo7@test', N'q', 0x00000000000000000000000000000000, N'Local', 0);

INSERT INTO dbo.Users_Prime (user_id, day_year, prime) VALUES (@U7, 1, @BigPrime);

SELECT @Primes = primes FROM dbo.UserPrimeSyncOutbox WHERE user_id = @U7;
SET @GotPrime = CAST(JSON_VALUE(@Primes, '$[0].prime') AS bigint);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @GotPrime IS NULL OR @GotPrime <> @BigPrime
   RAISERROR ('TEST 7 FAIL [%dms]: expected prime %I64d in payload, got %I64d', 16, -1, @ElapsedMs, @BigPrime, @GotPrime)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a prime beyond 2^31 reached the JSON payload intact'

ROLLBACK TRAN UPO_Test07
GO
