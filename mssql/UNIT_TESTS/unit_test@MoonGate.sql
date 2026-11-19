SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests: the moon factor counts only for a moon-sensitive fish (dbo.fish.fish_moon_sensitive = 1).
  dbo.fn_fish_location_today reads the fish's dbo.fish_lunar_catch_probability curve; a fish with a curve
  but the flag 0 (pink salmon, kokanee: curves kept, no species study) must get lunarFactor 1.
  Fixture per test: a fish (name token 'utmng') with a two-point curve (moon day 10 = 50, day 20 = 100),
  a dbo.WaterStation and a fish_location row with probability 80. No month curve, oxygen or flow group.

  TEST  1 - flag 0 with a curve -> lunarFactor 1, today 80
  TEST  2 - flag 1 with the same curve -> lunarFactor 0.5, today 40
  TEST  3 - fn_fish_reasoning_json: flag 0 -> factors.lunar 1 and week[0].lunarFactor 1
*/
PRINT 'Unit tests for the moon-sensitivity gate on lunarFactor';
GO
-- ============================================================================ TEST 1
BEGIN TRAN MNG_Test1
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(6,3), @v int;
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
     VALUES (@F, N'Utmng-fish1', N'Utmng one', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability) VALUES (@F, 10, 50), (@F, 20, 100);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTMNG_001', N'Utmng Lake', 1);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = lunarFactor, @v = newToday FROM dbo.fn_fish_location_today(6, 10) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 1 OR ISNULL(@v, 0) <> 80 RAISERROR ('TEST 1 FAIL: no moon flag must give lunar 1, 80', 16, -1)
ELSE PRINT 'TEST 1 PASS: no moon flag, curve ignored: lunar 1, 80'
ROLLBACK TRAN MNG_Test1
GO
-- ============================================================================ TEST 2
BEGIN TRAN MNG_Test2
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @k decimal(6,3), @v int;
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
     VALUES (@F, N'Utmng-fish2', N'Utmng two', SYSUTCDATETIME(), SYSUTCDATETIME(), 1, 0);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability) VALUES (@F, 10, 50), (@F, 20, 100);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTMNG_002', N'Utmng Lake', 1);
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SELECT @k = lunarFactor, @v = newToday FROM dbo.fn_fish_location_today(6, 10) WHERE station_Id = @S AND fish_Id = @F;
IF ISNULL(@k, 0) <> 0.5 OR ISNULL(@v, 0) <> 40 RAISERROR ('TEST 2 FAIL: moon flag must give lunar 0.5, 40', 16, -1)
ELSE PRINT 'TEST 2 PASS: moon flag, day 10 of best 100: lunar 0.5, 40'
ROLLBACK TRAN MNG_Test2
GO
-- ============================================================================ TEST 3
BEGIN TRAN MNG_Test3
SET NOCOUNT ON;
DECLARE @F uniqueidentifier = NEWID(), @S uniqueidentifier = NEWID(), @sid int, @j nvarchar(max);
DECLARE @at datetime2 = '2026-11-19T12:00:00', @d tinyint;
SET @d = dbo.fn_moon_day(@at);
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, created, stamp, fish_moon_sensitive, fish_migrate_pattern)
     VALUES (@F, N'Utmng-fish3', N'Utmng three', SYSUTCDATETIME(), SYSUTCDATETIME(), 0, 0);
INSERT INTO dbo.fish_lunar_catch_probability (fish_id, [day], probability)
     VALUES (@F, @d, 50), (@F, CASE WHEN @d = 28 THEN 1 ELSE @d + 1 END, 100);
INSERT INTO dbo.WaterStation (id, mli, lakeName, locType) VALUES (@S, 'UTMNG_003', N'Utmng Lake', 1);
SELECT @sid = sid FROM dbo.WaterStation WHERE id = @S;
INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, stamp) VALUES (@S, @F, 80, GETUTCDATE());
SET @j = dbo.fn_fish_reasoning_json(@sid, @F, @at);
IF ISNULL(JSON_VALUE(@j, '$.factors.lunar'), '') <> '1.000' OR ISNULL(JSON_VALUE(@j, '$.week[0].lunarFactor'), '') <> '1.000'
     RAISERROR ('TEST 3 FAIL: reasoning must show lunar 1 with no moon flag', 16, -1)
ELSE PRINT 'TEST 3 PASS: reasoning shows lunar 1 with no moon flag'
ROLLBACK TRAN MNG_Test3
GO
