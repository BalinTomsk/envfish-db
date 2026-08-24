SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_map_fish_list_nearest_station -- sport species (max length > 10 cm)
  recorded at the single WaterStation closest to a coordinate.

  Caller: FishTracker.TUserList.AppendNearestStationSpecies (Forecast/Planning.aspx.cs) -- for a
  registered (non-trial) visitor, up to 10 of these not already in the region's top-15
  (dbo.fn_map_fish_list_bystate) are appended to the "Select desire fish" combobox.

  "Closest" is the nearest station by squared lat/lon distance (a planar approximation, adequate
  at map scale) -- there is exactly ONE nearest station per call, and every species returned comes
  from that one station's dbo.fish_location rows.

  Uses real tables dbo.fish / dbo.fish_zoo / dbo.fish_location / dbo.WaterStation. Each test runs
  in its own named transaction, rolled back at the end of its own GO batch.

  TEST 1 - picks the nearer of two stations, not the farther one
  TEST 2 - size filter: only species with fish_zoo.fish_max_length > 10 are returned
  TEST 3 - sport-fish filter: a non-sport species at the same station is excluded
  TEST 4 - country scoping: a station in a different country, even if geographically closer, is
           never selected
*/

-- ===================================================================================
-- TEST 1: the nearer of two candidate stations wins
-- ===================================================================================
BEGIN TRAN Test01NearestStationPicksCloser
    DECLARE @test_name sysname = N'Test01NearestStationPicksCloser [fn_map_fish_list_nearest_station] : nearer station wins'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Near uniqueidentifier = NEWID(), @Far uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@Near, N'UT_NST_N', 'ON', 50.00, -95.00, 'CA', N'UT NST NEAR', 2, N'UT NST Near', N'', 990601, N'UT NST Lake', 1),
       (@Far,  N'UT_NST_F', 'ON', 55.00, -95.00, 'CA', N'UT NST FAR',  2, N'UT NST Far',  N'', 990602, N'UT NST Lake', 1);

DECLARE @NearFish uniqueidentifier = NEWID(), @FarFish uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@NearFish, 'UT NST NearFish', 'Ut nst nearfish', 1, 1),
  (@FarFish,  'UT NST FarFish',  'Ut nst farfish',  1, 1);
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) VALUES (@NearFish, 40), (@FarFish, 40);
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) VALUES
  (@Near, @NearFish, GETUTCDATE()), (@Far, @FarFish, GETUTCDATE());

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_nearest_station(50.00, -95.00, 'CA')
WHERE fish_name LIKE 'UT NST %';

SET @expected = N'UT NST NearFish';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: species from the nearer station returned, farther station ignored';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test01NearestStationPicksCloser
GO

-- ===================================================================================
-- TEST 2: size filter -- only fish_max_length > 10 cm species are returned
-- ===================================================================================
BEGIN TRAN Test02NearestStationSizeFilter
    DECLARE @test_name sysname = N'Test02NearestStationSizeFilter [fn_map_fish_list_nearest_station] : length > 10cm only'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @St uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@St, N'UT_NST_2', 'ON', 51.00, -95.00, 'CA', N'UT NST STATION 2', 2, N'UT NST Station 2', N'', 990603, N'UT NST Lake', 1);

DECLARE @Big uniqueidentifier = NEWID(), @TooSmall uniqueidentifier = NEWID(), @Boundary uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@Big,      'UT NST Big',      'Ut nst big',      1, 1),
  (@TooSmall, 'UT NST TooSmall', 'Ut nst toosmall', 1, 1),
  (@Boundary, 'UT NST Boundary', 'Ut nst boundary', 1, 1);
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) VALUES
  (@Big, 40),        -- > 10 -> keep
  (@TooSmall, 8),    -- < 10 -> drop
  (@Boundary, 10);   -- = 10, filter is strictly > 10 -> drop
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) VALUES
  (@St, @Big, GETUTCDATE()), (@St, @TooSmall, GETUTCDATE()), (@St, @Boundary, GETUTCDATE());

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_nearest_station(51.00, -95.00, 'CA')
WHERE fish_name LIKE 'UT NST %';

