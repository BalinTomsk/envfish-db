/*
  Unit tests for the per-tab "Save JSON" export functions used by Editor/LakeEditor.aspx and its
  sibling tab pages, served by Editor/HandlerImage.ashx?lakejson=<guid>&tab=<name>:

    dbo.fn_lake_description_json   Description  (LakeEditor.aspx)      lake fields + photos(base64)
    dbo.fn_lake_stats_json         Stats        (LakeState.aspx)       Lake_State per-month rows
    dbo.fn_lake_maps_json          Maps         (LakeMap.aspx)         lake_map attachments(base64)
    dbo.fn_lake_source_json        Source       (EditLakeLink Type=16) Tributaries side 16
    dbo.fn_lake_mouth_json         Mouth        (EditLakeLink Type=32) Tributaries side 32
    dbo.fn_lake_tributary_json     Tributary    (EditTributary.aspx)   all Tributaries rows
    dbo.fn_lake_fishing_json       Fishing      (EditLakeFish.aspx)    lake_fish rows
    dbo.fn_lake_regulation_json    Regulation   (LakeRegulation.aspx)  regulations for this lake
    dbo.fn_lake_view_json          View         (wfRiverViewer.aspx)   vw_lake + fish + photos

  Also covers the write counterparts of the Source/Mouth tabs (docapi RiverController):
    dbo.sp_lake_source_update      PATCH /api/v1/river/source/{guid}   merge-patch, Tributaries side 16
    dbo.sp_lake_mouth_update       PATCH /api/v1/river/mouth/{guid}    merge-patch, Tributaries side 32

  Real tables only. Each test is its own named transaction, rolled back in its own GO batch.

  SET QUOTED_IDENTIFIER ON is required: dbo.lake and dbo.regulations carry filtered indexes, so an
  INSERT fails with Msg 1934 otherwise (same as unit_test@lake.sql).
*/
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------- TEST 1: description fields + images
BEGIN TRAN TestLakeJson1
    DECLARE @test_name sysname = N'TestLakeJson1 [fn_lake_description_json] : fields + images array';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, descript) VALUES (@Lake, 1, N'UT Lake Json', N'a description');
DECLARE @pic varbinary(max) = 0xFFD8AA010203;
INSERT INTO dbo.lake_image (lake_image_ownerid, lake_image_pic, lake_image_source, lake_image_author, lake_image_link, lake_image_hash, lake_image_stamp)
    VALUES (@Lake, @pic, N'a source', N'an author', N'http://example/x.jpg', HASHBYTES('MD5', @pic), '2026-01-01');
