SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the database half of the per-account prime allocation:
    dbo.sp_user_prime_bounds  - where the two prime sequences currently end
    dbo.sp_user_prime_assign  - stores the primes the app generated
    UK_Users_prime / UK_Users_Prime - the uniqueness the app's retry loop depends on

  The primes themselves are NOT generated here any more. FishTracker.PrimeGenerator
  (fishfind-frontend/aspnet/Models/PrimeGenerator.cs, a segmented sieve) computes them and
  FishTracker.UserPrimeAllocator passes them in through the dbo.UserPrimeList table-valued
  parameter; dbo.fn_prime_next_list was removed on 2026-09-04 because trial division in T-SQL cost
  ~500ms per registration at ~1000 accounts. So these tests deliberately feed the procedure
  arbitrary distinct values rather than real primes -- the database's contract is "store what you
  were given and keep it unique", and testing it with real primes would hide a failure to enforce
  that.

  Uses the real tables dbo.Users and dbo.Users_Prime. Each test scrubs its own fixture rows before
  running, so sharing one transaction creates no cross-test interference; the transaction is rolled
  back at the end and the database is left unchanged.

  TEST  1 - sp_user_prime_bounds applies the seed floors (1000000 / 97) when a sequence is unstarted
  TEST  2 - sp_user_prime_bounds returns the live maxima once rows exist
  TEST  3 - sp_user_prime_assign stores @userPrime into Users.prime
  TEST  4 - it stores every @dayPrimes row, day_year and prime preserved exactly
  TEST  5 - it is idempotent: a second call changes nothing
  TEST  6 - an unknown @userid is ignored (FK_Users_Prime guard), no error and no rows
  TEST  7 - a day prime already in use is REJECTED (this is what the app's retry loop catches)
  TEST  8 - a Users.prime already in use is REJECTED
  TEST  9 - prime = 0 is allowed on many rows at once (UK_Users_prime is filtered on prime <> 0)
  TEST 10 - spSaveUser creates the account WITHOUT primes -- the app allocates straight after
*/
SET NOCOUNT ON;

DECLARE @tStart    datetime2;
DECLARE @ElapsedMs int;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Fixture values, far above anything the real sequences have reached, so they cannot collide
    -- with existing rows. They are deliberately NOT prime: the database does not check primality.
    DECLARE @base bigint = 900000000;

    DECLARE @uidA uniqueidentifier = NEWID();
    DELETE FROM dbo.Users WHERE email IN ('ut_prime_a@example.com', 'ut_prime_b@example.com', 'ut_prime_reg@example.com');

    -- ----------------------------------------------------------------
    -- TEST 1: sp_user_prime_bounds applies the seed floors when a sequence is unstarted
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @u1 bigint, @d1 bigint, @haveUsers int, @haveDays int;
    SELECT @haveUsers = COUNT(*) FROM dbo.Users WHERE prime > 0;
    SELECT @haveDays  = COUNT(*) FROM dbo.Users_Prime;
    EXEC dbo.sp_user_prime_bounds @u1 OUTPUT, @d1 OUTPUT;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    -- On a fresh build both sequences are empty and the floors apply; if a previous test file left
    -- rows behind, the bounds must at least never fall below the floors.
    IF @u1 >= 1000000 AND @d1 >= 97
       AND (@haveUsers > 0 OR @u1 = 1000000)
       AND (@haveDays  > 0 OR @d1 = 97)
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bounds honour the 1000000 / 97 seed floors';
    ELSE
        PRINT 'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: user bound=' + ISNULL(CAST(@u1 AS varchar), 'NULL')
              + ' day bound=' + ISNULL(CAST(@d1 AS varchar), 'NULL')
              + ' (existing primed users=' + CAST(@haveUsers AS varchar) + ', day rows=' + CAST(@haveDays AS varchar) + ')';

    -- ----------------------------------------------------------------
    -- Shared fixture: an account with its primes, written the way the app writes them
    -- ----------------------------------------------------------------
    INSERT INTO dbo.Users (id, userName, email, firstName, lastName, psw, question, answer, country)
        VALUES (@uidA, 'ut_prime_a', 'ut_prime_a@example.com', N'Ut', N'PrimeA', HASHBYTES('MD5', 'ut-prime-a'), 'dog', 0x0024, 'CA');

    DECLARE @primes dbo.UserPrimeList;
    ;WITH n (d) AS (
        SELECT TOP (365) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects
    )
    INSERT INTO @primes (day_year, prime) SELECT d, @base + d * 2 FROM n;

    DECLARE @userPrimeA bigint = @base + 100000;
    EXEC dbo.sp_user_prime_assign @uidA, @userPrimeA, @primes;

    -- ----------------------------------------------------------------
    -- TEST 2: sp_user_prime_bounds returns the live maxima once rows exist
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @u2 bigint, @d2 bigint;
    EXEC dbo.sp_user_prime_bounds @u2 OUTPUT, @d2 OUTPUT;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @u2 = @userPrimeA AND @d2 = @base + 730
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bounds track the current maxima of both sequences';
    ELSE
        PRINT 'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: user bound=' + ISNULL(CAST(@u2 AS varchar), 'NULL')
              + ' (expected ' + CAST(@userPrimeA AS varchar) + ') day bound=' + ISNULL(CAST(@d2 AS varchar), 'NULL')
              + ' (expected ' + CAST(@base + 730 AS varchar) + ')';

    -- ----------------------------------------------------------------
    -- TEST 3: sp_user_prime_assign stores @userPrime into Users.prime
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @storedUserPrime bigint;
    SELECT @storedUserPrime = prime FROM dbo.Users WHERE id = @uidA;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @storedUserPrime = @userPrimeA
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: Users.prime holds the value the caller supplied';
    ELSE
        PRINT 'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: expected ' + CAST(@userPrimeA AS varchar)
              + ' got ' + ISNULL(CAST(@storedUserPrime AS varchar), 'NULL');

    -- ----------------------------------------------------------------
    -- TEST 4: it stores every @dayPrimes row, day_year and prime preserved exactly
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @rows4 int, @wrong4 int, @minDay4 int, @maxDay4 int;
    SELECT @rows4 = COUNT(*), @minDay4 = MIN(day_year), @maxDay4 = MAX(day_year)
        FROM dbo.Users_Prime WHERE user_id = @uidA;
    SELECT @wrong4 = COUNT(*) FROM dbo.Users_Prime
        WHERE user_id = @uidA AND prime <> @base + day_year * 2;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @rows4 = 365 AND @minDay4 = 1 AND @maxDay4 = 365 AND @wrong4 = 0
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: all 365 day/prime pairs stored verbatim over day_year 1..365';
    ELSE
        PRINT 'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: rows=' + ISNULL(CAST(@rows4 AS varchar), 'NULL')
              + ' days=' + ISNULL(CAST(@minDay4 AS varchar), 'NULL') + '..' + ISNULL(CAST(@maxDay4 AS varchar), 'NULL')
              + ' mismatched=' + ISNULL(CAST(@wrong4 AS varchar), 'NULL');

    -- ----------------------------------------------------------------
    -- TEST 5: it is idempotent - a second call changes nothing
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @rows5 int, @prime5 bigint, @err5 varchar(200) = NULL;
    DECLARE @other dbo.UserPrimeList;
    INSERT INTO @other (day_year, prime) VALUES (1, @base + 999001), (2, @base + 999002);
    BEGIN TRY
        EXEC dbo.sp_user_prime_assign @uidA, 999999999, @other;
    END TRY
    BEGIN CATCH
        SET @err5 = LEFT(ERROR_MESSAGE(), 200);
    END CATCH;
    SELECT @rows5 = COUNT(*) FROM dbo.Users_Prime WHERE user_id = @uidA;
    SELECT @prime5 = prime FROM dbo.Users WHERE id = @uidA;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @err5 IS NULL AND @rows5 = 365 AND @prime5 = @userPrimeA
        PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: re-running the allocation left the prime and the 365 rows untouched';
    ELSE
        PRINT 'TEST 5 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: rows=' + ISNULL(CAST(@rows5 AS varchar), 'NULL')
              + ' prime=' + ISNULL(CAST(@prime5 AS varchar), 'NULL') + ' error=' + ISNULL(@err5, 'none');

    -- ----------------------------------------------------------------
    -- TEST 6: an unknown @userid is ignored (FK_Users_Prime guard), no error and no rows
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @ghost uniqueidentifier = NEWID();
    DECLARE @rows6 int, @err6 varchar(200) = NULL;
    DECLARE @ghostPrimes dbo.UserPrimeList;
    INSERT INTO @ghostPrimes (day_year, prime) VALUES (1, @base + 888001);
    BEGIN TRY
        EXEC dbo.sp_user_prime_assign @ghost, 888888888, @ghostPrimes;
    END TRY
    BEGIN CATCH
        SET @err6 = LEFT(ERROR_MESSAGE(), 200);
    END CATCH;
    SELECT @rows6 = COUNT(*) FROM dbo.Users_Prime WHERE user_id = @ghost;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @err6 IS NULL AND @rows6 = 0
        PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a userid with no Users row is skipped silently, no FK violation';
    ELSE
        PRINT 'TEST 6 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: rows=' + ISNULL(CAST(@rows6 AS varchar), 'NULL')
              + ' error=' + ISNULL(@err6, 'none');

    -- ----------------------------------------------------------------
    -- TEST 7: a day prime already in use is REJECTED
    --         This is the collision FishTracker.UserPrimeAllocator retries on; if the index ever
    --         stopped enforcing it, two accounts would silently share a prime.
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @uidB uniqueidentifier = NEWID();
    INSERT INTO dbo.Users (id, userName, email, firstName, lastName, psw, question, answer, country)
        VALUES (@uidB, 'ut_prime_b', 'ut_prime_b@example.com', N'Ut', N'PrimeB', HASHBYTES('MD5', 'ut-prime-b'), 'dog', 0x0024, 'CA');

    DECLARE @clash dbo.UserPrimeList;
    INSERT INTO @clash (day_year, prime) VALUES (1, @base + 2);   -- day 1 of user A already holds this
    DECLARE @err7 int = 0, @rows7 int;
    DECLARE @userPrimeB bigint = @base + 100001;   -- EXEC arguments must be variables, not expressions
    BEGIN TRY
        EXEC dbo.sp_user_prime_assign @uidB, @userPrimeB, @clash;
    END TRY
    BEGIN CATCH
        SET @err7 = ERROR_NUMBER();
    END CATCH;
    SELECT @rows7 = COUNT(*) FROM dbo.Users_Prime WHERE user_id = @uidB;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @err7 IN (2601, 2627) AND @rows7 = 0
        PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a duplicate day prime raises ' + CAST(@err7 AS varchar) + ' and writes nothing';
    ELSE
        PRINT 'TEST 7 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: error number=' + CAST(@err7 AS varchar)
              + ' (expected 2601/2627) rows written=' + ISNULL(CAST(@rows7 AS varchar), 'NULL');

    -- ----------------------------------------------------------------
    -- TEST 8: a Users.prime already in use is REJECTED
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @err8 int = 0, @prime8 bigint;
    DECLARE @fresh dbo.UserPrimeList;
    INSERT INTO @fresh (day_year, prime) VALUES (1, @base + 777001);
    BEGIN TRY
        EXEC dbo.sp_user_prime_assign @uidB, @userPrimeA, @fresh;   -- @userPrimeA belongs to user A
    END TRY
    BEGIN CATCH
        SET @err8 = ERROR_NUMBER();
    END CATCH;
    SELECT @prime8 = prime FROM dbo.Users WHERE id = @uidB;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @err8 IN (2601, 2627) AND ISNULL(@prime8, -1) = 0
        PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a duplicate Users.prime raises ' + CAST(@err8 AS varchar) + ' and the account keeps prime 0';
    ELSE
        PRINT 'TEST 8 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: error number=' + CAST(@err8 AS varchar)
              + ' (expected 2601/2627) prime=' + ISNULL(CAST(@prime8 AS varchar), 'NULL');

    -- ----------------------------------------------------------------
    -- TEST 9: prime = 0 is allowed on many rows at once (UK_Users_prime is filtered)
    --         Registration now commits the account before the app allocates, so several rows can
    --         legitimately sit at 0 simultaneously.
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @uidC uniqueidentifier = NEWID(), @uidD uniqueidentifier = NEWID();
    DECLARE @err9 varchar(200) = NULL, @zeros int;
    BEGIN TRY
        INSERT INTO dbo.Users (id, userName, email, firstName, lastName, psw, question, answer, country)
            VALUES (@uidC, 'ut_prime_c', 'ut_prime_c@example.com', N'Ut', N'PrimeC', HASHBYTES('MD5', 'c'), 'dog', 0x0024, 'CA'),
                   (@uidD, 'ut_prime_d', 'ut_prime_d@example.com', N'Ut', N'PrimeD', HASHBYTES('MD5', 'd'), 'dog', 0x0024, 'CA');
    END TRY
    BEGIN CATCH
        SET @err9 = LEFT(ERROR_MESSAGE(), 200);
    END CATCH;
    SELECT @zeros = COUNT(*) FROM dbo.Users WHERE id IN (@uidB, @uidC, @uidD) AND prime = 0;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @err9 IS NULL AND @zeros = 3
        PRINT 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: three accounts hold prime 0 at once - the filtered index permits it';
    ELSE
        PRINT 'TEST 9 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: rows at zero=' + ISNULL(CAST(@zeros AS varchar), 'NULL')
              + ' (expected 3) error=' + ISNULL(@err9, 'none');

    -- ----------------------------------------------------------------
    -- TEST 10: spSaveUser creates the account WITHOUT primes
    --          The app allocates immediately afterwards; this pins the procedure's new contract so
    --          nobody quietly puts generation back into the database.
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @mail10 varchar(128) = 'ut_prime_reg@example.com';
    EXEC dbo.spSaveUser '127.0.0.1', 'unit-test', '127.0.0.1', 'localhost', 'ut_prime_reg', @mail10,
                        'CA', 'N2M5L3', N'Ut', N'Register', 'Passw0rd!';
    DECLARE @uid10 uniqueidentifier, @prime10 bigint, @rows10 int;
    SELECT @uid10 = id, @prime10 = prime FROM dbo.Users WHERE email = @mail10;
    SELECT @rows10 = COUNT(*) FROM dbo.Users_Prime WHERE user_id = @uid10;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @uid10 IS NOT NULL AND @prime10 = 0 AND @rows10 = 0
        PRINT 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spSaveUser registers the account and leaves prime allocation to the app';
    ELSE
        PRINT 'TEST 10 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: userId=' + ISNULL(CAST(@uid10 AS varchar(40)), 'NULL')
              + ' prime=' + ISNULL(CAST(@prime10 AS varchar), 'NULL') + ' day rows=' + ISNULL(CAST(@rows10 AS varchar), 'NULL');

    ROLLBACK TRANSACTION;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'EXCEPTION during test: ' + ERROR_MESSAGE()
        + '  (proc=' + ISNULL(ERROR_PROCEDURE(), 'n/a')
        + ', line='  + CAST(ERROR_LINE() AS varchar) + ')';
END CATCH;
