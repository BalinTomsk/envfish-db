print 'Unit tests for weather_station_coverage (which providers can serve which gauge)'
GO
------------------------------------------------------------------------------------------------
-- dbo.weather_station_coverage records, per (gauge, provider), whether that provider has any data
-- for that point.
--
-- Not every provider can answer every coordinate. Weather Canada's SWOB is an OBSERVATION network
-- with real geographic gaps: measured 2026-08-08, a 0.5 degree (~55 km) search box still found no
-- station for ~16% of Canadian gauges. Gridded providers (Open-Meteo, Visual Crossing, Google) can
-- answer any coordinate. Flagging the gaps lets a different worker pick those gauges up instead of
-- them silently skipping every cycle forever.
--
-- Called by: WeatherService (C#) -> Data/WeatherStationCoverageRepository ->
--            dbo.sp_save_weather_station_coverage (write, from the station processors) and
--            dbo.fn_weather_uncovered_stations (read, by the fallback worker).
------------------------------------------------------------------------------------------------

BEGIN TRAN Test01CoverageUnknown
    declare @test_name sysname = N'Test01 [fn_weather_uncovered_stations] : unchecked gauge is not listed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1./2. nothing recorded for this provider at all
SELECT @rows = COUNT(*) FROM dbo.fn_weather_uncovered_stations('unit-test-provider');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. a gauge nobody has checked yet is NOT a known gap -- only a recorded miss counts
IF @rows IS NULL OR @rows <> 0
   RAISERROR ('TEST 1 FAIL [%dms]: an unchecked provider must list no uncovered stations', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unchecked provider lists nothing'

ROLLBACK TRAN Test01CoverageUnknown
GO

BEGIN TRAN Test02CoverageMissFlagged
    declare @test_name sysname = N'Test02 [sp_save_weather_station_coverage] : a miss is listed for the fallback worker'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @mli varchar(64), @lat float, @lon float, @rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. a gauge to flag
-- A gauge of our own: the freshly-built test database carries no WaterStation rows, and the
-- uncovered-stations function joins to it for the coordinate. Rolled back with the transaction.
SET @mli = 'UT-COVERAGE-CA-1';
INSERT dbo.WaterStation (MLI, id, lat, lon, country, state, locDesc, locType, locName, sid, lakeName, county, stamp, supported)
VALUES (@mli, NEWID(), 52.1234, -106.6543, 'CA', 'SK', 'unit test gauge', 2, 'UT gauge', 999001, 'UT lake', 'UT county', GETUTCDATE(), 1);

-- 2. the Weather Canada worker found no SWOB site near it
EXEC dbo.sp_save_weather_station_coverage @mli = @mli, @provider = 'weather-canada', @covered = 0;

SELECT @rows = COUNT(*), @lat = MIN(lat), @lon = MIN(lon)
FROM dbo.fn_weather_uncovered_stations('weather-canada')
WHERE mli = @mli;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. the fallback worker needs the coordinate too, or it cannot fetch anything
IF @rows IS NULL OR @rows <> 1 OR @lat IS NULL OR @lon IS NULL
   RAISERROR ('TEST 2 FAIL [%dms]: a recorded miss must be listed with its coordinate', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: uncovered gauge listed with coordinate'

ROLLBACK TRAN Test02CoverageMissFlagged
GO

BEGIN TRAN Test03CoverageHitNotListed
    declare @test_name sysname = N'Test03 [sp_save_weather_station_coverage] : a covered gauge is not listed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @mli varchar(64), @rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- A gauge of our own: the freshly-built test database carries no WaterStation rows, and the
-- uncovered-stations function joins to it for the coordinate. Rolled back with the transaction.
SET @mli = 'UT-COVERAGE-CA-1';
INSERT dbo.WaterStation (MLI, id, lat, lon, country, state, locDesc, locType, locName, sid, lakeName, county, stamp, supported)
VALUES (@mli, NEWID(), 52.1234, -106.6543, 'CA', 'SK', 'unit test gauge', 2, 'UT gauge', 999001, 'UT lake', 'UT county', GETUTCDATE(), 1);

-- 1./2. recorded as covered
EXEC dbo.sp_save_weather_station_coverage @mli = @mli, @provider = 'weather-canada', @covered = 1;

SELECT @rows = COUNT(*) FROM dbo.fn_weather_uncovered_stations('weather-canada') WHERE mli = @mli;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @rows IS NULL OR @rows <> 0
   RAISERROR ('TEST 3 FAIL [%dms]: a covered gauge must not be listed as a gap', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: covered gauge is not listed'

ROLLBACK TRAN Test03CoverageHitNotListed
GO

BEGIN TRAN Test04CoverageRecovers
    declare @test_name sysname = N'Test04 [sp_save_weather_station_coverage] : a gap that later resolves is cleared'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @mli varchar(64), @rows int, @dupes int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- A gauge of our own: the freshly-built test database carries no WaterStation rows, and the
-- uncovered-stations function joins to it for the coordinate. Rolled back with the transaction.
SET @mli = 'UT-COVERAGE-CA-1';
INSERT dbo.WaterStation (MLI, id, lat, lon, country, state, locDesc, locType, locName, sid, lakeName, county, stamp, supported)
VALUES (@mli, NEWID(), 52.1234, -106.6543, 'CA', 'SK', 'unit test gauge', 2, 'UT gauge', 999001, 'UT lake', 'UT county', GETUTCDATE(), 1);

-- 1. flagged as a gap
EXEC dbo.sp_save_weather_station_coverage @mli = @mli, @provider = 'weather-canada', @covered = 0;
-- 2. a later cycle (e.g. after widening the search box) finds data
EXEC dbo.sp_save_weather_station_coverage @mli = @mli, @provider = 'weather-canada', @covered = 1;

SELECT @rows = COUNT(*) FROM dbo.fn_weather_uncovered_stations('weather-canada') WHERE mli = @mli;
SELECT @dupes = COUNT(*) FROM dbo.fn_weather_station_coverage(@mli, 'weather-canada');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. the flag is a current fact, not an append-only log: one row, and the gap is gone
IF @rows IS NULL OR @rows <> 0 OR @dupes IS NULL OR @dupes <> 1
   RAISERROR ('TEST 4 FAIL [%dms]: re-checking must update the one row and clear the gap', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a resolved gap is cleared, one row kept'

ROLLBACK TRAN Test04CoverageRecovers
GO

BEGIN TRAN Test05CoverageIsPerProvider
    declare @test_name sysname = N'Test05 [fn_weather_uncovered_stations] : providers do not share coverage'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @mli varchar(64), @canada int, @open int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- A gauge of our own: the freshly-built test database carries no WaterStation rows, and the
-- uncovered-stations function joins to it for the coordinate. Rolled back with the transaction.
SET @mli = 'UT-COVERAGE-CA-1';
INSERT dbo.WaterStation (MLI, id, lat, lon, country, state, locDesc, locType, locName, sid, lakeName, county, stamp, supported)
VALUES (@mli, NEWID(), 52.1234, -106.6543, 'CA', 'SK', 'unit test gauge', 2, 'UT gauge', 999001, 'UT lake', 'UT county', GETUTCDATE(), 1);

-- 1./2. SWOB has a gap here; the gridded provider does not
EXEC dbo.sp_save_weather_station_coverage @mli = @mli, @provider = 'weather-canada', @covered = 0;
EXEC dbo.sp_save_weather_station_coverage @mli = @mli, @provider = 'open',           @covered = 1;

SELECT @canada = COUNT(*) FROM dbo.fn_weather_uncovered_stations('weather-canada') WHERE mli = @mli;
SELECT @open   = COUNT(*) FROM dbo.fn_weather_uncovered_stations('open')           WHERE mli = @mli;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. the whole point: the same gauge is a gap for one provider and fine for another
IF @canada IS NULL OR @canada <> 1 OR @open IS NULL OR @open <> 0
   RAISERROR ('TEST 5 FAIL [%dms]: coverage must be tracked per provider, not per gauge', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: coverage is per provider'

ROLLBACK TRAN Test05CoverageIsPerProvider
GO