DECLARE @json nvarchar(max) = dbo.fn_lake_description_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.lakeName')          = N'UT Lake Json'
   AND JSON_VALUE(@json, '$.guid')              = CONVERT(varchar(36), @Lake)
   AND JSON_VALUE(@json, '$.description')        = N'a description'
   AND JSON_QUERY(@json, '$.images')            IS NOT NULL
   AND JSON_VALUE(@json, '$.images[0].author')  = N'an author'
   AND JSON_VALUE(@json, '$.images[1].id')      IS NULL
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_description_json returns the fields and a 1-element images array';
ELSE RAISERROR('TEST 1 FAIL [%dms]: expected populated fields and one image', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson1
GO
-- ---------------------------------------------------------------------------- TEST 2: description photo bytes round-trip
BEGIN TRAN TestLakeJson2
    DECLARE @test_name sysname = N'TestLakeJson2 [fn_lake_description_json] : photo bytes round-trip base64';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Lake Json 2');
DECLARE @pic varbinary(max) = 0x89504E470D0A1A0A0000000D49484452;
INSERT INTO dbo.lake_image (lake_image_ownerid, lake_image_pic, lake_image_source, lake_image_author, lake_image_link, lake_image_hash, lake_image_stamp)
    VALUES (@Lake, @pic, N's', N'a', N'l', HASHBYTES('MD5', @pic), '2026-01-01');
DECLARE @json nvarchar(max) = dbo.fn_lake_description_json(@Lake);
DECLARE @b64 varchar(max) = JSON_VALUE(@json, '$.images[0].pic');
DECLARE @decoded varbinary(max) = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@b64"))', 'varbinary(max)');
IF @decoded = @pic SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: description images[0].pic base64 decodes back to the stored bytes';
ELSE RAISERROR('TEST 2 FAIL [%dms]: decoded base64 did not equal the stored picture bytes', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson2
GO
-- ---------------------------------------------------------------------------- TEST 3: stats
BEGIN TRAN TestLakeJson3
    DECLARE @test_name sysname = N'TestLakeJson3 [fn_lake_stats_json] : per-month Lake_State rows';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Stats');
INSERT INTO dbo.Lake_State (Lake_id, [month], water_degree, PH, cold_cool, stamp) VALUES (@Lake, 6, 15, 7.2, 1, '2026-01-01');
DECLARE @json nvarchar(max) = dbo.fn_lake_stats_json(@Lake);
-- The Stats page edits one month at a time, so the export must carry ALL 12 months: real data where a
-- Lake_State row exists (hasData=true), a placeholder with null measurements otherwise (hasData=false).
IF @json IS NOT NULL
   AND CAST(JSON_VALUE(@json, '$.states[0].month')  AS int)       = 1        -- Jan present even with no row
   AND JSON_VALUE(@json, '$.states[0].hasData')                   = 'false'
   AND JSON_VALUE(@json, '$.states[0].waterDegree')               IS NULL
   AND CAST(JSON_VALUE(@json, '$.states[5].month')  AS int)       = 6        -- Jun has the row
   AND CAST(JSON_VALUE(@json, '$.states[5].waterDegree') AS float) = 15
   AND JSON_VALUE(@json, '$.states[5].coldCool')                  = 'true'
   AND JSON_VALUE(@json, '$.states[5].hasData')                   = 'true'
   AND CAST(JSON_VALUE(@json, '$.states[11].month') AS int)       = 12       -- exactly 12 entries
   AND JSON_VALUE(@json, '$.states[12].month')                    IS NULL
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_stats_json returns all 12 months (data + placeholders)';
ELSE BEGIN DECLARE @d3 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 3 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d3); END
ROLLBACK TRAN TestLakeJson3
GO
-- ---------------------------------------------------------------------------- TEST 4: maps + base64
BEGIN TRAN TestLakeJson4
    DECLARE @test_name sysname = N'TestLakeJson4 [fn_lake_maps_json] : attachment + base64 round-trip';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Maps');
DECLARE @pic varbinary(max) = 0x255044462D312E34;   -- "%PDF-1.4"
INSERT INTO dbo.lake_map (lake_map_ownerid, lake_map_pic, lake_map_source, lake_map_author, lake_map_link, lake_map_label, lake_map_kind, lake_map_hash, lake_map_stamp)
    VALUES (@Lake, @pic, N's', N'a', N'', N'plan.pdf', 2, HASHBYTES('MD5', @pic), '2026-01-01');
DECLARE @json nvarchar(max) = dbo.fn_lake_maps_json(@Lake);
DECLARE @b64 varchar(max) = JSON_VALUE(@json, '$.maps[0].pic');
DECLARE @decoded varbinary(max) = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@b64"))', 'varbinary(max)');
IF @json IS NOT NULL AND JSON_VALUE(@json, '$.maps[0].label') = N'plan.pdf' AND @decoded = @pic SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_maps_json returns the attachment and its bytes round-trip';
ELSE RAISERROR('TEST 4 FAIL [%dms]: expected maps[0].label=plan.pdf and matching bytes', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson4
GO
-- ---------------------------------------------------------------------------- TEST 5: source (side 16)
BEGIN TRAN TestLakeJson5
    DECLARE @test_name sysname = N'TestLakeJson5 [fn_lake_source_json] : Tributaries side 16';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Source');
-- TR_Lake_INS auto-creates the side-16 source placeholder (Lake_id = @Lake); give it a coordinate.
UPDATE dbo.Tributaries SET lat = 45.1, lon = -79.2 WHERE Main_Lake_id = @Lake AND side = 16;
DECLARE @json nvarchar(max) = dbo.fn_lake_source_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.sources[0].pointId')   = CONVERT(varchar(36), @Lake)   -- self placeholder
   AND CAST(JSON_VALUE(@json, '$.sources[0].lat') AS float) = 45.1
   AND JSON_VALUE(@json, '$.sources[1].id')        IS NULL     -- exactly one side-16 row
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_source_json returns only the side-16 link';
ELSE RAISERROR('TEST 5 FAIL [%dms]: expected one source (self placeholder) at lat 45.1', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson5
GO
-- ---------------------------------------------------------------------------- TEST 6: mouth (side 32)
BEGIN TRAN TestLakeJson6
    DECLARE @test_name sysname = N'TestLakeJson6 [fn_lake_mouth_json] : Tributaries side 32';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Mouth');
-- TR_Lake_INS auto-creates the side-32 mouth placeholder (Lake_id = @Lake).
DECLARE @json nvarchar(max) = dbo.fn_lake_mouth_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.mouths[0].pointId') = CONVERT(varchar(36), @Lake)
   AND JSON_VALUE(@json, '$.mouths[1].id')      IS NULL
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_mouth_json returns the side-32 link';
ELSE RAISERROR('TEST 6 FAIL [%dms]: expected one mouth link', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson6
GO
-- ---------------------------------------------------------------------------- TEST 7: tributary (all sides)
BEGIN TRAN TestLakeJson7
    DECLARE @test_name sysname = N'TestLakeJson7 [fn_lake_tributary_json] : all Tributaries rows';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID(); DECLARE @Point uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake,  1, N'UT Trib');         -- auto side 16,32 placeholders
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Point, 2, N'UT Trib Point');   -- FK target for the inflow row
-- an inflow tributary (side 4) from @Point into @Lake, on top of @Lake's two self placeholders
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side, Tributaries_stamp) VALUES (@Lake, @Point, 4, '2026-01-01');
DECLARE @json nvarchar(max) = dbo.fn_lake_tributary_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.tributaries[0].side')      = '4'                              -- ordered by side: 4, 16, 32
   AND JSON_VALUE(@json, '$.tributaries[0].pointId')   = CONVERT(varchar(36), @Point)
   AND JSON_VALUE(@json, '$.tributaries[0].pointName') = N'UT Trib Point'
   AND JSON_VALUE(@json, '$.tributaries[2].side')      = '32'
   AND JSON_VALUE(@json, '$.tributaries[3].id')        IS NULL
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_tributary_json returns all rows (inflow + 2 placeholders) ordered by side';
ELSE RAISERROR('TEST 7 FAIL [%dms]: expected side 4 (named point) then placeholders 16,32', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson7
GO
-- ---------------------------------------------------------------------------- TEST 8: fishing
BEGIN TRAN TestLakeJson8
    DECLARE @test_name sysname = N'TestLakeJson8 [fn_lake_fishing_json] : assigned lake_fish';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID(); DECLARE @Fish uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Fishing');
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, status, note, stamp) VALUES (@Lake, @Fish, 2, N'a note', '2026-01-01');
DECLARE @json nvarchar(max) = dbo.fn_lake_fishing_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.fish[0].fishId') = CONVERT(varchar(36), @Fish)
   AND JSON_VALUE(@json, '$.fish[0].status') = '2'
   AND JSON_VALUE(@json, '$.fish[0].note')   = N'a note'
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_fishing_json returns the assigned fish';
ELSE RAISERROR('TEST 8 FAIL [%dms]: expected fish[0].fishId to match', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson8
GO
-- ---------------------------------------------------------------------------- TEST 9: regulation
BEGIN TRAN TestLakeJson9
    DECLARE @test_name sysname = N'TestLakeJson9 [fn_lake_regulation_json] : regulations for this lake';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT Reg');
INSERT INTO dbo.regulations (regulations_part, resident_type, state, Lake_id, reg_year, regulations_sport) VALUES (N'', 0, 'ON', @Lake, 2026, 4);
DECLARE @json nvarchar(max) = dbo.fn_lake_regulation_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.regulations[0].regYear') = '2026'
   AND JSON_VALUE(@json, '$.regulations[0].sport')   = '4'
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_regulation_json returns the lake rule';
ELSE RAISERROR('TEST 9 FAIL [%dms]: expected regulations[0].regYear=2026', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson9
GO
-- ---------------------------------------------------------------------------- TEST 10: view + empty arrays
BEGIN TRAN TestLakeJson10
    DECLARE @test_name sysname = N'TestLakeJson10 [fn_lake_view_json] : core + empty fish/images arrays';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, descript) VALUES (@Lake, 2, N'UT View', N'v');
DECLARE @json nvarchar(max) = dbo.fn_lake_view_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.lakeName')   = N'UT View'
   AND JSON_VALUE(@json, '$.type')       = '2'
   AND JSON_QUERY(@json, '$.fish')       = '[]'
   AND JSON_QUERY(@json, '$.images')     = '[]'
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_view_json returns core fields and empty arrays';
ELSE RAISERROR('TEST 10 FAIL [%dms]: expected view core + empty fish/images arrays', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson10
GO
-- ---------------------------------------------------------------------------- TEST 11: every function -> NULL for unknown id
BEGIN TRAN TestLakeJson11
    DECLARE @test_name sysname = N'TestLakeJson11 [fn_lake_*_json] : unknown id returns NULL';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @z uniqueidentifier = '00000000-0000-0000-0000-000000000000';
IF  dbo.fn_lake_description_json(@z) IS NULL
AND dbo.fn_lake_stats_json(@z)       IS NULL
AND dbo.fn_lake_maps_json(@z)        IS NULL
AND dbo.fn_lake_source_json(@z)      IS NULL
AND dbo.fn_lake_mouth_json(@z)       IS NULL
AND dbo.fn_lake_tributary_json(@z)   IS NULL
AND dbo.fn_lake_fishing_json(@z)     IS NULL
AND dbo.fn_lake_regulation_json(@z)  IS NULL
AND dbo.fn_lake_view_json(@z)        IS NULL
AND dbo.fn_lake_weather_json(@z)     IS NULL
AND dbo.fn_lake_fishing_view_json(@z) IS NULL
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: all eleven functions return NULL for an unknown lake id';
ELSE RAISERROR('TEST 11 FAIL [%dms]: a function returned non-NULL for an unknown lake id', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson11
GO
-- ---------------------------------------------------------------------------- TEST 12: weather (empty stations)
BEGIN TRAN TestLakeJson12
    DECLARE @test_name sysname = N'TestLakeJson12 [fn_lake_weather_json] : core + empty stations array';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 2, N'UT Weather');
DECLARE @json nvarchar(max) = dbo.fn_lake_weather_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.lakeName') = N'UT Weather'
   AND JSON_QUERY(@json, '$.stations') = '[]'                 -- no monitoring stations attached
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 12 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_weather_json returns core + empty stations array';
ELSE BEGIN DECLARE @d12 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 12 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d12); END
ROLLBACK TRAN TestLakeJson12
GO
-- ---------------------------------------------------------------------------- TEST 13: fishing view (empty)
BEGIN TRAN TestLakeJson13
    DECLARE @test_name sysname = N'TestLakeJson13 [fn_lake_fishing_view_json] : core + empty species/catchLog';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 2, N'UT FishView');
DECLARE @json nvarchar(max) = dbo.fn_lake_fishing_view_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.lakeName')  = N'UT FishView'
   AND JSON_QUERY(@json, '$.species')   = '[]'                -- no assigned fish
   AND JSON_QUERY(@json, '$.catchLog')  = '[]'                -- no catch memos
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 13 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_fishing_view_json returns core + empty species/catchLog';
ELSE BEGIN DECLARE @d13 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 13 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d13); END
ROLLBACK TRAN TestLakeJson13
GO
-- ---------------------------------------------------------------------------- TEST 14: fishing view catch log + base64 photo
BEGIN TRAN TestLakeJson14
    DECLARE @test_name sysname = N'TestLakeJson14 [fn_lake_fishing_view_json] : catch log memo + base64 photo';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
