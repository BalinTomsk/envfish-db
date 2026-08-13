SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_ows_meteo_open -- the procedure dbo.TR_ows_meteo runs when the weather
  worker stores a document in dbo.ows_meteo with type = 2. It shreds that document into
  dbo.weather_Forecast (one row per day).

  Caller: efcs-backend WeatherService (WeatherDataRepository does
  "UPDATE dbo.ows_meteo SET type=@type, ows=@ows, stamp=GETDATE()"), which fires TR_ows_meteo.
  Downstream readers: dbo.fn_station_weather_today (the weather table on the river-viewer Weather
  tab) and dbo.fn_plot_weather (the Highcharts series).

  The worker stores MORE THAN ONE provider's document shape under type = 2. This procedure
  originally understood only the Open-Meteo shape ($.hourly.time / $.daily.time), so a
  Visual Crossing document ($.days[]) parsed to zero rows, the MERGE had nothing to merge, and
  NOTHING was written -- with no error, because an empty parse is indistinguishable from success.
  On prod that left stations with current water data and a freshly collected payload showing no
  weather at all (e.g. MLI 13068500, BLACKFOOT RIVER NR BLACKFOOT).

  UNITS ARE THE TRAP: Open-Meteo serves metric (degC, km/h, mm) and every consumer expects metric,
  but Visual Crossing serves US units (degF, mph, inches). TEST 1 pins the conversions down.

  Tests drive the REAL path -- they UPDATE dbo.ows_meteo and let TR_ows_meteo dispatch -- so the
  routing is covered too. Uses real tables; each test is its own transaction, rolled back.

  TEST 1 - Visual Crossing document -> rows written, US units converted to metric
  TEST 2 - Open-Meteo document -> still shredded exactly as before (no regression)
  TEST 3 - a shape the procedure does not understand -> writes nothing and does not throw
*/
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: a Visual Crossing document must produce forecast rows, converted to metric
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01VisualCrossing
    DECLARE @test_name sysname = N'Test01VisualCrossing [sp_ows_meteo_open] : days[] document is shredded'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake1 uniqueidentifier = NEWID(), @St1 uniqueidentifier = NEWID();
DECLARE @Mli1 varchar(64) = 'UT_OWS_VC1';
DECLARE @today date = CAST(GETDATE() AS date);
DECLARE @rows1 int, @tmHigh float, @tmLow float, @air int, @rain int, @gpfD float, @gpfN float;
DECLARE @wind float, @deg float, @dir varchar(8), @pop int, @press int, @short varchar(64);
DECLARE @icon varchar(255), @code int, @tm time(7);
DECLARE @err1 nvarchar(2048), @msg1 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a station, and the document shape Visual Crossing returns.
--    94.7F/53.7F/78.3F, 0.5 inch of rain, 10 mph wind.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'UT OWS Lake 1');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St1, @Mli1, 43.13, -112.47, 'US', N'unit-test station', 2, N'UT OWS Station 1', N'', 960101, @Lake1, N'UT OWS Lake 1', 1);

DECLARE @d0 varchar(10) = CONVERT(varchar(10), @today, 23);
DECLARE @d1 varchar(10) = CONVERT(varchar(10), DATEADD(day, 1, @today), 23);
DECLARE @vc nvarchar(max) =
    N'{"queryCost":1,"latitude":43.13,"longitude":-112.47,"timezone":"America/Boise","days":['
  + N'{"datetime":"' + @d0 + N'","tempmax":94.7,"tempmin":53.7,"temp":78.3,"humidity":25.9,'
  + N'"precip":0.5,"precipprob":75.0,"windspeed":10.0,"winddir":242.7,"pressure":1011.5,'
  + N'"conditions":"Rain","description":"Rain in the morning.","icon":"rain"},'
  + N'{"datetime":"' + @d1 + N'","tempmax":85.0,"tempmin":62.0,"temp":74.1,"humidity":39.7,'
  + N'"precip":0.0,"precipprob":6.0,"windspeed":12.8,"winddir":201.2,"pressure":1009.7,'
  + N'"conditions":"Clear","description":"Clear conditions.","icon":"clear-day"}]}';

-- 2. execute unit test : store it the way the worker does and let TR_ows_meteo dispatch

UPDATE dbo.ows_meteo SET type = 2, ows = @vc, stamp = GETDATE() WHERE mli = @Mli1;

SELECT @rows1 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli1;

SELECT @tmHigh = tmHigh, @tmLow = tmLow, @air = air_temperature, @rain = rain_today
     , @gpfD = gpfDay, @gpfN = gpfNight, @wind = wind_max_speed, @deg = wind_degree
     , @dir = wind_direction, @pop = pop, @press = pressure, @short = shortText
     , @icon = icon, @code = weather_code, @tm = tm
  FROM dbo.weather_Forecast WHERE mli = @Mli1 AND dt = @today;

