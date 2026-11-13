SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_forecast_stations_json -- the forecast-map stations near a point, for the app.
  Caller: docapi ForecastController GET /api/v1/forecast/stations (JdbcForecastQueryRepository.stations).

  It is the website's Planning.aspx map (dbo.fn_map_location: water AND weather AND fish, today's score
  from dbo.fish_location) cut to a radius around the caller, nearest first, at most @limit stations.

  TEST 1 - a station on the map within the radius -> listed with the map's today and distance 0
  TEST 2 - a station on the map beyond the radius -> not listed
  TEST 3 - nearest first, @limit cuts the list, total counts every station in the radius
  TEST 4 - a station off the map (no forecast) inside the radius -> not listed
  TEST 5 - unknown fish -> NULL; a known fish with nothing near -> total 0 and []
  TEST 6 - @country 'CA' drops a US station, NULL keeps both
  TEST 7 - marker = today / 10 - 1 (the map's pin colour), name = the map's location

  Uses real tables. #ut_fc_station adds one station with a reading, a forecast (optional) and the fish.
  Each test is its own transaction, rolled back at the end of its own GO batch.
*/
SET NOCOUNT ON;
GO
IF OBJECT_ID('tempdb..#ut_fc_station') IS NOT NULL DROP PROCEDURE #ut_fc_station
GO
CREATE PROCEDURE #ut_fc_station @sid int, @lat float, @lon float, @country char(2), @fish uniqueidentifier
                              , @today int, @weather bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @lake uniqueidentifier = NEWID(), @st uniqueidentifier = NEWID();
    DECLARE @mli varchar(64) = 'UT_FC_' + CAST(@sid AS varchar(12));
    INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@lake, 2, N'UT FC Lake ' + CAST(@sid AS nvarchar(12)));
    INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, state, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
    VALUES (@st, @mli, @lat, @lon, @country, CASE @country WHEN 'US' THEN 'NY' ELSE 'ON' END, N'ut station', 2
          , N'UT FC Station ' + CAST(@sid AS nvarchar(12)), N'UT County', @sid, @lake, N'UT FC Lake', 1);
    INSERT INTO dbo.fish_location (station_Id, fish_Id, today, stamp) VALUES (@st, @fish, @today, GETUTCDATE());
    INSERT INTO dbo.WaterData (mli, stamp, discharge) VALUES (@mli, GETDATE(), 3.5);
    IF @weather = 1
        INSERT INTO dbo.weather_Forecast (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight)
        VALUES (@st, @mli, CAST(GETDATE() AS date), '00:00:00', 20.0, 10.0, 0, 0);
END
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: a map station inside the radius is listed with the map's today
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01Near
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @doc nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id), @fishName varchar(64);
SELECT @fishName = fish_name FROM dbo.fish WHERE fish_id = @fish;
DECLARE @mapToday int, @today int, @km float, @sid int;
BEGIN TRY
    EXEC #ut_fc_station 941001, 44.10, -79.10, 'CA', @fish, 64;
    SELECT @mapToday = today FROM dbo.fn_map_location(@fishName, 44.10, -79.10, 'CA', 0) WHERE sid = 941001;
    SET @doc = dbo.fn_forecast_stations_json(@fish, 44.10, -79.10, 50, NULL, 10);
    SELECT @sid = sid, @today = today, @km = distanceKm
      FROM OPENJSON(@doc, '$.stations') WITH (sid int, today int, distanceKm float)
     WHERE sid = 941001;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 1 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF @sid IS NULL OR @mapToday IS NULL OR @today <> @mapToday OR @km <> 0
    RAISERROR ('TEST 1 FAIL [%dms]: near station missing or today differs from map', 16, -1, @ms)
ELSE
    PRINT 'TEST 1 PASS [' + CAST(@ms AS varchar) + 'ms]: near station listed with map today'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01Near
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: a map station beyond the radius is not listed
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02Far
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @doc nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
DECLARE @far int = -1;
BEGIN TRY
    EXEC #ut_fc_station 941002, 45.10, -79.10, 'CA', @fish, 50;   -- ~111 km north
    SET @doc = dbo.fn_forecast_stations_json(@fish, 44.10, -79.10, 50, NULL, 10);
    SELECT @far = COUNT(*) FROM OPENJSON(@doc, '$.stations') WITH (sid int) WHERE sid = 941002;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 2 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF @doc IS NULL OR @far <> 0
    RAISERROR ('TEST 2 FAIL [%dms]: a station 111 km away is inside a 50 km radius', 16, -1, @ms)
ELSE
    PRINT 'TEST 2 PASS [' + CAST(@ms AS varchar) + 'ms]: station beyond the radius left out'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02Far
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: nearest first, @limit cuts the list, total counts all in the radius
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03Order
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @doc nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
DECLARE @first int, @n int, @total int, @limit int;
BEGIN TRY
    EXEC #ut_fc_station 941003, 44.30, -79.10, 'CA', @fish, 40;   -- ~22 km
    EXEC #ut_fc_station 941004, 44.12, -79.10, 'CA', @fish, 30;   -- ~2 km
    SET @doc = dbo.fn_forecast_stations_json(@fish, 44.10, -79.10, 50, NULL, 1);
    SELECT @n = COUNT(*), @first = MIN(sid) FROM OPENJSON(@doc, '$.stations') WITH (sid int);
    SET @total = JSON_VALUE(@doc, '$.total');
    SET @limit = JSON_VALUE(@doc, '$.limit');
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 3 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF @n <> 1 OR @first <> 941004 OR @total < 2 OR @limit <> 1
    RAISERROR ('TEST 3 FAIL [%dms]: expected the nearest one only, total >= 2', 16, -1, @ms)