DECLARE @Memo uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 2, N'UT FishView2');
INSERT INTO dbo.catch_memo (catch_memo_id, catch_memo_lake_id, catch_memo_userid, catch_memo_private, catch_memo_created)
    VALUES (@Memo, @Lake, NEWID(), 0, '2026-01-01');
DECLARE @pic varbinary(max) = 0xFFD8FFE000104A46;
INSERT INTO dbo.catch_memo_photo (catch_memo_photo_id, catch_memo_photo_memoid, catch_memo_photo_pic, catch_memo_photo_hidden)
    VALUES (NEWID(), @Memo, @pic, 0);
DECLARE @json nvarchar(max) = dbo.fn_lake_fishing_view_json(@Lake);
DECLARE @b64 varchar(max) = JSON_VALUE(@json, '$.catchLog[0].photos[0].catch_memo_photo_pic');
DECLARE @decoded varbinary(max) = CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@b64"))', 'varbinary(max)');
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.catchLog[0].catch_memo_id') = CONVERT(varchar(36), @Memo)
   AND @decoded = @pic
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 14 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: catchLog carries the memo and its photo round-trips base64';
ELSE BEGIN DECLARE @d14 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 14 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d14); END
ROLLBACK TRAN TestLakeJson14
GO
-- ---------------------------------------------------------------------------- TEST 15: sp_lake_source_update patches editable fields
BEGIN TRAN TestLakeJson15
    DECLARE @test_name sysname = N'TestLakeJson15 [sp_lake_source_update] : merge-patch editable fields';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT SourceUpd');
