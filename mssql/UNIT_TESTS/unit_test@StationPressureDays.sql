SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: dbo.fn_station_pressure_days (weather-front state from daily air pressure) and
  dbo.sp_fill_pressure_state. Fixture per test: a dbo.WaterStation (mli 'UTPRS_n') and one dbo.weather_Forecast row
  per day (pressure in hPa) for days -6..+6 around 2030-01-15 (day 0), so nothing real is touched.

  TEST  1 - classic front: 24 hPa swing -> FRONT on day 0, PRE_1 / POST_1 beside it, PRE_3 / POST_3, strength 1.0
  TEST  2 - weak front: 6 hPa fall + 4 hPa rise -> FRONT, strength 0.5
  TEST  3 - a 5 hPa jump with no low nearby -> RISING; flat days -> STABLE
  TEST  4 - only 3 of the 7 days around a day have pressure -> state NULL
  TEST  5 - sp_fill_pressure_state writes the window with weight = strength x season (January 1.0)
*/
PRINT 'Unit tests for dbo.fn_station_pressure_days (weather-front clock)';
GO
-- ============================================================================ TEST 1
BEGIN TRAN PRS_Test1
SET NOCOUNT ON;
DECLARE @S uniqueidentifier = NEWID(), @d0 date = '2030-01-15';
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, lat) VALUES (@S, 'UTPRS_1', N'Utprs Lake', 1, 45);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, tm, mli, pressure)
SELECT @S, 5, 0, 0, 0, DATEADD(DAY, v.o, @d0), '23:00', 'UTPRS_1', v.p
  FROM (VALUES (-6,1020),(-5,1020),(-4,1019),(-3,1016),(-2,1012),(-1,1008),(0,1004),
               (1,1010),(2,1016),(3,1020),(4,1021),(5,1021),(6,1021)) v(o, p);
DECLARE @s0 varchar(8), @sm1 varchar(8), @sp1 varchar(8), @sm3 varchar(8), @sp3 varchar(8), @str decimal(3,2), @sw int;
SELECT @s0 = MAX(CASE WHEN dt = @d0 THEN state END), @sm1 = MAX(CASE WHEN dt = DATEADD(DAY, -1, @d0) THEN state END)
     , @sp1 = MAX(CASE WHEN dt = DATEADD(DAY, 1, @d0) THEN state END), @sm3 = MAX(CASE WHEN dt = DATEADD(DAY, -3, @d0) THEN state END)
     , @sp3 = MAX(CASE WHEN dt = DATEADD(DAY, 3, @d0) THEN state END)
     , @str = MAX(CASE WHEN dt = @d0 THEN strength END), @sw = MAX(CASE WHEN dt = @d0 THEN swing_hpa END)
  FROM dbo.fn_station_pressure_days('UTPRS_1', DATEADD(DAY, -3, @d0), DATEADD(DAY, 3, @d0));
IF ISNULL(@s0,'') <> 'FRONT' OR ISNULL(@sm1,'') <> 'PRE_1' OR ISNULL(@sp1,'') <> 'POST_1'
   OR ISNULL(@sm3,'') <> 'PRE_3' OR ISNULL(@sp3,'') <> 'POST_3' OR ISNULL(@str, 0) <> 1.00 OR ISNULL(@sw, 0) <> 24
    RAISERROR ('TEST 1 FAIL: %s %s %s %s %s swing %d', 16, -1, @sm3, @sm1, @s0, @sp1, @sp3, @sw)
ELSE PRINT 'TEST 1 PASS: 24 hPa front -> PRE_3..FRONT..POST_3, strength 1'
ROLLBACK TRAN PRS_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN PRS_Test2
SET NOCOUNT ON;
DECLARE @S uniqueidentifier = NEWID(), @d0 date = '2030-01-15';
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, lat) VALUES (@S, 'UTPRS_2', N'Utprs Lake', 1, 45);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, tm, mli, pressure)
SELECT @S, 5, 0, 0, 0, DATEADD(DAY, v.o, @d0), '23:00', 'UTPRS_2', v.p
  FROM (VALUES (-6,1015),(-5,1015),(-4,1015),(-3,1015),(-2,1013),(-1,1011),(0,1009),
               (1,1012),(2,1013),(3,1013),(4,1013),(5,1013),(6,1013)) v(o, p);
DECLARE @s0 varchar(8), @str decimal(3,2);
SELECT @s0 = state, @str = strength FROM dbo.fn_station_pressure_days('UTPRS_2', @d0, @d0);
IF ISNULL(@s0,'') <> 'FRONT' OR ISNULL(@str, 0) <> 0.50
    RAISERROR ('TEST 2 FAIL: weak front must be FRONT with strength 0.5, got %s', 16, -1, @s0)
