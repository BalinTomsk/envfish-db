SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: dbo.fn_station_flow_state, the discharge trend of one gauge from dbo.WaterData daily means.
  Each test writes a 30-day series (one reading a day at 12:00, day 0 = 2030-01-31) for a gauge id that is not a
  dbo.WaterStation, so TR_insWaterData leaves CurrentWaterState alone, then rolls back. Base flow 10.

  TEST  1 - flat 10 -> STABLE
  TEST  2 - day 0 = 12 -> RISING (+20 % in a day)
  TEST  3 - day 0 = 30 -> SPATE
  TEST  4 - peak 40 on day 1, day 0 = 25 -> DROPPING, days_since_peak 1
  TEST  5 - peak 40 on day 4, day 0 = 12 -> SETTLED
  TEST  6 - days 0..2 = 4 -> LOW
  TEST  7 - days 0..2 = 8 -> FALLING
  TEST  8 - a negative reading (tidal gauge) -> no row
  TEST  9 - day 0 = 25 x day 1 (glitch) -> no row
  TEST 10 - only 3 of days 0..7 -> no row
  TEST 11 - a -999 (no-reading marker) is skipped -> STABLE
*/
PRINT 'Unit tests for fn_station_flow_state';
GO
-- ============================================================================ TEST 1
BEGIN TRAN SFS_Test1
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-1', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), 10.0
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'STABLE' RAISERROR ('TEST 1 FAIL: flat flow must be STABLE, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 1 PASS: flat flow is STABLE'
ROLLBACK TRAN SFS_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN SFS_Test2
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-2', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d = 0 THEN 12.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'RISING' RAISERROR ('TEST 2 FAIL: +20 %% in a day must be RISING, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 2 PASS: +20 % in a day is RISING'
ROLLBACK TRAN SFS_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN SFS_Test3
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-3', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d = 0 THEN 30.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'SPATE' RAISERROR ('TEST 3 FAIL: 3 x in a day must be SPATE, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 3 PASS: 3 x in a day is SPATE'
ROLLBACK TRAN SFS_Test3
GO
-- ============================================================================ TEST 4
BEGIN TRAN SFS_Test4
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-4', @rst varchar(10), @dsp tinyint;
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE n.d WHEN 0 THEN 25.0 WHEN 1 THEN 40.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state, @dsp = days_since_peak FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'DROPPING' OR ISNULL(@dsp, 99) <> 1
     RAISERROR ('TEST 4 FAIL: falling from yesterday''s peak must be DROPPING / 1, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 4 PASS: falling from yesterday''s peak is DROPPING'
ROLLBACK TRAN SFS_Test4
GO
-- ============================================================================ TEST 5
BEGIN TRAN SFS_Test5
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-5', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE n.d WHEN 0 THEN 12.0 WHEN 1 THEN 12.0 WHEN 4 THEN 40.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'SETTLED' RAISERROR ('TEST 5 FAIL: near normal 4 days after a peak must be SETTLED, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 5 PASS: near normal 4 days after a peak is SETTLED'
ROLLBACK TRAN SFS_Test5
GO
-- ============================================================================ TEST 6
BEGIN TRAN SFS_Test6
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-6', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d <= 2 THEN 4.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'LOW' RAISERROR ('TEST 6 FAIL: 3 days under half the median must be LOW, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 6 PASS: 3 days under half the median is LOW'
ROLLBACK TRAN SFS_Test6
GO
-- ============================================================================ TEST 7
BEGIN TRAN SFS_Test7
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-7', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d <= 2 THEN 8.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'FALLING' RAISERROR ('TEST 7 FAIL: 20 %% under days 3..7 must be FALLING, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 7 PASS: 20 % under days 3..7 is FALLING'
ROLLBACK TRAN SFS_Test7
GO
-- ============================================================================ TEST 8
BEGIN TRAN SFS_Test8
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-8', @n int;
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d = 10 THEN -3.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @n = COUNT(*) FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF @n <> 0 RAISERROR ('TEST 8 FAIL: a negative reading must give no row', 16, -1)
ELSE PRINT 'TEST 8 PASS: a negative reading (tidal) gives no row'
ROLLBACK TRAN SFS_Test8
GO
-- ============================================================================ TEST 9
BEGIN TRAN SFS_Test9
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-9', @n int;
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d = 0 THEN 250.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
SELECT @n = COUNT(*) FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF @n <> 0 RAISERROR ('TEST 9 FAIL: a 25 x one-day jump must give no row', 16, -1)
ELSE PRINT 'TEST 9 PASS: a 25 x one-day jump (glitch) gives no row'
ROLLBACK TRAN SFS_Test9
GO
-- ============================================================================ TEST 10
BEGIN TRAN SFS_Test10
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-10', @n int;
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), 10.0
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n
 WHERE n.d NOT IN (1, 2, 3, 4, 5);
SELECT @n = COUNT(*) FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF @n <> 0 RAISERROR ('TEST 10 FAIL: 3 of days 0..7 must give no row', 16, -1)
ELSE PRINT 'TEST 10 PASS: only 3 of days 0..7 gives no row'
ROLLBACK TRAN SFS_Test10
GO
-- ============================================================================ TEST 11
BEGIN TRAN SFS_Test11
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-sfs-11', @rst varchar(10);
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), 10.0
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
INSERT INTO dbo.WaterData (mli, stamp, discharge) VALUES (@mli, '2030-01-31 15:00', -999);
SELECT @rst = flow_state FROM dbo.fn_station_flow_state(@mli, '2030-01-31 18:00');
IF ISNULL(@rst, '-') <> 'STABLE' RAISERROR ('TEST 11 FAIL: a -999 marker must be skipped, got %s', 16, -1, @rst)
ELSE PRINT 'TEST 11 PASS: a -999 marker is skipped'
ROLLBACK TRAN SFS_Test11
GO
