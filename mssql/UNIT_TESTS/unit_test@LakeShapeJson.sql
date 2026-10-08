SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lake_shape_geojson(@lake_id): the shapes of one water body (dbo.Lake_Shape) as a GeoJSON
  FeatureCollection, for drawing on a map. No caller yet; planned for the site's Leaflet maps / docapi.

  TEST 1 - unknown water body                         -> NULL
  TEST 2 - water body without shapes                  -> FeatureCollection with an empty features array
  TEST 3 - a river line (type 1, LineString)          -> one LineString feature, kind "line", [lon,lat] order
  TEST 4 - a lake outline with an island (type 2)     -> Polygon with 2 rings, kind "outline"
  TEST 5 - MultiLineString + MultiPolygon             -> right GeoJSON types and nesting depth
  TEST 6 - shapes of another water body               -> not included
*/
PRINT 'Unit tests for fn_lake_shape_geojson (map shapes of a water body)';
GO
-- ============================================================================
-- TEST 1: unknown water body
-- ============================================================================
BEGIN TRAN LSJ_Test1
    declare @test_name sysname = N'LSJ_Test1 [fn_lake_shape_geojson] : unknown'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max) = N'not set';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @json = dbo.fn_lake_shape_geojson(NEWID());

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @json IS NOT NULL
   RAISERROR ('TEST 1 FAIL [%dms]: an unknown water body must give NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown water body -> NULL'

ROLLBACK TRAN LSJ_Test1
GO
-- ============================================================================
-- TEST 2: no shapes -> empty FeatureCollection
-- ============================================================================
BEGIN TRAN LSJ_Test2
    declare @test_name sysname = N'LSJ_Test2 [fn_lake_shape_geojson] : no shapes'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utlsj Empty Lake');
SET @json = dbo.fn_lake_shape_geojson(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISJSON(@json) <> 1
  OR JSON_VALUE(@json, '$.type') <> 'FeatureCollection'
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$.guid')) <> @L
  OR JSON_QUERY(@json, '$.features') <> N'[]'
   RAISERROR ('TEST 2 FAIL [%dms]: no shapes must give an empty FeatureCollection', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no shapes -> empty FeatureCollection'

ROLLBACK TRAN LSJ_Test2
GO
-- ============================================================================
-- TEST 3: a river line
-- ============================================================================
BEGIN TRAN LSJ_Test3
    declare @test_name sysname = N'LSJ_Test3 [fn_lake_shape_geojson] : LineString'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlsj River');
-- Lake_Shape_hash is supplied (as sp_add_lake_shape does): UK_Lake_Shape is unique and the trigger fills it only after insert
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp, Lake_Shape_hash)
SELECT v.id, v.g, v.t, GETUTCDATE(), CAST(HASHBYTES('MD5', v.g.ToString()) AS bigint)
FROM (VALUES (@L, geography::STGeomFromText('LINESTRING(-66.5 46.1, -66.4 46.2, -66.3 46.25)', 4326), 1)) v(id, g, t);
SET @json = dbo.fn_lake_shape_geojson(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features')) <> 1
  OR JSON_VALUE(@json, '$.features[0].type') <> 'Feature'
  OR JSON_VALUE(@json, '$.features[0].geometry.type') <> 'LineString'
  OR JSON_VALUE(@json, '$.features[0].properties.kind') <> 'line'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features[0].geometry.coordinates')) <> 3
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.features[0].geometry.coordinates[0][0]')) <> -66.5
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.features[0].geometry.coordinates[0][1]')) <> 46.1
   RAISERROR ('TEST 3 FAIL [%dms]: river line must be one LineString, [lon,lat], 3 points', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: river line -> LineString in [lon,lat]'

ROLLBACK TRAN LSJ_Test3
GO
-- ============================================================================
-- TEST 4: a lake outline with an island
-- ============================================================================
BEGIN TRAN LSJ_Test4
    declare @test_name sysname = N'LSJ_Test4 [fn_lake_shape_geojson] : Polygon with hole'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 1, N'Utlsj Island Lake');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp, Lake_Shape_hash)
SELECT v.id, v.g, v.t, GETUTCDATE(), CAST(HASHBYTES('MD5', v.g.ToString()) AS bigint)
FROM (VALUES (@L, geography::STGeomFromText('POLYGON((-66 46, -65.9 46, -65.9 46.1, -66 46.1, -66 46), (-65.97 46.03, -65.97 46.06, -65.93 46.06, -65.93 46.03, -65.97 46.03))', 4326), 2)) v(id, g, t);
SET @json = dbo.fn_lake_shape_geojson(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISJSON(@json) <> 1
  OR JSON_VALUE(@json, '$.features[0].geometry.type') <> 'Polygon'
  OR JSON_VALUE(@json, '$.features[0].properties.kind') <> 'outline'
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features[0].geometry.coordinates')) <> 2
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features[0].geometry.coordinates[0]')) <> 5
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.features[0].geometry.coordinates[0][0][0]')) IS NULL
   RAISERROR ('TEST 4 FAIL [%dms]: outline must be a Polygon with 2 rings of points', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lake outline -> Polygon, 2 rings'

ROLLBACK TRAN LSJ_Test4
GO
-- ============================================================================
-- TEST 5: MultiLineString and MultiPolygon
-- ============================================================================
BEGIN TRAN LSJ_Test5
    declare @test_name sysname = N'LSJ_Test5 [fn_lake_shape_geojson] : multi types'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlsj Braided River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp, Lake_Shape_hash)
SELECT v.id, v.g, v.t, GETUTCDATE(), CAST(HASHBYTES('MD5', v.g.ToString()) AS bigint)
FROM (VALUES (@L, geography::STGeomFromText('MULTILINESTRING((-66.5 46.1, -66.4 46.2), (-66.3 46.3, -66.2 46.4, -66.1 46.45))', 4326), 1),
             (@L, geography::STGeomFromText('MULTIPOLYGON(((-66 46, -65.9 46, -65.9 46.1, -66 46.1, -66 46)), ((-65 47, -64.9 47, -64.9 47.1, -65 47.1, -65 47)))', 4326), 2)) v(id, g, t);
SET @json = dbo.fn_lake_shape_geojson(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json, '$.features')) <> 2
  OR NOT EXISTS (SELECT 1 FROM OPENJSON(@json, '$.features') f WHERE JSON_VALUE(f.value, '$.geometry.type') = 'MultiLineString'
                    AND (SELECT COUNT(*) FROM OPENJSON(f.value, '$.geometry.coordinates[1]')) = 3)
  OR NOT EXISTS (SELECT 1 FROM OPENJSON(@json, '$.features') f WHERE JSON_VALUE(f.value, '$.geometry.type') = 'MultiPolygon'
                    AND (SELECT COUNT(*) FROM OPENJSON(f.value, '$.geometry.coordinates')) = 2
                    AND TRY_CONVERT(float, JSON_VALUE(f.value, '$.geometry.coordinates[1][0][0][0]')) IS NOT NULL)
   RAISERROR ('TEST 5 FAIL [%dms]: MultiLineString / MultiPolygon must nest correctly', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: MultiLineString + MultiPolygon nested right'

ROLLBACK TRAN LSJ_Test5
GO
-- ============================================================================
-- TEST 6: shapes of another water body are not included
-- ============================================================================
BEGIN TRAN LSJ_Test6
    declare @test_name sysname = N'LSJ_Test6 [fn_lake_shape_geojson] : own shapes only'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID(), @Other uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlsj Own River'), (@Other, 2, N'Utlsj Other River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type, Lake_Shape_stamp, Lake_Shape_hash)
SELECT v.id, v.g, v.t, GETUTCDATE(), CAST(HASHBYTES('MD5', v.g.ToString()) AS bigint)
FROM (VALUES (@L, geography::STGeomFromText('LINESTRING(-66.5 46.1, -66.4 46.2)', 4326), 1),
             (@Other, geography::STGeomFromText('LINESTRING(-67.5 46.1, -67.4 46.2)', 4326), 1)) v(id, g, t);
SET @json = dbo.fn_lake_shape_geojson(@L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json, '$.features')) <> 1
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$.features[0].geometry.coordinates[0][0]')) <> -66.5
   RAISERROR ('TEST 6 FAIL [%dms]: only the water body''s own shapes may be returned', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: own shapes only'

ROLLBACK TRAN LSJ_Test6
GO
