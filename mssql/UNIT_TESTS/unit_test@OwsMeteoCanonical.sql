SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_ows_meteo_canonical -- the ONE shredder for the canonical forecast envelope
  that the weather workers emit, whichever provider they fetched from.

  WHY THIS EXISTS. Until 2026-08-13 each provider's RAW document was stored in dbo.ows_meteo.ows and
  parsed in T-SQL: sp_ows_meteo understood The Weather Company's $.daypart[] shape, sp_ows_meteo_open
  understood Open-Meteo and (from 2026-08-12) Visual Crossing, and four other providers were parsed by
  nothing at all. Every new provider meant a new T-SQL parser, unit conversion lived in SQL (degF->degC,
  mph->km/h, inches->mm), and a payload the parser did not understand produced NO rows and NO error --
  the shredder runs inside TR_ows_meteo, where raising would abort the worker's UPDATE and discard the
  payload it just fetched. That silence is how a whole provider went unnoticed.

  The workers now convert to a canonical envelope BEFORE storing, so:
    * conversion and provider quirks live in C#/Java where they are unit-testable and can throw,
    * the database has one shredder whose input shape is fixed,
    * adding a provider needs no database change at all.

  THE ENVELOPE (fishfind.weather.forecast/v1):
      { "schema":"fishfind.weather.forecast/v1", "provider":"visual-crossing", "providerType":4,
        "mli":"13068500", "fetchedUtc":"...",
        "days":[ { "date":"2026-08-13", "time":"00:00:00",
                   "tempHighC":.., "tempLowC":.., "tempC":.., "tempDayC":..,
                   "humidityPct":.., "windSpeedKmh":.., "windDegrees":.., "windDirection":"S",
                   "pressureHpa":.., "precipChancePct":.., "precipMm":..,
                   "precipDayMm":.., "precipNightMm":..,
                   "weatherCode":.., "icon":"om_2.png",
                   "conditionsShort":"..", "conditionsLong":".." } ],
        "raw": { ...the provider's original document, kept for diagnosis... } }

  Members map 1:1 onto dbo.weather_Forecast, so the procedure is OPENJSON ... WITH ... MERGE and
  nothing else -- no sniffing, no unit conversion, no aggregation. $.raw is deliberately ignored here;
  it exists so a stored payload can still be inspected and replayed, which is what made the
  2026-08-12 Visual Crossing diagnosis possible.

  Tests drive the REAL path: they UPDATE dbo.ows_meteo and let TR_ows_meteo dispatch on the envelope,
  so routing is covered too. Each test is its own transaction, rolled back.

  TEST 1 - a canonical envelope is shredded, every column mapped
  TEST 2 - the legacy raw-provider path still works while the services roll out (no regression)
  TEST 3 - an unknown schema version writes nothing and does not throw
*/
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: canonical envelope -> weather_Forecast, every column mapped
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01Canonical
    DECLARE @test_name sysname = N'Test01Canonical [sp_ows_meteo_canonical] : envelope shredded, columns mapped'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake1 uniqueidentifier = NEWID(), @St1 uniqueidentifier = NEWID();
DECLARE @Mli1 varchar(64) = 'UT_CANON_1';
DECLARE @today date = CAST(GETDATE() AS date);
DECLARE @rows1 int, @tmHigh float, @tmLow float, @air int, @tmDay float, @hum float;
DECLARE @wind float, @deg float, @dir varchar(8), @press int, @pop int, @rain int;
DECLARE @gpfD float, @gpfN float, @code int, @icon varchar(255), @short varchar(64), @long varchar(255);
DECLARE @tm time(7), @link uniqueidentifier;
DECLARE @err1 nvarchar(2048), @msg1 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a station, and the canonical envelope a worker would store.
--    Values are already metric and already reduced to one row per day -- that is the whole point.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'UT CANON Lake 1');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St1, @Mli1, 43.13, -112.47, 'US', N'unit-test station', 2, N'UT CANON Station 1', N'', 950101, @Lake1, N'UT CANON Lake 1', 1);

