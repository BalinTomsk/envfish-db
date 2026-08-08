print 'Unit tests for weather_gov_station (Weather.gov NWS station resolution cache)'
GO
------------------------------------------------------------------------------------------------
-- dbo.weather_gov_station caches "which NWS station serves this water gauge".
--
-- WaterStation.MLI is a WATER gauge identifier (USGS site number for US), never an NWS call sign,
-- so api.weather.gov/stations/{MLI} 404s for every US row. The weather service resolves the
-- station's COORDINATE to a nearby NWS station instead, and caches the answer here so it does not
-- spend a second API call per station on every cycle.
--
-- Called by: WeatherService (C#) -> Data/WeatherGovStationRepository -> dbo.fn_weather_gov_station
--            (read) and dbo.sp_save_weather_gov_station (write), used by
--            Sources/WeatherGovStationResolver.
------------------------------------------------------------------------------------------------

BEGIN TRAN Test01WeatherGovStationUnknown
    declare @test_name sysname = N'Test01 [fn_weather_gov_station] : unknown mli returns no row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rows int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare: deliberately nothing cached for this mli

-- 2. execute
SELECT @rows = COUNT(*) FROM dbo.fn_weather_gov_station('UNIT-TEST-NEVER-RESOLVED');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify: no row at all means "never asked", which is what makes the resolver call the API
IF @rows IS NULL OR @rows <> 0
   RAISERROR ('TEST 1 FAIL [%dms]: an unresolved mli must return no rows', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unresolved mli returns no rows'

ROLLBACK TRAN Test01WeatherGovStationUnknown
GO

BEGIN TRAN Test02WeatherGovStationSave
    declare @test_name sysname = N'Test02 [sp_save_weather_gov_station] : saves and reads back'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @station varchar(16), @lat float, @lon float;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare + 2. execute
EXEC dbo.sp_save_weather_gov_station @mli = '07263650', @station_id = 'KPBF',
                                     @lat = 34.1731, @lon = -91.9354;

SELECT @station = station_id, @lat = lat, @lon = lon
FROM dbo.fn_weather_gov_station('07263650');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify
IF @station IS NULL OR @station <> 'KPBF' OR @lat IS NULL OR ABS(@lat - 34.1731) > 0.00001
   RAISERROR ('TEST 2 FAIL [%dms]: saved station id and coordinate must read back', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: resolved station saved and read back'

ROLLBACK TRAN Test02WeatherGovStationSave
GO

BEGIN TRAN Test03WeatherGovStationUpsert
    declare @test_name sysname = N'Test03 [sp_save_weather_gov_station] : re-save replaces, never duplicates'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rows int, @station varchar(16);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare: an existing cached answer
EXEC dbo.sp_save_weather_gov_station @mli = '05398000', @station_id = 'KAUW',
                                     @lat = 44.8868, @lon = -89.6357;

-- 2. execute: the station moved / a better one was found
EXEC dbo.sp_save_weather_gov_station @mli = '05398000', @station_id = 'KCWA',
                                     @lat = 44.8868, @lon = -89.6357;

SELECT @rows = COUNT(*) FROM dbo.fn_weather_gov_station('05398000');
SELECT @station = station_id FROM dbo.fn_weather_gov_station('05398000');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify: one row per mli, holding the newest answer
IF @rows IS NULL OR @rows <> 1 OR @station IS NULL OR @station <> 'KCWA'
   RAISERROR ('TEST 3 FAIL [%dms]: re-saving must replace the row, not add one', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: re-save replaces the cached station'

ROLLBACK TRAN Test03WeatherGovStationUpsert
GO

BEGIN TRAN Test04WeatherGovStationNegCache
    declare @test_name sysname = N'Test04 [sp_save_weather_gov_station] : NULL station is a negative cache'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rows int, @station varchar(16);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare + 2. execute: the API was asked and answered "no station near here".
--    That must be remembered, or every cycle re-asks for a point that will never resolve.
EXEC dbo.sp_save_weather_gov_station @mli = 'UNIT-TEST-NO-STATION', @station_id = NULL,
                                     @lat = 19.5, @lon = -155.5;

SELECT @rows = COUNT(*) FROM dbo.fn_weather_gov_station('UNIT-TEST-NO-STATION');
SELECT @station = station_id FROM dbo.fn_weather_gov_station('UNIT-TEST-NO-STATION');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. verify: a row EXISTS (so we know we asked) but carries no station id
IF @rows IS NULL OR @rows <> 1 OR @station IS NOT NULL
   RAISERROR ('TEST 4 FAIL [%dms]: a resolved-but-empty answer must be a row with NULL station_id', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: negative answer cached as NULL station_id'

ROLLBACK TRAN Test04WeatherGovStationNegCache
GO
