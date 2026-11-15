SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lakes_near_json(@lakes, @lat, @lon, @radius_km): which water bodies of a list lie within a
  radius of a point, nearest first (docapi GET /api/v1/news/near, envfish-droid P1-09).
  Water bodies get their source (Tributaries side 16) and mouth (side 32) from TR_Lake_INS; the tests set the points.

  TEST 1 - bad point, radius or list                     -> NULL
  TEST 2 - empty list, unknown ids, junk entries         -> []
  TEST 3 - two near, one far: radius cuts, nearest first
  TEST 4 - distance is to the nearer of source and mouth
  TEST 5 - no source/mouth point -> left out; repeats once
*/
PRINT 'Unit tests for fn_lakes_near_json (water bodies near a point)';
GO
-- ============================================================================
-- TEST 1: bad arguments
-- ============================================================================
BEGIN TRAN LN_Test1
    declare @test_name sysname = N'LN_Test1 [fn_lakes_near_json] : bad arguments'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @a nvarchar(max) = N'x', @b nvarchar(max) = N'x', @c nvarchar(max) = N'x', @d nvarchar(max) = N'x';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @a = dbo.fn_lakes_near_json(N'[]', 91, -80, 100);
SET @b = dbo.fn_lakes_near_json(N'[]', 43, -181, 100);
SET @c = dbo.fn_lakes_near_json(N'[]', 43, -80, 0);
SET @d = dbo.fn_lakes_near_json(N'not json', 43, -80, 100);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @a IS NOT NULL OR @b IS NOT NULL OR @c IS NOT NULL OR @d IS NOT NULL
   RAISERROR ('TEST 1 FAIL [%dms]: bad point, radius or list -> NULL', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bad point, radius or list -> NULL'

ROLLBACK TRAN LN_Test1
GO
-- ============================================================================
-- TEST 2: nothing to find
-- ============================================================================
BEGIN TRAN LN_Test2
    declare @test_name sysname = N'LN_Test2 [fn_lakes_near_json] : nothing to find'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @a nvarchar(max) = N'x', @b nvarchar(max) = N'x';
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @a = dbo.fn_lakes_near_json(N'[]', 43.45, -80.49, 100);
SET @b = dbo.fn_lakes_near_json(CONCAT(N'["', NEWID(), N'", "junk", 7, null]'), 43.45, -80.49, 100);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@a, N'x') <> N'[]' OR ISNULL(@b, N'x') <> N'[]'
   RAISERROR ('TEST 2 FAIL [%dms]: empty list, unknown ids, junk entries -> []', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty list, unknown ids, junk entries -> []'

ROLLBACK TRAN LN_Test2
GO
-- ============================================================================
-- TEST 3: radius and order
-- ============================================================================
BEGIN TRAN LN_Test3
    declare @test_name sysname = N'LN_Test3 [fn_lakes_near_json] : radius and order'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @wide nvarchar(max), @narrow nvarchar(max);
DECLARE @A uniqueidentifier = NEWID(), @B uniqueidentifier = NEWID(), @C uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@A, 1, N'Utln Near'), (@B, 2, N'Utln Middle'), (@C, 1, N'Utln Far');
-- A: ~3 km north; B: ~40 km east; C: ~300 km away
UPDATE dbo.Tributaries SET lat = 43.477, lon = -80.49 WHERE Main_Lake_id = @A;
UPDATE dbo.Tributaries SET lat = 43.45,  lon = -79.995 WHERE Main_Lake_id = @B;
UPDATE dbo.Tributaries SET lat = 45.5,   lon = -78.0 WHERE Main_Lake_id = @C;
DECLARE @list nvarchar(max) = CONCAT(N'["', @C, N'","', @B, N'","', @A, N'"]');
SET @wide   = dbo.fn_lakes_near_json(@list, 43.45, -80.49, 100);
SET @narrow = dbo.fn_lakes_near_json(@list, 43.45, -80.49, 10);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@wide) IS NULL OR ISJSON(@wide) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@wide)) <> 2
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@wide, '$[0].lakeId')) <> @A
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@wide, '$[1].lakeId')) <> @B
  OR TRY_CONVERT(float, JSON_VALUE(@wide, '$[0].distanceKm')) NOT BETWEEN 2.9 AND 3.1
  OR TRY_CONVERT(float, JSON_VALUE(@wide, '$[1].distanceKm')) NOT BETWEEN 39 AND 41
  OR JSON_VALUE(@wide, '$[0].lakeName') <> N'Utln Near'
  OR (SELECT COUNT(*) FROM OPENJSON(@narrow)) <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: two near, one far: radius cuts, nearest first', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: two near, one far: radius cuts, nearest first'

ROLLBACK TRAN LN_Test3
GO
-- ============================================================================
-- TEST 4: nearer of source and mouth
-- ============================================================================
BEGIN TRAN LN_Test4
    declare @test_name sysname = N'LN_Test4 [fn_lakes_near_json] : nearer end'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @R uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@R, 2, N'Utln Long River');
UPDATE dbo.Tributaries SET lat = 44.17, lon = -80.49 WHERE Main_Lake_id = @R AND side = 16;   -- source ~80 km north
UPDATE dbo.Tributaries SET lat = 43.468, lon = -80.49 WHERE Main_Lake_id = @R AND side = 32;  -- mouth ~2 km north
SET @json = dbo.fn_lakes_near_json(CONCAT(N'["', @R, N'"]'), 43.45, -80.49, 50);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(float, JSON_VALUE(@json, '$[0].distanceKm')) NOT BETWEEN 1.9 AND 2.1
   RAISERROR ('TEST 4 FAIL [%dms]: distance is to the nearer of source and mouth', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: distance is to the nearer of source and mouth'

ROLLBACK TRAN LN_Test4
GO
-- ============================================================================
-- TEST 5: no point, repeats
-- ============================================================================
BEGIN TRAN LN_Test5
    declare @test_name sysname = N'LN_Test5 [fn_lakes_near_json] : no point, repeats'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @P uniqueidentifier = NEWID(), @Q uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@P, 1, N'Utln Pointless'), (@Q, 1, N'Utln Twice');
UPDATE dbo.Tributaries SET lat = NULL, lon = NULL WHERE Main_Lake_id = @P;
UPDATE dbo.Tributaries SET lat = 43.46, lon = -80.49 WHERE Main_Lake_id = @Q;
SET @json = dbo.fn_lakes_near_json(CONCAT(N'["', @P, N'","', @Q, N'","', LOWER(CONVERT(varchar(36), @Q)), N'"]'), 43.45, -80.49, 50);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISJSON(@json) IS NULL OR ISJSON(@json) <> 1
  OR (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0].lakeId')) <> @Q
   RAISERROR ('TEST 5 FAIL [%dms]: no source/mouth point -> left out; repeats once', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no source/mouth point -> left out; repeats once'

ROLLBACK TRAN LN_Test5
GO
