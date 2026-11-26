SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: pressureFactor in env.fn_fish_location_today and the pressure section of env.fn_fish_reasoning_json.
  Fixture per test: a fish (name token 'utprf') with fish_pressure_group, a dbo.WaterStation, an env.StationDay
  row for 2030-01-15 (pressure in mm Hg) and a fish_location row with probability 80. No month or lunar curve and
  no oxygen or flow state, so those factors are 1.

  TEST  1 - P1 (bass) on PRE_1, weight 1 -> pressureFactor 1.20, today 80 -> 96
  TEST  2 - P1 on POST_1, weight 0.5 -> 1 + (0.70 - 1) x 0.5 = 0.85, today 80 -> 68
  TEST  3 - no group -> 1; NULL @day -> 1
  TEST  4 - a row stamped more than 2 days ago counts as unknown -> 1
  TEST  5 - fn_fish_reasoning_json: factors.pressure, pressure.state / group / note, week[0].pressureState
*/
PRINT 'Unit tests for pressureFactor (forecast weather-front factor)';
GO
-- ============================================================================ TEST 1
BEGIN TRAN PRF_Test1
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2), @v int;
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_pressure_group)
     VALUES (@F, N'Utprf-fish1', N'Utprf one', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'P1');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, sid)
     VALUES (@S, 'UTPRF_001', N'Utprf Lake', 1, 'UTPRF_001', 'unit test', 'Utest', 45.0, -75.0, 'CA', 'ON', 990801);
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, strength, season, pressure_weight, pushed)
     SELECT sid, '2030-01-15', 756.1, 'PRE_1', 1.00, 1.00, 1.00, SYSUTCDATETIME() FROM dbo.WaterStation WHERE id = @S;
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = pressureFactor, @v = newToday FROM env.fn_fish_location_today(1, 10, '2030-01-15') WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1.20 OR ISNULL(@v, 0) <> 96 RAISERROR ('TEST 1 FAIL: bass before a front must be 1.20 and 96', 16, -1)
ELSE PRINT 'TEST 1 PASS: bass day before a front 1.20, today 80 -> 96'
ROLLBACK TRAN PRF_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN PRF_Test2
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2), @v int;
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_pressure_group)
     VALUES (@F, N'Utprf-fish2', N'Utprf two', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'P1');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, sid)
     VALUES (@S, 'UTPRF_002', N'Utprf Lake', 1, 'UTPRF_002', 'unit test', 'Utest', 45.0, -75.0, 'CA', 'ON', 990802);
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, strength, season, pressure_weight, pushed)
     SELECT sid, '2030-01-15', 765.1, 'POST_1', 0.50, 1.00, 0.50, SYSUTCDATETIME() FROM dbo.WaterStation WHERE id = @S;
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = pressureFactor, @v = newToday FROM env.fn_fish_location_today(1, 10, '2030-01-15') WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 0.85 OR ISNULL(@v, 0) <> 68 RAISERROR ('TEST 2 FAIL: weak front, day after must be 0.85 and 68', 16, -1)
ELSE PRINT 'TEST 2 PASS: weak front day after 0.85, today 80 -> 68'
ROLLBACK TRAN PRF_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN PRF_Test3
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2), @n decimal(4,2);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
     VALUES (@F, N'Utprf-fish3', N'Utprf three', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, sid)
     VALUES (@S, 'UTPRF_003', N'Utprf Lake', 1, 'UTPRF_003', 'unit test', 'Utest', 45.0, -75.0, 'CA', 'ON', 990803);
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, strength, season, pressure_weight, pushed)
     SELECT sid, '2030-01-15', 756.1, 'PRE_1', 1.00, 1.00, 1.00, SYSUTCDATETIME() FROM dbo.WaterStation WHERE id = @S;
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = pressureFactor FROM env.fn_fish_location_today(1, 10, '2030-01-15') WHERE station_Id = @S AND fish_Id = @F;
UPDATE dbo.fish SET fish_pressure_group = 'P1' WHERE fish_id = @F;
SELECT @n = pressureFactor FROM env.fn_fish_location_today(1, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1.00 OR ISNULL(@n, 0) <> 1.00 RAISERROR ('TEST 3 FAIL: no group or no day must be 1', 16, -1)
ELSE PRINT 'TEST 3 PASS: no group -> 1, no day -> 1'
ROLLBACK TRAN PRF_Test3
GO
-- ============================================================================ TEST 4
BEGIN TRAN PRF_Test4
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_pressure_group)
     VALUES (@F, N'Utprf-fish4', N'Utprf four', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'P1');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, sid)
     VALUES (@S, 'UTPRF_004', N'Utprf Lake', 1, 'UTPRF_004', 'unit test', 'Utest', 45.0, -75.0, 'CA', 'ON', 990804);
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, strength, season, pressure_weight, pushed)
     SELECT sid, '2030-01-15', 756.1, 'PRE_1', 1.00, 1.00, 1.00, DATEADD(DAY, -3, SYSUTCDATETIME()) FROM dbo.WaterStation WHERE id = @S;
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = pressureFactor FROM env.fn_fish_location_today(1, 10, '2030-01-15') WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1.00 RAISERROR ('TEST 4 FAIL: a state older than 2 days must count as unknown', 16, -1)
ELSE PRINT 'TEST 4 PASS: state older than 2 days -> 1'
ROLLBACK TRAN PRF_Test4
GO
-- ============================================================================ TEST 5
BEGIN TRAN PRF_Test5
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @sid int, @j nvarchar(max);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_pressure_group)
     VALUES (@F, N'Utprf-fish5', N'Utprf five', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'P1');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, sid)
     VALUES (@S, 'UTPRF_005', N'Utprf Lake', 1, 'UTPRF_005', 'unit test', 'Utest', 45.0, -75.0, 'CA', 'ON', 990805);
SET @sid = (SELECT sid FROM dbo.WaterStation WHERE id = @S);
INSERT INTO env.StationDay (sid, dt, pressure_mm, pressure_state, front_dt, swing_mm, strength, season, pressure_weight, pushed)
     VALUES (@sid, '2030-01-15', 756.1, 'PRE_1', '2030-01-16', 18.0, 1.00, 1.00, 1.00, SYSUTCDATETIME())
          , (@sid, '2030-01-16', 753.1, 'FRONT', '2030-01-16', 18.0, 1.00, 1.00, 1.00, SYSUTCDATETIME());
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SET @j = env.fn_fish_reasoning_json(@sid, @F, '2030-01-15T12:00:00');
IF ISNULL(JSON_VALUE(@j, '$.factors.pressure'), '') <> '1.200' OR ISNULL(JSON_VALUE(@j, '$.pressure.state'), '') <> 'PRE_1'
   OR ISNULL(JSON_VALUE(@j, '$.pressure.group'), '') <> 'P1' OR JSON_VALUE(@j, '$.pressure.note') IS NULL
   OR ISNULL(JSON_VALUE(@j, '$.week[1].pressureState'), '') <> 'FRONT' OR ISNULL(JSON_VALUE(@j, '$.pressure.series[1].mm'), '') <> '753.1'
    RAISERROR ('TEST 5 FAIL: reasoning pressure section wrong', 16, -1)
ELSE PRINT 'TEST 5 PASS: reasoning has factors.pressure, pressure, week states'
ROLLBACK TRAN PRF_Test5
GO