DECLARE @patch nvarchar(max) = N'{"lat":52.1,"lon":-95.4,"elevation":355,"country":"CA","state":"ON",
    "county":"Kenora","city":"Sioux Lookout","district":"Kenora","municipality":"Sioux Lookout",
    "region":"Northwestern Ontario","zone":5,"coast":"L","location":"Headwater","description":"A small headwater creek."}';
DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_source_update @Lake, @patch;
DECLARE @json nvarchar(max) = (SELECT TOP 1 results FROM @t);
DECLARE @doc nvarchar(max) = dbo.fn_lake_source_json(@Lake);
IF @json IS NOT NULL
   AND JSON_VALUE(@json, '$.lakeId') = CONVERT(varchar(36), @Lake)
   AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.updated')) = 14
   AND JSON_QUERY(@json, '$.protectedFields') = '[]'
   AND CAST(JSON_VALUE(@doc, '$.sources[0].lat') AS float) = 52.1
   AND JSON_VALUE(@doc, '$.sources[0].city') = N'Sioux Lookout'
   AND JSON_VALUE(@doc, '$.sources[0].description') = N'A small headwater creek.'
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 15 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_lake_source_update writes all 14 editable fields and reports them updated';
ELSE BEGIN DECLARE @d15 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 15 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d15); END
ROLLBACK TRAN TestLakeJson15
GO
-- ---------------------------------------------------------------------------- TEST 16: sp_lake_source_update protects identity/linkage fields
BEGIN TRAN TestLakeJson16
    DECLARE @test_name sysname = N'TestLakeJson16 [sp_lake_source_update] : identity fields are protected, not applied';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
