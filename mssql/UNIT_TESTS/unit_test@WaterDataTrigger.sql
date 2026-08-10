SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.TR_insWaterData (AFTER INSERT trigger on dbo.WaterData that keeps
  dbo.CurrentWaterState - the "latest reading per station" cache - in sync).
  Caller: the WaterData ingestion service (water readings harvested from
  https://waterservices.usgs.gov / https://dd.weather.gc.ca are INSERTed into dbo.WaterData;
  everything else reads the current state through dbo.CurrentWaterState).

  Uses real tables dbo.Lake, dbo.WaterStation, dbo.WaterData, dbo.CurrentWaterState.
  Each test is its own named transaction, rolled back at the end of its own GO batch -
  database state fully restored.

  TEST 1 - brand-new station (NO CurrentWaterState row yet) -> the WHEN NOT MATCHED branch
           must insert a row and carry WaterStation.sid into the NOT NULL sid column
  TEST 2 - the newly inserted row maps the measurements (ph / 10, discharge -999 -> NULL)
  TEST 3 - station that already has a CurrentWaterState row -> WHEN MATCHED still updates
           in place (one row, values refreshed, sid re-stamped) - no regression
*/
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: first ever water reading for a station with no CurrentWaterState row
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01NewStationState
    DECLARE @test_name sysname = N'Test01NewStationState [TR_insWaterData] : first reading for a brand-new station'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId1 uniqueidentifier = NEWID();
DECLARE @Mli1    varchar(64)      = 'UT_TRWD_NEW1';
DECLARE @Sid1    int              = 970101;
DECLARE @rows1 int, @gotSid1 bigint, @err1 nvarchar(2048), @msg1 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a water body and a station that were just onboarded,
--    so nothing has ever written a dbo.CurrentWaterState row for them

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId1, 2, N'UT TRWD Lake 1');

INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli1, 45.51, -75.51, 'CA', N'unit-test station TRWD 1', 2, N'UT TRWD Station 1', N'', @Sid1, @LakeId1, N'UT TRWD Lake 1', 1);

-- 2. execute unit test : the ingestion service inserts the station's first reading

INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge, turbidity, oxygen, ph, elevation)
VALUES (@Mli1, '2026-08-10T12:34:00', 18, 12.5, 30, 9.5, 74, 120.5);

SELECT @rows1 = COUNT(*) FROM dbo.CurrentWaterState WHERE mli = @Mli1;
SELECT @gotSid1 = sid   FROM dbo.CurrentWaterState WHERE mli = @Mli1;

END TRY
BEGIN CATCH
    SET @err1 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;   -- a trigger failure dooms the transaction
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err1 IS NOT NULL
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: inserting the first WaterData row for a new station raised: ' + @err1;
    RAISERROR (@msg1, 16, -1)
END
ELSE IF ISNULL(@rows1, 0) <> 1 OR ISNULL(@gotSid1, -1) <> @Sid1
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 CurrentWaterState row with sid '
              + CAST(@Sid1 AS varchar) + N', got rows=' + ISNULL(CAST(@rows1 AS varchar), 'NULL')
              + N' sid=' + ISNULL(CAST(@gotSid1 AS varchar), 'NULL');
    RAISERROR (@msg1, 16, -1)
END
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: new station got a CurrentWaterState row carrying WaterStation.sid'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01NewStationState
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: the row created by WHEN NOT MATCHED maps the measurements the same way the
--         WHEN MATCHED branch does (ph stored /10, the -999 "no reading" discharge -> NULL)
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02NewStationValues
    DECLARE @test_name sysname = N'Test02NewStationValues [TR_insWaterData] : measurements mapped on the inserted row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId2 uniqueidentifier = NEWID();
DECLARE @Mli2    varchar(64)      = 'UT_TRWD_NEW2';
DECLARE @Sid2    int              = 970102;
DECLARE @Stamp2  datetime2        = '2026-08-10T12:34:00';
DECLARE @ph2 float, @disch2 float, @temp2 float, @turb2 float, @oxy2 float, @elev2 float, @st2 datetime2;
DECLARE @err2 nvarchar(2048), @msg2 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId2, 2, N'UT TRWD Lake 2');

INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli2, 45.52, -75.52, 'CA', N'unit-test station TRWD 2', 2, N'UT TRWD Station 2', N'', @Sid2, @LakeId2, N'UT TRWD Lake 2', 1);

-- 2. execute unit test : ph 74 -> 7.4, discharge -999 (the source's "missing" marker) -> NULL

INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge, turbidity, oxygen, ph, elevation)
VALUES (@Mli2, @Stamp2, 21, -999, 45, 8.25, 74, 233.75);