END TRY
BEGIN CATCH
    SET @err1 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
--    94.7F = 34.833C, 53.7F = 12.056C, 78.3F = 25.72C -> 26, 0.5in = 12.7mm -> 13,
--    10mph = 16.093km/h, 242.7deg = SW, icon "rain" -> weather code 63 -> om_63.png

IF @err1 IS NOT NULL
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err1;
    RAISERROR (@msg1, 16, -1)
END
ELSE IF ISNULL(@rows1, 0) <> 2
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 2 forecast rows from the days[] document, got '
              + ISNULL(CAST(@rows1 AS varchar), 'NULL');
    RAISERROR (@msg1, 16, -1)
END
ELSE IF ABS(ISNULL(@tmHigh, -999) - 34.8333) > 0.01 OR ABS(ISNULL(@tmLow, -999) - 12.0556) > 0.01
     OR ISNULL(@air, -1) <> 26 OR ISNULL(@rain, -1) <> 13
     OR ABS(ISNULL(@gpfD, -1) - 6.35) > 0.01 OR ABS(ISNULL(@gpfN, -1) - 6.35) > 0.01
     OR ABS(ISNULL(@wind, -1) - 16.0934) > 0.01 OR ABS(ISNULL(@deg, -1) - 242.7) > 0.01
     OR ISNULL(@dir, '') <> 'SW' OR ISNULL(@pop, -1) <> 75 OR ISNULL(@press, -1) <> 1012
     OR ISNULL(@short, '') <> 'Rain' OR ISNULL(@icon, '') <> 'om_63.png' OR ISNULL(@code, -1) <> 63
     OR @tm IS NULL
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: mapping wrong - tmHigh='
              + ISNULL(CAST(@tmHigh AS varchar), 'NULL') + N' tmLow=' + ISNULL(CAST(@tmLow AS varchar), 'NULL')
              + N' air=' + ISNULL(CAST(@air AS varchar), 'NULL') + N' rain=' + ISNULL(CAST(@rain AS varchar), 'NULL')
              + N' gpfDay=' + ISNULL(CAST(@gpfD AS varchar), 'NULL') + N' gpfNight=' + ISNULL(CAST(@gpfN AS varchar), 'NULL')
              + N' wind=' + ISNULL(CAST(@wind AS varchar), 'NULL') + N' dir=' + ISNULL(@dir, 'NULL')
              + N' pop=' + ISNULL(CAST(@pop AS varchar), 'NULL') + N' press=' + ISNULL(CAST(@press AS varchar), 'NULL')
              + N' short=' + ISNULL(@short, 'NULL') + N' icon=' + ISNULL(@icon, 'NULL')
              + N' code=' + ISNULL(CAST(@code AS varchar), 'NULL');
    RAISERROR (@msg1, 16, -1)
END
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: Visual Crossing days[] shredded with US units converted to metric'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01VisualCrossing
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: the Open-Meteo path is untouched
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02OpenMeteo
    DECLARE @test_name sysname = N'Test02OpenMeteo [sp_ows_meteo_open] : hourly/daily document still shredded'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake2 uniqueidentifier = NEWID(), @St2 uniqueidentifier = NEWID();
DECLARE @Mli2 varchar(64) = 'UT_OWS_OM2';
DECLARE @today2 date = CAST(GETDATE() AS date);
DECLARE @rows2 int, @tmHigh2 float, @tmLow2 float, @air2 int, @hum2 float, @wind2 float;
DECLARE @dir2 varchar(8), @icon2 varchar(255), @tm2 time(7);
DECLARE @err2 nvarchar(2048), @msg2 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : Open-Meteo is already metric, so nothing must be converted

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 2, N'UT OWS Lake 2');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St2, @Mli2, 44.00, -70.00, 'US', N'unit-test station', 2, N'UT OWS Station 2', N'', 960102, @Lake2, N'UT OWS Lake 2', 1);

DECLARE @dd varchar(10) = CONVERT(varchar(10), @today2, 23);
DECLARE @om nvarchar(max) =
    N'{"hourly":{"time":["' + @dd + N'T22:00","' + @dd + N'T23:00"],'
  + N'"temperature_2m":[15.0,16.0],"relative_humidity_2m":[80,82],'
  + N'"precipitation_probability":[10,20],"pressure_msl":[1010,1011],'
  + N'"wind_speed_10m":[5.0,5.5],"wind_direction_10m":[180,191],'
  + N'"weather_code":[0,0],"rain":[0.0,0.0]},'
  + N'"daily":{"time":["' + @dd + N'"],"temperature_2m_max":[24.7],"temperature_2m_min":[11.8]}}';

-- 2. execute unit test

UPDATE dbo.ows_meteo SET type = 2, ows = @om, stamp = GETDATE() WHERE mli = @Mli2;

