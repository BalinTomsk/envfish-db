SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.vwWeatherForecastToDay (the weather worker's work list).

  Callers: efcs-backend service/weather WeatherService.Data.WeatherStationRepository
  (FindSupportedStationsAsync / CountSupportedStationsAsync -- "SELECT TOP (@limit) mli, lat, lon,
  state FROM dbo.vwWeatherForecastToDay WHERE country = @country"), and the Java weather service.

  THE CRITERION IS FISH: a station belongs in the work list when its water body has >= 1 assigned
  species. There is deliberately no water-data condition.

  Condition (b) was expressed as a 15-day window on dbo.ows_meteo.stamp. That column is NOT a
  water-data fact: ows_meteo rows are seeded by trg_WaterStation_AI_ows_meteo and thereafter
  stamp is only ever written by the WEATHER worker itself
  (WeatherDataRepository: "UPDATE dbo.ows_meteo SET type=@type, ows=@ows, stamp=GETDATE()").
  So the predicate really meant "we collected weather here in the last 15 days" -- self-referential.
  Once a station lapsed past the window nothing could ever move stamp again, so it was excluded
  permanently even while its water data kept flowing. On prod this had frozen out 43 CA stations
  that have fish AND current water data, all still stamped 2021-03-01 with ows IS NULL.

  Fixed by dropping that predicate so fish presence alone decides. Deliberately NOT re-expressed as
  "EXISTS (dbo.WaterData)": that would DROP 81 CA + 157 US stations collected today that hold no
  WaterData rows.

  Uses real tables dbo.Lake / dbo.WaterStation / dbo.lake_fish / dbo.ows_meteo / dbo.WaterData.
  NOTE: inserting a WaterStation fires trg_WaterStation_AI_ows_meteo, which creates the ows_meteo
  row with stamp = GETDATE(); tests that need a stale station UPDATE that stamp afterwards.
  Each test runs in its own named transaction, rolled back at the end of its own GO batch.

  TEST 1 - fish + current water data + STALE ows_meteo.stamp -> station IS in the work list
           (this is the regression: it was excluded before the fix)
  TEST 2 - fish + current water data + fresh ows_meteo.stamp -> still in the work list (no regression)
  TEST 3 - fish but NO water data at all -> INCLUDED (water data must not gate collection)
  TEST 4 - water data but NO fish -> excluded (fish is the criterion)
*/

-- ===================================================================================
-- TEST 1: the regression. Station has fish and current water data, but its ows_meteo row
--         is stale (never collected). It MUST appear in the work list -- otherwise it can
--         never be collected, and the staleness is self-perpetuating.
-- ===================================================================================
BEGIN TRAN Test01WeatherToDayStaleOws
    DECLARE @test_name sysname = N'Test01WeatherToDayStaleOws [vwWeatherForecastToDay] : stale ows_meteo must not exclude';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake1 uniqueidentifier = NEWID();
DECLARE @St1   uniqueidentifier = NEWID();
DECLARE @Fish1 uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'UT WFTD Lake 1');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake1, @Fish1);

INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported, backoffstate)
VALUES (@St1, N'UT_WFTD_1', 45.10, -75.10, 'CA', N'unit-test station', 2, N'UT WFTD Station 1', N'', 990201, @Lake1, N'UT WFTD Lake 1', 1, 0);

-- The station HAS current water data ...
INSERT INTO dbo.WaterData (mli, stamp, elevation) VALUES (N'UT_WFTD_1', GETDATE(), 1.23);

-- ... but weather was never collected: the auto-created ows_meteo row is left at an old stamp
-- with ows still NULL, exactly like the 43 prod stations frozen at 2021-03-01.
UPDATE dbo.ows_meteo SET stamp = DATEADD(YEAR, -5, GETDATE()) WHERE mli = N'UT_WFTD_1';

SELECT @Cnt = COUNT(*) FROM dbo.vwWeatherForecastToDay WHERE mli = N'UT_WFTD_1';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 1
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: station with fish + water data is listed despite a stale ows_meteo stamp';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected the station to be in the work list, got %d rows', 16, -1, @ElapsedMs, @Cnt);

ROLLBACK TRAN Test01WeatherToDayStaleOws
GO

