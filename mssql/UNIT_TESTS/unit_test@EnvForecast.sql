-- Unit tests: the forecast documents on schema [env] (env_service plan step 6b).
--   env.fn_map_location            dbo.fn_map_location reading env.StationState / env.StationDay
--   env.fn_forecast_stations_json  dbo.fn_forecast_stations_json on env.fn_map_location
--   env.fn_fish_reasoning_json     dbo.fn_fish_reasoning_json on env.*; pressure in mm Hg; no weather blocks
--                                  (env_service fills them from MySQL envdata)
--   env.fn_forecast_plot_meta_json the SQL Server half of the plot document (names, links)
-- Each test is its own transaction, rolled back at the end of its GO batch.

BEGIN TRAN Test01
    declare @test_name sysname = N'Test01 [env.fn_forecast_stations_json] : same document as the dbo function on the same data'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @old nvarchar(max), @new nvarchar(max), @total int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- the fish with the most stations; every one of its stations gets a fresh reading and a forecast day 20 days
-- ahead, on the legacy tables and the SAME on env.*
DECLARE @fish uniqueidentifier = (SELECT TOP 1 fl.fish_Id FROM dbo.fish_location fl GROUP BY fl.fish_Id ORDER BY COUNT(*) DESC);
DECLARE @st TABLE (sid int PRIMARY KEY, mli varchar(64), id uniqueidentifier, lat float, lon float);
INSERT INTO @st (sid, mli, id, lat, lon)
SELECT w.sid, w.MLI, w.id, w.lat, w.lon FROM dbo.WaterStation w
 WHERE EXISTS (SELECT 1 FROM dbo.fish_location fl WHERE fl.station_Id = w.id AND fl.fish_Id = @fish)
   AND EXISTS (SELECT 1 FROM dbo.CurrentWaterState c WHERE c.mli = w.MLI
                AND (c.discharge IS NOT NULL OR c.oxygen IS NOT NULL OR c.ph IS NOT NULL OR c.elevation IS NOT NULL))
   AND EXISTS (SELECT 1 FROM dbo.weather_Forecast wf WHERE wf.mli = w.MLI);
UPDATE c SET stamp = GETDATE() FROM dbo.CurrentWaterState c JOIN @st s ON s.mli = c.mli;
DECLARE @future date = DATEADD(DAY, 20, CAST(SYSUTCDATETIME() AS date));
UPDATE wf SET dt = @future
  FROM dbo.weather_Forecast wf
  JOIN (SELECT wf2.mli, MAX(wf2.dt) AS dt FROM dbo.weather_Forecast wf2 JOIN @st s ON s.mli = wf2.mli GROUP BY wf2.mli) m
    ON m.mli = wf.mli AND m.dt = wf.dt;
DELETE e FROM env.StationState e JOIN @st s ON s.sid = e.sid;
INSERT INTO env.StationState (sid, mli, ts, discharge, turbidity, oxygen, ph, elevation)
SELECT s.sid, s.mli, SYSUTCDATETIME(), c.discharge, c.turbidity, c.oxygen, c.ph, c.elevation
  FROM @st s JOIN dbo.CurrentWaterState c ON c.mli = s.mli;
INSERT INTO env.StationDay (sid, dt) SELECT s.sid, @future FROM @st s;

DECLARE @lat float = (SELECT AVG(lat) FROM @st), @lon float = (SELECT AVG(lon) FROM @st);
SET @old = dbo.fn_forecast_stations_json(@fish, @lat, @lon, 500, NULL, 200);
SET @new = env.fn_forecast_stations_json(@fish, @lat, @lon, 500, NULL, 200);
SET @total = JSON_VALUE(@new, '$.total');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @total > 10 AND @old = @new
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: env stations list = dbo list (' + CAST(@total AS varchar) + ')'
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: env.fn_forecast_stations_json differs from the dbo function', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test01
GO

BEGIN TRAN Test02
    declare @test_name sysname = N'Test02 [env.fn_map_location] : a pin needs a reading of the last 15 days and a forecast day'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @both int, @stale int, @noDay int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @fish uniqueidentifier, @fishName varchar(64), @sid int, @mli varchar(64), @country char(2);
SELECT TOP 1 @fish = f.fish_id, @fishName = f.fish_name, @sid = w.sid, @mli = w.MLI, @country = RTRIM(w.country)
  FROM dbo.fish_location fl JOIN dbo.fish f ON f.fish_id = fl.fish_Id JOIN dbo.vWaterStation w ON w.id = fl.station_Id
 ORDER BY w.sid;
