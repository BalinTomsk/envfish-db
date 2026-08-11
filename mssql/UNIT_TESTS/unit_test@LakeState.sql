SET QUOTED_IDENTIFIER ON
GO
PRINT 'Unit tests for Lake_State unit/range CHECK constraints'
PRINT '-----------------------------------------------------------------------------------------------------------------------------'
-- Verifies the CK_Lake_State_* range constraints: valid values and NULLs are
-- accepted; out-of-range values are rejected. Each test runs in its own
-- transaction and rolls back, so the DB is unchanged when finished.
-- A rejected INSERT must be caught (never SELECTed) so its error does not leak
-- into cleaned.txt and look like a failure.
-- prep lake_id used by every test (FK target). Rolled back with each test.
----------------------------------------------------------------------------------------------------------

PRINT '-----------------------------------------------------------------------------------------------------------------------------'
----------------------------------------------------------------------------------------------------------
BEGIN TRAN TestLS1
DECLARE @test_name SYSNAME = 'TestLS1 [Lake_State] valid in-range row is accepted';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @result1 int = -1;   -- initialised before TRY so it still has a value if CATCH fires

BEGIN TRY  SET NOCOUNT ON;
    SET @tStart = SYSUTCDATETIME();
    -- 1. prepare data for unit test
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES ('f1f1f1f1-0000-0000-0000-000000000001', 2, N'River', 'ABCDE');

    -- 2. execute unit test: every column within its allowed range
    INSERT INTO Lake_State ([month], lake_id, PH, Phosphorus, TDS, Conductivity, Alkalinity, Hardness, Sodium
        , Chloride, Bicarbonate, Transparency, Oxygen, Salinity, Clarity, Velocity, water_degree, air_degree)
        VALUES (6, 'f1f1f1f1-0000-0000-0000-000000000001', 7.2, 0.05, 596, 955, 449, 372, 90
        , 11, 482, 1.5, 9.1, 6, 1.2, 0.8, 18, -5);

    SET @result1 = (SELECT COUNT(*) FROM Lake_State WHERE lake_id = 'f1f1f1f1-0000-0000-0000-000000000001' AND [month] = 6);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
               @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @result1 = 1
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: row with every measurement in range is accepted'
    ELSE
       RAISERROR ('TEST 1 FAIL [%dms]: valid in-range row must be accepted, got %d rows', 16, -1, @ElapsedMs, @result1)
IF XACT_STATE() <> 0 ROLLBACK TRAN TestLS1
GO

----------------------------------------------------------------------------------------------------------
BEGIN TRAN TestLS2
DECLARE @test_name SYSNAME = 'TestLS2 [Lake_State] water_degree > 100 is rejected';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @threw int = 0;

SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();
INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES ('f1f1f1f1-0000-0000-0000-000000000001', 2, N'River', 'ABCDE');
BEGIN TRY
    INSERT INTO Lake_State ([month], lake_id, water_degree) VALUES (1, 'f1f1f1f1-0000-0000-0000-000000000001', 150);
END TRY
BEGIN CATCH
    SET @threw = 1;   -- swallow the expected CHECK violation (do not SELECT it)
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @threw = 1
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: water_degree = 150 is rejected by the range CHECK'
    ELSE
       RAISERROR ('TEST 2 FAIL [%dms]: water_degree = 150 must be rejected', 16, -1, @ElapsedMs)
IF XACT_STATE() <> 0 ROLLBACK TRAN TestLS2
GO

----------------------------------------------------------------------------------------------------------
BEGIN TRAN TestLS3
DECLARE @test_name SYSNAME = 'TestLS3 [Lake_State] PH outside 0..14 is rejected';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @threw int = 0;

SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();
INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES ('f1f1f1f1-0000-0000-0000-000000000001', 2, N'River', 'ABCDE');
BEGIN TRY
    INSERT INTO Lake_State ([month], lake_id, PH) VALUES (1, 'f1f1f1f1-0000-0000-0000-000000000001', 20);
