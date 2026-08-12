SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the objects that procedures/functions in this schema REFERENCE but that were
  missing from the scriptNN sources - the same class of gap as dbo.GetDatePeriod /
  dbo.fn_get_float_as_string (2026-08-05): the module compiles because SQL Server defers name
  resolution, then fails at run time in any freshly built database.

  TEST 1 - guard: no module may reference an object that does not exist (catches the whole class)
  TEST 2 - dbo.fn_Parser                    - comma list -> trimmed items (used by fn_first_item)
  TEST 3 - dbo.fn_first_item                - first item of a list / bare value unchanged
  TEST 4 - dbo.fn_direction_by_degree       - wind degrees -> compass point
  TEST 5 - dbo.UNIX_TIMESTAMP_TO_DATETIME   - epoch seconds -> datetime2
  TEST 6 - dbo.sp_del_river                 - deletes the water body with its species and tributaries
                                              (FishTracker Editor/LakeEditor.aspx.cs - delete water body)
  TEST 7 - dbo.UScode                       - sp_push_us_water_data registers the measurement it saw
                                              (waterservice WaterDataRepository - USGS series push)
  TEST 8 - guard: the objects retired on 2026-08-11 stay gone

  TEST 4 and TEST 5 cover two functions whose only caller (dbo.sp_weather_forecast16) was retired on
  2026-08-11; they are kept because they exist on production, so this file is what justifies them.

  Uses real tables: dbo.Lake, dbo.fish, dbo.fish_family, dbo.lake_fish, dbo.Tributaries,
  dbo.WaterStation, dbo.WaterData, dbo.UScode.
  Each test is its own named transaction, rolled back at the end of its own GO batch.
*/
PRINT 'Unit tests for restored schema references (fn_Parser, fn_direction_by_degree, UNIX_TIMESTAMP_TO_DATETIME, UScode)'
GO
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: every object a module references must exist.
--         Triggers are excluded (their INSERTED/DELETED pseudo-tables and query aliases are
--         reported as unresolved by design), as are caller-dependent EXECs (unqualified
--         EXEC name, resolved at run time) and the CLR method dbo.ToString.
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01NoDanglingReferences
    DECLARE @test_name sysname = N'Test01NoDanglingReferences [schema] : no module references a missing object'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @bad1 int = -1, @list1 nvarchar(2000), @msg1 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1./2. no fixture - the assertion is over the shipped schema itself

SELECT @bad1 = COUNT(*)
  FROM sys.sql_expression_dependencies d
  JOIN sys.objects o ON o.object_id = d.referencing_id
 WHERE d.referenced_id             IS NULL
   AND d.referenced_server_name    IS NULL
   AND d.referenced_database_name  IS NULL
   AND d.referenced_class          = 1        -- OBJECT_OR_COLUMN
   AND d.is_caller_dependent       = 0
   AND o.type_desc NOT LIKE '%TRIGGER%'
   AND d.referenced_entity_name NOT IN (N'ToString');

