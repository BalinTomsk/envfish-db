SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the dbo.UScode registration inside dbo.sp_push_us_water_data
  (waterservice WaterDataRepository - the USGS series push; the proc records each measurement
  name/unit it is handed, then shreds the readings into dbo.WaterData).

  The check was written as
        IF NOT EXISTS (SELECT * FROM UScode WHERE name like @name AND unit LIKE @unit)
  which fails as a catalogue lookup in three separate ways, all of them exercised here:

  TEST 1 - USGS names routinely contain [ ] - e.g. 'Total nitrogen [nitrate + nitrite + ...]'.
           Under LIKE that bracket group is a CHARACTER CLASS matching ONE character, so the row
           can never match itself and every push inserts another copy. This is the dominant cause
           of the duplication measured on production: 9,694 rows for 279 distinct pairs, and
           `WHERE name LIKE @name` returned 0 rows for a name that `=` matched 5,409 times.
  TEST 2 - unit LIKE NULL is UNKNOWN, never true, so any measurement with no unit re-inserts on
           every push (613 such rows on production).
  TEST 3 - the reverse failure: _ and % in an incoming name match OTHER stored names, so a
           genuinely new measurement can be silently skipped and never registered.

  Uses real tables: dbo.Lake, dbo.WaterStation, dbo.WaterData, dbo.UScode.
  Each test is its own named transaction, rolled back at the end of its own GO batch.
*/
PRINT 'Unit tests for sp_push_us_water_data UScode registration'
GO
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: a measurement name containing a [ ] group registers exactly once, however often
--         the same series is pushed
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01BracketName
    DECLARE @test_name sysname = N'Test01BracketName [sp_push_us_water_data] : name with [ ] registers once'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId1 uniqueidentifier = NEWID();
DECLARE @Mli1 varchar(64) = 'UT_USCODE_01';
DECLARE @Name1 sysname = N'UT Total nitrogen [nitrate + nitrite + ammonia + organic-N]';
DECLARE @rows1 int = -1, @err1 nvarchar(2048), @msg1 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId1, 2, N'UT USCODE River 1');
INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli1, 43.51, -80.21, 'US', N'unit-test station USCODE 1', 2, N'UT USCODE Station 1', N'', 970801, @LakeId1, N'UT USCODE River 1', 1);

-- 2. execute unit test : the collector pushes the same series twice, as it does every cycle

EXEC dbo.sp_push_us_water_data @mli = @Mli1, @state = N'NY', @name = @Name1, @unit = 'mg/l',
     @xmldoc = N'<root><a d="2026-08-11" v="1.10" /></root>';
EXEC dbo.sp_push_us_water_data @mli = @Mli1, @state = N'NY', @name = @Name1, @unit = 'mg/l',
     @xmldoc = N'<root><a d="2026-08-11" v="1.20" /></root>';

SELECT @rows1 = COUNT(*) FROM dbo.UScode WHERE name = @Name1;

END TRY
BEGIN CATCH
    SET @err1 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err1 IS NOT NULL
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: sp_push_us_water_data raised: ' + @err1;
    RAISERROR (@msg1, 16, -1)
END
ELSE IF @rows1 = 1
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a name containing a [ ] group registered exactly once across two pushes'
ELSE
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 UScode row for the bracketed name, got '
              + ISNULL(CAST(@rows1 AS nvarchar(10)), N'NULL');
    RAISERROR (@msg1, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01BracketName
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: a measurement with NO unit registers exactly once
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02NullUnit
    DECLARE @test_name sysname = N'Test02NullUnit [sp_push_us_water_data] : measurement with NULL unit registers once'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId2 uniqueidentifier = NEWID();
DECLARE @Mli2 varchar(64) = 'UT_USCODE_02';
DECLARE @Name2 sysname = N'UT unitless measurement';
DECLARE @rows2 int = -1, @err2 nvarchar(2048), @msg2 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId2, 2, N'UT USCODE River 2');
INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli2, 43.52, -80.22, 'US', N'unit-test station USCODE 2', 2, N'UT USCODE Station 2', N'', 970802, @LakeId2, N'UT USCODE River 2', 1);

-- 2. execute unit test : same series twice, this time with no unit at all

EXEC dbo.sp_push_us_water_data @mli = @Mli2, @state = N'NY', @name = @Name2, @unit = NULL,
     @xmldoc = N'<root><a d="2026-08-11" v="2.10" /></root>';
EXEC dbo.sp_push_us_water_data @mli = @Mli2, @state = N'NY', @name = @Name2, @unit = NULL,
     @xmldoc = N'<root><a d="2026-08-11" v="2.20" /></root>';

SELECT @rows2 = COUNT(*) FROM dbo.UScode WHERE name = @Name2;

END TRY
BEGIN CATCH
    SET @err2 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err2 IS NOT NULL
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: sp_push_us_water_data raised: ' + @err2;
    RAISERROR (@msg2, 16, -1)