END TRY
BEGIN CATCH
    SET @threw = 1;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @threw = 1
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: PH = 20 is rejected by the 0..14 range CHECK'
    ELSE
       RAISERROR ('TEST 3 FAIL [%dms]: PH = 20 must be rejected', 16, -1, @ElapsedMs)
IF XACT_STATE() <> 0 ROLLBACK TRAN TestLS3
GO

----------------------------------------------------------------------------------------------------------
BEGIN TRAN TestLS4
DECLARE @test_name SYSNAME = 'TestLS4 [Lake_State] NULL measurements are allowed';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @result1 int = -1;

BEGIN TRY  SET NOCOUNT ON;
    SET @tStart = SYSUTCDATETIME();
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES ('f1f1f1f1-0000-0000-0000-000000000001', 2, N'River', 'ABCDE');

    -- only the required key columns; all measurements left NULL
    INSERT INTO Lake_State ([month], lake_id) VALUES (3, 'f1f1f1f1-0000-0000-0000-000000000001');

    SET @result1 = (SELECT COUNT(*) FROM Lake_State WHERE lake_id = 'f1f1f1f1-0000-0000-0000-000000000001' AND [month] = 3);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
               @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @result1 = 1
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: row with all measurements NULL is accepted'
    ELSE
       RAISERROR ('TEST 4 FAIL [%dms]: NULL measurements must be accepted, got %d rows', 16, -1, @ElapsedMs, @result1)
IF XACT_STATE() <> 0 ROLLBACK TRAN TestLS4
GO

----------------------------------------------------------------------------------------------------------
BEGIN TRAN TestLS5
DECLARE @test_name SYSNAME = 'TestLS5 [Lake_State] negative concentration (Oxygen) is rejected';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @threw int = 0;

SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();
INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES ('f1f1f1f1-0000-0000-0000-000000000001', 2, N'River', 'ABCDE');
BEGIN TRY
    INSERT INTO Lake_State ([month], lake_id, Oxygen) VALUES (1, 'f1f1f1f1-0000-0000-0000-000000000001', -5);
END TRY
BEGIN CATCH
    SET @threw = 1;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @threw = 1
        PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: negative concentration Oxygen = -5 is rejected'
    ELSE
       RAISERROR ('TEST 5 FAIL [%dms]: Oxygen = -5 must be rejected', 16, -1, @ElapsedMs)
IF XACT_STATE() <> 0 ROLLBACK TRAN TestLS5
GO

----------------------------------------------------------------------------------------------------------
BEGIN TRAN TestLS6
DECLARE @test_name SYSNAME = 'TestLS6 [Lake_State] sub-zero air_degree is allowed, extreme is rejected';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @threw int = 0;
DECLARE @result1 int = -1;

BEGIN TRY  SET NOCOUNT ON;
    SET @tStart = SYSUTCDATETIME();
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES ('f1f1f1f1-0000-0000-0000-000000000001', 2, N'River', 'ABCDE');

    -- valid sub-zero air temperature accepted
    INSERT INTO Lake_State ([month], lake_id, air_degree) VALUES (1, 'f1f1f1f1-0000-0000-0000-000000000001', -40);
    SET @result1 = (SELECT COUNT(*) FROM Lake_State WHERE lake_id = 'f1f1f1f1-0000-0000-0000-000000000001' AND [month] = 1);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
               @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH

-- impossibly cold air temperature rejected
BEGIN TRY
    INSERT INTO Lake_State ([month], lake_id, air_degree) VALUES (2, 'f1f1f1f1-0000-0000-0000-000000000001', -300);
END TRY
BEGIN CATCH
    SET @threw = 1;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

    IF @result1 = 1 AND @threw = 1
        PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: air_degree = -40 is accepted while -300 is rejected'
    ELSE
       RAISERROR ('TEST 6 FAIL [%dms]: air_degree -40 must be accepted (got %d rows) and -300 rejected (threw=%d)', 16, -1, @ElapsedMs, @result1, @threw)
IF XACT_STATE() <> 0 ROLLBACK TRAN TestLS6
GO