DECLARE @d0 varchar(10) = CONVERT(varchar(10), @today, 23);
DECLARE @d1 varchar(10) = CONVERT(varchar(10), DATEADD(day, 1, @today), 23);
DECLARE @doc nvarchar(max) =
    N'{"schema":"fishfind.weather.forecast/v1","provider":"visual-crossing","providerType":4,'
  + N'"mli":"' + @Mli1 + N'","fetchedUtc":"2026-08-13T04:12:00Z","days":['
  + N'{"date":"' + @d0 + N'","time":"00:00:00","tempHighC":29.44,"tempLowC":16.67,"tempC":23,'
  + N'"tempDayC":24.1,"humidityPct":39.7,"windSpeedKmh":20.6,"windDegrees":201.2,"windDirection":"S",'
  + N'"pressureHpa":1010,"precipChancePct":6,"precipMm":3,"precipDayMm":2.0,"precipNightMm":1.0,'
  + N'"weatherCode":2,"icon":"om_2.png","conditionsShort":"Partially cloudy",'
  + N'"conditionsLong":"Partly cloudy throughout the day."},'
  + N'{"date":"' + @d1 + N'","time":"00:00:00","tempHighC":22.28,"tempLowC":14.94,"tempC":18,'
  + N'"tempDayC":19.0,"humidityPct":75.7,"windSpeedKmh":14.8,"windDegrees":180.4,"windDirection":"S",'
  + N'"pressureHpa":1009,"precipChancePct":75,"precipMm":2,"precipDayMm":1.0,"precipNightMm":1.0,'
  + N'"weatherCode":63,"icon":"om_63.png","conditionsShort":"Rain","conditionsLong":"Rain."}],'
  + N'"raw":{"queryCost":1,"days":[{"datetime":"' + @d0 + N'","tempmax":85.0}]}}';

-- 2. execute unit test : store it the way a worker does and let TR_ows_meteo dispatch

UPDATE dbo.ows_meteo SET type = 4, ows = @doc, stamp = GETDATE() WHERE mli = @Mli1;

SELECT @rows1 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli1;
SELECT @tmHigh = tmHigh, @tmLow = tmLow, @air = air_temperature, @tmDay = tmDay, @hum = humidity
     , @wind = wind_max_speed, @deg = wind_degree, @dir = wind_direction, @press = pressure
     , @pop = pop, @rain = rain_today, @gpfD = gpfDay, @gpfN = gpfNight, @code = weather_code
     , @icon = icon, @short = shortText, @long = longText, @tm = tm, @link = [link]
  FROM dbo.weather_Forecast WHERE mli = @Mli1 AND dt = @today;

END TRY
BEGIN CATCH
    SET @err1 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err1 IS NOT NULL
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err1;
    RAISERROR (@msg1, 16, -1)
END
ELSE IF ISNULL(@rows1, 0) <> 2
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 2 forecast rows from the canonical envelope, got '
              + ISNULL(CAST(@rows1 AS varchar), 'NULL');
    RAISERROR (@msg1, 16, -1)
END
ELSE IF ABS(ISNULL(@tmHigh, -999) - 29.44) > 0.001 OR ABS(ISNULL(@tmLow, -999) - 16.67) > 0.001
     OR ISNULL(@air, -1) <> 23 OR ABS(ISNULL(@tmDay, -1) - 24.1) > 0.001
     OR ABS(ISNULL(@hum, -1) - 39.7) > 0.001 OR ABS(ISNULL(@wind, -1) - 20.6) > 0.001
     OR ABS(ISNULL(@deg, -1) - 201.2) > 0.001 OR ISNULL(@dir, '') <> 'S'
     OR ISNULL(@press, -1) <> 1010 OR ISNULL(@pop, -1) <> 6 OR ISNULL(@rain, -1) <> 3
     OR ABS(ISNULL(@gpfD, -1) - 2.0) > 0.001 OR ABS(ISNULL(@gpfN, -1) - 1.0) > 0.001
     OR ISNULL(@code, -1) <> 2 OR ISNULL(@icon, '') <> 'om_2.png'
     OR ISNULL(@short, '') <> 'Partially cloudy'
     OR ISNULL(@long, '') <> 'Partly cloudy throughout the day.'
     OR ISNULL(CAST(@tm AS varchar(8)), '') <> '00:00:00' OR @link <> @St1
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: mapping wrong - tmHigh='
              + ISNULL(CAST(@tmHigh AS varchar), 'NULL') + N' tmLow=' + ISNULL(CAST(@tmLow AS varchar), 'NULL')
              + N' air=' + ISNULL(CAST(@air AS varchar), 'NULL') + N' tmDay=' + ISNULL(CAST(@tmDay AS varchar), 'NULL')
              + N' hum=' + ISNULL(CAST(@hum AS varchar), 'NULL') + N' wind=' + ISNULL(CAST(@wind AS varchar), 'NULL')
              + N' deg=' + ISNULL(CAST(@deg AS varchar), 'NULL') + N' dir=' + ISNULL(@dir, 'NULL')
              + N' press=' + ISNULL(CAST(@press AS varchar), 'NULL') + N' pop=' + ISNULL(CAST(@pop AS varchar), 'NULL')
              + N' rain=' + ISNULL(CAST(@rain AS varchar), 'NULL') + N' gpfDay=' + ISNULL(CAST(@gpfD AS varchar), 'NULL')
              + N' gpfNight=' + ISNULL(CAST(@gpfN AS varchar), 'NULL') + N' code=' + ISNULL(CAST(@code AS varchar), 'NULL')
              + N' icon=' + ISNULL(@icon, 'NULL') + N' short=' + ISNULL(@short, 'NULL')
              + N' tm=' + ISNULL(CAST(@tm AS varchar(8)), 'NULL');
    RAISERROR (@msg1, 16, -1)
