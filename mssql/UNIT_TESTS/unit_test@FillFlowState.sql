SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: dbo.sp_fill_flow_state, which copies dbo.fn_station_flow_state into dbo.CurrentWaterState.
  Each test adds a CurrentWaterState row and a 30-day dbo.WaterData series for a gauge id that is not a
  dbo.WaterStation (so neither table's trigger reaches other rows), fills that one station, then rolls back.

  TEST  1 - a rising series fills flow_state RISING, the ratios and flow_stamp
  TEST  2 - a station with no discharge data has its old state cleared to NULL
  TEST  3 - with fresh flow_stamp data, a full run is skipped (returns 0)
  The lock (a second caller gets -1) needs two sessions, so it is not tested here.
*/
PRINT 'Unit tests for sp_fill_flow_state';
GO
-- ============================================================================ TEST 1
BEGIN TRAN FFS_Test1
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-ffs-1', @r int, @st varchar(10), @r1 float, @fs datetime2;
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp) VALUES (@mli, '2030-01-31 12:00', -1, SYSUTCDATETIME());
INSERT INTO dbo.WaterData (mli, stamp, discharge)
SELECT @mli, DATEADD(DAY, -n.d, '2030-01-31 12:00'), CASE WHEN n.d = 0 THEN 12.0 ELSE 10.0 END
  FROM (SELECT TOP 30 ROW_NUMBER() OVER (ORDER BY object_id) - 1 AS d FROM sys.all_objects) n;
EXEC @r = dbo.sp_fill_flow_state @at = '2030-01-31 18:00', @mli = @mli;
SELECT @st = flow_state, @r1 = q_ratio_1d, @fs = flow_stamp FROM dbo.CurrentWaterState WHERE mli = @mli;
IF @r <> 1 OR ISNULL(@st, '-') <> 'RISING' OR ABS(ISNULL(@r1, 0) - 1.2) > 0.001 OR @fs IS NULL
     RAISERROR ('TEST 1 FAIL: rising series must fill RISING, ratio 1.2 and flow_stamp, got %s', 16, -1, @st)
ELSE PRINT 'TEST 1 PASS: a rising series fills RISING, ratio and flow_stamp'
ROLLBACK TRAN FFS_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN FFS_Test2
SET NOCOUNT ON;
DECLARE @mli varchar(64) = 'ut-ffs-2', @r int, @st varchar(10), @fs datetime2;
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_state, q_ratio_1d)
     VALUES (@mli, '2030-01-31 12:00', -1, SYSUTCDATETIME(), 'SPATE', 3.0);
EXEC @r = dbo.sp_fill_flow_state @at = '2030-01-31 18:00', @mli = @mli;
SELECT @st = flow_state, @fs = flow_stamp FROM dbo.CurrentWaterState WHERE mli = @mli;
IF @r <> 0 OR @st IS NOT NULL OR @fs IS NULL
     RAISERROR ('TEST 2 FAIL: no data must clear the old state, got %s', 16, -1, @st)
ELSE PRINT 'TEST 2 PASS: no discharge data clears the old state'
ROLLBACK TRAN FFS_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN FFS_Test3
SET NOCOUNT ON;
DECLARE @r int;
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid, iterstamp, flow_stamp) VALUES ('ut-ffs-3', SYSUTCDATETIME(), -1, SYSUTCDATETIME(), SYSUTCDATETIME());
EXEC @r = dbo.sp_fill_flow_state @max_age_hours = 6;
IF @r <> 0 RAISERROR ('TEST 3 FAIL: a full run with fresh data must be skipped', 16, -1)
ELSE PRINT 'TEST 3 PASS: a full run with fresh flow data is skipped'
ROLLBACK TRAN FFS_Test3
GO
