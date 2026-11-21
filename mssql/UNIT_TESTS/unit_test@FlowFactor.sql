SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: flowFactor in dbo.fn_fish_location_today and the flow section of dbo.fn_fish_reasoning_json.
  Fixture per test: a fish (name token 'utflf'), a dbo.WaterStation with a CurrentWaterState row carrying flow_state,
  and a fish_location row with probability 80. No month or lunar curve and no oxygen, so those factors are 1.

  TEST  1 - group B (trout) + RISING -> flowFactor 1.25, today 80 -> 100
  TEST  2 - group C (bass) + SPATE -> flowFactor 0.42, today 80 -> 34
  TEST  3 - a state older than 2 days counts as unknown -> flowFactor 1
  TEST  4 - no group -> flowFactor 1
  TEST  5 - group G (sturgeon) + DROPPING: 1.18 in a spawn month, 1 outside it
  TEST  6 - fn_fish_reasoning_json: factors.flow, flow.state, flow.group, flow.note and week[0].flowFactor
*/
PRINT 'Unit tests for flowFactor (forecast discharge factor)';
GO
-- ============================================================================ TEST 1
BEGIN TRAN FLF_Test1
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2), @v int;
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_flow_group)
     VALUES (@F, N'Utflf-fish1', N'Utflf one', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'B');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTFLF_001', N'Utflf Lake', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, flow_stamp) VALUES ('UTFLF_001', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), 'RISING', SYSUTCDATETIME());
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = flowFactor, @v = newToday FROM dbo.fn_fish_location_today(6, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1.25 OR ISNULL(@v, 0) <> 100 RAISERROR ('TEST 1 FAIL: trout on RISING must be 1.25 and 100', 16, -1)
ELSE PRINT 'TEST 1 PASS: trout on rising flow 1.25, today 80 -> 100'
ROLLBACK TRAN FLF_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN FLF_Test2
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2), @v int;
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_flow_group)
     VALUES (@F, N'Utflf-fish2', N'Utflf two', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'C');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTFLF_002', N'Utflf Lake', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, flow_stamp) VALUES ('UTFLF_002', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), 'SPATE', SYSUTCDATETIME());
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = flowFactor, @v = newToday FROM dbo.fn_fish_location_today(6, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 0.42 OR ISNULL(@v, 0) <> 34 RAISERROR ('TEST 2 FAIL: bass in a SPATE must be 0.42 and 34', 16, -1)
ELSE PRINT 'TEST 2 PASS: bass in a spate 0.42, today 80 -> 34'
ROLLBACK TRAN FLF_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN FLF_Test3
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_flow_group)
     VALUES (@F, N'Utflf-fish3', N'Utflf three', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'C');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTFLF_003', N'Utflf Lake', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, flow_stamp)
     VALUES ('UTFLF_003', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), 'SPATE', DATEADD(DAY, -3, SYSUTCDATETIME()));
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = flowFactor FROM dbo.fn_fish_location_today(6, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1 RAISERROR ('TEST 3 FAIL: a 3-day-old state must count as unknown', 16, -1)
ELSE PRINT 'TEST 3 PASS: a state older than 2 days gives factor 1'
ROLLBACK TRAN FLF_Test3
GO
-- ============================================================================ TEST 4
BEGIN TRAN FLF_Test4
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(4,2);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
     VALUES (@F, N'Utflf-fish4', N'Utflf four', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTFLF_004', N'Utflf Lake', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, flow_stamp) VALUES ('UTFLF_004', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), 'SPATE', SYSUTCDATETIME());
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = flowFactor FROM dbo.fn_fish_location_today(6, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1 RAISERROR ('TEST 4 FAIL: a fish without a group must be factor 1', 16, -1)
ELSE PRINT 'TEST 4 PASS: a fish without a group gives factor 1'
ROLLBACK TRAN FLF_Test4
GO
-- ============================================================================ TEST 5
BEGIN TRAN FLF_Test5
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @in decimal(4,2), @out decimal(4,2);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_flow_group)
     VALUES (@F, N'Utflf-fish5', N'Utflf five', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'G');
INSERT INTO dbo.fish_Rule (fish_Id, periodStart, periodEnd) VALUES (@F, 5, 6);   -- spawns May-June
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTFLF_005', N'Utflf Lake', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, flow_stamp) VALUES ('UTFLF_005', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), 'DROPPING', SYSUTCDATETIME());
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @in  = flowFactor FROM dbo.fn_fish_location_today(6, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
SELECT @out = flowFactor FROM dbo.fn_fish_location_today(9, 10, NULL) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@in, 0) <> 1.18 OR ISNULL(@out, 0) <> 1 RAISERROR ('TEST 5 FAIL: sturgeon must be 1.18 in June, 1 in September', 16, -1)
ELSE PRINT 'TEST 5 PASS: sturgeon 1.18 in a spawn month, 1 outside it'
ROLLBACK TRAN FLF_Test5
GO
-- ============================================================================ TEST 6
BEGIN TRAN FLF_Test6
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @sid int, @j nvarchar(max);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern, fish_flow_group)
     VALUES (@F, N'Utflf-fish6', N'Utflf six', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0, 'B');
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTFLF_006', N'Utflf Lake', 1);
SELECT @sid = sid FROM dbo.WaterStation WHERE id = @S;
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, q_ratio_1d, flow_stamp)
     VALUES ('UTFLF_006', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), 'RISING', 1.3, SYSUTCDATETIME());
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SET @j = dbo.fn_fish_reasoning_json(@sid, @F, SYSUTCDATETIME());
IF ISNULL(JSON_VALUE(@j, '$.factors.flow'), '') <> '1.250' OR ISNULL(JSON_VALUE(@j, '$.flow.state'), '') <> 'RISING'
   OR ISNULL(JSON_VALUE(@j, '$.flow.group'), '') <> 'B' OR JSON_VALUE(@j, '$.flow.note') IS NULL
   OR ISNULL(JSON_VALUE(@j, '$.flow.ratio1d'), '') <> '1.300' OR ISNULL(JSON_VALUE(@j, '$.week[0].flowFactor'), '') <> '1.250'
     RAISERROR ('TEST 6 FAIL: reasoning JSON must carry the flow factor and section', 16, -1)
ELSE PRINT 'TEST 6 PASS: reasoning JSON carries factors.flow and the flow section'
ROLLBACK TRAN FLF_Test6
GO
