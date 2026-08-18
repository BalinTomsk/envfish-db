SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_map_fish_list_bylatlon_trial and dbo.fn_map_fish_list_bylatlon
  (the sport-fish shortlist the forecast map offers for a coordinate).

  Caller: FishTracker.Forecast.Planning.LoadInitialFishes -- the _trial variant is chosen for
  trial users, the plain one for registered users (see "Trial vs. registered users" in the
  frontend CLAUDE.md).

  Focus: dbo.fish.water_type is a BITMASK (1 Freshwater, 2 Saltwater, 4 Clear water,
  8 Low velocity, ...), and the _trial variant tested it with "water_type = 1", which keeps
  only species tagged freshwater AND NOTHING ELSE. On the live database that drops 6 of the
  22 eligible sport species -- Cisco Shortjaw (5 = Fresh+Clear), Whitefish Round (7),
  Bass Guadalupe (9 = Fresh+Low velocity), Herring Blueback (3 = Fresh+Salt) among them.
  The very same function already treats fish_Type as a mask one line above, so the two
  predicates disagreed about what the columns mean.

  Uses real tables dbo.fish / dbo.fish_zoo / dbo.fish_location / dbo.WaterStation.
  Each test runs in its own named transaction, rolled back at the end of its own GO batch.

  TEST 1 - the trial list keeps every species carrying the Freshwater bit, not just
           water_type = 1, and still excludes saltwater-only / 0 / NULL
  TEST 2 - the other predicates are unchanged: non-sport fish, an over-long fish, and a
           fish whose station is out of range are all still excluded
  TEST 3 - the non-trial variant has no water_type predicate at all (its line is commented
           out in source) and must keep returning species of every water type
*/

-- ===================================================================================
-- TEST 1: freshwater is a BIT, not a value
-- ===================================================================================
BEGIN TRAN Test01MapTrialWaterMask
    DECLARE @test_name sysname = N'Test01MapTrialWaterMask [fn_map_fish_list_bylatlon_trial] : Freshwater matched as a bit'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @St uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@St, N'UT_MFL_1', 'ON', 50.0, -95.0, 'CA', N'UT MFL STATION', 2, N'UT MFL Station', N'', 990501, N'UT MFL Lake', 1);

DECLARE @t TABLE (id uniqueidentifier, nm varchar(32), wt int);
INSERT INTO @t VALUES
  (NEWID(), 'UT MFL W1 Plain',   1),      -- Freshwater                  -> keep
  (NEWID(), 'UT MFL W3 Diadrom', 3),      -- Freshwater + Saltwater      -> keep
  (NEWID(), 'UT MFL W5 Clear',   5),      -- Freshwater + Clear water    -> keep
  (NEWID(), 'UT MFL W9 Slow',    9),      -- Freshwater + Low velocity   -> keep
  (NEWID(), 'UT MFL W2 Salt',    2),      -- Saltwater only              -> drop
  (NEWID(), 'UT MFL W0 Zero',    0),      -- nothing recorded            -> drop
  (NEWID(), 'UT MFL WN Null',    NULL);   -- nothing recorded            -> drop

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type)
    SELECT id, nm, 'Ut mfl ' + LOWER(REPLACE(nm, 'UT MFL ', '')), 1, wt FROM @t;
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) SELECT id, 40 FROM @t;   -- < 65 and > 25
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) SELECT @St, id, GETUTCDATE() FROM @t;

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_bylatlon_trial(50.0, -95.0, 'CA')
WHERE fish_name LIKE 'UT MFL %';

SET @expected = N'UT MFL W1 Plain,UT MFL W3 Diadrom,UT MFL W5 Clear,UT MFL W9 Slow';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: trial map list kept plain and combined freshwater, dropped salt-only/0/NULL';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test01MapTrialWaterMask
GO