SELECT @rows2 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli2;
SELECT @tmHigh2 = tmHigh, @tmLow2 = tmLow, @air2 = air_temperature, @hum2 = humidity
     , @wind2 = wind_max_speed, @dir2 = wind_direction, @icon2 = icon, @tm2 = tm
  FROM dbo.weather_Forecast WHERE mli = @Mli2 AND dt = @today2;

END TRY
BEGIN CATCH
    SET @err2 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification : the LAST hour of the day wins (23:00 -> 16 degC, 82 %, 5.5 km/h, 191 deg)

IF @err2 IS NOT NULL
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err2;
    RAISERROR (@msg2, 16, -1)
END
ELSE IF ISNULL(@rows2, 0) <> 1 OR ABS(ISNULL(@tmHigh2, -999) - 24.7) > 0.001
     OR ABS(ISNULL(@tmLow2, -999) - 11.8) > 0.001 OR ISNULL(@air2, -1) <> 16
     OR ABS(ISNULL(@hum2, -1) - 82) > 0.001 OR ABS(ISNULL(@wind2, -1) - 5.5) > 0.001
     OR ISNULL(@dir2, '') <> 'S' OR ISNULL(@icon2, '') <> 'om_0.png'
     OR ISNULL(CAST(@tm2 AS varchar(8)), '') <> '23:00:00'
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: rows=' + ISNULL(CAST(@rows2 AS varchar), 'NULL')
              + N' tmHigh=' + ISNULL(CAST(@tmHigh2 AS varchar), 'NULL') + N' tmLow=' + ISNULL(CAST(@tmLow2 AS varchar), 'NULL')
              + N' air=' + ISNULL(CAST(@air2 AS varchar), 'NULL') + N' hum=' + ISNULL(CAST(@hum2 AS varchar), 'NULL')
              + N' wind=' + ISNULL(CAST(@wind2 AS varchar), 'NULL') + N' dir=' + ISNULL(@dir2, 'NULL')
              + N' icon=' + ISNULL(@icon2, 'NULL') + N' tm=' + ISNULL(CAST(@tm2 AS varchar(8)), 'NULL');
    RAISERROR (@msg2, 16, -1)
END
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: Open-Meteo document still shredded, metric values untouched'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02OpenMeteo
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: a document in neither shape writes nothing and does not throw
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03UnknownShape
    DECLARE @test_name sysname = N'Test03UnknownShape [sp_ows_meteo_open] : unrecognised document is a no-op'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake3 uniqueidentifier = NEWID(), @St3 uniqueidentifier = NEWID();
DECLARE @Mli3 varchar(64) = 'UT_OWS_WU3';
DECLARE @rows3 int = -1, @err3 nvarchar(2048), @msg3 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : the Weather Underground station-observation shape -- one of
--    several non-forecast documents the worker also stores under type = 2 (the others measured on
--    prod being weather.gov/NWS GeoJSON, MSC SWOB GeoJSON and a current-conditions document).
--    It carries CURRENT OBSERVATIONS, not a forecast, so there is nothing here that could become a
--    weather_Forecast row -- the correct outcome is to write nothing, quietly, rather than invent
--    a day from an observation.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'UT OWS Lake 3');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St3, @Mli3, 48.90, -96.66, 'US', N'unit-test station', 2, N'UT OWS Station 3', N'', 960103, @Lake3, N'UT OWS Lake 3', 1);

DECLARE @wu nvarchar(max) =
    N'{"observations":[{"stationID":"KTESTUT1","obsTimeUtc":"2026-08-12T10:34:24Z","country":"US",'
  + N'"lon":-96.668,"lat":48.905,"humidity":95,"winddir":180,'
  + N'"imperial":{"temp":53,"heatIndex":53,"dewpt":51,"windChill":53,"windSpeed":3}}]}';

-- 2. execute unit test

UPDATE dbo.ows_meteo SET type = 2, ows = @wu, stamp = GETDATE() WHERE mli = @Mli3;

SELECT @rows3 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli3;

END TRY
BEGIN CATCH
    SET @err3 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err3 IS NOT NULL
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: an unrecognised document must not throw, but raised: ' + @err3;
    RAISERROR (@msg3, 16, -1)
END
ELSE IF ISNULL(@rows3, -1) <> 0
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 0 forecast rows, got '
              + ISNULL(CAST(@rows3 AS varchar), 'NULL');
    RAISERROR (@msg3, 16, -1)
END
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unrecognised document wrote nothing and did not throw'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03UnknownShape
GO
-- ---------------------------------------------------------------------------------------
-- TEST 4: provider-specific type routing -- Visual Crossing is stamped type = 4 by the
--         weather workers, and TR_ows_meteo must still send it to sp_ows_meteo_open
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test04TypeFourRouted
    DECLARE @test_name sysname = N'Test04TypeFourRouted [TR_ows_meteo] : type 4 (Visual Crossing) routes to the shredder'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake4 uniqueidentifier = NEWID(), @St4 uniqueidentifier = NEWID();
