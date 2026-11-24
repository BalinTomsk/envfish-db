-- Unit tests: the fish model on schema [env] (env_service plan step 5).
--   env.fn_fish_location_today  dbo.fn_fish_location_today reading env.StationState / env.StationDay
--   env.Setting                 probability_source = legacy (default) | env: which path writes fish_location.today
--   env.sp_update_probability   the update on the env path; does nothing while the source is legacy
--   dbo.spTotalUpdateProbability does nothing once the source is env (the Java weather service keeps calling it)
--   env.fn_probability_diff     both paths side by side, for the comparison days
-- Each test is its own transaction, rolled back at the end of its GO batch.

BEGIN TRAN Test01
    declare @test_name sysname = N'Test01 [env.fn_fish_location_today] : same newToday as the dbo function on the same states'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @compared int, @diff int, @withFlow int, @withPressure int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @now datetime2 = SYSUTCDATETIME();
DECLARE @day date = (SELECT MAX(dt) FROM dbo.StationPressureDay WHERE state IS NOT NULL);
DECLARE @month tinyint = MONTH(@day), @moon tinyint = dbo.fn_moon_day(@now);

-- 300 stations that carry fish: give the legacy tables fresh flow + pressure states (all 7 flow states in turn) ...
DECLARE @st TABLE (sid int PRIMARY KEY, mli varchar(64), id uniqueidentifier);
INSERT INTO @st (sid, mli, id)
SELECT TOP 300 w.sid, w.MLI, w.id FROM dbo.WaterStation w
 WHERE EXISTS (SELECT 1 FROM dbo.fish_location fl WHERE fl.station_Id = w.id)
   AND EXISTS (SELECT 1 FROM dbo.CurrentWaterState c WHERE c.mli = w.MLI)
 ORDER BY w.sid;
UPDATE c SET flow_state = CHOOSE(s.sid % 7 + 1, 'SPATE','RISING','DROPPING','SETTLED','STABLE','FALLING','LOW'),
             flow_stamp = @now, stamp = @now
  FROM dbo.CurrentWaterState c JOIN @st s ON s.mli = c.MLI;
DELETE p FROM dbo.StationPressureDay p JOIN @st s ON s.mli = p.mli AND p.dt = @day;
INSERT INTO dbo.StationPressureDay (mli, dt, hpa, state, weight, stamp)
SELECT s.mli, @day, 1013, CHOOSE(s.sid % 10 + 1, 'PRE_3','PRE_2','PRE_1','FRONT','POST_1','POST_2','POST_3','FALLING','RISING','STABLE'),
       0.80, @now FROM @st s;

-- ... and the SAME states to env.*
INSERT INTO env.StationState (sid, mli, ts, discharge, turbidity, oxygen, ph, elevation, flow_state, flow_stamp)
SELECT s.sid, s.mli, c.stamp, c.discharge, c.turbidity, c.oxygen, NULL, c.elevation, c.flow_state, c.flow_stamp
  FROM @st s JOIN dbo.CurrentWaterState c ON c.mli = s.mli;
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, pressure_weight)
SELECT s.sid, p.dt, 759.8, p.state, p.weight FROM @st s JOIN dbo.StationPressureDay p ON p.mli = s.mli AND p.dt = @day;

SELECT @compared = COUNT(*)
     , @diff = SUM(CASE WHEN o.newToday = n.newToday AND ISNULL(o.flowState,'') = ISNULL(n.flowState,'')
                         AND ISNULL(o.pressureState,'') = ISNULL(n.pressureState,'') THEN 0 ELSE 1 END)
     , @withFlow = SUM(CASE WHEN n.flowFactor <> 1.00 THEN 1 ELSE 0 END)
     , @withPressure = SUM(CASE WHEN n.pressureFactor <> 1.00 THEN 1 ELSE 0 END)
  FROM dbo.fn_fish_location_today(@month, @moon, @day) o
  JOIN env.fn_fish_location_today(@month, @moon, @day) n ON n.id = o.id
 WHERE o.station_Id IN (SELECT id FROM @st);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @compared > 1000 AND @diff = 0 AND @withFlow > 0 AND @withPressure > 0
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: env and dbo give the same newToday on '
          + CAST(@compared AS varchar) + ' rows'
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: env.fn_fish_location_today differs from the dbo function', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test01
GO

BEGIN TRAN Test02
    declare @test_name sysname = N'Test02 [env.fn_fish_location_today] : oxygen older than 7 days does not count'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @fresh decimal(5,2), @old decimal(5,2);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- a fish with an oxygen habitat rule (ri_type 33), at one of its stations; the rule gets a 5..14 mg/L range here
-- (local data carries no oxygen ranges, so the factor would always be 1)
DECLARE @fl int, @sid int, @mli varchar(64), @rp uniqueidentifier;
SELECT TOP 1 @fl = fl.id, @sid = w.sid, @mli = w.MLI, @rp = ri.ri_parent_id
  FROM dbo.fish_location fl
  JOIN dbo.WaterStation w ON w.id = fl.station_Id
  JOIN dbo.fish_Rule r ON r.fish_Id = fl.fish_Id AND r.periodStart = -1 AND r.periodEnd = -1
  JOIN dbo.real_interval ri ON ri.ri_parent_id = r.id AND ri.ri_type = 33
 ORDER BY fl.id;
