/*
  Unit tests for dbo.fn_lake_view_info (Resources/wfRiverViewer.aspx, LoadRiver). The page's
  "second name" line under the title picks the first present of Alt. Name, French, Former name,
  Native Name, reading these exact XML node names off this function's output - so the node names
  and values are locked in here.

  Real tables only. Each test is its own named transaction, rolled back in its own GO batch.

  SET QUOTED_IDENTIFIER ON is required: dbo.lake carries a filtered index, so an INSERT fails with
  Msg 1934 otherwise (same as unit_test@lake.sql / unit_test@LakeJson.sql).
*/
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------- TEST 1: former_name node is emitted
BEGIN TRAN TestLakeViewInfo1
    DECLARE @test_name sysname = N'TestLakeViewInfo1 [fn_lake_view_info] : former_name node is emitted';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, alt_name, french_name, former_name, [native])
    VALUES (@Lake, 2, N'UT View Info River', N'UT Alt', N'UT French', N'UT Former', N'UT Native');
DECLARE @doc xml = (SELECT CAST(doc AS xml) FROM dbo.fn_lake_view_info(@Lake));
DECLARE @former nvarchar(255) = @doc.value('(/root/node[@name="former_name"]/text())[1]', 'nvarchar(255)');
IF @former = N'UT Former' SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_view_info emits a former_name node with the lake''s former_name';
ELSE RAISERROR('TEST 1 FAIL [%dms]: former_name node missing or wrong value', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeViewInfo1
GO
-- ---------------------------------------------------------------------------- TEST 2: all 4 name-priority nodes present under the exact tag names the app reads
BEGIN TRAN TestLakeViewInfo2
    DECLARE @test_name sysname = N'TestLakeViewInfo2 [fn_lake_view_info] : alt_name/french_name/former_name/native node names';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, alt_name, french_name, former_name, [native])
    VALUES (@Lake, 2, N'UT View Info River 2', N'UT Alt2', N'UT French2', N'UT Former2', N'UT Native2');
DECLARE @doc xml = (SELECT CAST(doc AS xml) FROM dbo.fn_lake_view_info(@Lake));
IF @doc.value('(/root/node[@name="alt_name"]/text())[1]', 'nvarchar(255)')        = N'UT Alt2'
   AND @doc.value('(/root/node[@name="french_name"]/text())[1]', 'nvarchar(255)') = N'UT French2'
   AND @doc.value('(/root/node[@name="former_name"]/text())[1]', 'nvarchar(255)') = N'UT Former2'
   AND @doc.value('(/root/node[@name="native"]/text())[1]', 'nvarchar(255)')      = N'UT Native2'
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: all four name nodes render under the exact tag names the app selects';
ELSE RAISERROR('TEST 2 FAIL [%dms]: one or more name nodes missing/mismatched', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeViewInfo2
GO