DECLARE @Mli4 varchar(64) = 'UT_OWS_VC4';
DECLARE @today4 date = CAST(GETDATE() AS date);
DECLARE @rows4 int, @tmHigh4 float, @err4 nvarchar(2048), @msg4 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : the same Visual Crossing document as TEST 1, but stamped with
--    the provider-specific type the workers now use instead of the catch-all 2.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 2, N'UT OWS Lake 4');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St4, @Mli4, 43.13, -112.47, 'US', N'unit-test station', 2, N'UT OWS Station 4', N'', 960104, @Lake4, N'UT OWS Lake 4', 1);

DECLARE @d4 varchar(10) = CONVERT(varchar(10), @today4, 23);
DECLARE @vc4 nvarchar(max) =
    N'{"queryCost":1,"latitude":43.13,"longitude":-112.47,"timezone":"America/Boise","days":['
  + N'{"datetime":"' + @d4 + N'","tempmax":94.7,"tempmin":53.7,"temp":78.3,"humidity":25.9,'
  + N'"precip":0.5,"precipprob":75.0,"windspeed":10.0,"winddir":242.7,"pressure":1011.5,'
  + N'"conditions":"Rain","description":"Rain in the morning.","icon":"rain"}]}';

-- 2. execute unit test

UPDATE dbo.ows_meteo SET type = 4, ows = @vc4, stamp = GETDATE() WHERE mli = @Mli4;

SELECT @rows4 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli4;
SELECT @tmHigh4 = tmHigh FROM dbo.weather_Forecast WHERE mli = @Mli4 AND dt = @today4;

END TRY
BEGIN CATCH
    SET @err4 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err4 IS NOT NULL
BEGIN
    SET @msg4 = N'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err4;
    RAISERROR (@msg4, 16, -1)
END
ELSE IF ISNULL(@rows4, 0) <> 1 OR ABS(ISNULL(@tmHigh4, -999) - 34.8333) > 0.01
BEGIN
    SET @msg4 = N'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 forecast row from a type-4 document, got rows='
              + ISNULL(CAST(@rows4 AS varchar), 'NULL') + N' tmHigh=' + ISNULL(CAST(@tmHigh4 AS varchar), 'NULL');
    RAISERROR (@msg4, 16, -1)
END
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: type 4 (Visual Crossing) is routed to sp_ows_meteo_open'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test04TypeFourRouted
GO
-- ---------------------------------------------------------------------------------------
-- TEST 5: an observation-only provider gets its own type and is simply not routed -- it must
--         write nothing and must not throw, since an error here would abort the worker's UPDATE
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test05ObservationTypeNoOp
    DECLARE @test_name sysname = N'Test05ObservationTypeNoOp [TR_ows_meteo] : observation-only provider type is a no-op'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake5 uniqueidentifier = NEWID(), @St5 uniqueidentifier = NEWID();
DECLARE @Mli5 varchar(64) = 'UT_OWS_WU5';
DECLARE @rows5 int = -1, @err5 nvarchar(2048), @msg5 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : Weather Underground station observations, now stamped type 7.
--    No shredder claims that type, so the trigger must leave weather_Forecast alone.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake5, 2, N'UT OWS Lake 5');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St5, @Mli5, 48.90, -96.66, 'US', N'unit-test station', 2, N'UT OWS Station 5', N'', 960105, @Lake5, N'UT OWS Lake 5', 1);

DECLARE @wu5 nvarchar(max) =
    N'{"observations":[{"stationID":"KTESTUT5","obsTimeUtc":"2026-08-12T10:34:24Z","country":"US",'
  + N'"humidity":95,"winddir":180,"imperial":{"temp":53,"windSpeed":3}}]}';

-- 2. execute unit test

UPDATE dbo.ows_meteo SET type = 7, ows = @wu5, stamp = GETDATE() WHERE mli = @Mli5;

SELECT @rows5 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli5;

END TRY
BEGIN CATCH
    SET @err5 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err5 IS NOT NULL
BEGIN
    SET @msg5 = N'TEST 5 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: an unrouted provider type must not throw, but raised: ' + @err5;
    RAISERROR (@msg5, 16, -1)
END
ELSE IF ISNULL(@rows5, -1) <> 0
BEGIN
    SET @msg5 = N'TEST 5 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 0 forecast rows, got '
              + ISNULL(CAST(@rows5 AS varchar), 'NULL');
    RAISERROR (@msg5, 16, -1)
END
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: observation-only provider type wrote nothing and did not throw'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test05ObservationTypeNoOp
GO