UPDATE dbo.real_interval SET ri_min = 5, ri_low = 6, ri_avg = 8, ri_high = 10, ri_max = 14 WHERE ri_parent_id = @rp AND ri_type = 33;
DELETE FROM env.StationState WHERE sid = @sid;
-- oxygen 0.5 mg/L, under the habitat minimum = factor 0 while fresh
INSERT INTO env.StationState (sid, mli, ts, oxygen) VALUES (@sid, @mli, SYSUTCDATETIME(), 0.5);
SELECT @fresh = oxygenFactor FROM env.fn_fish_location_today(1, 1, CAST(SYSUTCDATETIME() AS date)) WHERE id = @fl;
UPDATE env.StationState SET ts = DATEADD(DAY, -8, SYSUTCDATETIME()) WHERE sid = @sid;
SELECT @old = oxygenFactor FROM env.fn_fish_location_today(1, 1, CAST(SYSUTCDATETIME() AS date)) WHERE id = @fl;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @fresh = 0.00 AND @old = 1.00
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: oxygen counts when fresh, not after 7 days'
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: oxygen age-out wrong on the env path', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test02
GO

BEGIN TRAN Test03
    declare @test_name sysname = N'Test03 [env.Setting] : legacy by default; env.sp_update_probability does nothing then'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rc int, @changed int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DELETE FROM env.Setting WHERE name = 'probability_source';
DECLARE @fl int = (SELECT MIN(id) FROM dbo.fish_location);
UPDATE dbo.fish_location SET today = -1 WHERE id = @fl;
EXEC @rc = env.sp_update_probability;
SELECT @changed = COUNT(*) FROM dbo.fish_location WHERE id = @fl AND today <> -1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @rc = -1 AND @changed = 0 AND env.fn_probability_source() = 'legacy'
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no setting = legacy; the env update returns -1, writes nothing'
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: env path wrote while the source is legacy', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test03
GO

BEGIN TRAN Test04
    declare @test_name sysname = N'Test04 [env.sp_update_probability] : with source env it writes newToday; dbo is a no-op'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rcEnv int, @rcDbo int, @ok int, @dboTouched int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DELETE FROM env.Setting WHERE name = 'probability_source';
INSERT INTO env.Setting (name, value) VALUES ('probability_source', 'env');
DECLARE @fl int = (SELECT MIN(id) FROM dbo.fish_location);
UPDATE dbo.fish_location SET today = -1, stamp = '2000-01-01' WHERE id = @fl;

EXEC @rcDbo = dbo.spTotalUpdateProbability;
SELECT @dboTouched = COUNT(*) FROM dbo.fish_location WHERE id = @fl AND today <> -1;

EXEC @rcEnv = env.sp_update_probability;
DECLARE @now datetime2 = SYSUTCDATETIME();
SELECT @ok = COUNT(*) FROM dbo.fish_location fl
  JOIN env.fn_fish_location_today(MONTH(@now), dbo.fn_moon_day(@now), CAST(@now AS date)) x ON x.id = fl.id
 WHERE fl.id = @fl AND fl.today = x.newToday AND fl.stamp > '2000-01-01';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @rcDbo = 0 AND @dboTouched = 0 AND @rcEnv >= 1 AND @ok = 1
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: source env: env path writes, dbo path does nothing'
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: the switch did not move the update to the env path', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test04
GO

BEGIN TRAN Test05
    declare @test_name sysname = N'Test05 [env.fn_probability_diff] : lists a row whose two paths disagree'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @listed int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @sid int, @mli varchar(64), @id uniqueidentifier;
SELECT TOP 1 @sid = w.sid, @mli = w.MLI, @id = w.id
  FROM dbo.WaterStation w JOIN dbo.fish f ON 1 = 1
  JOIN dbo.fish_location fl ON fl.station_Id = w.id AND fl.fish_Id = f.fish_id
  JOIN dbo.flow_response fr ON fr.flow_group = f.fish_flow_group AND fr.flow_state = 'SPATE' AND fr.factor <> 1 AND fr.spawn_only = 0
 WHERE EXISTS (SELECT 1 FROM dbo.CurrentWaterState c WHERE c.mli = w.MLI)
 ORDER BY w.sid;
-- legacy: no flow state; env: SPATE, fresh -> the factor differs for that station's fish
UPDATE dbo.CurrentWaterState SET flow_state = NULL WHERE mli = @mli;
DELETE FROM env.StationState WHERE sid = @sid;
INSERT INTO env.StationState (sid, mli, ts, flow_state, flow_stamp) VALUES (@sid, @mli, SYSUTCDATETIME(), 'SPATE', SYSUTCDATETIME());
SELECT @listed = COUNT(*) FROM env.fn_probability_diff() WHERE station_Id = @id AND envFlowState = 'SPATE';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @listed >= 1
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a station whose flow differs is listed by the diff'
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: env.fn_probability_diff missed a disagreeing row', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test05
GO