DECLARE @Other uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT SourceProt');
DECLARE @patch nvarchar(max) = N'{"guid":"' + CONVERT(varchar(36), @Other) + N'","lakeName":"Hijacked",
    "id":999,"pointId":"' + CONVERT(varchar(36), @Other) + N'","pointName":"Hijacked Point","stamp":"2000-01-01T00:00:00"}';
DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_source_update @Lake, @patch;
DECLARE @json nvarchar(max) = (SELECT TOP 1 results FROM @t);
DECLARE @doc nvarchar(max) = dbo.fn_lake_source_json(@Lake);
IF @json IS NOT NULL
   AND JSON_QUERY(@json, '$.updated') = '[]'
   AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.protectedFields')) = 6
   AND JSON_VALUE(@doc, '$.lakeName') = N'UT SourceProt'                       -- unchanged
   AND JSON_VALUE(@doc, '$.sources[0].pointId') = CONVERT(varchar(36), @Lake)  -- still the self placeholder
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 16 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_lake_source_update reports 6 protected fields and applies none of them';
ELSE BEGIN DECLARE @d16 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 16 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d16); END
ROLLBACK TRAN TestLakeJson16
GO
-- ---------------------------------------------------------------------------- TEST 17: sp_lake_mouth_update targets side 32 only
BEGIN TRAN TestLakeJson17
    DECLARE @test_name sysname = N'TestLakeJson17 [sp_lake_mouth_update] : patches side 32, leaves side 16 untouched';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT MouthUpd');
