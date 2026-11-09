SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the oxygen factor of dbo.spTotalUpdateProbability (dbo.fn_habitat_koef via
  dbo.fn_fish_location_today; the fixture fish have no month or lunar curve, so only this factor applies).
  Water temperature is no longer a station reading (removed 2026-11-08), so a fish's temperature habitat
  rule (ri_type 17) must not change the probability any more.
  Uses real tables dbo.fish, dbo.fish_Rule, dbo.real_interval, dbo.WaterStation,
  dbo.CurrentWaterState, dbo.fish_location - each test uses a fresh fish/station id and a
  unique mli value, so merging into one shared transaction does not create cross-test
  interference. Transaction is rolled back at end - database state restored.

  TEST 1 - a temperature habitat rule no longer affects today (today = probability)
  TEST 2 - oxygen at optimal -> 100% coefficient
  TEST 3 - oxygen outside viable range -> 0% coefficient
  TEST 4 - oxygen at 90% zone
*/
SET NOCOUNT ON;

DECLARE @tStart    datetime2;
DECLARE @ElapsedMs int;

BEGIN TRY
    BEGIN TRANSACTION;

    -- ----------------------------------------------------------------
    -- TEST 1: a temperature habitat rule no longer affects today
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @FishId4 uniqueidentifier = NEWID();
    DECLARE @StationId4 uniqueidentifier = NEWID();
    DECLARE @RuleId4 uniqueidentifier;
    DECLARE @Mli4 varchar(64) = 'TEST_MLI_004';
    INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, stamp, numRuls, locked, fish_moon_sensitive, fish_migrate_pattern, fish_ability)
    VALUES (@FishId4, 'Test Fish 4', 'Testus fishus4', (SELECT TOP 1 Family_id FROM dbo.fish_family), GETUTCDATE(), 0, 0, 0, 0, 0);
    SELECT @RuleId4 = id FROM dbo.fish_Rule WHERE fish_Id = @FishId4 AND periodStart = -1 AND periodEnd = -1;
    INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_avg, ri_high, ri_max, ri_stamp)
    VALUES (@RuleId4, 17, 10.0, 12.0, 15.0, 18.0, 20.0, GETUTCDATE());
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
    VALUES (@StationId4, @Mli4, 'Test Lake 4', 1, 'Test Station 4', 'Test Station Description', 'Test County', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 999);
    INSERT INTO dbo.CurrentWaterState (mli, discharge, stamp, iterstamp, sid)
    VALUES (@Mli4, 3.5, GETUTCDATE(), GETUTCDATE(), 999);
    INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp)
    VALUES (@StationId4, @FishId4, 100, 100, GETUTCDATE());
    EXEC dbo.spTotalUpdateProbability;
    DECLARE @R4 int; SELECT @R4 = today FROM dbo.fish_location WHERE station_Id = @StationId4 AND fish_Id = @FishId4;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R4 = 100 PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: temperature habitat rule ignored -> factor 1';
    ELSE PRINT 'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: expected 100, got ' + CAST(ISNULL(@R4, -999) AS varchar);

    -- ----------------------------------------------------------------
    -- TEST 2: oxygen at optimal
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @FishId5 uniqueidentifier = NEWID();
    DECLARE @StationId5 uniqueidentifier = NEWID();
    DECLARE @RuleId5 uniqueidentifier;
    DECLARE @Mli5 varchar(64) = 'TEST_MLI_005';
    INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, stamp, numRuls, locked, fish_moon_sensitive, fish_migrate_pattern, fish_ability)
    VALUES (@FishId5, 'Test Fish 5', 'Testus fishus5', (SELECT TOP 1 Family_id FROM dbo.fish_family), GETUTCDATE(), 0, 0, 0, 0, 0);
    SELECT @RuleId5 = id FROM dbo.fish_Rule WHERE fish_Id = @FishId5 AND periodStart = -1 AND periodEnd = -1;
    INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_avg, ri_high, ri_max, ri_stamp)
    VALUES (@RuleId5, 33, 6.0, 7.0, 8.0, 9.0, 10.0, GETUTCDATE());
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
    VALUES (@StationId5, @Mli5, 'Test Lake 5', 1, 'Test Station 5', 'Test Station Description', 'Test County', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 999);
    INSERT INTO dbo.CurrentWaterState (mli, oxygen, stamp, iterstamp, sid)
    VALUES (@Mli5, 8.0, GETUTCDATE(), GETUTCDATE(), 999);
    INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp)
    VALUES (@StationId5, @FishId5, 100, 100, GETUTCDATE());
    EXEC dbo.spTotalUpdateProbability;
    DECLARE @R5 int; SELECT @R5 = today FROM dbo.fish_location WHERE station_Id = @StationId5 AND fish_Id = @FishId5;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R5 = 100 PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: oxygen at optimal -> 100% coefficient';
    ELSE PRINT 'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: expected 100, got ' + CAST(ISNULL(@R5, -999) AS varchar);

    -- ----------------------------------------------------------------
    -- TEST 3: oxygen outside viable range
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @FishId6 uniqueidentifier = NEWID();
    DECLARE @StationId6 uniqueidentifier = NEWID();
    DECLARE @RuleId6 uniqueidentifier;
    DECLARE @Mli6 varchar(64) = 'TEST_MLI_006';
    INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, stamp, numRuls, locked, fish_moon_sensitive, fish_migrate_pattern, fish_ability)
    VALUES (@FishId6, 'Test Fish 6', 'Testus fishus6', (SELECT TOP 1 Family_id FROM dbo.fish_family), GETUTCDATE(), 0, 0, 0, 0, 0);
    SELECT @RuleId6 = id FROM dbo.fish_Rule WHERE fish_Id = @FishId6 AND periodStart = -1 AND periodEnd = -1;
    INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_avg, ri_high, ri_max, ri_stamp)
    VALUES (@RuleId6, 33, 6.0, 7.0, 8.0, 9.0, 10.0, GETUTCDATE());
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
    VALUES (@StationId6, @Mli6, 'Test Lake 6', 1, 'Test Station 6', 'Test Station Description', 'Test County', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 999);
    INSERT INTO dbo.CurrentWaterState (mli, oxygen, stamp, iterstamp, sid)
    VALUES (@Mli6, 4.0, GETUTCDATE(), GETUTCDATE(), 999);
    INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp)
    VALUES (@StationId6, @FishId6, 100, 100, GETUTCDATE());
    EXEC dbo.spTotalUpdateProbability;
    DECLARE @R6 int; SELECT @R6 = today FROM dbo.fish_location WHERE station_Id = @StationId6 AND fish_Id = @FishId6;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R6 = 0 PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: oxygen outside viable range -> 0% coefficient';
    ELSE PRINT 'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: expected 0, got ' + CAST(ISNULL(@R6, -999) AS varchar);

    -- ----------------------------------------------------------------
    -- TEST 4: oxygen at 90% zone
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @FishId7 uniqueidentifier = NEWID();
    DECLARE @StationId7 uniqueidentifier = NEWID();
    DECLARE @RuleId7 uniqueidentifier;
    DECLARE @Mli7 varchar(64) = 'TEST_MLI_007';
    INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, stamp, numRuls, locked, fish_moon_sensitive, fish_migrate_pattern, fish_ability)
    VALUES (@FishId7, 'Test Fish 7', 'Testus fishus7', (SELECT TOP 1 Family_id FROM dbo.fish_family), GETUTCDATE(), 0, 0, 0, 0, 0);
    SELECT @RuleId7 = id FROM dbo.fish_Rule WHERE fish_Id = @FishId7 AND periodStart = -1 AND periodEnd = -1;
    INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_avg, ri_high, ri_max, ri_stamp)
    VALUES (@RuleId7, 33, 6.0, 7.0, 8.0, 9.0, 10.0, GETUTCDATE());
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
    VALUES (@StationId7, @Mli7, 'Test Lake 7', 1, 'Test Station 7', 'Test Station Description', 'Test County', 45.0, -75.0, 'CA', 'ON', 'TEST', GETUTCDATE(), 1, 999);
    INSERT INTO dbo.CurrentWaterState (mli, oxygen, stamp, iterstamp, sid)
    VALUES (@Mli7, 7.0, GETUTCDATE(), GETUTCDATE(), 999);
    INSERT INTO dbo.fish_location (station_Id, fish_Id, probability, today, stamp)
    VALUES (@StationId7, @FishId7, 100, 100, GETUTCDATE());
    EXEC dbo.spTotalUpdateProbability;
    DECLARE @R7 int; SELECT @R7 = today FROM dbo.fish_location WHERE station_Id = @StationId7 AND fish_Id = @FishId7;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R7 = 90 PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: oxygen at 90% zone';
    ELSE PRINT 'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: expected 90, got ' + CAST(ISNULL(@R7, -999) AS varchar);

    ROLLBACK TRANSACTION;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'EXCEPTION during test: ' + ERROR_MESSAGE()
        + '  (proc=' + ISNULL(ERROR_PROCEDURE(), 'n/a')
        + ', line='  + CAST(ERROR_LINE() AS varchar) + ')';
END CATCH;