SELECT @temp2 = temperature, @disch2 = discharge, @turb2 = turbidity, @oxy2 = oxygen
     , @ph2 = ph, @elev2 = elevation, @st2 = stamp
  FROM dbo.CurrentWaterState WHERE mli = @Mli2;

END TRY
BEGIN CATCH
    SET @err2 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err2 IS NOT NULL
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: WaterData insert raised: ' + @err2;
    RAISERROR (@msg2, 16, -1)
END
ELSE IF @ph2 IS NULL OR ABS(@ph2 - 7.4) > 0.0001 OR @disch2 IS NOT NULL
     OR ISNULL(@temp2, -1) <> 21 OR ISNULL(@turb2, -1) <> 45 OR ABS(ISNULL(@oxy2, -1) - 8.25) > 0.0001
     OR ABS(ISNULL(@elev2, -1) - 233.75) > 0.0001 OR ISNULL(@st2, '1900-01-01') <> @Stamp2
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected ph=7.4 discharge=NULL temp=21 turb=45 oxy=8.25 elev=233.75, got ph='
              + ISNULL(CAST(@ph2 AS varchar), 'NULL') + N' discharge=' + ISNULL(CAST(@disch2 AS varchar), 'NULL')
              + N' temp=' + ISNULL(CAST(@temp2 AS varchar), 'NULL') + N' turb=' + ISNULL(CAST(@turb2 AS varchar), 'NULL')
              + N' oxy=' + ISNULL(CAST(@oxy2 AS varchar), 'NULL') + N' elev=' + ISNULL(CAST(@elev2 AS varchar), 'NULL')
              + N' stamp=' + ISNULL(CONVERT(varchar(30), @st2, 126), 'NULL');
    RAISERROR (@msg2, 16, -1)
END
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: inserted state has ph/10, -999 discharge nulled and the reading copied'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02NewStationValues
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: station that already has a CurrentWaterState row -> updated in place (no regression)
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03ExistingStateUpd
    DECLARE @test_name sysname = N'Test03ExistingStateUpd [TR_insWaterData] : existing state row updated, not duplicated'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId3 uniqueidentifier = NEWID();
DECLARE @Mli3    varchar(64)      = 'UT_TRWD_OLD3';
DECLARE @Sid3    int              = 970103;
DECLARE @rows3 int, @gotSid3 bigint, @temp3 float, @ph3 float, @err3 nvarchar(2048), @msg3 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a long-standing station that already has a cached state
--    row holding a stale reading and a stale sid

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId3, 2, N'UT TRWD Lake 3');

INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli3, 45.53, -75.53, 'CA', N'unit-test station TRWD 3', 2, N'UT TRWD Station 3', N'', @Sid3, @LakeId3, N'UT TRWD Lake 3', 1);

INSERT INTO dbo.CurrentWaterState (mli, stamp, temperature, ph, sid, iterstamp)
VALUES (@Mli3, '2026-08-01T00:00:00', 4, 6.1, 111111, GETUTCDATE());

-- 2. execute unit test

INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge, turbidity, oxygen, ph, elevation)
VALUES (@Mli3, '2026-08-10T12:34:00', 19, 3.5, 12, 7.5, 68, 15.0);

SELECT @rows3 = COUNT(*) FROM dbo.CurrentWaterState WHERE mli = @Mli3;
SELECT @gotSid3 = sid, @temp3 = temperature, @ph3 = ph FROM dbo.CurrentWaterState WHERE mli = @Mli3;

END TRY
BEGIN CATCH
    SET @err3 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err3 IS NOT NULL
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: WaterData insert raised: ' + @err3;
    RAISERROR (@msg3, 16, -1)
END
ELSE IF ISNULL(@rows3, 0) <> 1 OR ISNULL(@gotSid3, -1) <> @Sid3 OR ISNULL(@temp3, -1) <> 19
     OR @ph3 IS NULL OR ABS(@ph3 - 6.8) > 0.0001
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 row sid=' + CAST(@Sid3 AS varchar)
              + N' temp=19 ph=6.8, got rows=' + ISNULL(CAST(@rows3 AS varchar), 'NULL')
              + N' sid=' + ISNULL(CAST(@gotSid3 AS varchar), 'NULL')
              + N' temp=' + ISNULL(CAST(@temp3 AS varchar), 'NULL')
              + N' ph=' + ISNULL(CAST(@ph3 AS varchar), 'NULL');
    RAISERROR (@msg3, 16, -1)
END
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: existing state row updated in place with the new reading and station sid'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03ExistingStateUpd
GO