ELSE PRINT 'TEST 2 PASS: 6 + 4 hPa swing -> FRONT, strength 0.5'
ROLLBACK TRAN PRS_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN PRS_Test3
SET NOCOUNT ON;
DECLARE @S uniqueidentifier = NEWID(), @d0 date = '2030-01-15';
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, lat) VALUES (@S, 'UTPRS_3', N'Utprs Lake', 1, 45);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, tm, mli, pressure)
SELECT @S, 5, 0, 0, 0, DATEADD(DAY, v.o, @d0), '23:00', 'UTPRS_3', v.p
  FROM (VALUES (-6,1015),(-5,1015),(-4,1015),(-3,1015),(-2,1015),(-1,1015),(0,1020),
               (1,1020),(2,1020),(3,1020),(4,1020),(5,1020),(6,1020)) v(o, p);
DECLARE @s0 varchar(8), @sm2 varchar(8);
SELECT @s0 = MAX(CASE WHEN dt = @d0 THEN state END), @sm2 = MAX(CASE WHEN dt = DATEADD(DAY, -2, @d0) THEN state END)
  FROM dbo.fn_station_pressure_days('UTPRS_3', DATEADD(DAY, -2, @d0), @d0);
IF ISNULL(@s0,'') <> 'RISING' OR ISNULL(@sm2,'') <> 'STABLE'
    RAISERROR ('TEST 3 FAIL: jump must be RISING and flat STABLE, got %s / %s', 16, -1, @s0, @sm2)
ELSE PRINT 'TEST 3 PASS: +5 hPa without a low -> RISING, flat -> STABLE'
ROLLBACK TRAN PRS_Test3
GO
-- ============================================================================ TEST 4
BEGIN TRAN PRS_Test4
SET NOCOUNT ON;
DECLARE @S uniqueidentifier = NEWID(), @d0 date = '2030-01-15';
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, lat) VALUES (@S, 'UTPRS_4', N'Utprs Lake', 1, 45);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, tm, mli, pressure)
SELECT @S, 5, 0, 0, 0, DATEADD(DAY, v.o, @d0), '23:00', 'UTPRS_4', v.p
  FROM (VALUES (-3,1015),(0,1010),(3,1015),(-2,NULL),(-1,NULL),(1,NULL),(2,NULL)) v(o, p);
DECLARE @s0 varchar(8), @n int;
SELECT @n = COUNT(*), @s0 = MAX(state) FROM dbo.fn_station_pressure_days('UTPRS_4', @d0, @d0);
IF ISNULL(@n, 0) <> 1 OR @s0 IS NOT NULL
    RAISERROR ('TEST 4 FAIL: 3 of 7 days must give one row with state NULL, got %s', 16, -1, @s0)
ELSE PRINT 'TEST 4 PASS: 3 of 7 days with pressure -> state NULL'
ROLLBACK TRAN PRS_Test4
GO
-- ============================================================================ TEST 5
BEGIN TRAN PRS_Test5
SET NOCOUNT ON;
DECLARE @S uniqueidentifier = NEWID(), @d0 date = '2030-01-15', @rows int;
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, lat) VALUES (@S, 'UTPRS_5', N'Utprs Lake', 1, 45);
INSERT INTO dbo.weather_Forecast (link, tmHigh, tmLow, gpfDay, gpfNight, dt, tm, mli, pressure)
SELECT @S, 5, 0, 0, 0, DATEADD(DAY, v.o, @d0), '23:00', 'UTPRS_5', v.p
  FROM (VALUES (-6,1015),(-5,1015),(-4,1015),(-3,1015),(-2,1013),(-1,1011),(0,1009),
               (1,1012),(2,1013),(3,1013),(4,1013),(5,1013),(6,1013)) v(o, p);
EXEC @rows = dbo.sp_fill_pressure_state @at = '2030-01-15', @mli = 'UTPRS_5';
DECLARE @st varchar(8), @w decimal(3,2), @se decimal(3,2), @n int;
SELECT @st = state, @w = weight, @se = season FROM dbo.StationPressureDay WHERE mli = 'UTPRS_5' AND dt = @d0;
SELECT @n = COUNT(*) FROM dbo.StationPressureDay WHERE mli = 'UTPRS_5';
IF ISNULL(@st,'') <> 'FRONT' OR ISNULL(@se, 0) <> 1.00 OR ISNULL(@w, 0) <> 0.50 OR ISNULL(@n, 0) <> 11 OR ISNULL(@rows, 0) <> 11
    RAISERROR ('TEST 5 FAIL: fill must write 11 days, FRONT weight 0.5, got %s rows %d', 16, -1, @st, @n)
ELSE PRINT 'TEST 5 PASS: fill writes 11 days, weak front weight 0.5'
ROLLBACK TRAN PRS_Test5
GO
