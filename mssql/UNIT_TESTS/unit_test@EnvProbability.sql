

BEGIN TRAN Test02
    declare @test_name sysname = N'Test02 [env.fn_fish_location_today] : oxygen older than 7 days does not count'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @fresh decimal(5,2), @old decimal(5,2);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- a fish with an oxygen habitat rule (ri_type 33), at one of its stations; the rule gets a 5..14 mg/L range here
-- (local data carries no oxygen ranges, so the factor would always be 1)
DECLARE @fl int, @sid int, @mli varchar(64), @rp uniqueidentifier;
SELECT TOP 1 @fl = fl.id, @sid = w.sid, @mli = w.MLI, @rp = ri.ri_parent_id
  FROM dbo.fish_location fl
  JOIN dbo.WaterStation w ON w.id = fl.station_Id
  JOIN dbo.fish_Rule r ON r.fish_Id = fl.fish_Id AND r.periodStart = -1 AND r.periodEnd = -1
  JOIN dbo.real_interval ri ON ri.ri_parent_id = r.id AND ri.ri_type = 33
 ORDER BY fl.id;
UPDATE dbo.real_interval SET ri_min = 5, ri_low = 6, ri_avg = 8, ri_high = 10, ri_max = 14 WHERE ri_parent_id = @rp AND ri_type = 33;
DELETE FROM env.StationState WHERE sid = @sid;
-- oxygen 0.5 mg/L, under the habitat minimum = factor 0 while fresh
INSERT INTO env.StationState (sid, mli, ts, oxygen) VALUES (@sid, @mli, SYSUTCDATETIME(), 0.5);
SELECT @fresh = oxygenFactor FROM env.fn_fish_location_today(1, 1, CAST(SYSUTCDATETIME() AS date)) WHERE id = @fl;
UPDATE env.StationState SET ts = DATEADD(DAY, -8, SYSUTCDATETIME()) WHERE sid = @sid;
SELECT @old = oxygenFactor FROM env.fn_fish_location_today(1, 1, CAST(SYSUTCDATETIME() AS date)) WHERE id = @fl;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @fresh = 0.00 AND @old = 1.00
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: oxygen counts when fresh, not after 7 days'
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: oxygen age-out wrong on the env path', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test02
GO

BEGIN TRAN Test03
    declare @test_name sysname = N'Test03 [env.Setting] : legacy by default; env.sp_update_probability does nothing then'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @rc int, @changed int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DELETE FROM env.Setting WHERE name = 'probability_source';
DECLARE @fl int = (SELECT MIN(id) FROM dbo.fish_location);
UPDATE dbo.fish_location SET today = -1 WHERE id = @fl;
EXEC @rc = env.sp_update_probability;
SELECT @changed = COUNT(*) FROM dbo.fish_location WHERE id = @fl AND today <> -1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @rc = -1 AND @changed = 0 AND env.fn_probability_source() = 'legacy'
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no setting = legacy; the env update returns -1, writes nothing'
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: env path wrote while the source is legacy', 16, -1, @ElapsedMs)

ROLLBACK TRAN Test03
GO
