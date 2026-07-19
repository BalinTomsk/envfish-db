SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for water-station-pusher HTTP 503 backoff procedures.
  Backoff state is stored on dbo.WaterStation and vwWaterStation only returns supported stations.
*/
SET NOCOUNT ON;

BEGIN TRAN Test01Water503Daily
DECLARE @test_name sysname;
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @stationId uniqueidentifier;
DECLARE @mli varchar(64);
DECLARE @backoffstate int, @daily int, @weekly int, @supported bit, @viewCount int;
DECLARE @next date;
BEGIN TRY
    SET @test_name = N'Test01WaterStation503DailyToWeekly';
    SET @stationId = NEWID();
    SET @mli = 'UTW503D' + RIGHT(REPLACE(CONVERT(varchar(36), @stationId), '-', ''), 12);
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
    VALUES (@stationId, @mli, 'Unit Lake', 1, 'Unit Water Station Daily', 'Unit Water Station', 'Unit', 1.0, 2.0, 'CA', 'QC', 'UNIT', GETUTCDATE(), 1, 50401);

    SET @tStart = SYSUTCDATETIME();
    EXEC dbo.sp_water_station_503_record 'unit-water', 'CA', @mli, 'QC', '2026-07-01';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'CA', @mli, 'QC', '2026-07-02';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'CA', @mli, 'QC', '2026-07-03';

    SELECT @backoffstate = backoffstate, @daily = backoff_daily_503_count, @weekly = backoff_weekly_503_count,
           @next = backoff_next_date, @supported = supported
      FROM dbo.WaterStation
     WHERE mli = @mli;
    SELECT @viewCount = COUNT(*) FROM dbo.vwWaterStation WHERE mli = @mli;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
           @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH

IF @backoffstate = 2 AND @daily = 3 AND @weekly = 0 AND @next = '2026-07-10' AND @supported = 0 AND @viewCount = 0
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: three daily 503 failures set WaterStation weekly backoff and remove station from vwWaterStation';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected backoffstate=2 daily=3 weekly=0 next=2026-07-10 supported=0 viewCount=0', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test01Water503Daily
GO

BEGIN TRAN Test02Water503Refresh
DECLARE @test_name sysname;
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @stationId uniqueidentifier;
DECLARE @mli varchar(64);
DECLARE @backoffstate int, @supported bit, @viewCount int;
DECLARE @next date;
BEGIN TRY
    SET @test_name = N'Test02WaterStation503RefreshDue';
    SET @stationId = NEWID();
    SET @mli = 'UTW503R' + RIGHT(REPLACE(CONVERT(varchar(36), @stationId), '-', ''), 12);
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid,
                                  backoffstate, backoff_daily_503_count, backoff_weekly_503_count, backoff_last_503_date, backoff_next_date)
    VALUES (@stationId, @mli, 'Unit Lake', 1, 'Unit Water Station Refresh', 'Unit Water Station', 'Unit', 1.0, 2.0, 'US', 'KS', 'UNIT', GETUTCDATE(), 0, 50402,
            2, 3, 0, '2026-07-03', '2026-07-10');

    SET @tStart = SYSUTCDATETIME();
    EXEC dbo.sp_water_station_503_refresh_due '2026-07-10';

    SELECT @backoffstate = backoffstate, @next = backoff_next_date, @supported = supported
      FROM dbo.WaterStation
     WHERE mli = @mli;
    SELECT @viewCount = COUNT(*) FROM dbo.vwWaterStation WHERE mli = @mli;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
           @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH

IF @backoffstate = 0 AND @next IS NULL AND @supported = 1 AND @viewCount = 1
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: due weekly backoff refresh restores supported water station';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: refresh due must reset backoffstate, clear next date, and restore supported station', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test02Water503Refresh
GO