DECLARE @patch nvarchar(max) = N'{"lat":51.9,"lon":-94.8,"elevation":198}';
DECLARE @t TABLE (results nvarchar(max));
INSERT INTO @t EXEC dbo.sp_lake_mouth_update @Lake, @patch;
DECLARE @json nvarchar(max) = (SELECT TOP 1 results FROM @t);
DECLARE @mouthDoc nvarchar(max) = dbo.fn_lake_mouth_json(@Lake);
DECLARE @sourceDoc nvarchar(max) = dbo.fn_lake_source_json(@Lake);
IF @json IS NOT NULL
   AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.updated')) = 3
   AND CAST(JSON_VALUE(@mouthDoc, '$.mouths[0].lat') AS float) = 51.9
   AND JSON_VALUE(@sourceDoc, '$.sources[0].lat') IS NULL                     -- side-16 row unaffected
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 17 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_lake_mouth_update writes only the side-32 row';
ELSE BEGIN DECLARE @d17 varchar(400) = LEFT(ISNULL(@json, '<NULL>'), 380); RAISERROR('TEST 17 FAIL [%dms]: %s', 16, -1, @ElapsedMs, @d17); END
ROLLBACK TRAN TestLakeJson17
GO
-- ---------------------------------------------------------------------------- TEST 18: unknown lake id + malformed JSON
BEGIN TRAN TestLakeJson18
    DECLARE @test_name sysname = N'TestLakeJson18 [sp_lake_source_update/sp_lake_mouth_update] : unknown id -> NULL, bad JSON -> protected error';
DECLARE @tStart datetime2, @ElapsedMs int; DECLARE @ok int = 0;
BEGIN TRY  SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @Unknown uniqueidentifier = NEWID();
DECLARE @Lake uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@Lake, 1, N'UT BadPatch');
DECLARE @t1 TABLE (results nvarchar(max));
INSERT INTO @t1 EXEC dbo.sp_lake_source_update @Unknown, N'{"lat":1}';
DECLARE @t2 TABLE (results nvarchar(max));
INSERT INTO @t2 EXEC dbo.sp_lake_mouth_update @Unknown, N'{"lat":1}';
DECLARE @t3 TABLE (results nvarchar(max));
INSERT INTO @t3 EXEC dbo.sp_lake_source_update @Lake, N'not-json';
DECLARE @badJson nvarchar(max) = (SELECT TOP 1 results FROM @t3);
IF (SELECT TOP 1 results FROM @t1) IS NULL
   AND (SELECT TOP 1 results FROM @t2) IS NULL
   AND @badJson IS NOT NULL
   AND JSON_QUERY(@badJson, '$.updated') = '[]'
   AND JSON_VALUE(@badJson, '$.protectedFields[0].reason') = N'body is not well-formed JSON'
   SET @ok = 1;
END TRY
BEGIN CATCH SELECT ERROR_NUMBER() AS ErrorNumber, @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage; END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 18 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown lake id returns NULL for both procs; malformed JSON reports a protected-field error';
ELSE RAISERROR('TEST 18 FAIL [%dms]: expected NULL for unknown id and a protectedFields error for malformed JSON', 16, -1, @ElapsedMs);
ROLLBACK TRAN TestLakeJson18
GO