-- ===================================================================================
-- TEST 2: no regression -- a station that was already being collected (fresh ows_meteo
--         stamp) stays in the work list.
-- ===================================================================================
BEGIN TRAN Test02WeatherToDayFreshOws
    DECLARE @test_name sysname = N'Test02WeatherToDayFreshOws [vwWeatherForecastToDay] : actively collected station still listed';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake2 uniqueidentifier = NEWID();
DECLARE @St2   uniqueidentifier = NEWID();
DECLARE @Fish2 uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 2, N'UT WFTD Lake 2');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake2, @Fish2);

INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported, backoffstate)
VALUES (@St2, N'UT_WFTD_2', 45.20, -75.20, 'CA', N'unit-test station', 2, N'UT WFTD Station 2', N'', 990202, @Lake2, N'UT WFTD Lake 2', 1, 0);

INSERT INTO dbo.WaterData (mli, stamp, elevation) VALUES (N'UT_WFTD_2', GETDATE(), 2.34);
-- ows_meteo row is auto-created with stamp = GETDATE(), i.e. actively collected.

SELECT @Cnt = COUNT(*) FROM dbo.vwWeatherForecastToDay WHERE mli = N'UT_WFTD_2';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 1
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: actively collected station is still listed';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected the station to be in the work list, got %d rows', 16, -1, @ElapsedMs, @Cnt);

ROLLBACK TRAN Test02WeatherToDayFreshOws
GO

-- ===================================================================================
-- TEST 3: a fish-bearing station with NO water data at all IS collected. Water data must not
--         gate weather: these are exactly the stations the old ows_meteo predicate stranded
--         forever, and 3 of the 46 recovered CA stations are in this state.
-- ===================================================================================
BEGIN TRAN Test03WeatherToDayNoWaterData
    DECLARE @test_name sysname = N'Test03WeatherToDayNoWaterData [vwWeatherForecastToDay] : no water data -> still listed';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake3 uniqueidentifier = NEWID();
DECLARE @St3   uniqueidentifier = NEWID();
DECLARE @Fish3 uniqueidentifier = (SELECT TOP 1 fish_id FROM dbo.fish ORDER BY fish_id);

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'UT WFTD Lake 3');
INSERT INTO dbo.lake_fish (lake_fish_id, lake_id, fish_id) VALUES (NEWID(), @Lake3, @Fish3);

INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported, backoffstate)
VALUES (@St3, N'UT_WFTD_3', 45.30, -75.30, 'CA', N'unit-test station', 2, N'UT WFTD Station 3', N'', 990203, @Lake3, N'UT WFTD Lake 3', 1, 0);

-- deliberately NO dbo.WaterData rows for this station

SELECT @Cnt = COUNT(*) FROM dbo.vwWeatherForecastToDay WHERE mli = N'UT_WFTD_3';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 1
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fish-bearing station with no water data is still listed';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: expected the station to be in the work list, got %d rows', 16, -1, @ElapsedMs, @Cnt);

ROLLBACK TRAN Test03WeatherToDayNoWaterData
GO

-- ===================================================================================
-- TEST 4: the "with fish" half of the contract still holds -- a station with current
--         water data but NO assigned species is NOT collected.
-- ===================================================================================
BEGIN TRAN Test04WeatherToDayNoFish
    DECLARE @test_name sysname = N'Test04WeatherToDayNoFish [vwWeatherForecastToDay] : no fish -> excluded';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Cnt int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake4 uniqueidentifier = NEWID();
DECLARE @St4   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 2, N'UT WFTD Lake 4');
-- deliberately NO dbo.lake_fish rows for this lake

INSERT INTO dbo.WaterStation (id, MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported, backoffstate)
VALUES (@St4, N'UT_WFTD_4', 45.40, -75.40, 'CA', N'unit-test station', 2, N'UT WFTD Station 4', N'', 990204, @Lake4, N'UT WFTD Lake 4', 1, 0);

INSERT INTO dbo.WaterData (mli, stamp, elevation) VALUES (N'UT_WFTD_4', GETDATE(), 4.56);

SELECT @Cnt = COUNT(*) FROM dbo.vwWeatherForecastToDay WHERE mli = N'UT_WFTD_4';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Cnt = 0
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: station with no assigned species stays excluded';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: expected 0 rows, got %d', 16, -1, @ElapsedMs, @Cnt);

ROLLBACK TRAN Test04WeatherToDayNoFish
GO