-- ===================================================================================
-- TEST 2: the change must widen ONLY the water-type predicate. The sport-fish mask, the
--         size ceiling and the coordinate window keep excluding what they always did.
-- ===================================================================================
BEGIN TRAN Test02MapTrialOtherFilters
    DECLARE @test_name sysname = N'Test02MapTrialOtherFilters [fn_map_fish_list_bylatlon_trial] : other predicates unchanged'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Near uniqueidentifier = NEWID(), @Far uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@Near, N'UT_MFL_N', 'ON', 50.0, -95.0, 'CA', N'UT MFL NEAR', 2, N'UT MFL Near', N'', 990502, N'UT MFL Lake', 1),
       (@Far,  N'UT_MFL_F', 'ON', 80.0, -20.0, 'CA', N'UT MFL FAR',  2, N'UT MFL Far',  N'', 990503, N'UT MFL Lake', 1);

DECLARE @ok uniqueidentifier = NEWID(), @notSport uniqueidentifier = NEWID(),
        @tooBig uniqueidentifier = NEWID(), @faraway uniqueidentifier = NEWID();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@ok,       'UT MFL Keep',     'Ut mfl keep',  1, 5),   -- sport, combined freshwater -> keep
  (@notSport, 'UT MFL NotSport', 'Ut mfl nosp',  2, 5),   -- fish_Type bit 1 clear      -> drop
  (@tooBig,   'UT MFL TooBig',   'Ut mfl big',   1, 5),   -- max_length >= 65           -> drop
  (@faraway,  'UT MFL FarAway',  'Ut mfl far',   1, 5);   -- station out of range       -> drop

INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) VALUES (@ok, 40), (@notSport, 40), (@tooBig, 90), (@faraway, 40);
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) VALUES
  (@Near, @ok, GETUTCDATE()), (@Near, @notSport, GETUTCDATE()),
  (@Near, @tooBig, GETUTCDATE()), (@Far, @faraway, GETUTCDATE());

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_bylatlon_trial(50.0, -95.0, 'CA')
WHERE fish_name LIKE 'UT MFL %';

SET @expected = N'UT MFL Keep';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: non-sport, oversized and out-of-range species stayed excluded';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test02MapTrialOtherFilters
GO

-- ===================================================================================
-- TEST 3: the registered-user variant filters on no water type at all -- its line is
--         commented out in source. Pinned so nobody "fixes" it into a freshwater filter
--         by symmetry with the trial one and silently narrows the map for real users.
-- ===================================================================================
BEGIN TRAN Test03MapPlainNoWaterFilter
    DECLARE @test_name sysname = N'Test03MapPlainNoWaterFilter [fn_map_fish_list_bylatlon] : no water_type predicate'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @St3 uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@St3, N'UT_MFL_3', 'ON', 50.0, -95.0, 'CA', N'UT MFL STATION 3', 2, N'UT MFL Station 3', N'', 990504, N'UT MFL Lake', 1);

DECLARE @t3 TABLE (id uniqueidentifier, nm varchar(32), wt int);
INSERT INTO @t3 VALUES
  (NEWID(), 'UT MFL P1 Fresh', 1),
  (NEWID(), 'UT MFL P2 Salt',  2),        -- saltwater: kept, this variant does not filter
  (NEWID(), 'UT MFL P5 Clear', 5);

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type)
    SELECT id, nm, 'Ut mfl ' + LOWER(REPLACE(nm, 'UT MFL ', '')), 1, wt FROM @t3;
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) SELECT id, 40 FROM @t3;   -- > 25
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) SELECT @St3, id, GETUTCDATE() FROM @t3;

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_bylatlon(50.0, -95.0, 'CA', 3)
WHERE fish_name LIKE 'UT MFL %';

SET @expected = N'UT MFL P1 Fresh,UT MFL P2 Salt,UT MFL P5 Clear';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the registered-user variant returned every water type, as it always has';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test03MapPlainNoWaterFilter
GO
