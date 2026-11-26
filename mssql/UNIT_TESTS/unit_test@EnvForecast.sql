

BEGIN TRAN Test02
    declare @test_name sysname = N'Test02 [env.fn_map_location] : a pin needs a reading of the last 15 days and a forecast day'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @both int, @stale int, @noDay int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @fish uniqueidentifier, @fishName varchar(64), @sid int, @mli varchar(64), @country char(2);
SELECT TOP 1 @fish = f.fish_id, @fishName = f.fish_name, @sid = w.sid, @mli = w.MLI, @country = RTRIM(w.country)
  FROM dbo.fish_location fl JOIN dbo.fish f ON f.fish_id = fl.fish_Id JOIN dbo.vWaterStation w ON w.id = fl.station_Id
 ORDER BY w.sid;
DELETE FROM env.StationState WHERE sid = @sid;
DELETE FROM env.StationDay WHERE sid = @sid;
INSERT INTO env.StationState (sid, mli, ts, discharge) VALUES (@sid, @mli, SYSUTCDATETIME(), 3.5);
INSERT INTO env.StationDay (sid, dt) VALUES (@sid, CAST(SYSUTCDATETIME() AS date));
SELECT @both = COUNT(*) FROM env.fn_map_location(@fishName, 0, 0, @country, 0) WHERE sid = @sid;
UPDATE env.StationState SET ts = DATEADD(DAY, -16, SYSUTCDATETIME()) WHERE sid = @sid;
SELECT @stale = COUNT(*) FROM env.fn_map_location(@fishName, 0, 0, @country, 0) WHERE sid = @sid;
UPDATE env.StationState SET ts = SYSUTCDATETIME() WHERE sid = @sid;
UPDATE env.StationDay SET dt = DATEADD(DAY, -1, dt) WHERE sid = @sid;
SELECT @noDay = COUNT(*) FROM env.fn_map_location(@fishName, 0, 0, @country, 0) WHERE sid = @sid;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @both = 1 AND @stale = 0 AND @noDay = 0
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: pin needs a fresh reading and a forecast day'
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: env.fn_map_location pin rules wrong', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test02
GO
