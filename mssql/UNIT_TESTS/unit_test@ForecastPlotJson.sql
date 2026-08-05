SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_forecast_plot_json (one JSON document per monitoring station for the
  Highcharts forecast plot; caller: FishTracker.Forecast.Plot.GetJsonPlot -- Forecast/Plot.aspx.cs,
  the page shown inside the Forecast/Planning.aspx iframe).

  Focus: the "lakename" member added 2026-08-04 so the plot frame can render the water-body name
  as a link to /Resources/wfRiverViewer.aspx?LakeId=<lakeid>.

  Uses real tables dbo.Lake / dbo.WaterStation / dbo.CurrentWaterState / dbo.WaterData.
  Two fixture notes:
    * a WaterData row is required -- the document's "stamp" member reads it, and a NULL there
      would make the whole concatenated document NULL;
    * TR_insWaterData MERGEs into dbo.CurrentWaterState and its "not matched" branch omits the
      NOT NULL column sid, so the CurrentWaterState row is seeded first (matched branch).
  Each test runs in its own named transaction, rolled back at the end of its own GO batch -
  database state fully restored.

  TEST 1 - Station whose lakeid resolves     -> "lakename" carries lake.lake_name, "lakeid" matches
  TEST 2 - Station whose lakeid is an orphan -> "lakename" is empty, document still valid JSON
  TEST 3 - A lake name containing a double quote is escaped, so the document stays parseable
*/

-- ===================================================================================
-- TEST 1: the station's water body is named in the document, next to its id
-- ===================================================================================
BEGIN TRAN Test01ForecastPlotLakeName
    DECLARE @test_name sysname = N'Test01ForecastPlotLakeName [fn_forecast_plot_json] : lakename returned';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @lakename nvarchar(255), @lakeidOut varchar(36), @place varchar(255);
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake1 uniqueidentifier = NEWID();
DECLARE @St1   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 2, N'UT FPJ Grand River');
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St1, N'UT_FPJ_1', 'ON', 43.50, -80.50, 'CA', N'UT FPJ STATION NEAR ELMIRA', 2, N'UT FPJ Station 1', N'', 990401, @Lake1, N'UT FPJ Grand River', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid) VALUES (N'UT_FPJ_1', GETDATE(), 990401);
INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge, elevation)
VALUES (N'UT_FPJ_1', CAST(GETDATE() AS smalldatetime), 17, 4.2, 312.5);

SET @json = dbo.fn_forecast_plot_json(990401, '00000000-0000-0000-0000-000000000000');

SET @lakename  = JSON_VALUE(@json, '$.lakename');
SET @lakeidOut = JSON_VALUE(@json, '$.lakeid');
SET @place     = JSON_VALUE(@json, '$.place');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @lakename = N'UT FPJ Grand River'
   AND @lakeidOut = CAST(@Lake1 AS varchar(36))
   AND @place = N'UT FPJ STATION NEAR ELMIRA'
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lakename returned alongside lakeid and the station place';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: expected lakename=UT FPJ Grand River, got lakename=%s lakeid=%s', 16, -1, @ElapsedMs, @lakename, @lakeidOut);

ROLLBACK TRAN Test01ForecastPlotLakeName
GO

-- ===================================================================================
-- TEST 2: a station pointing at a lakeid with no lake row must still produce a usable
--         document - "lakename" empty, everything else intact. The caller keys the link
--         off a non-empty name, so it renders nothing rather than a dead link.
--         This state is unreachable in a freshly built database (FK_WaterStation_Lake),
--         but it is real on the live database, which carries NO foreign keys on
--         dbo.WaterStation at all and holds 514 such orphan stations. The constraint is
--         therefore switched off inside this transaction to reproduce production, and
--         switched back on before the rollback.
-- ===================================================================================
BEGIN TRAN Test02ForecastPlotOrphanLake
    DECLARE @test_name sysname = N'Test02ForecastPlotOrphanLake [fn_forecast_plot_json] : orphan lakeid -> empty lakename';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @lakename nvarchar(255), @isJson int, @place varchar(255);
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Orphan uniqueidentifier = NEWID();   -- deliberately NOT inserted into dbo.Lake
DECLARE @St2    uniqueidentifier = NEWID();

ALTER TABLE dbo.WaterStation NOCHECK CONSTRAINT FK_WaterStation_Lake;

INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St2, N'UT_FPJ_2', 'ON', 44.10, -79.90, 'CA', N'UT FPJ ORPHAN STATION', 2, N'UT FPJ Station 2', N'', 990402, @Orphan, N'UT FPJ Orphan', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid) VALUES (N'UT_FPJ_2', GETDATE(), 990402);
INSERT INTO dbo.WaterData (mli, stamp, temperature) VALUES (N'UT_FPJ_2', CAST(GETDATE() AS smalldatetime), 11);

SET @json = dbo.fn_forecast_plot_json(990402, '00000000-0000-0000-0000-000000000000');

SET @isJson   = ISJSON(@json);
SET @lakename = JSON_VALUE(@json, '$.lakename');
SET @place    = JSON_VALUE(@json, '$.place');

ALTER TABLE dbo.WaterStation CHECK CONSTRAINT FK_WaterStation_Lake;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @isJson = 1 AND @lakename = N'' AND @place = N'UT FPJ ORPHAN STATION'
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: orphan lakeid yields an empty lakename in a still-valid document';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: expected valid JSON with empty lakename, got isjson=%d lakename=%s', 16, -1, @ElapsedMs, @isJson, @lakename);

ROLLBACK TRAN Test02ForecastPlotOrphanLake
GO

-- ===================================================================================
-- TEST 3: the document is built by string concatenation, so a double quote in the name
--         would break it. It is escaped the same way locDesc already is (" -> '').
-- ===================================================================================
BEGIN TRAN Test03ForecastPlotQuotedName
    DECLARE @test_name sysname = N'Test03ForecastPlotQuotedName [fn_forecast_plot_json] : quote in lake name escaped';
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @lakename nvarchar(255), @isJson int;
BEGIN TRY SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake3 uniqueidentifier = NEWID();
DECLARE @St3   uniqueidentifier = NEWID();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'UT FPJ ' + CHAR(34) + N'Quoted' + CHAR(34) + N' Creek');
INSERT INTO dbo.WaterStation (id, MLI, state, lat, lon, country, locDesc, locType, locName, county, sid, lakeId, lakeName, supported)
VALUES (@St3, N'UT_FPJ_3', 'ON', 45.20, -78.30, 'CA', N'UT FPJ QUOTED STATION', 2, N'UT FPJ Station 3', N'', 990403, @Lake3, N'UT FPJ Quoted Creek', 1);
INSERT INTO dbo.CurrentWaterState (mli, stamp, sid) VALUES (N'UT_FPJ_3', GETDATE(), 990403);
INSERT INTO dbo.WaterData (mli, stamp, temperature) VALUES (N'UT_FPJ_3', CAST(GETDATE() AS smalldatetime), 9);

SET @json = dbo.fn_forecast_plot_json(990403, '00000000-0000-0000-0000-000000000000');

SET @isJson   = ISJSON(@json);
SET @lakename = JSON_VALUE(@json, '$.lakename');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @isJson = 1 AND @lakename = N'UT FPJ ''Quoted'' Creek'
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: double quote in the lake name escaped, document still parseable';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: expected the quotes replaced by apostrophes, got isjson=%d lakename=%s', 16, -1, @ElapsedMs, @isJson, @lakename);

ROLLBACK TRAN Test03ForecastPlotQuotedName
GO
