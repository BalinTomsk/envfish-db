SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_map_fish_list_bystate and dbo.fn_map_fish_list_bystate_trial (the region's
  ranked top-15 for the Forecast/Planning.aspx "Select desire fish" combobox).

  Caller: FishTracker.TUserList.LoadInitialFishes / FillFishListByState (Forecast/Planning.aspx.cs).

  Both functions are plain filtered reads of dbo.fish_region_top -- no lat/lon/proximity join (an
  earlier design intersected the region list against dbo.fn_map_fish_list_bylatlon, which cut most
  regions down to a handful of species wherever nearby station coverage was thin; dropped once
  "every region must offer its 15" became the requirement). Both additionally filter to the
  freshwater bit of dbo.fish.water_type, and both currently behave identically -- the seed data is
  freshwater-only by curation, so there is no trial-vs-registered distinction here; the runtime
  filter is a safety net against a future non-freshwater row being added to the table.

  Uses real tables dbo.fish / dbo.fish_region_top. Each test runs in its own named transaction,
  rolled back at the end of its own GO batch.

  TEST 1 - returns exactly the fixture's ranked rows, ordered by top_rank
  TEST 2 - a fixture row that is NOT freshwater (water_type bit 1 clear) is excluded from both
           variants, even though it is a resolved, correctly-ranked row in the table
  TEST 3 - a fixture row with fish_id NULL (unresolved name) is never offered
  TEST 4 - region scoping: the same state code under a different country does not leak, and an
           unknown region returns zero rows (not an error)
  TEST 5 - fn_map_fish_list_bystate_trial matches fn_map_fish_list_bystate row-for-row for the same
           fixture (both apply the same freshwater filter, by current design)
*/

-- ===================================================================================
-- TEST 1: ranked rows for a known region, in top_rank order
-- ===================================================================================
BEGIN TRAN Test01MapByStateRanked
    DECLARE @test_name sysname = N'Test01MapByStateRanked [fn_map_fish_list_bystate] : returns ranked fixture rows'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @F1 uniqueidentifier = NEWID(), @F2 uniqueidentifier = NEWID(), @F3 uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@F1, 'UT MBS Rank1', 'Ut mbs rank1', 1, 1),
  (@F2, 'UT MBS Rank2', 'Ut mbs rank2', 1, 1),
  (@F3, 'UT MBS Rank3', 'Ut mbs rank3', 1, 1);

INSERT INTO dbo.fish_region_top (country, state, top_rank, common_name, fish_name, fish_id) VALUES
  ('US', 'T1', 2, 'UT MBS Rank2', 'UT MBS Rank2', @F2),
  ('US', 'T1', 1, 'UT MBS Rank1', 'UT MBS Rank1', @F1),
  ('US', 'T1', 3, 'UT MBS Rank3', 'UT MBS Rank3', @F3);

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY top_rank)
FROM dbo.fn_map_fish_list_bystate('US', 'T1');

SET @expected = N'UT MBS Rank1,UT MBS Rank2,UT MBS Rank3';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: region list returned in top_rank order';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test01MapByStateRanked
GO

-- ===================================================================================
-- TEST 2: a non-freshwater fixture row is excluded even though it is resolved and ranked
-- ===================================================================================
BEGIN TRAN Test02MapByStateFreshwaterOnly
    DECLARE @test_name sysname = N'Test02MapByStateFreshwaterOnly [fn_map_fish_list_bystate] : non-freshwater row excluded'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Fresh uniqueidentifier = NEWID(), @Salt uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@Fresh, 'UT MBS Fresh', 'Ut mbs fresh', 1, 1),   -- freshwater bit set -> keep
  (@Salt,  'UT MBS Salt',  'Ut mbs salt',  1, 2);   -- saltwater only     -> drop

INSERT INTO dbo.fish_region_top (country, state, top_rank, common_name, fish_name, fish_id) VALUES
  ('US', 'T2', 1, 'UT MBS Fresh', 'UT MBS Fresh', @Fresh),
  ('US', 'T2', 2, 'UT MBS Salt',  'UT MBS Salt',  @Salt);

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY top_rank)
FROM dbo.fn_map_fish_list_bystate('US', 'T2');

SET @expected = N'UT MBS Fresh';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: saltwater-only fixture row dropped, freshwater row kept';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test02MapByStateFreshwaterOnly
GO

-- ===================================================================================
-- TEST 3: an unresolved row (fish_id NULL) is never offered
-- ===================================================================================
BEGIN TRAN Test03MapByStateUnresolvedRow
    DECLARE @test_name sysname = N'Test03MapByStateUnresolvedRow [fn_map_fish_list_bystate] : fish_id NULL excluded'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @kept nvarchar(400), @expected nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Ok uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@Ok, 'UT MBS Resolved', 'Ut mbs resolved', 1, 1);

