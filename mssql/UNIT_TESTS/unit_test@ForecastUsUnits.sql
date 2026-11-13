SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for metric storage of US water data and metric forecast documents.

  Rule (2026-11-13): the database stores and returns metric for every country; the website converts
  to US units for a US visitor. dbo.sp_push_us_water_data converts what USGS sends on the way in:
    level ft -> m (x 0.3048), discharge ft3/s -> m3/s (x 0.0283168), velocity ft/s -> m/s (x 0.3048),
    wind mph -> km/h (x 1.609344), precipitation in -> mm (x 25.4), pressure mmHg -> hPa (x 1.33322).
  The collectors pass the unit with no leading space ('in ft', 'feet per second'), which the old
  procedure did not match, and it stored ft3/s as m3/h (x 101.941).

  TEST 1 - sp_push_us_water_data, Streamflow ft^3/s           -> discharge in m3/s
  TEST 2 - sp_push_us_water_data, level 'in ft'                -> elevation in m
  TEST 3 - sp_push_us_water_data, velocity 'feet per second'   -> velocity in m/s
  TEST 4 - sp_push_us_water_data, wind mph / rain in / mmHg    -> km/h, mm, hPa
  TEST 5 - fn_forecast_plot_json, US station                   -> stored metric values
  TEST 6 - fn_plot_weather, US station                         -> stored degC, km/h, mm
  TEST 7 - fn_fish_reasoning_json, US station                  -> metric, precipMm, country trimmed
  TEST 8 - vScienceView, US station                            -> stored values, metric units
  Each test rolls back its own transaction.
*/

