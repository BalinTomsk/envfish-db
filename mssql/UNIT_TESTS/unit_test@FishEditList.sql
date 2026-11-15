SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_read_fish_edit_list -- the habitat row of a fish species.
  Callers: FishTracker.Resources.wfFishViewer.LoadHabitat (one fish, WHERE fish_id = @id)
           FishTracker.Editor.TFishEditor.LoadUnEditedFish (every fish).
  It was a multi-statement TVF that built the row for EVERY fish into a table variable before
  the viewer's WHERE applied; wfFishViewer.LoadHabitat hit the 30 s timeout 24 times on prod.

  TEST 1 - the function is inline, so a fish_id filter reaches the base tables
  TEST 2 - base-rule (-1/-1) intervals and flags are returned, seasonal rules are ignored
  TEST 3 - a fish with no base rule still returns its row, habitat columns NULL
*/
BEGIN TRAN Test1
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int;
DECLARE @type char(2) = (SELECT type FROM sys.objects WHERE object_id = OBJECT_ID('dbo.fn_read_fish_edit_list'));
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF ISNULL(@type, '') <> 'IF'
    RAISERROR ('TEST 1 FAIL [%dms]: fn_read_fish_edit_list is not an inline TVF', 16, -1, @ElapsedMs)
ELSE
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_read_fish_edit_list is inline';
ROLLBACK TRAN Test1
GO

BEGIN TRAN Test2
DECLARE @tStart datetime2, @ElapsedMs int, @ok bit = 0;
BEGIN TRY  SET NOCOUNT ON;
    DECLARE @fam uniqueidentifier = NEWID(), @fish uniqueidentifier = NEWID();
    INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@fam, N'__TEST_FAMILY__', -999, GETUTCDATE());
    INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, water_type, created, stamp)
    VALUES (@fish, N'__TEST_FISH__', N'Testus habitatus', @fam, 3, GETUTCDATE(), GETUTCDATE());
    -- TR_ins_Fish created the base (-1/-1) rule and a seasonal 4..6 one
    DECLARE @ed uniqueidentifier = NEWID();
    UPDATE dbo.fish_Rule SET habitat = 5, feedsOver = 6, locked = 1, editor = @ed
     WHERE fish_Id = @fish AND periodStart = -1 AND periodEnd = -1;
    DECLARE @base uniqueidentifier = (SELECT id FROM dbo.fish_Rule WHERE fish_Id = @fish AND periodStart = -1 AND periodEnd = -1);
    DECLARE @seas uniqueidentifier = (SELECT TOP 1 id FROM dbo.fish_Rule WHERE fish_Id = @fish AND periodStart > 0);
    INSERT INTO dbo.real_interval (ri_parent_id, ri_type, ri_min, ri_low, ri_avg, ri_high, ri_max, ri_stamp) VALUES
      (@base, 17, 1, 10, 15, 20, 30, SYSUTCDATETIME()),   -- temperature
      (@base,  9, 5, 6.5, 7, 8.5, 9, SYSUTCDATETIME()),   -- pH
      (@base,  3, 2, NULL, NULL, NULL, 12, SYSUTCDATETIME()),  -- depth
      (@base, 73, 40, NULL, NULL, NULL, 180, SYSUTCDATETIME()), -- hardness
      (@seas, 17, 99, 99, 99, 99, 99, SYSUTCDATETIME());  -- seasonal: must be ignored

    SET @tStart = SYSUTCDATETIME();
    SELECT @ok = CASE WHEN tmL = 10 AND tmH = 20 AND tmLD = 1 AND tmHD = 30 AND phL = 6.5 AND phH = 8.5
                       AND depthMin = 2 AND depthMax = 12 AND HardnessL = 40 AND HardnessH = 180
                       AND habitat = 5 AND feedsOver = 6 AND locked = 1 AND editor = CAST(@ed AS varchar(36))
                       AND water_type = 3 AND oxL IS NULL THEN 1 ELSE 0 END
      FROM dbo.fn_read_fish_edit_list() WHERE fish_id = @fish;
    IF @@ROWCOUNT <> 1 SET @ok = 0;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SET @ok = 0; PRINT 'TEST 2 ERROR: ' + ERROR_MESSAGE();
END CATCH
IF @ok = 1
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: base-rule habitat values returned';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: base-rule habitat values wrong', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test2
GO

BEGIN TRAN Test3
DECLARE @tStart datetime2, @ElapsedMs int, @ok bit = 0;
BEGIN TRY  SET NOCOUNT ON;
    DECLARE @fam uniqueidentifier = NEWID(), @fish uniqueidentifier = NEWID();
    INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@fam, N'__TEST_FAMILY__', -999, GETUTCDATE());
    INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
    VALUES (@fish, N'__TEST_FISH__', N'Testus nullus', @fam, GETUTCDATE(), GETUTCDATE());
    DELETE FROM dbo.fish_Rule WHERE fish_Id = @fish;   -- drop the rules TR_ins_Fish created

    SET @tStart = SYSUTCDATETIME();
    SELECT @ok = CASE WHEN fish_name = '__TEST_FISH__' AND habitat IS NULL AND tmL IS NULL
                       AND depthMin IS NULL THEN 1 ELSE 0 END
      FROM dbo.fn_read_fish_edit_list() WHERE fish_id = @fish;
    IF @@ROWCOUNT <> 1 SET @ok = 0;
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
END TRY
BEGIN CATCH
    SET @ok = 0; PRINT 'TEST 3 ERROR: ' + ERROR_MESSAGE();
END CATCH
IF @ok = 1
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fish without a rule returns NULL habitat';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: fish without a rule lost or wrong', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test3
GO
