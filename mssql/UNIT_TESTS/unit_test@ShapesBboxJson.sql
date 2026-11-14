SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_shapes_bbox_geojson(@west, @south, @east, @north, @zoom, @limit): the Lake_Shape shapes
  crossing a bounding box, simplified per zoom, as GeoJSON (docapi GET /api/v1/map/shapes, envfish-droid P0-10).
  Test shapes sit in the Beaufort Sea (-140.5..-138.8, 69.8..70), where no real shape is.

  TEST 1 - west >= east, over 5 deg, NULL edge -> NULL
  TEST 2 - box without shapes -> empty FeatureCollection
  TEST 3 - lake outline in the box -> Polygon, lakeId, name
  TEST 4 - shape outside the box -> left out
  TEST 5 - river crossing the box -> whole line, not clipped
  TEST 6 - pond under 2 px: out at zoom 6, in at zoom 16
  TEST 7 - limit 2 of 3 -> the longest 2, truncated
  TEST 8 - 401-point zigzag: few points at zoom 8, all at 22
*/
PRINT 'Unit tests for fn_shapes_bbox_geojson (map shapes in a box)';
GO
-- ============================================================================
-- TEST 1: bad box
-- ============================================================================
BEGIN TRAN SBJ_Test1
    declare @test_name sysname = N'SBJ_Test1 [fn_shapes_bbox_geojson] : bad box'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_shapes_bbox_geojson(-60, 45, -61, 46, 10, NULL);