INSERT INTO dbo.fish_region_top (country, state, top_rank, common_name, fish_name, fish_id) VALUES
  ('US', 'T3', 1, 'UT MBS Resolved',   'UT MBS Resolved',   @Ok),
  ('US', 'T3', 2, 'UT MBS Unresolved', NULL,                NULL);   -- group name, never matched

SELECT @kept = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY top_rank)
FROM dbo.fn_map_fish_list_bystate('US', 'T3');

SET @expected = N'UT MBS Resolved';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @kept = @expected
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unresolved (fish_id NULL) row never offered';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: expected [%s], got [%s]', 16, -1, @ElapsedMs, @expected, @kept);

ROLLBACK TRAN Test03MapByStateUnresolvedRow
GO

-- ===================================================================================
-- TEST 4: region scoping -- same state code under a different country does not leak,
--         and an unknown region returns zero rows rather than erroring
-- ===================================================================================
BEGIN TRAN Test04MapByStateRegionScoping
    DECLARE @test_name sysname = N'Test04MapByStateRegionScoping [fn_map_fish_list_bystate] : country/state scoping'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @usCount int, @caCount int, @unknownCount int;
DECLARE @usName nvarchar(64), @caName nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @UsFish uniqueidentifier = NEWID(), @CaFish uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@UsFish, 'UT MBS US Only', 'Ut mbs us', 1, 1),
  (@CaFish, 'UT MBS CA Only', 'Ut mbs ca', 1, 1);

-- Deliberately the SAME two-letter code ('T4') under both countries, to prove the PK/WHERE
-- clause scopes on (country, state) together, not state alone.
INSERT INTO dbo.fish_region_top (country, state, top_rank, common_name, fish_name, fish_id) VALUES
  ('US', 'T4', 1, 'UT MBS US Only', 'UT MBS US Only', @UsFish),
  ('CA', 'T4', 1, 'UT MBS CA Only', 'UT MBS CA Only', @CaFish);

SELECT @usCount = COUNT(*), @usName = MAX(fish_name) FROM dbo.fn_map_fish_list_bystate('US', 'T4');
SELECT @caCount = COUNT(*), @caName = MAX(fish_name) FROM dbo.fn_map_fish_list_bystate('CA', 'T4');
SELECT @unknownCount = COUNT(*) FROM dbo.fn_map_fish_list_bystate('US', 'ZZ');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @usCount = 1 AND @usName = N'UT MBS US Only' AND @caCount = 1 AND @caName = N'UT MBS CA Only' AND @unknownCount = 0
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US/T4 and CA/T4 stayed separate, unknown region returned 0 rows';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: usCount=%d usName=[%s] caCount=%d caName=[%s] unknownCount=%d', 16, -1,
        @ElapsedMs, @usCount, @usName, @caCount, @caName, @unknownCount);

ROLLBACK TRAN Test04MapByStateRegionScoping
GO

-- ===================================================================================
-- TEST 5: the trial variant matches the registered variant row-for-row (same freshwater
--         filter, by current design -- pinned so a future divergence is a deliberate change)
-- ===================================================================================
BEGIN TRAN Test05MapByStateTrialMatch
    DECLARE @test_name sysname = N'Test05MapByStateTrialMatch [fn_map_fish_list_bystate_trial] : matches registered variant'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @registered nvarchar(400), @trial nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Fresh5 uniqueidentifier = NEWID(), @Salt5 uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, fish_Type, water_type) VALUES
  (@Fresh5, 'UT MBS T5 Fresh', 'Ut mbs t5 fresh', 1, 1),
  (@Salt5,  'UT MBS T5 Salt',  'Ut mbs t5 salt',  1, 2);

INSERT INTO dbo.fish_region_top (country, state, top_rank, common_name, fish_name, fish_id) VALUES
  ('US', 'T5', 1, 'UT MBS T5 Fresh', 'UT MBS T5 Fresh', @Fresh5),
  ('US', 'T5', 2, 'UT MBS T5 Salt',  'UT MBS T5 Salt',  @Salt5);

SELECT @registered = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY top_rank)
FROM dbo.fn_map_fish_list_bystate('US', 'T5');

SELECT @trial = STRING_AGG(CAST(fish_name AS nvarchar(MAX)), ',') WITHIN GROUP (ORDER BY top_rank)
FROM dbo.fn_map_fish_list_bystate_trial('US', 'T5');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @registered = @trial AND @registered = N'UT MBS T5 Fresh'
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: trial and registered variants returned the same freshwater-only list';
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: registered=[%s] trial=[%s]', 16, -1, @ElapsedMs, @registered, @trial);

ROLLBACK TRAN Test05MapByStateTrialMatch
GO