END
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: canonical envelope shredded with every column mapped'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01Canonical
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: the legacy raw-provider path still works during the rollout
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02LegacyStillWorks
    DECLARE @test_name sysname = N'Test02LegacyStillWorks [TR_ows_meteo] : raw provider payloads still shredded'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake2 uniqueidentifier = NEWID(), @St2 uniqueidentifier = NEWID();
DECLARE @Mli2 varchar(64) = 'UT_CANON_2';
DECLARE @today2 date = CAST(GETDATE() AS date);
DECLARE @rows2 int, @tmHigh2 float, @err2 nvarchar(2048), @msg2 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a RAW Visual Crossing document, as the services still emit until
--    both are redeployed. The envelope check must not have broken this path.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 2, N'UT CANON Lake 2');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St2, @Mli2, 43.13, -112.47, 'US', N'unit-test station', 2, N'UT CANON Station 2', N'', 950102, @Lake2, N'UT CANON Lake 2', 1);

DECLARE @dd varchar(10) = CONVERT(varchar(10), @today2, 23);
DECLARE @raw nvarchar(max) =
    N'{"queryCost":1,"latitude":43.13,"longitude":-112.47,"timezone":"America/Boise","days":['
  + N'{"datetime":"' + @dd + N'","tempmax":94.7,"tempmin":53.7,"temp":78.3,"humidity":25.9,'
  + N'"precip":0.5,"precipprob":75.0,"windspeed":10.0,"winddir":242.7,"pressure":1011.5,'
  + N'"conditions":"Rain","description":"Rain in the morning.","icon":"rain"}]}';

-- 2. execute unit test

UPDATE dbo.ows_meteo SET type = 4, ows = @raw, stamp = GETDATE() WHERE mli = @Mli2;

SELECT @rows2 = COUNT(*) FROM dbo.weather_Forecast WHERE mli = @Mli2;
SELECT @tmHigh2 = tmHigh FROM dbo.weather_Forecast WHERE mli = @Mli2 AND dt = @today2;

END TRY
BEGIN CATCH
    SET @err2 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification : 94.7F still converts to 34.83C through the legacy branch

IF @err2 IS NOT NULL
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err2;
    RAISERROR (@msg2, 16, -1)
END
ELSE IF ISNULL(@rows2, 0) <> 1 OR ABS(ISNULL(@tmHigh2, -999) - 34.8333) > 0.01
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected the raw payload still shredded, got rows='
              + ISNULL(CAST(@rows2 AS varchar), 'NULL') + N' tmHigh=' + ISNULL(CAST(@tmHigh2 AS varchar), 'NULL');
    RAISERROR (@msg2, 16, -1)
END
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: legacy raw provider payload still shredded during rollout'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02LegacyStillWorks
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: an envelope version this database does not know writes nothing and does not throw
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03UnknownVersion
    DECLARE @test_name sysname = N'Test03UnknownVersion [sp_ows_meteo_canonical] : unknown schema version is a no-op'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake3 uniqueidentifier = NEWID(), @St3 uniqueidentifier = NEWID();
DECLARE @Mli3 varchar(64) = 'UT_CANON_3';
DECLARE @rows3 int = -1, @err3 nvarchar(2048), @msg3 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a worker deployed AHEAD of the database emits v2. The database
--    must not guess at a shape it does not know, and must not throw -- an error inside the trigger
--    would abort the worker's UPDATE and discard the payload.

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'UT CANON Lake 3');
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St3, @Mli3, 43.13, -112.47, 'US', N'unit-test station', 2, N'UT CANON Station 3', N'', 950103, @Lake3, N'UT CANON Lake 3', 1);

DECLARE @future nvarchar(max) =
    N'{"schema":"fishfind.weather.forecast/v2","provider":"open-meteo","providerType":2,'
  + N'"mli":"' + @Mli3 + N'","periods":[{"startsAt":"2026-08-13T00:00:00Z","tempC":21}]}';

-- 2. execute unit test

UPDATE dbo.ows_meteo SET type = 2, ows = @future, stamp = GETDATE() WHERE mli = @Mli3;

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
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: an unknown envelope version must not throw, but raised: ' + @err3;
    RAISERROR (@msg3, 16, -1)
END
ELSE IF ISNULL(@rows3, -1) <> 0
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 0 forecast rows, got '
              + ISNULL(CAST(@rows3 AS varchar), 'NULL');
    RAISERROR (@msg3, 16, -1)
END
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown envelope version wrote nothing and did not throw'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03UnknownVersion
GO