SET @j2 = dbo.fn_shapes_bbox_geojson(-70, 45, -60, 46, 10, NULL);
SET @j3 = dbo.fn_shapes_bbox_geojson(-60, 45, NULL, 46, 10, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NOT NULL OR @j2 IS NOT NULL OR @j3 IS NOT NULL
   RAISERROR ('TEST 1 FAIL [%dms]: west >= east, over 5 deg, NULL edge -> NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: west >= east, over 5 deg, NULL edge -> NULL'

ROLLBACK TRAN SBJ_Test1
GO
-- ============================================================================
-- TEST 2: empty box
-- ============================================================================
BEGIN TRAN SBJ_Test2
    declare @test_name sysname = N'SBJ_Test2 [fn_shapes_bbox_geojson] : empty box'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_shapes_bbox_geojson(-139.5, 69.5, -139.4, 69.6, 12, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR JSON_VALUE(@json, '$.type') <> 'FeatureCollection'
  OR JSON_QUERY(@json, '$.features') <> N'[]' OR JSON_VALUE(@json, '$.truncated') <> 'false'
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.bbox[0]')) <> -139.5
  OR TRY_CONVERT(int, JSON_VALUE(@json, '$.zoom')) <> 12
   RAISERROR ('TEST 2 FAIL [%dms]: box without shapes -> empty FeatureCollection', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: box without shapes -> empty FeatureCollection'

ROLLBACK TRAN SBJ_Test2
GO
-- ============================================================================
-- TEST 3: outline inside
-- ============================================================================
BEGIN TRAN SBJ_Test3
    declare @test_name sysname = N'SBJ_Test3 [fn_shapes_bbox_geojson] : outline inside'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsbj Lake');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp)
VALUES (@L, geography::STGeomFromText('POLYGON((-139.9 69.9, -139.8 69.9, -139.8 69.95, -139.9 69.95, -139.9 69.9))', 4326), 2, GETUTCDATE());
SET @json = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 12, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features')) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.features[0].properties.lakeId')) <> @L
  OR JSON_VALUE(@json, '$.features[0].properties.lakeName') <> N'Utsbj Lake'
  OR JSON_VALUE(@json, '$.features[0].properties.kind') <> 'outline'
  OR TRY_CONVERT(int, JSON_VALUE(@json, '$.features[0].properties.locType')) <> 1
  OR JSON_VALUE(@json, '$.features[0].geometry.type') <> 'Polygon'
   RAISERROR ('TEST 3 FAIL [%dms]: lake outline in the box -> Polygon, lakeId, name', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lake outline in the box -> Polygon, lakeId, name'

ROLLBACK TRAN SBJ_Test3
GO
-- ============================================================================
-- TEST 4: outside
-- ============================================================================
BEGIN TRAN SBJ_Test4
    declare @test_name sysname = N'SBJ_Test4 [fn_shapes_bbox_geojson] : outside'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsbj Far Lake');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp)
VALUES (@L, geography::STGeomFromText('POLYGON((-138.9 69.9, -138.8 69.9, -138.8 69.95, -138.9 69.95, -138.9 69.9))', 4326), 2, GETUTCDATE());
SET @json = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 12, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR JSON_QUERY(@json, '$.features') <> N'[]'
   RAISERROR ('TEST 4 FAIL [%dms]: shape outside the box -> left out', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: shape outside the box -> left out'

ROLLBACK TRAN SBJ_Test4
GO
-- ============================================================================
-- TEST 5: river through
-- ============================================================================
BEGIN TRAN SBJ_Test5
    declare @test_name sysname = N'SBJ_Test5 [fn_shapes_bbox_geojson] : river through'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utsbj River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp)
VALUES (@L, geography::STGeomFromText('LINESTRING(-140.5 69.85, -139.85 69.9, -139.2 69.95)', 4326), 1, GETUTCDATE());
SET @json = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 22, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features')) <> 1
  OR JSON_VALUE(@json, '$.features[0].geometry.type') <> 'LineString'
  OR JSON_VALUE(@json, '$.features[0].properties.kind') <> 'line'
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.features[0].geometry.coordinates[0][0]')) <> -140.5
   RAISERROR ('TEST 5 FAIL [%dms]: river crossing the box -> whole line, not clipped', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: river crossing the box -> whole line, not clipped'

ROLLBACK TRAN SBJ_Test5
GO
-- ============================================================================
-- TEST 6: tiny shape
-- ============================================================================
BEGIN TRAN SBJ_Test6
    declare @test_name sysname = N'SBJ_Test6 [fn_shapes_bbox_geojson] : tiny shape'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utsbj Pond');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp)
VALUES (@L, geography::STGeomFromText('POLYGON((-139.85 69.9, -139.849 69.9, -139.849 69.9005, -139.85 69.9005, -139.85 69.9))', 4326), 2, GETUTCDATE());
SET @json = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 6, NULL);
SET @j2 = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 16, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR JSON_QUERY(@json, '$.features') <> N'[]' OR (SELECT COUNT(*) FROM OPENJSON(@j2, '$.features')) <> 1
   RAISERROR ('TEST 6 FAIL [%dms]: pond under 2 px: out at zoom 6, in at zoom 16', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: pond under 2 px: out at zoom 6, in at zoom 16'

ROLLBACK TRAN SBJ_Test6
GO
-- ============================================================================
-- TEST 7: limit
-- ============================================================================
BEGIN TRAN SBJ_Test7
    declare @test_name sysname = N'SBJ_Test7 [fn_shapes_bbox_geojson] : limit'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utsbj River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp)
SELECT @L, geography::STGeomFromText(v.w, 4326), 1, GETUTCDATE()
  FROM (VALUES ('LINESTRING(-139.95 69.85, -139.9 69.86)'), ('LINESTRING(-139.95 69.87, -139.75 69.88)'),
               ('LINESTRING(-139.95 69.9, -139.85 69.91)')) v(w);
SET @json = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 14, 2);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features')) <> 2 OR JSON_VALUE(@json, '$.truncated') <> 'true'
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.features[0].geometry.coordinates[1][0]')) <> -139.75
   RAISERROR ('TEST 7 FAIL [%dms]: limit 2 of 3 -> the longest 2, truncated', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: limit 2 of 3 -> the longest 2, truncated'

ROLLBACK TRAN SBJ_Test7
GO
-- ============================================================================
-- TEST 8: zoom simplifies
-- ============================================================================
BEGIN TRAN SBJ_Test8
    declare @test_name sysname = N'SBJ_Test8 [fn_shapes_bbox_geojson] : zoom simplifies'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set', @j2 nvarchar(max), @j3 nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utsbj Zigzag');
DECLARE @w nvarchar(max) = N'LINESTRING(' + (SELECT STRING_AGG(CAST(CONCAT(-139.95 + n * 0.0005, ' ', 69.9 + (n % 2) * 0.0001) AS nvarchar(max)), ', ')
        WITHIN GROUP (ORDER BY n)
    FROM (SELECT TOP 401 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n FROM sys.all_objects) t) + N')';
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp)
VALUES (@L, geography::STGeomFromText(@w, 4326), 1, GETUTCDATE());
SET @json = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 8, NULL);
SET @j2 = dbo.fn_shapes_bbox_geojson(-140, 69.8, -139.7, 70, 22, NULL);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features[0].geometry.coordinates')) > 10
  OR (SELECT COUNT(*) FROM OPENJSON(@j2, '$.features[0].geometry.coordinates')) < 300
   RAISERROR ('TEST 8 FAIL [%dms]: 401-point zigzag: few points at zoom 8, all at 22', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: 401-point zigzag: few points at zoom 8, all at 22'

ROLLBACK TRAN SBJ_Test8
GO