BEGIN TRAN Test03Water503Weekly
DECLARE @test_name sysname;
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @stationId uniqueidentifier;
DECLARE @mli varchar(64);
DECLARE @backoffstate int, @weekly int, @supported bit;
DECLARE @next date;
BEGIN TRY
    SET @test_name = N'Test03WaterStation503WeeklyToMonthly';
    SET @stationId = NEWID();
    SET @mli = 'UTW503W' + RIGHT(REPLACE(CONVERT(varchar(36), @stationId), '-', ''), 12);
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid)
    VALUES (@stationId, @mli, 'Unit Lake', 1, 'Unit Water Station Weekly', 'Unit Water Station', 'Unit', 1.0, 2.0, 'US', 'WA', 'UNIT', GETUTCDATE(), 1, 50403);

    SET @tStart = SYSUTCDATETIME();
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-01';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-02';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-03';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-10';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-17';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-24';
    EXEC dbo.sp_water_station_503_record 'unit-water', 'US', @mli, 'WA', '2026-07-31';

    SELECT @backoffstate = backoffstate, @weekly = backoff_weekly_503_count, @next = backoff_next_date, @supported = supported
      FROM dbo.WaterStation
     WHERE mli = @mli;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
           @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH

IF @backoffstate = 3 AND @weekly = 4 AND @next = '2026-08-31' AND @supported = 0
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: four weekly 503 failures set monthly water-station backoff';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: expected backoffstate=3 weekly=4 next=2026-08-31 supported=0', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test03Water503Weekly
GO

BEGIN TRAN Test04Water503Reset
DECLARE @test_name sysname;
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @stationId uniqueidentifier;
DECLARE @mli varchar(64);
DECLARE @backoffstate int, @daily int, @weekly int, @supported bit;
DECLARE @next date;
BEGIN TRY
    SET @test_name = N'Test04WaterStation503Reset';
    SET @stationId = NEWID();
    SET @mli = 'UTW503S' + RIGHT(REPLACE(CONVERT(varchar(36), @stationId), '-', ''), 12);
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid,
                                  backoffstate, backoff_daily_503_count, backoff_weekly_503_count, backoff_last_503_date, backoff_next_date)
    VALUES (@stationId, @mli, 'Unit Lake', 1, 'Unit Water Station Reset', 'Unit Water Station', 'Unit', 1.0, 2.0, 'US', 'WA', 'UNIT', GETUTCDATE(), 0, 50404,
            3, 3, 4, '2026-07-31', '2026-08-31');

    SET @tStart = SYSUTCDATETIME();
    EXEC dbo.sp_water_station_503_reset 'unit-water', 'US', @mli;

    SELECT @backoffstate = backoffstate, @daily = backoff_daily_503_count, @weekly = backoff_weekly_503_count,
           @next = backoff_next_date, @supported = supported
      FROM dbo.WaterStation
     WHERE mli = @mli;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
           @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH

IF @backoffstate = 0 AND @daily = 0 AND @weekly = 0 AND @next IS NULL AND @supported = 1
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: successful water-station processing reset restores supported station';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: reset must clear backoff and restore supported', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test04Water503Reset
GO

BEGIN TRAN Test05Water503Summary
DECLARE @test_name sysname;
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @stationId uniqueidentifier;
DECLARE @mli varchar(64);
DECLARE @count bigint;
BEGIN TRY
    SET @test_name = N'Test05WaterStation503Summary';
    SET @stationId = NEWID();
    SET @mli = 'UTW503M' + RIGHT(REPLACE(CONVERT(varchar(36), @stationId), '-', ''), 12);
    INSERT INTO dbo.WaterStation (id, mli, lakeName, locType, locName, locDesc, county, lat, lon, country, state, agency, stamp, supported, sid,
                                  backoffstate, backoff_daily_503_count, backoff_weekly_503_count, backoff_last_503_date, backoff_next_date)
    VALUES (@stationId, @mli, 'Unit Lake', 1, 'Unit Water Station Summary', 'Unit Water Station', 'Unit', 1.0, 2.0, 'US', 'WA', 'UNIT', GETUTCDATE(), 0, 50405,
            2, 3, 0, '2026-07-03', '2026-07-10');

    SET @tStart = SYSUTCDATETIME();
    DECLARE @summary TABLE (state char(2), backoff_stage varchar(16), station_count bigint);
    INSERT INTO @summary EXEC dbo.sp_water_station_503_summary_by_state;
    SELECT @count = station_count FROM @summary WHERE state = 'WA' AND backoff_stage = 'WEEKLY';
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState,
           @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH

IF @count = 1
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: summary reduces WaterStation 503 backoff stations by state';
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: expected WA weekly count 1', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test05Water503Summary
GO