ELSE
    PRINT 'TEST 3 PASS [' + CAST(@ms AS varchar) + 'ms]: nearest first, limit and total hold'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03Order
GO
-- ---------------------------------------------------------------------------------------
-- TEST 4: a station the map leaves out (no forecast) is not listed either
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test04OffMap
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @doc nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
DECLARE @hit int = -1;
BEGIN TRY
    EXEC #ut_fc_station 941005, 44.11, -79.10, 'CA', @fish, 70, 0;
    SET @doc = dbo.fn_forecast_stations_json(@fish, 44.10, -79.10, 50, NULL, 10);
    SELECT @hit = COUNT(*) FROM OPENJSON(@doc, '$.stations') WITH (sid int) WHERE sid = 941005;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 4 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF @doc IS NULL OR @hit <> 0
    RAISERROR ('TEST 4 FAIL [%dms]: a station with no forecast was listed', 16, -1, @ms)
ELSE
    PRINT 'TEST 4 PASS [' + CAST(@ms AS varchar) + 'ms]: station without a forecast left out'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test04OffMap
GO
-- ---------------------------------------------------------------------------------------
-- TEST 5: unknown fish -> NULL; known fish with nothing near -> total 0, []
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test05Empty
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @doc nvarchar(max), @none nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
BEGIN TRY
    SET @none = dbo.fn_forecast_stations_json(NEWID(), 44.10, -79.10, 50, NULL, 10);
    SET @doc  = dbo.fn_forecast_stations_json(@fish, -45.0, 170.0, 10, NULL, 10);
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 5 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF @none IS NOT NULL OR @doc IS NULL OR JSON_VALUE(@doc, '$.total') <> '0'
     OR JSON_QUERY(@doc, '$.stations') <> '[]'
    RAISERROR ('TEST 5 FAIL [%dms]: unknown fish must be NULL, empty area total 0', 16, -1, @ms)
ELSE
    PRINT 'TEST 5 PASS [' + CAST(@ms AS varchar) + 'ms]: unknown fish NULL, empty area []'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test05Empty
GO
-- ---------------------------------------------------------------------------------------
-- TEST 6: @country 'CA' drops a US station across the border, NULL keeps both
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test06Country
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @ca nvarchar(max), @all nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
DECLARE @caUs int = -1, @allUs int = -1, @allCa int = -1;
BEGIN TRY
    EXEC #ut_fc_station 941006, 43.10, -79.05, 'CA', @fish, 50;
    EXEC #ut_fc_station 941007, 43.10, -78.95, 'US', @fish, 50;
    SET @ca  = dbo.fn_forecast_stations_json(@fish, 43.10, -79.00, 30, 'CA', 10);
    SET @all = dbo.fn_forecast_stations_json(@fish, 43.10, -79.00, 30, NULL, 10);
    SELECT @caUs  = COUNT(*) FROM OPENJSON(@ca,  '$.stations') WITH (sid int) WHERE sid = 941007;
    SELECT @allUs = COUNT(*) FROM OPENJSON(@all, '$.stations') WITH (sid int) WHERE sid = 941007;
    SELECT @allCa = COUNT(*) FROM OPENJSON(@all, '$.stations') WITH (sid int) WHERE sid = 941006;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 6 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF @caUs <> 0 OR @allUs <> 1 OR @allCa <> 1
    RAISERROR ('TEST 6 FAIL [%dms]: country filter wrong', 16, -1, @ms)
ELSE
    PRINT 'TEST 6 PASS [' + CAST(@ms AS varchar) + 'ms]: CA drops the US station, NULL keeps both'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test06Country
GO
-- ---------------------------------------------------------------------------------------
-- TEST 7: marker = today / 10 - 1 (Planning.aspx pin colour); name = the map's location
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test07Marker
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ms int, @err nvarchar(2048), @doc nvarchar(max);
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);
DECLARE @marker int, @name nvarchar(255);
BEGIN TRY
    EXEC #ut_fc_station 941008, 44.10, -79.10, 'CA', @fish, 87;
    SET @doc = dbo.fn_forecast_stations_json(@fish, 44.10, -79.10, 5, 'CA', 10);
    SELECT @marker = marker, @name = name
      FROM OPENJSON(@doc, '$.stations') WITH (sid int, marker int, name nvarchar(255)) WHERE sid = 941008;
END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @err IS NOT NULL
    RAISERROR ('TEST 7 FAIL [%dms]: %s', 16, -1, @ms, @err)
ELSE IF ISNULL(@marker, -9) <> 7 OR ISNULL(@name, N'') <> N'UT FC Station 941008'
    RAISERROR ('TEST 7 FAIL [%dms]: marker must be 7 for 87, name the location', 16, -1, @ms)
ELSE
    PRINT 'TEST 7 PASS [' + CAST(@ms AS varchar) + 'ms]: marker is today/10-1, name is the location'
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test07Marker
GO
DROP PROCEDURE #ut_fc_station
GO
