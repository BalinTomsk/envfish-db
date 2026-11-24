-- Unit tests: schema [env], the boundary env_service writes and reads in SQL Server (env_service plan step 4).
--   env.fn_station_list       the station master for env_service's mirror into MySQL envdata
--   env.sp_push_station_state the current reading + flow state per station  -> env.StationState
--   env.sp_push_station_day   weather + pressure state per station and day   -> env.StationDay
--   env.sp_station_day_trim   drops StationDay rows before a date
-- Each test is its own transaction, rolled back at the end of its GO batch.

BEGIN TRAN Test01
    declare @test_name sysname = N'Test01 [env.fn_station_list] : hasFish follows lake_fish, no coordinate = not listed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @fish int, @nofish int, @nocoord int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @lake uniqueidentifier = (SELECT TOP 1 lake_Id FROM dbo.lake_fish);
-- sid is an IDENTITY in the live table: let it be assigned, find the rows by MLI
INSERT INTO dbo.WaterStation (MLI, id, lat, lon, country, lakeId, locName) VALUES
    ('ENVT01A', NEWID(), 45, -79, 'CA', @lake, 'with fish'),
    ('ENVT01B', NEWID(), 45, -79, 'US', NULL, NULL),
    ('ENVT01C', NEWID(), NULL, -79, 'US', NULL, 'no coordinate');

SELECT @fish    = COUNT(*) FROM env.fn_station_list() WHERE mli = 'ENVT01A' AND hasFish = 1 AND country = 'CA';
SELECT @nofish  = COUNT(*) FROM env.fn_station_list() WHERE mli = 'ENVT01B' AND hasFish = 0 AND locName = '';
SELECT @nocoord = COUNT(*) FROM env.fn_station_list() WHERE mli = 'ENVT01C';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @fish = 1 AND @nofish = 1 AND @nocoord = 0
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: hasFish from lake_fish, no coordinate not listed'
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: env.fn_station_list hasFish or coordinate filter wrong', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test01
GO

BEGIN TRAN Test02
    declare @test_name sysname = N'Test02 [env.sp_push_station_state] : upsert by sid'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ok int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @rows env.StationStateRows;
INSERT INTO @rows (sid, mli, ts, discharge, oxygen, flow_state, q_median_30d)
VALUES (99990001, 'ENVT02', '2026-11-24 10:00', 5, 8.5, 'RISING', 4);
EXEC env.sp_push_station_state @rows;
DELETE FROM @rows;
INSERT INTO @rows (sid, mli, ts, discharge, oxygen, flow_state, q_median_30d)
VALUES (99990001, 'ENVT02', '2026-11-24 11:00', 6, NULL, 'SPATE', 4);
EXEC env.sp_push_station_state @rows;

SELECT @ok = COUNT(*) FROM env.StationState
 WHERE sid = 99990001 AND ts = '2026-11-24 11:00' AND discharge = 6 AND oxygen IS NULL AND flow_state = 'SPATE';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ok = 1 AND (SELECT COUNT(*) FROM env.StationState WHERE sid = 99990001) = 1
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: station state upserted by sid, as pushed'
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: env.sp_push_station_state did not upsert', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test02
GO

BEGIN TRAN Test03
    declare @test_name sysname = N'Test03 [env.sp_push_station_day] : upsert by sid + dt, mm Hg kept'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ok int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @rows env.StationDayRows;
INSERT INTO @rows (sid, dt, tm_high, pressure_mm, pressure_state, pressure_weight)
VALUES (99990001, '2026-11-24', 5, 755.3, 'FRONT', 0.60), (99990001, '2026-11-25', 3, 759.8, 'POST_1', 0.60);
EXEC env.sp_push_station_day @rows;
DELETE FROM @rows;
INSERT INTO @rows (sid, dt, tm_high, pressure_mm, pressure_state, pressure_weight)
VALUES (99990001, '2026-11-25', 4, 760.1, 'POST_1', 1.00);
EXEC env.sp_push_station_day @rows;

SELECT @ok = COUNT(*) FROM env.StationDay
 WHERE sid = 99990001 AND ((dt = '2026-11-24' AND pressure_mm = 755.3 AND pressure_state = 'FRONT')
    OR (dt = '2026-11-25' AND tm_high = 4 AND pressure_mm = 760.1 AND pressure_weight = 1.00));

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ok = 2
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: station days upserted by sid and date'
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: env.sp_push_station_day did not upsert', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test03
GO

BEGIN TRAN Test04
    declare @test_name sysname = N'Test04 [env.sp_station_day_trim] : rows before the date go, later stay'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @left int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @rows env.StationDayRows;
INSERT INTO @rows (sid, dt, tm_high) VALUES (99990001, '2026-11-01', 1), (99990001, '2026-11-20', 2);
EXEC env.sp_push_station_day @rows;
EXEC env.sp_station_day_trim '2026-11-10';
SELECT @left = COUNT(*) FROM env.StationDay WHERE sid = 99990001;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @left = 1 AND EXISTS (SELECT 1 FROM env.StationDay WHERE sid = 99990001 AND dt = '2026-11-20')
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: days before the trim date deleted'
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: env.sp_station_day_trim kept old or lost new rows', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test04
GO
