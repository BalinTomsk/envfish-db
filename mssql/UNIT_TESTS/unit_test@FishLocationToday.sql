SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the forecast-map probability: dbo.fn_moon_day, dbo.fn_fish_location_today and
  dbo.spTotalUpdateProbability. fish_location.today must be recomputed from the base probability on every run:
  today = probability x month factor x lunar factor x temperature factor x oxygen factor, clamped 0..100,
  each factor counted once. Called by the weather services after every station update
  (efcs-backend WeatherService / OWMService, efj-backend weather).

  Fixture notes: fish, station and family are created per test; names carry the token 'utflt'. Inserting a fish
  creates its habitat rule (periodStart = periodEnd = -1) by trigger; tests add real_interval rows to it.

  TEST 1 - fn_moon_day: new moon -> 1, full moon -> 14, always 1..28
  TEST 2 - no curves, no water data -> today = probability (a compounded value is reset)
  TEST 3 - month factor = this month / the fish's peak month
  TEST 4 - lunar factor = moon day's value / the fish's peak day
  TEST 5 - all factors multiply once (100 x 0.5 x 0.5 x 0.8 = 20)
  TEST 6 - running the procedure twice does not compound
  TEST 7 - clamped to 100; NULL probability counts as 100
*/
PRINT 'Unit tests for fn_fish_location_today (forecast map today)';
GO
-- ============================================================================
-- TEST 1: fn_moon_day
-- ============================================================================
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @new int, @full int, @bad int;
BEGIN TRY
    SET @new  = dbo.fn_moon_day('2000-01-06T18:14:00');   -- new moon
    SET @full = dbo.fn_moon_day('2000-01-21T04:40:00');   -- full moon (total lunar eclipse)
    SELECT @bad = COUNT(*) FROM (SELECT TOP 400 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) x
     WHERE dbo.fn_moon_day(DATEADD(HOUR, x.n * 6, '2026-01-01')) NOT BETWEEN 1 AND 28;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@new, 0) <> 1 OR ISNULL(@full, 0) <> 14 OR ISNULL(@bad, 1) <> 0
   RAISERROR ('TEST 1 FAIL [%dms]: moon day of new / full moon', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: new moon 1, full moon 14, range 1..28'
GO
-- ============================================================================
-- TEST 2: no curves, no water data -> today = probability
-- ============================================================================
BEGIN TRAN FLT_Test2
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @v int;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utflt family2', 900502, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utflt-fish2', N'Utflt two', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UTFLT_002', 'Utflt Lake', 1, 'Utflt Station 2', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990502);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp) VALUES (@S, @F, 80, 7, GETUTCDATE());
EXEC dbo.spTotalUpdateProbability;
SELECT @v = today FROM dbo.fish_location WHERE station_Id = @S AND fish_Id = @F;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@v, -1) <> 80
   RAISERROR ('TEST 2 FAIL [%dms]: today must be reset to probability 80', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no factors -> today = probability'
IF @@TRANCOUNT > 0 ROLLBACK TRAN FLT_Test2
GO
-- ============================================================================
-- TEST 3: month factor = this month / peak month
-- ============================================================================
BEGIN TRAN FLT_Test3
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @v int, @k float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utflt family3', 900503, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utflt-fish3', N'Utflt three', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UTFLT_003', 'Utflt Lake', 1, 'Utflt Station 3', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990503);
INSERT INTO dbo.fish_catch_probability (fish_id, [month], probability) VALUES (@F, 5, 150), (@F, 8, 300), (@F, 12, 30);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp) VALUES (@S, @F, 80, 80, GETUTCDATE());
SELECT @v = newToday, @k = monthFactor FROM dbo.fn_fish_location_today(5, 1) WHERE station_Id = @S AND fish_Id = @F;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@v, -1) <> 40 OR ISNULL(@k, -1) <> 0.5
   RAISERROR ('TEST 3 FAIL [%dms]: May 150 of peak 300 must halve 80 to 40', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: month factor 150/300 -> 80 x 0.5 = 40'
IF @@TRANCOUNT > 0 ROLLBACK TRAN FLT_Test3
GO
-- ============================================================================
-- TEST 4: lunar factor = moon day's value / peak day
-- ============================================================================
BEGIN TRAN FLT_Test4
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @v int, @k float;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utflt family4', 900504, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utflt-fish4', N'Utflt four', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UTFLT_004', 'Utflt Lake', 1, 'Utflt Station 4', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990504);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability) VALUES (@F, 14, 92), (@F, 21, 46), (@F, 24, 42);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp) VALUES (@S, @F, 80, 80, GETUTCDATE());
SELECT @v = newToday, @k = lunarFactor FROM dbo.fn_fish_location_today(1, 21) WHERE station_Id = @S AND fish_Id = @F;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@v, -1) <> 40 OR ISNULL(@k, -1) <> 0.5
   RAISERROR ('TEST 4 FAIL [%dms]: moon day 21 = 46 of peak 92 must halve 80 to 40', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lunar factor 46/92 -> 80 x 0.5 = 40'
IF @@TRANCOUNT > 0 ROLLBACK TRAN FLT_Test4
GO
-- ============================================================================
-- TEST 5: all factors multiply once
-- ============================================================================
BEGIN TRAN FLT_Test5
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @R uniqueidentifier, @v int;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utflt family5', 900505, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utflt-fish5', N'Utflt five', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 0);
SELECT @R = id FROM dbo.fish_Rule WHERE fish_Id = @F AND periodStart = -1 AND periodEnd = -1;
INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_avg, ri_high, ri_max, ri_stamp)
VALUES (@R, 17, 10.0, 12.0, 15.0, 18.0, 20.0, GETUTCDATE());                       -- 10 C = minimum -> 0.80
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UTFLT_005', 'Utflt Lake', 1, 'Utflt Station 5', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990505);
INSERT INTO dbo.CurrentWaterState (mli, temperature, stamp, iterstamp, sid) VALUES ('UTFLT_005', 10.0, GETUTCDATE(), GETUTCDATE(), 990505);
INSERT INTO dbo.fish_catch_probability (fish_id, [month], probability) VALUES (@F, 6, 100), (@F, 7, 200);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability) VALUES (@F, 1, 90), (@F, 10, 45);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp) VALUES (@S, @F, 100, 100, GETUTCDATE());
SELECT @v = newToday FROM dbo.fn_fish_location_today(6, 10) WHERE station_Id = @S AND fish_Id = @F;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@v, -1) <> 20
   RAISERROR ('TEST 5 FAIL [%dms]: 100 x 0.5 x 0.5 x 0.8 must be 20', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: 100 x 0.5 x 0.5 x 0.8 = 20'
IF @@TRANCOUNT > 0 ROLLBACK TRAN FLT_Test5
GO
-- ============================================================================
-- TEST 6: running twice does not compound
-- ============================================================================
BEGIN TRAN FLT_Test6
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID(), @v1 int, @v2 int;
DECLARE @moon tinyint = dbo.fn_moon_day(SYSUTCDATETIME());
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utflt family6', 900506, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utflt-fish6', N'Utflt six', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UTFLT_006', 'Utflt Lake', 1, 'Utflt Station 6', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990506);
-- today's moon day is half the peak, whatever day the test runs on
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability)
VALUES (@F, @moon, 40), (@F, CASE WHEN @moon = 28 THEN 1 ELSE @moon + 1 END, 80);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp) VALUES (@S, @F, 100, 100, GETUTCDATE());
EXEC dbo.spTotalUpdateProbability;
SELECT @v1 = today FROM dbo.fish_location WHERE station_Id = @S AND fish_Id = @F;
EXEC dbo.spTotalUpdateProbability;
SELECT @v2 = today FROM dbo.fish_location WHERE station_Id = @S AND fish_Id = @F;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@v1, -1) <> 50 OR ISNULL(@v2, -1) <> 50
   RAISERROR ('TEST 6 FAIL [%dms]: two runs must both give 50, not 50 then 25', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: two runs -> 50 and 50, no compounding'
IF @@TRANCOUNT > 0 ROLLBACK TRAN FLT_Test6
GO
-- ============================================================================
-- TEST 7: clamp to 100; NULL probability counts as 100
-- ============================================================================
BEGIN TRAN FLT_Test7
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @S2 uniqueidentifier = NEWID(), @Fam uniqueidentifier = NEWID();
DECLARE @hi int, @nul int;
BEGIN TRY  SET NOCOUNT ON;
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Fam, N'Utflt family7', 900507, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
VALUES (@F, N'Utflt-fish7', N'Utflt seven', @Fam, SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
VALUES (@S, 'UTFLT_007', 'Utflt Lake', 1, 'Utflt Station 7', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990507),
       (@S2, 'UTFLT_008', 'Utflt Lake', 1, 'Utflt Station 8', 'Utflt station', 'Utflt', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 990508);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp)
VALUES (@S, @F, 130, 0, GETUTCDATE()), (@S2, @F, NULL, 0, GETUTCDATE());
SELECT @hi  = newToday FROM dbo.fn_fish_location_today(1, 1) WHERE station_Id = @S  AND fish_Id = @F;
SELECT @nul = newToday FROM dbo.fn_fish_location_today(1, 1) WHERE station_Id = @S2 AND fish_Id = @F;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@hi, -1) <> 100 OR ISNULL(@nul, -1) <> 100
   RAISERROR ('TEST 7 FAIL [%dms]: 130 must clamp to 100, NULL must count as 100', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: 130 -> 100, NULL -> 100'
IF @@TRANCOUNT > 0 ROLLBACK TRAN FLT_Test7
GO