END
ELSE IF @rows2 = 1
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a measurement with no unit registered exactly once across two pushes'
ELSE
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 UScode row for the unitless measurement, got '
              + ISNULL(CAST(@rows2 AS nvarchar(10)), N'NULL');
    RAISERROR (@msg2, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02NullUnit
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: the opposite failure - a new measurement whose name differs from a stored one only
--         where _ would wildcard must still be registered, not swallowed by the match
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03WildcardSwallow
    DECLARE @test_name sysname = N'Test03WildcardSwallow [sp_push_us_water_data] : near-miss name still registered'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId3 uniqueidentifier = NEWID();
DECLARE @Mli3 varchar(64) = 'UT_USCODE_03';
DECLARE @NameA3 sysname = N'UT gageXheight';   -- stored first
DECLARE @NameB3 sysname = N'UT gage_height';   -- _ matches the X above under LIKE
DECLARE @rowsA3 int = -1, @rowsB3 int = -1, @err3 nvarchar(2048), @msg3 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId3, 2, N'UT USCODE River 3');
INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli3, 43.53, -80.23, 'US', N'unit-test station USCODE 3', 2, N'UT USCODE Station 3', N'', 970803, @LakeId3, N'UT USCODE River 3', 1);

-- 2. execute unit test : two genuinely different measurement names, same unit

EXEC dbo.sp_push_us_water_data @mli = @Mli3, @state = N'NY', @name = @NameA3, @unit = 'ft',
     @xmldoc = N'<root><a d="2026-08-11" v="3.10" /></root>';
EXEC dbo.sp_push_us_water_data @mli = @Mli3, @state = N'NY', @name = @NameB3, @unit = 'ft',
     @xmldoc = N'<root><a d="2026-08-11" v="3.20" /></root>';

SELECT @rowsA3 = COUNT(*) FROM dbo.UScode WHERE name = @NameA3;
SELECT @rowsB3 = COUNT(*) FROM dbo.UScode WHERE name = @NameB3;

END TRY
BEGIN CATCH
    SET @err3 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err3 IS NOT NULL
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: sp_push_us_water_data raised: ' + @err3;
    RAISERROR (@msg3, 16, -1)
END
ELSE IF @rowsA3 = 1 AND @rowsB3 = 1
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a name differing only where _ would wildcard was registered in its own right'
ELSE
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 row for each name, got '
              + ISNULL(CAST(@rowsA3 AS nvarchar(10)), N'NULL') + N' and ' + ISNULL(CAST(@rowsB3 AS nvarchar(10)), N'NULL');
    RAISERROR (@msg3, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03WildcardSwallow
GO
-- ---------------------------------------------------------------------------------------
-- TEST 4: UK_UScode_name_unit makes a duplicate pair impossible at the table, so a future
--         caller cannot reintroduce the duplication however it writes. Both the ordinary
--         case and the NULL-unit case are checked - SQL Server treats NULLs as equal in a
--         UNIQUE constraint, which is the behaviour this relies on.
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test04UniqueConstraint
    DECLARE @test_name sysname = N'Test04UniqueConstraint [UScode] : duplicate pair rejected by UK_UScode_name_unit'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Name4 sysname = N'UT constrained measurement';
DECLARE @dupBlocked int = 0, @nullDupBlocked int = 0, @distinctOk int = 0;
DECLARE @msg4 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

INSERT INTO dbo.UScode (name, unit) VALUES (@Name4, 'ft');
INSERT INTO dbo.UScode (name, unit) VALUES (@Name4, NULL);

-- 2. execute unit test : each duplicate attempt must raise, a different unit must not

BEGIN TRY  INSERT INTO dbo.UScode (name, unit) VALUES (@Name4, 'ft');   END TRY
BEGIN CATCH SET @dupBlocked = 1;                                        END CATCH

BEGIN TRY  INSERT INTO dbo.UScode (name, unit) VALUES (@Name4, NULL);  END TRY
BEGIN CATCH SET @nullDupBlocked = 1;                                    END CATCH

BEGIN TRY  INSERT INTO dbo.UScode (name, unit) VALUES (@Name4, 'm');
           SET @distinctOk = 1;                                         END TRY
BEGIN CATCH SET @distinctOk = 0;                                        END CATCH

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @dupBlocked = 1 AND @nullDupBlocked = 1 AND @distinctOk = 1
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: duplicate pairs rejected (unit and NULL unit), a distinct unit still accepted'
ELSE
BEGIN
    SET @msg4 = N'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected dup blocked / NULL dup blocked / distinct accepted = 1/1/1, got '
              + CAST(@dupBlocked AS nvarchar(2)) + N'/' + CAST(@nullDupBlocked AS nvarchar(2)) + N'/' + CAST(@distinctOk AS nvarchar(2));
    RAISERROR (@msg4, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test04UniqueConstraint
GO