SET @expected = N'UT NST Big';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: too-small and exactly-10cm species dropped, >10cm kept';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test02NearestStationSizeFilter
GO

-- ===================================================================================
-- TEST 3: sport-fish filter -- a non-sport species at the same station is excluded
-- ===================================================================================
BEGIN TRAN Test03NearestStationSportFilter
    DECLARE @test_name sysname = N'Test03NearestStationSportFilter [fn_map_fish_list_nearest_station] : sport fish only'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @St uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@St, N'UT_NST_3', 'ON', 52.00, -95.00, 'CA', N'UT NST STATION 3', 2, N'UT NST Station 3', N'', 990604, N'UT NST Lake', 1);

DECLARE @Sport uniqueidentifier = NEWID(), @NotSport uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@Sport,    'UT NST Sport',    'Ut nst sport',    1, 1),   -- fish_Type bit 1 set -> keep
  (@NotSport, 'UT NST NotSport', 'Ut nst notsport', 2, 1);   -- fish_Type bit 1 clear -> drop
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) VALUES (@Sport, 40), (@NotSport, 40);
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) VALUES
  (@St, @Sport, GETUTCDATE()), (@St, @NotSport, GETUTCDATE());

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_nearest_station(52.00, -95.00, 'CA')
WHERE fish_name LIKE 'UT NST %';

SET @expected = N'UT NST Sport';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: non-sport species dropped, sport species kept';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test03NearestStationSportFilter
GO

-- ===================================================================================
-- TEST 4: country scoping -- a geographically closer station in a different country is
--         never selected
-- ===================================================================================
BEGIN TRAN Test04NearestStationCountryScope
    DECLARE @test_name sysname = N'Test04NearestStationCountryScope [fn_map_fish_list_nearest_station] : country scoping'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- @CloserWrongCountry sits exactly at the query point but is tagged US; @FartherRightCountry is
-- 1 degree away but tagged CA. The CA station must win even though it is farther away.
DECLARE @CloserWrongCountry uniqueidentifier = NEWID(), @FartherRightCountry uniqueidentifier = NEWID();
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, supported)
VALUES (@CloserWrongCountry,   N'UT_NST_4A', 'MN', 53.00, -95.00, 'US', N'UT NST WRONG COUNTRY', 2, N'UT NST Wrong', N'', 990605, N'UT NST Lake', 1),
       (@FartherRightCountry,  N'UT_NST_4B', 'ON', 54.00, -95.00, 'CA', N'UT NST RIGHT COUNTRY', 2, N'UT NST Right', N'', 990606, N'UT NST Lake', 1);

DECLARE @WrongFish uniqueidentifier = NEWID(), @RightFish uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@WrongFish, 'UT NST WrongCountryFish', 'Ut nst wrongfish', 1, 1),
  (@RightFish, 'UT NST RightCountryFish', 'Ut nst rightfish', 1, 1);
INSERT INTO dbo.fish_zoo (fish_id, fish_max_length) VALUES (@WrongFish, 40), (@RightFish, 40);
INSERT INTO dbo.fish_location (station_Id, fish_Id, stamp) VALUES
  (@CloserWrongCountry, @WrongFish, GETUTCDATE()), (@FartherRightCountry, @RightFish, GETUTCDATE());

-- Query at the exact coordinate of the wrong-country station, asking for CA.
SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY fish_name)
FROM dbo.fn_map_fish_list_nearest_station(53.00, -95.00, 'CA')
WHERE fish_name LIKE 'UT NST %';

SET @expected = N'UT NST RightCountryFish';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: farther same-country station won over closer wrong-country station';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test04NearestStationCountryScope
GO