DELETE FROM env.StationState WHERE sid = @sid;
DELETE FROM env.StationDay WHERE sid = @sid;
INSERT INTO env.StationState (sid, mli, ts, discharge) VALUES (@sid, @mli, SYSUTCDATETIME(), 3.5);
INSERT INTO env.StationDay (sid, dt) VALUES (@sid, CAST(SYSUTCDATETIME() AS date));
SELECT @both = COUNT(*) FROM env.fn_map_location(@fishName, 0, 0, @country, 0) WHERE sid = @sid;
UPDATE env.StationState SET ts = DATEADD(DAY, -16, SYSUTCDATETIME()) WHERE sid = @sid;
SELECT @stale = COUNT(*) FROM env.fn_map_location(@fishName, 0, 0, @country, 0) WHERE sid = @sid;
UPDATE env.StationState SET ts = SYSUTCDATETIME() WHERE sid = @sid;
UPDATE env.StationDay SET dt = DATEADD(DAY, -1, dt) WHERE sid = @sid;
SELECT @noDay = COUNT(*) FROM env.fn_map_location(@fishName, 0, 0, @country, 0) WHERE sid = @sid;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @both = 1 AND @stale = 0 AND @noDay = 0
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: pin needs a fresh reading and a forecast day'
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: env.fn_map_location pin rules wrong', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test02
GO

BEGIN TRAN Test03
    declare @test_name sysname = N'Test03 [env.fn_fish_reasoning_json] : same score, factors and states as dbo; pressure in mm'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @old nvarchar(max), @new nvarchar(max), @same int = 0, @mmOk int = 0;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @now datetime2 = SYSUTCDATETIME(), @day0 date = CAST(SYSUTCDATETIME() AS date);
DECLARE @fish uniqueidentifier, @sid int, @mli varchar(64);
SELECT TOP 1 @fish = fl.fish_Id, @sid = w.sid, @mli = w.MLI
  FROM dbo.fish_location fl JOIN dbo.WaterStation w ON w.id = fl.station_Id
  JOIN dbo.fish f ON f.fish_id = fl.fish_Id
 WHERE EXISTS (SELECT 1 FROM dbo.CurrentWaterState c WHERE c.mli = w.MLI)
   AND f.fish_flow_group IS NOT NULL AND f.fish_pressure_group IS NOT NULL
 ORDER BY w.sid;
-- legacy: a RISING flow and a front picture -3..+3 days (hPa)
UPDATE dbo.CurrentWaterState SET flow_state = 'RISING', flow_stamp = @now, q_ratio_1d = 1.2, q_ratio_2d = 1.3, q_ratio_3_7d = 1.4,
       days_since_peak = 2, oxygen = 8.5, discharge = 12.25, stamp = @now WHERE mli = @mli;
DELETE FROM dbo.StationPressureDay WHERE mli = @mli;
INSERT INTO dbo.StationPressureDay (mli, dt, hpa, d1_hpa, state, front_dt, swing_hpa, strength, season, weight, stamp)
SELECT @mli, DATEADD(DAY, n, @day0), 1013 + n * 2, CASE WHEN n = 0 THEN -6 END, CHOOSE(n + 4, 'PRE_3','PRE_2','PRE_1','FRONT','POST_1','POST_2','POST_3'),
       @day0, 10, 0.50, 1.00, 0.50, @now
  FROM (VALUES (-3), (-2), (-1), (0), (1), (2), (3)) v(n);
-- env: the same in mm Hg
DELETE FROM env.StationState WHERE sid = @sid;
DELETE FROM env.StationDay WHERE sid = @sid;
INSERT INTO env.StationState (sid, mli, ts, discharge, oxygen, flow_state, q_ratio_1d, q_ratio_2d, q_ratio_3_7d, days_since_peak, flow_stamp)
VALUES (@sid, @mli, @now, 12.25, 8.5, 'RISING', 1.2, 1.3, 1.4, 2, @now);
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, front_dt, swing_mm, strength, season, pressure_weight)
SELECT @sid, DATEADD(DAY, n, @day0), CAST((1013 + n * 2) * 0.750062 AS decimal(5,1)),
       CHOOSE(n + 4, 'PRE_3','PRE_2','PRE_1','FRONT','POST_1','POST_2','POST_3'), @day0, 7.5, 0.50, 1.00, 0.50
  FROM (VALUES (-3), (-2), (-1), (0), (1), (2), (3)) v(n);

SET @old = dbo.fn_fish_reasoning_json(@sid, @fish, @now);
SET @new = env.fn_fish_reasoning_json(@sid, @fish, @now);

