SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_station_weather_today (today's weather at ONE monitoring station;
  caller: FishTracker Resources/wfRiverViewWeather.aspx.cs LoadStationWeather -- the weather
  table under each station card on the water-body Weather tab).
  Uses real tables dbo.Lake / dbo.WaterStation / dbo.weather_Forecast (weather_Forecast.link
  has FK_weather_Forecast_stattion -> WaterStation.id, so stations are inserted with explicit ids).
  Each test runs in its own named transaction, rolled back at the end of its own GO batch -
  database state fully restored.

  TEST 1 - Station with a row for today -> exactly one row, every field mapped correctly
  TEST 2 - Station whose only rows are yesterday/tomorrow -> ZERO rows (never zero-filled)
  TEST 3 - No cross-station leak; unknown sid -> zero rows
  TEST 4 - Two collection times on the same day -> the latest tm wins
*/

-- ===================================================================================
-- TEST 1: a station that has today's forecast returns it, with the fields mapped right
-- ===================================================================================
BEGIN TRAN Test01StationWeatherToday
    DECLARE @test_name sysname = N'Test01StationWeatherToday [fn_station_weather_today] : today row returned';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @Match int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake1 uniqueidentifier = NEWID();
DECLARE @St1   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'UT SWT Lake 1');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St1, N'UT_SWT_1', 45.10, -75.10, 'CA', N'unit-test station', 2, N'UT SWT Station 1', N'', 990101, @Lake1, N'UT SWT Lake 1', 1);

INSERT INTO dbo.weather_Forecast
    (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight, tmDay, air_temperature, humidity,
     wind_max_speed, wind_direction, wind_degree, pop, rain_today, shortText, longText, icon, weather_code)
VALUES
    (@St1, N'UT_SWT_1', CAST(GETDATE() AS DATE), '23:00:00', 22.7, 13.9, 0, 0, 19.4, 17, 99,
     14.4, N'NE', 45, 96, 3, N'Rain showers', N'Rain showers throughout the day', N'om_80.png', 80);

SELECT @Cnt = COUNT(*) FROM dbo.fn_station_weather_today(990101);

SELECT @Match = COUNT(*) FROM dbo.fn_station_weather_today(990101)
WHERE dt = CAST(GETDATE() AS DATE)
  AND conditions      = N'Rain showers'
  AND conditions_long = N'Rain showers throughout the day'
  AND icon            = N'om_80.png'
  AND air_temp        = 17
  AND temp_high       = 22.7
  AND temp_low        = 13.9
  AND humidity        = 99
  AND wind_speed      = 14.4
  AND wind_direction  = N'NE'
  AND wind_degree     = 45
  AND precip_chance   = 96
  AND precip_amount   = 3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 1 AND @Match = 1
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: today''s weather row returned with all fields mapped';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected 1 row fully matching, got rows=%d match=%d', 16, -1, @ElapsedMs, @Cnt, @Match);

ROLLBACK TRAN Test01StationWeatherToday
GO

-- ===================================================================================
-- TEST 2: only past/future rows -> ZERO rows. This is the contract the page depends on:
--         "no data" must be distinguishable from a real reading (contrast with
--         dbo.fn_plot_weather, which zero-fills missing days for the chart).
-- ===================================================================================
BEGIN TRAN Test02StationWeatherNoToday
    DECLARE @test_name sysname = N'Test02StationWeatherNoToday [fn_station_weather_today] : no row for today';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @Padded int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake2 uniqueidentifier = NEWID();
DECLARE @St2   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 2, N'UT SWT Lake 2');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St2, N'UT_SWT_2', 46.10, -76.10, 'CA', N'unit-test station', 2, N'UT SWT Station 2', N'', 990102, @Lake2, N'UT SWT Lake 2', 1);

-- yesterday and tomorrow, but nothing for today
INSERT INTO dbo.weather_Forecast
    (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight, air_temperature, humidity, wind_max_speed, shortText)
VALUES
    (@St2, N'UT_SWT_2', CAST(DATEADD(DAY, -1, GETDATE()) AS DATE), '23:00:00', 20.0, 10.0, 0, 0, 15, 80, 5.0, N'Clear'),
    (@St2, N'UT_SWT_2', CAST(DATEADD(DAY,  1, GETDATE()) AS DATE), '23:00:00', 21.0, 11.0, 0, 0, 16, 82, 6.0, N'Cloudy');

SELECT @Cnt = COUNT(*) FROM dbo.fn_station_weather_today(990102);