-- ===================================================================================
-- TEST 1: USGS streamflow in ft3/s is stored in m3/s
-- ===================================================================================
BEGIN TRAN FUU_Test1
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @x xml = CAST(N'<root><a d="' + CONVERT(char(10), GETDATE(), 23) + N'" v="1000" /></root>' AS xml);
DECLARE @dis float, @cws float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (N'UT_FUU_1', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 1', 2, N'UT FUU 1', N'', 990711, 1);
EXEC dbo.sp_push_us_water_data @mli = N'UT_FUU_1', @state = N'NE', @name = N'Streamflow', @unit = 'ft^3/s', @xmldoc = @x;
SELECT @dis = discharge FROM dbo.WaterData WHERE mli = N'UT_FUU_1';
SELECT @cws = discharge FROM dbo.CurrentWaterState WHERE mli = N'UT_FUU_1';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ROUND(@dis, 2) = 28.32 AND ROUND(@cws, 2) = 28.32
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: ft3/s stored as m3/s';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: 1000 ft3/s not stored as 28.32 m3/s', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test1
GO

-- ===================================================================================
-- TEST 2: a level sent as 'in ft' (no leading space, as the collectors send it) is stored in m
-- ===================================================================================
BEGIN TRAN FUU_Test2
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @x xml = CAST(N'<root><a d="' + CONVERT(char(10), GETDATE(), 23) + N'" v="10" /></root>' AS xml);
DECLARE @elev float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (N'UT_FUU_2', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 2', 2, N'UT FUU 2', N'', 990712, 1);
EXEC dbo.sp_push_us_water_data @mli = N'UT_FUU_2', @state = N'NE'
   , @name = N'Stream water level elevation above NAVD 1988', @unit = 'in ft', @xmldoc = @x;
SELECT @elev = elevation FROM dbo.WaterData WHERE mli = N'UT_FUU_2';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ROUND(@elev, 3) = 3.048
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: level in ft stored in m';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: 10 ft not stored as 3.048 m', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test2
GO

-- ===================================================================================
-- TEST 3: a velocity sent in 'feet per second' is stored in m/s (WaterData.velocity is tinyint)
-- ===================================================================================
BEGIN TRAN FUU_Test3
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @x xml = CAST(N'<root><a d="' + CONVERT(char(10), GETDATE(), 23) + N'" v="6.6" /></root>' AS xml);
DECLARE @vel float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (N'UT_FUU_3', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 3', 2, N'UT FUU 3', N'', 990713, 1);
EXEC dbo.sp_push_us_water_data @mli = N'UT_FUU_3', @state = N'NE'
   , @name = N'Water velocity reading from field sensor', @unit = 'feet per second', @xmldoc = @x;
SELECT @vel = velocity FROM dbo.WaterData WHERE mli = N'UT_FUU_3';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @vel = 2
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: velocity in ft/s stored in m/s';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: 6.6 ft/s not stored as 2 m/s', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test3
GO

-- ===================================================================================
-- TEST 4: wind mph, precipitation inches and pressure mmHg are stored as km/h, mm and hPa
-- ===================================================================================
BEGIN TRAN FUU_Test4
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @d nvarchar(10) = CONVERT(char(10), GETDATE(), 23);
DECLARE @xw xml = CAST(N'<root><a d="' + @d + N'" v="10" /></root>' AS xml);
DECLARE @xp xml = CAST(N'<root><a d="' + @d + N'" v="1" /></root>' AS xml);
DECLARE @xb xml = CAST(N'<root><a d="' + @d + N'" v="750" /></root>' AS xml);
DECLARE @wind int, @prc int, @prs int;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (N'UT_FUU_4', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 4', 2, N'UT FUU 4', N'', 990714, 1);
EXEC dbo.sp_push_us_water_data @mli = N'UT_FUU_4', @state = N'NE', @name = N'Wind speed', @unit = 'mph', @xmldoc = @xw;
EXEC dbo.sp_push_us_water_data @mli = N'UT_FUU_4', @state = N'NE', @name = N'Precipitation', @unit = 'total, in', @xmldoc = @xp;
EXEC dbo.sp_push_us_water_data @mli = N'UT_FUU_4', @state = N'NE', @name = N'Barometric pressure', @unit = 'mmHg', @xmldoc = @xb;
SELECT @wind = wind, @prc = precipitation, @prs = pressure FROM dbo.WaterData WHERE mli = N'UT_FUU_4';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @wind = 16 AND @prc = 25 AND @prs = 1000
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mph, in, mmHg stored as km/h, mm, hPa';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: wind/rain/pressure not stored metric', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test4
GO

-- ===================================================================================
-- TEST 5: the plot document of a US station returns the stored metric values
-- ===================================================================================
BEGIN TRAN FUU_Test5
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @S uniqueidentifier = NEWID(), @json nvarchar(max);
DECLARE @tm float, @prc float, @lvl float, @dis float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (id, MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (@S, N'UT_FUU_5', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 5', 2, N'UT FUU 5', N'', 990715, 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp) VALUES (N'UT_FUU_5', GETDATE(), 990715, GETDATE());
INSERT INTO dbo.WaterData (mli, stamp, discharge, elevation)
VALUES (N'UT_FUU_5', CAST(GETDATE() AS smalldatetime), 28.3, 3.05);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, mli, tmDay, air_temperature)
VALUES (@S, 25, 15, 6, 4, CAST(GETUTCDATE() AS date), N'UT_FUU_5', 20, 20);
SET @json = dbo.fn_forecast_plot_json(990715, '00000000-0000-0000-0000-000000000000');
SELECT @tm  = MAX(TRY_CAST(value AS float)) FROM OPENJSON(@json, '$.temperature');
SELECT @prc = MAX(TRY_CAST(value AS float)) FROM OPENJSON(@json, '$.precipitation');
SELECT @lvl = MAX(TRY_CAST(value AS float)) FROM OPENJSON(@json, '$.level');
SELECT @dis = MAX(TRY_CAST(value AS float)) FROM OPENJSON(@json, '$.discharge');
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @tm = 20 AND @prc = 5 AND @lvl = 3.05 AND @dis = 28.3
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US plot returns stored metric values';
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: US plot not metric', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test5
GO

-- ===================================================================================
-- TEST 6: the weather grid of a US station returns degC, km/h and mm
-- ===================================================================================
BEGIN TRAN FUU_Test6
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @S uniqueidentifier = NEWID();
DECLARE @lo int, @hi int, @wind int, @prc float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (id, MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (@S, N'UT_FUU_6', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 6', 2, N'UT FUU 6', N'', 990716, 1);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, mli, wind_max_speed, rain_today, shortText)
VALUES (@S, 20, 0, 0, 0, CAST(GETDATE() AS date), N'UT_FUU_6', 16, 25, 'UT sunny');
SELECT @lo = temperature_low, @hi = temperature_high, @wind = wind_max_speed, @prc = precipitation
  FROM dbo.fn_plot_weather(990716) WHERE shortText = 'UT sunny';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @lo = 0 AND @hi = 20 AND @wind = 16 AND @prc = 25
    PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US weather grid in degC, km/h, mm';
ELSE
    RAISERROR ('TEST 6 FAIL [%dms]: US weather grid not metric', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test6
GO

-- ===================================================================================
-- TEST 7: the reasoning document of a US station is metric, keeps precipMm, trims country
-- ===================================================================================
BEGIN TRAN FUU_Test7
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
DECLARE @at datetime2 = '2026-06-10T12:00:00', @json nvarchar(max), @md tinyint;
DECLARE @dis float, @hi float, @wind float, @prc float, @weekHi float, @country nvarchar(8);
BEGIN TRY  SET NOCOUNT ON;
SET @md = dbo.fn_moon_day(@at);
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utfuu family', 900711, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utfuu-fish', N'Utfuu one', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UT_FUU_7', 'Utfuu River', 1, 'Utfuu Station', 'Utfuu station', 'Utfuu', 42.49, -96.41, 'US', 'NE', 'TEST', GETUTCDATE(), 1, 990717);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, discharge, velocity)
VALUES ('UT_FUU_7', GETUTCDATE(), 990717, GETUTCDATE(), 28.317, 1);
INSERT INTO dbo.fish_catch_probability (fish_id, [month], probability) VALUES (@F, 6, 100);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability) VALUES (@F, @md, 45);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp) VALUES (@S, @F, 100, 100, GETUTCDATE());
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, mli, wind_max_speed, rain_today, shortText, tm)
VALUES (@S, 20, 0, 0, 0, '2026-06-10', 'UT_FUU_7', 16, 25, 'UT sunny', '12:00');
SET @json = dbo.fn_fish_reasoning_json(990717, @F, @at);
SET @dis  = JSON_VALUE(@json, '$.water.discharge');  SET @hi  = JSON_VALUE(@json, '$.weather.airHigh');
SET @wind = JSON_VALUE(@json, '$.weather.wind');     SET @prc = JSON_VALUE(@json, '$.weather.precipMm');
SET @weekHi = JSON_VALUE(@json, '$.week[0].weather.airHigh');
SET @country = JSON_VALUE(@json, '$.country');
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @dis = 28.317 AND @hi = 20 AND @wind = 16 AND @prc = 25 AND @weekHi = 20 AND @country = N'US'
    PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US reasoning metric, country trimmed';
ELSE
    RAISERROR ('TEST 7 FAIL [%dms]: US reasoning not metric or country padded', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test7
GO

-- ===================================================================================
-- TEST 8: the Science view of a US station shows stored values with metric units
-- ===================================================================================
BEGIN TRAN FUU_Test8
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @S uniqueidentifier = NEWID();
DECLARE @dis varchar(16), @elev varchar(16), @uD varchar(16), @uE varchar(16), @uV varchar(16);
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.WaterStation (id, MLI, lakeName, state, lat, lon, country, locDesc, locType, locName, county, sid, supported)
VALUES (@S, N'UT_FUU_8', N'UT FUU River', 'NE', 42.49, -96.41, 'US', N'UT FUU 8', 2, N'UT FUU 8', N'', 990718, 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp) VALUES (N'UT_FUU_8', GETDATE(), 990718, GETDATE());
INSERT INTO dbo.WaterData (mli, stamp, discharge, elevation, velocity)
VALUES (N'UT_FUU_8', CAST(GETDATE() AS smalldatetime), 28.3, 3.05, 1);
SELECT TOP 1 @dis = discharge, @elev = elevation, @uD = discharge_unit, @uE = elevation_unit, @uV = velocity_unit
  FROM dbo.vScienceView WHERE sid = 990718;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @dis = '28.3' AND @elev = '3.05' AND @uD = 'm^3/s' AND @uE = 'm' AND @uV = 'm/s'
    PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US Science view metric';
ELSE
    RAISERROR ('TEST 8 FAIL [%dms]: US Science view not metric', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN FUU_Test8
GO