IF JSON_VALUE(@old, '$.today') = JSON_VALUE(@new, '$.today')
   AND JSON_VALUE(@old, '$.base') = JSON_VALUE(@new, '$.base')
   AND JSON_VALUE(@old, '$.factors.flow') = JSON_VALUE(@new, '$.factors.flow')
   AND JSON_VALUE(@old, '$.factors.pressure') = JSON_VALUE(@new, '$.factors.pressure')
   AND JSON_VALUE(@old, '$.factors.oxygen') = JSON_VALUE(@new, '$.factors.oxygen')
   AND JSON_VALUE(@old, '$.flow.state') = JSON_VALUE(@new, '$.flow.state')
   AND ISNULL(JSON_VALUE(@old, '$.flow.note'), '') = ISNULL(JSON_VALUE(@new, '$.flow.note'), '')
   AND JSON_VALUE(@old, '$.pressure.state') = JSON_VALUE(@new, '$.pressure.state')
   AND ISNULL(JSON_VALUE(@old, '$.pressure.note'), '') = ISNULL(JSON_VALUE(@new, '$.pressure.note'), '')
   AND JSON_VALUE(@old, '$.station') = JSON_VALUE(@new, '$.station')
   AND JSON_VALUE(@old, '$.water.discharge') = JSON_VALUE(@new, '$.water.discharge')
   AND JSON_QUERY(@old, '$.spawn') = JSON_QUERY(@new, '$.spawn')
   AND JSON_VALUE(@old, '$.week[6].probability') = JSON_VALUE(@new, '$.week[6].probability')
   AND JSON_VALUE(@old, '$.week[3].pressureState') = JSON_VALUE(@new, '$.week[3].pressureState')
    SET @same = 1;
-- change1d = today's mm - yesterday's (env.StationDay stores no day change): 759.8 - 758.3
IF JSON_VALUE(@new, '$.pressure.mm') = '759.8' AND JSON_VALUE(@new, '$.pressure.change1d') = '1.5'
   AND JSON_VALUE(@new, '$.pressure.swingMm') = '7.5' AND JSON_VALUE(@new, '$.pressure.series[3].mm') = '759.8'
   AND JSON_VALUE(@new, '$.pressure.hpa') IS NULL AND JSON_QUERY(@new, '$.weather') IS NULL
   AND JSON_QUERY(@new, '$.week[0].weather') IS NULL AND JSON_VALUE(@new, '$.week[0].date') = CONVERT(char(10), @day0, 23)
    SET @mmOk = 1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @same = 1 AND @mmOk = 1
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: env reasoning = dbo reasoning, pressure in mm'
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: env.fn_fish_reasoning_json differs (same=%d mm=%d)', 16, -1, @ElapsedMs, @same, @mmOk)

ROLLBACK TRAN Test03
GO

BEGIN TRAN Test04
    declare @test_name sysname = N'Test04 [env.fn_fish_reasoning_json / plot meta] : NULL for an unknown station or a fish not there'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @unknownSid int, @notThere int, @metaOk int = 0;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @fish uniqueidentifier, @sid int, @other uniqueidentifier;
SELECT TOP 1 @fish = fl.fish_Id, @sid = w.sid FROM dbo.fish_location fl JOIN dbo.WaterStation w ON w.id = fl.station_Id ORDER BY w.sid;
SELECT TOP 1 @other = f.fish_id FROM dbo.fish f
 WHERE NOT EXISTS (SELECT 1 FROM dbo.fish_location fl JOIN dbo.WaterStation w ON w.id = fl.station_Id
                    WHERE w.sid = @sid AND fl.fish_Id = f.fish_id);
SET @unknownSid = CASE WHEN env.fn_fish_reasoning_json(-5, @fish, SYSUTCDATETIME()) IS NULL
                        AND env.fn_forecast_plot_meta_json(-5, @fish) IS NULL THEN 1 ELSE 0 END;
SET @notThere = CASE WHEN env.fn_fish_reasoning_json(@sid, @other, SYSUTCDATETIME()) IS NULL
                      AND env.fn_forecast_plot_meta_json(@sid, @other) IS NULL THEN 1 ELSE 0 END;

-- the plot meta of a real pair: the same names as dbo.fn_forecast_plot_json
DECLARE @plot nvarchar(max) = dbo.fn_forecast_plot_json(@sid, CAST(@fish AS varchar(36)));
DECLARE @meta nvarchar(max) = env.fn_forecast_plot_meta_json(@sid, @fish);
IF JSON_VALUE(@meta, '$.place') = JSON_VALUE(@plot, '$.place') AND JSON_VALUE(@meta, '$.fish') = JSON_VALUE(@plot, '$.fish')
   AND JSON_VALUE(@meta, '$.country') = RTRIM(JSON_VALUE(@plot, '$.country')) AND ISNULL(JSON_VALUE(@meta, '$.state'), '') = JSON_VALUE(@plot, '$.state')
   AND ISNULL(JSON_VALUE(@meta, '$.lakeid'), '') = LOWER(JSON_VALUE(@plot, '$.lakeid'))
   AND ISNULL(JSON_VALUE(@meta, '$.lakename'), '') = JSON_VALUE(@plot, '$.lakename')
   AND JSON_VALUE(@meta, '$.sid') = CAST(@sid AS varchar(12))
    SET @metaOk = 1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @unknownSid = 1 AND @notThere = 1 AND @metaOk = 1
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: NULL for unknown pairs; plot meta = dbo names'
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: unknown pair or plot meta wrong (%d %d %d)', 16, -1, @ElapsedMs, @unknownSid, @notThere, @metaOk)

ROLLBACK TRAN Test04
GO