SET @list1 = STUFF((SELECT N', ' + o.name + N' -> ' + d.referenced_entity_name
                      FROM sys.sql_expression_dependencies d
                      JOIN sys.objects o ON o.object_id = d.referencing_id
                     WHERE d.referenced_id             IS NULL
                       AND d.referenced_server_name    IS NULL
                       AND d.referenced_database_name  IS NULL
                       AND d.referenced_class          = 1
                       AND d.is_caller_dependent       = 0
                       AND o.type_desc NOT LIKE '%TRIGGER%'
                       AND d.referenced_entity_name NOT IN (N'ToString')
                     ORDER BY o.name, d.referenced_entity_name
                     FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @bad1 = 0
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no module references a missing object'
ELSE
BEGIN
    SET @msg1 = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: '
              + ISNULL(CAST(@bad1 AS nvarchar(10)), N'?') + N' dangling reference(s): '
              + ISNULL(@list1, N'<count query failed>');
    RAISERROR (@msg1, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01NoDanglingReferences
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: dbo.fn_Parser splits a comma-separated list and trims each item
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02Parser
    DECLARE @test_name sysname = N'Test02Parser [fn_Parser] : comma list split into trimmed items'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @cnt2 int = -1, @first2 nvarchar(128), @last2 nvarchar(128), @err2 nvarchar(2048), @msg2 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 2. execute unit test : padded items must come back trimmed, in order

SELECT @cnt2 = COUNT(*) FROM dbo.fn_Parser(N'Walleye,  Northern Pike , Lake Trout');
SELECT @first2 = Item FROM dbo.fn_Parser(N'Walleye,  Northern Pike , Lake Trout') WHERE Id = 1;
SELECT @last2  = Item FROM dbo.fn_Parser(N'Walleye,  Northern Pike , Lake Trout') WHERE Id = 3;

END TRY
BEGIN CATCH
    SET @err2 = ERROR_MESSAGE();
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err2 IS NOT NULL
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: fn_Parser raised: ' + @err2;
    RAISERROR (@msg2, 16, -1)
END
ELSE IF @cnt2 = 3 AND @first2 = N'Walleye' AND @last2 = N'Lake Trout'
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_Parser returned 3 trimmed items in order'
ELSE
BEGIN
    SET @msg2 = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 3 items Walleye..Lake Trout, got count='
              + ISNULL(CAST(@cnt2 AS nvarchar(10)), N'NULL') + N' first=' + ISNULL(@first2, N'NULL')
              + N' last=' + ISNULL(@last2, N'NULL');
    RAISERROR (@msg2, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02Parser
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: dbo.fn_first_item returns the first item of a list, and a bare value unchanged
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03FirstItem
    DECLARE @test_name sysname = N'Test03FirstItem [fn_first_item] : first item of a list / bare value'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @list3 nvarchar(128), @single3 nvarchar(128), @err3 nvarchar(2048), @msg3 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 2. execute unit test

SET @list3   = dbo.fn_first_item(N'Grand River, Speed River');
SET @single3 = dbo.fn_first_item(N'Grand River');

END TRY
BEGIN CATCH
    SET @err3 = ERROR_MESSAGE();
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err3 IS NOT NULL
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: fn_first_item raised: ' + @err3;
    RAISERROR (@msg3, 16, -1)
END
ELSE IF @list3 = N'Grand River' AND @single3 = N'Grand River'
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_first_item returned the first item and passed a bare value through'
ELSE
BEGIN
    SET @msg3 = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected Grand River twice, got list='
              + ISNULL(@list3, N'NULL') + N' single=' + ISNULL(@single3, N'NULL');
    RAISERROR (@msg3, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03FirstItem
GO
-- ---------------------------------------------------------------------------------------
-- TEST 4: dbo.fn_direction_by_degree maps wind degrees to a compass point
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test04DirectionByDegree
    DECLARE @test_name sysname = N'Test04DirectionByDegree [fn_direction_by_degree] : degrees -> compass point'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @n4 varchar(3), @e4 varchar(3), @s4 varchar(3), @w4 varchar(3), @ne4 varchar(3);
DECLARE @err4 nvarchar(2048), @msg4 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 2. execute unit test

SET @n4  = dbo.fn_direction_by_degree(0);
SET @e4  = dbo.fn_direction_by_degree(90);
SET @s4  = dbo.fn_direction_by_degree(180);
SET @w4  = dbo.fn_direction_by_degree(270);
SET @ne4 = dbo.fn_direction_by_degree(45);

END TRY
BEGIN CATCH
    SET @err4 = ERROR_MESSAGE();
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err4 IS NOT NULL
BEGIN
    SET @msg4 = N'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: fn_direction_by_degree raised: ' + @err4;
    RAISERROR (@msg4, 16, -1)
END
ELSE IF @n4 = 'N' AND @e4 = 'E' AND @s4 = 'S' AND @w4 = 'W' AND @ne4 = 'NE'
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_direction_by_degree returned N/E/S/W/NE for 0/90/180/270/45'
ELSE
BEGIN
    SET @msg4 = N'TEST 4 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected N,E,S,W,NE - got '
              + ISNULL(@n4, 'NULL') + N',' + ISNULL(@e4, 'NULL') + N',' + ISNULL(@s4, 'NULL')
              + N',' + ISNULL(@w4, 'NULL') + N',' + ISNULL(@ne4, 'NULL');
    RAISERROR (@msg4, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test04DirectionByDegree
GO
-- ---------------------------------------------------------------------------------------
-- TEST 5: dbo.UNIX_TIMESTAMP_TO_DATETIME converts epoch seconds to a datetime2
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test05UnixTimestamp
    DECLARE @test_name sysname = N'Test05UnixTimestamp [UNIX_TIMESTAMP_TO_DATETIME] : epoch seconds -> datetime2'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @epoch5 datetime2, @day5 datetime2, @err5 nvarchar(2048), @msg5 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 2. execute unit test : 0 is the epoch itself, 1 700 000 000 is 2023-11-14 22:13:20 UTC

SET @epoch5 = dbo.UNIX_TIMESTAMP_TO_DATETIME(0);
SET @day5   = dbo.UNIX_TIMESTAMP_TO_DATETIME(1700000000);

END TRY
BEGIN CATCH
    SET @err5 = ERROR_MESSAGE();
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err5 IS NOT NULL
BEGIN
    SET @msg5 = N'TEST 5 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: UNIX_TIMESTAMP_TO_DATETIME raised: ' + @err5;
    RAISERROR (@msg5, 16, -1)
END
ELSE IF @epoch5 = CAST('1970-01-01T00:00:00' AS datetime2) AND @day5 = CAST('2023-11-14T22:13:20' AS datetime2)
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: UNIX_TIMESTAMP_TO_DATETIME converted the epoch and a known timestamp'
ELSE
BEGIN
    SET @msg5 = N'TEST 5 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1970-01-01 and 2023-11-14 22:13:20, got '
              + ISNULL(CONVERT(nvarchar(30), @epoch5, 126), N'NULL') + N' and '
              + ISNULL(CONVERT(nvarchar(30), @day5, 126), N'NULL');
    RAISERROR (@msg5, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test05UnixTimestamp
GO
-- ---------------------------------------------------------------------------------------
-- TEST 6: dbo.sp_del_river deletes a water body together with its assigned species and its
--         tributary links, and leaves the linked water body alone
--         (FishTracker Editor/LakeEditor.aspx.cs - "delete water body").
--         Regression cover for the removal of its DELETE FROM Parking_Spot (2026-08-11).
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test06DelRiver
    DECLARE @test_name sysname = N'Test06DelRiver [sp_del_river] : water body deleted with species and tributaries'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId6 uniqueidentifier = NEWID();
DECLARE @OtherId6 uniqueidentifier = NEWID();
DECLARE @FamId6 uniqueidentifier = NEWID();
DECLARE @FishId6 uniqueidentifier = NEWID();
DECLARE @lakes6 int = -1, @fish6 int = -1, @trib6 int = -1, @other6 int = -1;
DECLARE @err6 nvarchar(2048), @msg6 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : the water body to delete, a species assigned to it, a tributary
--    link to a second water body that must survive

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId6,  2, N'UT SCHREF River 6');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@OtherId6, 2, N'UT SCHREF River 6 downstream');

INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
VALUES (@FamId6, N'__TEST_FAM_SCHREF_6__', -961, GETUTCDATE());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@FishId6, N'__TEST_FISH_SCHREF_6__', N'Testus deletus', @FamId6, GETUTCDATE(), GETUTCDATE());

INSERT INTO dbo.lake_fish (Lake_id, fish_id, created) VALUES (@LakeId6, @FishId6, GETDATE());
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side) VALUES (@OtherId6, @LakeId6, 4);

-- 2. execute unit test

EXEC dbo.sp_del_river @lake_id = @LakeId6;

SELECT @lakes6 = COUNT(*) FROM dbo.Lake        WHERE Lake_id = @LakeId6;
SELECT @fish6  = COUNT(*) FROM dbo.lake_fish   WHERE lake_id = @LakeId6;
SELECT @trib6  = COUNT(*) FROM dbo.Tributaries WHERE Main_Lake_id = @LakeId6 OR Lake_id = @LakeId6;
SELECT @other6 = COUNT(*) FROM dbo.Lake        WHERE Lake_id = @OtherId6;

END TRY
BEGIN CATCH
    SET @err6 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err6 IS NOT NULL
BEGIN
    SET @msg6 = N'TEST 6 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: sp_del_river raised: ' + @err6;
    RAISERROR (@msg6, 16, -1)
END
ELSE IF @lakes6 = 0 AND @fish6 = 0 AND @trib6 = 0 AND @other6 = 1
    PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_del_river removed the water body, its species and its tributary links only'
ELSE
BEGIN
    SET @msg6 = N'TEST 6 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 0 lakes / 0 lake_fish / 0 tributaries / 1 other, got '
              + ISNULL(CAST(@lakes6 AS nvarchar(10)), N'NULL') + N' / ' + ISNULL(CAST(@fish6 AS nvarchar(10)), N'NULL')
              + N' / ' + ISNULL(CAST(@trib6 AS nvarchar(10)), N'NULL') + N' / ' + ISNULL(CAST(@other6 AS nvarchar(10)), N'NULL');
    RAISERROR (@msg6, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test06DelRiver
GO
-- ---------------------------------------------------------------------------------------
-- TEST 7: dbo.sp_push_us_water_data registers the measurement it saw in dbo.UScode
--         (waterservice WaterDataRepository - USGS series push)
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test07PushUsWaterDataUScode
    DECLARE @test_name sysname = N'Test07PushUsWaterDataUScode [sp_push_us_water_data] : measurement registered in UScode'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @LakeId7 uniqueidentifier = NEWID();
DECLARE @Mli7 varchar(64) = 'UT_SCHREF_07';
DECLARE @Name7 sysname = N'Streamflow';
DECLARE @codes7 int = -1, @data7 int = -1, @err7 nvarchar(2048), @msg7 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : a station the USGS push can attach readings to

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@LakeId7, 2, N'UT SCHREF River 7');

INSERT INTO dbo.WaterStation (MLI, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@Mli7, 43.55, -80.25, 'US', N'unit-test station SCHREF 7', 2, N'UT SCHREF Station 7', N'', 970701, @LakeId7, N'UT SCHREF River 7', 1);

DELETE FROM dbo.UScode WHERE name = @Name7 AND unit = 'ut^3/s';

-- 2. execute unit test

EXEC dbo.sp_push_us_water_data @mli = @Mli7, @state = N'NY', @name = @Name7, @unit = 'ut^3/s',
     @xmldoc = N'<root><a d="2026-08-11" v="2.70" /></root>';

SELECT @codes7 = COUNT(*) FROM dbo.UScode   WHERE name = @Name7 AND unit = 'ut^3/s';
SELECT @data7  = COUNT(*) FROM dbo.WaterData WHERE mli = @Mli7;

END TRY
BEGIN CATCH
    SET @err7 = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err7 IS NOT NULL
BEGIN
    SET @msg7 = N'TEST 7 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: sp_push_us_water_data raised: ' + @err7;
    RAISERROR (@msg7, 16, -1)
END
ELSE IF @codes7 = 1 AND @data7 = 1
    PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_push_us_water_data registered the measurement in UScode and stored the reading'
ELSE
BEGIN
    SET @msg7 = N'TEST 7 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected 1 UScode row and 1 WaterData row, got '
              + ISNULL(CAST(@codes7 AS nvarchar(10)), N'NULL') + N' / ' + ISNULL(CAST(@data7 AS nvarchar(10)), N'NULL');
    RAISERROR (@msg7, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test07PushUsWaterDataUScode
GO
-- ---------------------------------------------------------------------------------------
-- TEST 8: the objects retired on 2026-08-11 must not come back.
--         dbo.Weather_station / dbo.sp_weather_station - never existed anywhere, no caller.
--         dbo.sp_weather_forecast16 - could never insert (omitted 3 NOT NULL columns of
--           weather_Forecast) and called a function that exists in no database.
--         dbo.Parking_Spot - superseded by dbo.Spot; its only reader was the DELETE inside
--           sp_del_river, removed with it.
--         dbo.fn_web_service_plot_json - wrapped dbo.fn_web_service_plot, renamed away in 2020;
--           calling it on production raised Invalid object name. fn_web_service_plot_json2 was
--           scaffolding returning a hard-coded string. Both production-only, no callers.
--         dbo.fn_forecast_plot - the pre-JSON ancestor of fn_forecast_plot_json; production-only
--           and orphaned. Not broken, just dead - its body is preserved in script02_Funct.sql.
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test08RetiredObjectsStayGone
    DECLARE @test_name sysname = N'Test08RetiredObjectsStayGone [schema] : retired objects are absent'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @alive8 int = -1, @list8 nvarchar(1000), @msg8 nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1./2. no fixture - the assertion is over the shipped schema itself

SELECT @alive8 = COUNT(*), @list8 = STUFF((SELECT N', ' + name FROM sys.objects
                                            WHERE name IN (N'Parking_Spot', N'sp_weather_forecast16',
                                                           N'sp_weather_station', N'Weather_station',
                                                           N'fn_web_service_plot_json', N'fn_web_service_plot_json2',
                                                           N'fn_forecast_plot')
                                            ORDER BY name FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
  FROM sys.objects
 WHERE name IN (N'Parking_Spot', N'sp_weather_forecast16', N'sp_weather_station', N'Weather_station',
                N'fn_web_service_plot_json', N'fn_web_service_plot_json2', N'fn_forecast_plot');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @alive8 = 0
    PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the retired weather-station / forecast16 / Parking_Spot / web_service_plot objects are absent'
ELSE
BEGIN
    SET @msg8 = N'TEST 8 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: retired object(s) present: '
              + ISNULL(@list8, N'<name query failed>');
    RAISERROR (@msg8, 16, -1)
END

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test08RetiredObjectsStayGone
GO
