SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.sp_add_tributary.
  Uses real tables dbo.lake / dbo.Tributaries. Transaction is rolled back at end -
  database state restored.

  sp_add_tributary - creates the RECIPROCAL Tributaries row on the water body being linked.
  Called by FishTracker.Editor.EditTributary.ButtonSubmit_Click; @type is the ddlFlow value
  (1 link / 2 through / 4 inflow / 8 outflow / 64 joined), NOT a side bitmask.
  TEST 1 - inflow (@type=4) on a lake with NO self source placeholder still creates the side-4 row
  TEST 2 - inflow (@type=4) on a lake WITH a self source placeholder keeps that side-16 row intact
  TEST 3 - through (@type=2) creates BOTH the side-4 and the side-8 reciprocal rows
  TEST 4 - outflow (@type=8) must not re-point an existing self mouth (side-32) row
*/
SET NOCOUNT ON;

DECLARE @tStart    datetime2;
DECLARE @ElapsedMs int;

BEGIN TRY
    BEGIN TRANSACTION;

    -- ----------------------------------------------------------------
    -- TEST 1: inflow on a lake with NO self source placeholder
    --         The reciprocal row must be created regardless of whether the lake happens to
    --         carry a self-referencing side-16 row (6,284 of 116,777 locType=1 lakes do not).
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @River5 uniqueidentifier = NEWID();
    DECLARE @Lake5  uniqueidentifier = NEWID();
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@River5, 2, N'River', 'UT5R');
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@Lake5,  1, N'Lake',  'UT5L');
    -- TR_Lake_INS auto-creates the self source (16) / mouth (32) placeholders for every new lake,
    -- so drop the source one to reproduce a LEGACY lake that predates that trigger.
    DELETE FROM Tributaries WHERE Main_Lake_id = @Lake5 AND Lake_id = @Lake5 AND side = 16;
    EXEC dbo.sp_add_tributary @main_lake_id = @River5, @lake_id = @Lake5, @type = 4, @lat = 51.25, @lon = -96.75;
    DECLARE @R5 int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake5 AND lake_id = @River5 AND side = 4);
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R5 = 1
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: inflow reciprocal row created without a source placeholder';
    ELSE
        PRINT 'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: expected 1 side-4 row, got ' + CAST(@R5 AS varchar);

    -- ----------------------------------------------------------------
    -- TEST 2: inflow on a lake WITH a self source placeholder
    --         The side-16 self row is what fn_EditLakeLink returns for the Source tab of
    --         Editor/EditLakeLink.aspx and holds that point's zone/district/city/elevation -
    --         it must survive untouched, with the inflow added as a separate row.
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @River6 uniqueidentifier = NEWID();
    DECLARE @Lake6  uniqueidentifier = NEWID();
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@River6, 2, N'River', 'UT6R');
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@Lake6,  1, N'Lake',  'UT6L');
    -- the side-16 placeholder already exists (TR_Lake_INS); tag it so we can prove it survives
    UPDATE Tributaries SET zone = 42 WHERE Main_Lake_id = @Lake6 AND Lake_id = @Lake6 AND side = 16;
    EXEC dbo.sp_add_tributary @main_lake_id = @River6, @lake_id = @Lake6, @type = 4, @lat = 51.25, @lon = -96.75;
    DECLARE @R6a int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake6 AND lake_id = @River6 AND side = 4);
    DECLARE @R6b int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake6 AND lake_id = @Lake6  AND side = 16 AND zone = 42);
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R6a = 1 AND @R6b = 1
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: inflow row added and the self source row preserved';
    ELSE
        PRINT 'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: side4=' + CAST(@R6a AS varchar) + ' self16=' + CAST(@R6b AS varchar);

    -- ----------------------------------------------------------------
    -- TEST 3: through (@type=2) creates BOTH reciprocal directions
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @River7 uniqueidentifier = NEWID();
    DECLARE @Lake7  uniqueidentifier = NEWID();
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@River7, 2, N'River', 'UT7R');
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@Lake7,  1, N'Lake',  'UT7L');
    EXEC dbo.sp_add_tributary @main_lake_id = @River7, @lake_id = @Lake7, @type = 2, @lat = 51.25, @lon = -96.75;
    DECLARE @R7a int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake7 AND lake_id = @River7 AND side = 4);
    DECLARE @R7b int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake7 AND lake_id = @River7 AND side = 8);
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R7a = 1 AND @R7b = 1
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: through created both side-4 and side-8 rows';
    ELSE
        PRINT 'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: side4=' + CAST(@R7a AS varchar) + ' side8=' + CAST(@R7b AS varchar);

    -- ----------------------------------------------------------------
    -- TEST 4: outflow on a lake that has a self MOUTH row but no self SOURCE row.
    --         The old code tested @srcid here but updated @mthid, so this case re-pointed the
    --         side-32 mouth row into a side-8 row - destroying the Mouth tab's data.
    -- ----------------------------------------------------------------
    SET @tStart = SYSUTCDATETIME();
    DECLARE @River8 uniqueidentifier = NEWID();
    DECLARE @Lake8  uniqueidentifier = NEWID();
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@River8, 2, N'River', 'UT8R');
    INSERT INTO lake (lake_id, locType, lake_name, CGNDB) VALUES (@Lake8,  1, N'Lake',  'UT8L');
    -- no self SOURCE row (so the old code's @srcid was NULL), but the self MOUTH row is present
    -- and tagged - the old ELSE branch then updated @mthid and re-pointed it to side 8.
    DELETE FROM Tributaries WHERE Main_Lake_id = @Lake8 AND Lake_id = @Lake8 AND side = 16;
    UPDATE Tributaries SET zone = 77 WHERE Main_Lake_id = @Lake8 AND Lake_id = @Lake8 AND side = 32;
    EXEC dbo.sp_add_tributary @main_lake_id = @River8, @lake_id = @Lake8, @type = 8, @lat = 51.25, @lon = -96.75;
    DECLARE @R8a int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake8 AND lake_id = @River8 AND side = 8);
    DECLARE @R8b int = (SELECT COUNT(*) FROM Tributaries WHERE main_lake_id = @Lake8 AND lake_id = @Lake8  AND side = 32 AND zone = 77);
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
    IF @R8a = 1 AND @R8b = 1
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: outflow row added and the self mouth row preserved';
    ELSE
        PRINT 'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + 'ms]: side8=' + CAST(@R8a AS varchar) + ' self32=' + CAST(@R8b AS varchar);

    ROLLBACK TRANSACTION;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'EXCEPTION during test: ' + ERROR_MESSAGE()
        + '  (proc=' + ISNULL(ERROR_PROCEDURE(), 'n/a')
        + ', line='  + CAST(ERROR_LINE() AS varchar) + ')';
END CATCH;