-- Contrast: the pre-existing chart function DOES hand back a zero-filled placeholder for the
-- very same station/day (0 degrees, 0 humidity, '' text). That is correct for a Highcharts
-- series and wrong for a page, and is exactly why fn_station_weather_today exists.
SELECT @Padded = COUNT(*) FROM dbo.fn_plot_weather(990102)
WHERE dt = CAST(GETDATE() AS DATE) AND temperature_high = 0 AND humidity = 0;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 0 AND @Padded = 1
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no row for today (while fn_plot_weather zero-fills the same day)';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected 0 rows and 1 zero-filled plot row, got rows=%d padded=%d', 16, -1, @ElapsedMs, @Cnt, @Padded);

ROLLBACK TRAN Test02StationWeatherNoToday
GO

-- ===================================================================================
-- TEST 3: one station's weather never leaks into another's; unknown sid -> zero rows
-- ===================================================================================
BEGIN TRAN Test03StationWeatherIsolation
    DECLARE @test_name sysname = N'Test03StationWeatherIsolation [fn_station_weather_today] : per-station isolation';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @CntA int, @CntB int, @Leak int, @CntNone int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake3 uniqueidentifier = NEWID();
DECLARE @StA   uniqueidentifier = NEWID();
DECLARE @StB   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'UT SWT Lake 3');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@StA, N'UT_SWT_3A', 47.10, -77.10, 'CA', N'unit-test station', 2, N'UT SWT Station 3A', N'', 990103, @Lake3, N'UT SWT Lake 3', 1),
       (@StB, N'UT_SWT_3B', 47.20, -77.20, 'CA', N'unit-test station', 2, N'UT SWT Station 3B', N'', 990104, @Lake3, N'UT SWT Lake 3', 1);

-- both stations sit on the SAME water body, each with its own distinct reading
INSERT INTO dbo.weather_Forecast
    (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight, air_temperature, humidity, wind_max_speed, shortText)
VALUES
    (@StA, N'UT_SWT_3A', CAST(GETDATE() AS DATE), '23:00:00', 30.0, 20.0, 0, 0, 25, 50, 9.0, N'Clear'),
    (@StB, N'UT_SWT_3B', CAST(GETDATE() AS DATE), '23:00:00', 10.0,  0.0, 0, 0,  5, 90, 1.0, N'Overcast');

SELECT @CntA = COUNT(*) FROM dbo.fn_station_weather_today(990103) WHERE conditions = N'Clear'    AND air_temp = 25;
SELECT @CntB = COUNT(*) FROM dbo.fn_station_weather_today(990104) WHERE conditions = N'Overcast' AND air_temp =  5;
SELECT @Leak = COUNT(*) FROM dbo.fn_station_weather_today(990103) WHERE conditions = N'Overcast';
SELECT @CntNone = COUNT(*) FROM dbo.fn_station_weather_today(-1);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @CntA = 1 AND @CntB = 1 AND @Leak = 0 AND @CntNone = 0
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: each station returns only its own reading, unknown sid returns none';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: A=%d B=%d leak=%d unknown=%d', 16, -1, @ElapsedMs, @CntA, @CntB, @Leak, @CntNone);

ROLLBACK TRAN Test03StationWeatherIsolation
GO

-- ===================================================================================
-- TEST 4: the unique index is (link, dt, tm), so a day may hold several collection
--         times -- the function must return exactly one row: the latest tm.
-- ===================================================================================
BEGIN TRAN Test04StationWeatherLatestTm
    DECLARE @test_name sysname = N'Test04StationWeatherLatestTm [fn_station_weather_today] : latest tm of the day wins';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int, @Late int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake4 uniqueidentifier = NEWID();
DECLARE @St4   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 2, N'UT SWT Lake 4');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St4, N'UT_SWT_4', 48.10, -78.10, 'CA', N'unit-test station', 2, N'UT SWT Station 4', N'', 990105, @Lake4, N'UT SWT Lake 4', 1);

INSERT INTO dbo.weather_Forecast
    (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight, air_temperature, humidity, wind_max_speed, shortText)
VALUES
    (@St4, N'UT_SWT_4', CAST(GETDATE() AS DATE), '07:00:00', 18.0, 9.0, 0, 0, 11, 70, 4.0, N'Morning run'),
    (@St4, N'UT_SWT_4', CAST(GETDATE() AS DATE), '23:00:00', 19.0, 8.0, 0, 0, 12, 72, 4.5, N'Evening run');

SELECT @Cnt  = COUNT(*) FROM dbo.fn_station_weather_today(990105);
SELECT @Late = COUNT(*) FROM dbo.fn_station_weather_today(990105) WHERE conditions = N'Evening run';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 1 AND @Late = 1
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a single row returned, taken from the latest collection time of the day';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: expected 1 row from the 23:00 run, got rows=%d latest=%d', 16, -1, @ElapsedMs, @Cnt, @Late);

ROLLBACK TRAN Test04StationWeatherLatestTm
GO
