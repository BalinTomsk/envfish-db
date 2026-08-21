SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_map_location -- the station points plotted on the FORECAST map.
  Caller: FishTracker Forecast/Planning.aspx.cs (FishTracker.Forecast.MapFrame.LoadMapLocation),
  "SELECT lat, lon, today, location, sid, country, state, county FROM dbo.fn_map_location(...)".

  THE RULE: a station belongs on the map only when it has WATER and WEATHER and FISH -- all three.
  A pin the angler can tap must lead to a page with something on it.

    fish    - already enforced, and per species: the function joins dbo.fish_location for the fish
              being searched, so a station only appears for a fish actually recorded there.
    water   - was only "EXISTS (SELECT 1 FROM dbo.WaterData WHERE mli = ...)", i.e. a row EVER
              existed. That is satisfied by the ~127 US stations whose rows are entirely empty:
              they publish a row a day carrying no measurement at all. The station must instead have
              a RECENT reading that actually carries a value.
    weather - was not required at all, so a station with no forecast still got a pin.

  Uses real tables. Each test is its own transaction, rolled back at the end of its own GO batch.

  TEST 1 - water + weather + fish            -> the station is on the map
  TEST 2 - no forecast row                   -> not on the map
  TEST 3 - WaterData rows exist but are empty -> not on the map
  TEST 4 - the species is not recorded there  -> not on the map (per-species, no regression)
*/
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: all three present -> the station is plotted
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01MapAllThree
    DECLARE @test_name sysname = N'Test01MapAllThree [fn_map_location] : water + weather + fish is on the map'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake1 uniqueidentifier = NEWID(), @St1 uniqueidentifier = NEWID();
DECLARE @Mli1 varchar(64) = 'UT_MAP_1';
DECLARE @Fish1 uniqueidentifier, @FishName1 varchar(64);
DECLARE @rows1 int, @err1 nvarchar(2048), @msg1 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

SELECT TOP 1 @Fish1 = fish_id, @FishName1 = fish_name FROM dbo.fish ORDER BY fish_id;

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'UT MAP Lake 1');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake1, @Fish1);
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St1, @Mli1, 44.10, -79.10, 'CA', N'unit-test station', 2, N'UT MAP Station 1', N'UT County', 940101, @Lake1, N'UT MAP Lake 1', 1);
INSERT INTO dbo.fish_location (station_Id, fish_Id, today, stamp) VALUES (@St1, @Fish1, 55, GETUTCDATE());

-- a real reading, and a forecast for today
INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge) VALUES (@Mli1, GETDATE(), 17, 3.5);
INSERT INTO dbo.weather_Forecast (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight)
VALUES (@St1, @Mli1, CAST(GETDATE() AS date), '00:00:00', 22.0, 11.0, 0, 0);

-- 2. execute unit test

SELECT @rows1 = COUNT(*) FROM dbo.fn_map_location(@FishName1, 44.10, -79.10, 'CA', 0) WHERE sid = 940101;

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
ELSE IF ISNULL(@rows1, 0) <> 1
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: a station with water, weather and the fish must be on the map, got '
              + ISNULL(CAST(@rows1 AS varchar), 'NULL') + N' rows';
    RAISERROR (@msg1, 16, -1)
END
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: station with water, weather and fish is plotted'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01MapAllThree
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: no forecast -> no pin. Weather was not a condition at all before.
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02MapNoWeather
    DECLARE @test_name sysname = N'Test02MapNoWeather [fn_map_location] : a station with no forecast is not plotted'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake2 uniqueidentifier = NEWID(), @St2 uniqueidentifier = NEWID();
DECLARE @Mli2 varchar(64) = 'UT_MAP_2';
DECLARE @Fish2 uniqueidentifier, @FishName2 varchar(64);
DECLARE @rows2 int = -1, @err2 nvarchar(2048), @msg2 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : water and fish, but weather was never collected here

SELECT TOP 1 @Fish2 = fish_id, @FishName2 = fish_name FROM dbo.fish ORDER BY fish_id;

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 2, N'UT MAP Lake 2');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake2, @Fish2);
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St2, @Mli2, 44.20, -79.20, 'CA', N'unit-test station', 2, N'UT MAP Station 2', N'UT County', 940102, @Lake2, N'UT MAP Lake 2', 1);
INSERT INTO dbo.fish_location (station_Id, fish_Id, today, stamp) VALUES (@St2, @Fish2, 55, GETUTCDATE());
INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge) VALUES (@Mli2, GETDATE(), 17, 3.5);
-- deliberately NO dbo.weather_Forecast row

-- 2. execute unit test

SELECT @rows2 = COUNT(*) FROM dbo.fn_map_location(@FishName2, 44.20, -79.20, 'CA', 0) WHERE sid = 940102;

END TRY
BEGIN CATCH
    SET @err2 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err2 IS NOT NULL
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err2;
    RAISERROR (@msg2, 16, -1)
END
ELSE IF ISNULL(@rows2, -1) <> 0
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: a station with no forecast must not be plotted, got '
              + ISNULL(CAST(@rows2 AS varchar), 'NULL') + N' rows';
    RAISERROR (@msg2, 16, -1)
END
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a station with no forecast is not plotted'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02MapNoWeather
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: WaterData rows exist but carry nothing -> no pin.
--         "EXISTS (SELECT 1 FROM WaterData)" was true for these stations, which is how a gauge
--         that has never published a single measurement still got plotted.
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03MapEmptyWater
    DECLARE @test_name sysname = N'Test03MapEmptyWater [fn_map_location] : empty water rows do not count as water'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake3 uniqueidentifier = NEWID(), @St3 uniqueidentifier = NEWID();
DECLARE @Mli3 varchar(64) = 'UT_MAP_3';
DECLARE @Fish3 uniqueidentifier, @FishName3 varchar(64);
DECLARE @rows3 int = -1, @err3 nvarchar(2048), @msg3 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : fish and weather, and water rows that are entirely empty

SELECT TOP 1 @Fish3 = fish_id, @FishName3 = fish_name FROM dbo.fish ORDER BY fish_id;

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'UT MAP Lake 3');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake3, @Fish3);
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St3, @Mli3, 44.30, -79.30, 'CA', N'unit-test station', 2, N'UT MAP Station 3', N'UT County', 940103, @Lake3, N'UT MAP Lake 3', 1);
INSERT INTO dbo.fish_location (station_Id, fish_Id, today, stamp) VALUES (@St3, @Fish3, 55, GETUTCDATE());

INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge, turbidity, oxygen, ph, elevation)
VALUES (@Mli3, GETDATE(), NULL, NULL, NULL, NULL, NULL, NULL);

INSERT INTO dbo.weather_Forecast (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight)
VALUES (@St3, @Mli3, CAST(GETDATE() AS date), '00:00:00', 22.0, 11.0, 0, 0);

-- 2. execute unit test

SELECT @rows3 = COUNT(*) FROM dbo.fn_map_location(@FishName3, 44.30, -79.30, 'CA', 0) WHERE sid = 940103;

END TRY
BEGIN CATCH
    SET @err3 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err3 IS NOT NULL
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err3;
    RAISERROR (@msg3, 16, -1)
END
ELSE IF ISNULL(@rows3, -1) <> 0
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: water rows carrying no measurement must not count as water, got '
              + ISNULL(CAST(@rows3 AS varchar), 'NULL') + N' rows';
    RAISERROR (@msg3, 16, -1)
END
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty water rows do not put a station on the map'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03MapEmptyWater
GO
-- ---------------------------------------------------------------------------------------
-- TEST 4: the map is PER SPECIES -- a station without that fish recorded is not plotted for it.
--         This already held and must keep holding.
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test04MapPerSpecies
    DECLARE @test_name sysname = N'Test04MapPerSpecies [fn_map_location] : a station without the species is not plotted'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Lake4 uniqueidentifier = NEWID(), @St4 uniqueidentifier = NEWID();
DECLARE @Mli4 varchar(64) = 'UT_MAP_4';
DECLARE @Fish4 uniqueidentifier, @Other4 uniqueidentifier, @OtherName4 varchar(64);
DECLARE @rows4 int = -1, @err4 nvarchar(2048), @msg4 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : everything present, but recorded for a DIFFERENT species

SELECT TOP 1 @Fish4 = fish_id FROM dbo.fish ORDER BY fish_id;
SELECT TOP 1 @Other4 = fish_id, @OtherName4 = fish_name FROM dbo.fish WHERE fish_id <> @Fish4 ORDER BY fish_id DESC;

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 2, N'UT MAP Lake 4');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake4, @Fish4);
INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St4, @Mli4, 44.40, -79.40, 'CA', N'unit-test station', 2, N'UT MAP Station 4', N'UT County', 940104, @Lake4, N'UT MAP Lake 4', 1);
INSERT INTO dbo.fish_location (station_Id, fish_Id, today, stamp) VALUES (@St4, @Fish4, 55, GETUTCDATE());
INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge) VALUES (@Mli4, GETDATE(), 17, 3.5);
INSERT INTO dbo.weather_Forecast (link, mli, dt, tm, tmHigh, tmLow, gpfDay, gpfNight)
VALUES (@St4, @Mli4, CAST(GETDATE() AS date), '00:00:00', 22.0, 11.0, 0, 0);

-- 2. execute unit test : ask for the OTHER species

SELECT @rows4 = COUNT(*) FROM dbo.fn_map_location(@OtherName4, 44.40, -79.40, 'CA', 0) WHERE sid = 940104;

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
ELSE IF ISNULL(@rows4, -1) <> 0
BEGIN
    SET @msg4 = N'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: the station must not be plotted for a species not recorded there, got '
              + ISNULL(CAST(@rows4 AS varchar), 'NULL') + N' rows';
    RAISERROR (@msg4, 16, -1)
END
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a station without that species is not plotted for it'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test04MapPerSpecies
GO
