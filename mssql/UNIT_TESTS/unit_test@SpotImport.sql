SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the Ontario fishing-spot import: dbo.sp_spot_upsert(@source, @json, @inserted OUT, @updated OUT) and the
  descriptive columns of dbo.Spot
  (spot_name, spot_type, spot_parking, spot_owner, spot_surface, spot_access, spot_fee, spot_info_url, spot_comment,
  spot_verified, spot_verified_by, spot_source, spot_source_id, spot_source_stamp).
  Source: LIO "Fishing access points" (FISHING_ACCESS_POINT, 2,430 points of Ontario), loaded by ontario_spots/Import-LioSpots.ps1.
  Readers of the result: Resources/wfRiverViewer.aspx.cs (via dbo.fn_lake_view_info 'fishspot').

  TEST 1 - JSON row -> one typed row (Yes/No -> bit, Unknown -> NULL, blank -> NULL, dates parsed, source set, lake_Id zero)
  TEST 2 - same JSON again                          -> nothing inserted, nothing updated, still one row
  TEST 3 - changed name and parking                 -> one update, same spot_id, no duplicate
  TEST 4 - same id under another source, legacy row -> separate row, legacy row untouched
  TEST 5 - rows without id or coordinates           -> skipped
  (dbo.sp_spot_link_by_name is tested in unit_test@SpotLinkByName.sql)
*/
PRINT 'Unit tests for sp_spot_upsert (Ontario fishing access points)';
GO
-- ============================================================================
-- TEST 1: JSON row -> typed row
-- ============================================================================
BEGIN TRAN SI_Test1
    declare @test_name sysname = N'SI_Test1 [sp_spot_upsert] : typed row'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ok bit = 0, @ins int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @json nvarchar(max) = N'[{"id":"900000001","type":"Boat Launch","name":"Utsi Lake Access","lat":45.5,"lon":-79.5,
  "parking":"Yes","owner":"Municipal","surface":"Unknown","access":"No","fee":"No","info_url":"","comment":"Gravel ramp",
  "verified":"20240924000000","verified_by":"Site visit","stamp":"20241015155746"}]';
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = @json, @inserted = @ins OUTPUT;

SELECT @ok = CASE WHEN COUNT(*) = 1
        AND MAX(spot_name) = N'Utsi Lake Access' AND MAX(spot_type) = 'Boat Launch' AND MAX(CAST(spot_parking AS int)) = 1
        AND MAX(CAST(spot_fee AS int)) = 0 AND MAX(spot_owner) = 'Municipal' AND MAX(spot_surface) IS NULL
        AND MAX(spot_access) = 'No' AND MAX(spot_info_url) IS NULL AND MAX(spot_comment) = N'Gravel ramp'
        AND MAX(spot_verified) = '2024-09-24' AND MAX(spot_verified_by) = N'Site visit'
        AND MAX(spot_source_stamp) = '2024-10-15T15:57:46'
        AND MAX(spot_lat) = 45.5 AND MAX(spot_lon) = -79.5
        AND MAX(CAST(lake_Id AS varchar(40))) = '00000000-0000-0000-0000-000000000000' THEN 1 ELSE 0 END
  FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000001';
IF @ins <> 1 SET @ok = 0;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ok <> 1
   RAISERROR ('TEST 1 FAIL [%dms]: the JSON row must become one typed Spot row', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: JSON row stored as one typed spot'

ROLLBACK TRAN SI_Test1
GO
-- ============================================================================
-- TEST 2: same JSON again -> nothing changes
-- ============================================================================
BEGIN TRAN SI_Test2
    declare @test_name sysname = N'SI_Test2 [sp_spot_upsert] : idempotent'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ins int, @upd int, @n int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @json nvarchar(max) = N'[{"id":"900000002","type":"Shoreline Access","name":"Utsi Shore","lat":45.6,"lon":-79.6,"parking":"No","fee":"Unknown"}]';
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = @json;
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = @json, @inserted = @ins OUTPUT, @updated = @upd OUTPUT;
SET @n = (SELECT COUNT(*) FROM dbo.Spot WHERE spot_source = 'UTSI');
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@ins, -1) <> 0 OR ISNULL(@upd, -1) <> 0 OR ISNULL(@n, 0) <> 1
   RAISERROR ('TEST 2 FAIL [%dms]: a second run of the same JSON must insert and update nothing', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: second run inserted and updated nothing'

ROLLBACK TRAN SI_Test2
GO
-- ============================================================================
-- TEST 3: changed fields -> update in place
-- ============================================================================
BEGIN TRAN SI_Test3
    declare @test_name sysname = N'SI_Test3 [sp_spot_upsert] : update in place'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ok bit = 0, @ins int, @upd int, @id1 uniqueidentifier, @id2 uniqueidentifier;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000003","type":"Boat Launch","name":"Old name","lat":45.7,"lon":-79.7,"parking":"No"}]';
SET @id1 = (SELECT spot_id FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000003');
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000003","type":"Boat Launch","name":"New name","lat":45.7,"lon":-79.7,"parking":"Yes"}]'
   , @inserted = @ins OUTPUT, @updated = @upd OUTPUT;
SET @id2 = (SELECT spot_id FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000003');
SELECT @ok = CASE WHEN COUNT(*) = 1 AND MAX(spot_name) = N'New name' AND MAX(CAST(spot_parking AS int)) = 1 THEN 1 ELSE 0 END
  FROM dbo.Spot WHERE spot_source = 'UTSI';
IF @id1 IS NULL OR @id1 <> @id2 OR @ins <> 0 OR @upd <> 1 SET @ok = 0;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ok <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: changed fields must update the same row, not add one', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: changed fields updated in place'

ROLLBACK TRAN SI_Test3
GO
-- ============================================================================
-- TEST 4: other source / legacy row
-- ============================================================================
BEGIN TRAN SI_Test4
    declare @test_name sysname = N'SI_Test4 [sp_spot_upsert] : sources are separate'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ok bit = 0, @legacy uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Spot (spot_id, spot_lat, spot_lon, lake_Id) VALUES (@legacy, 45.0, -79.0, NEWID());
EXEC dbo.sp_spot_upsert @source = 'UTSI', @json = N'[{"id":"900000004","name":"From one","lat":45.8,"lon":-79.8}]';
EXEC dbo.sp_spot_upsert @source = 'UTSJ', @json = N'[{"id":"900000004","name":"From two","lat":45.9,"lon":-79.9}]';
SELECT @ok = CASE WHEN (SELECT COUNT(*) FROM dbo.Spot WHERE spot_source_id = '900000004') = 2
                   AND (SELECT spot_name FROM dbo.Spot WHERE spot_source = 'UTSI' AND spot_source_id = '900000004') = N'From one'
                   AND (SELECT spot_name FROM dbo.Spot WHERE spot_source = 'UTSJ' AND spot_source_id = '900000004') = N'From two'
                   AND (SELECT COUNT(*) FROM dbo.Spot WHERE spot_id = @legacy AND spot_source IS NULL AND spot_name IS NULL AND spot_lat = 45.0) = 1
                  THEN 1 ELSE 0 END;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @ok <> 1
   RAISERROR ('TEST 4 FAIL [%dms]: the same id under another source is its own row; legacy rows stay as they are', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sources kept apart, legacy row untouched'

ROLLBACK TRAN SI_Test4
GO
-- ============================================================================
-- TEST 5: incomplete rows skipped
-- ============================================================================
BEGIN TRAN SI_Test5
    declare @test_name sysname = N'SI_Test5 [sp_spot_upsert] : skip incomplete rows'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @ins int, @n int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

EXEC dbo.sp_spot_upsert @source = 'UTSI'
   , @json = N'[{"id":"","name":"no id","lat":45.1,"lon":-79.1},{"id":"900000005","name":"no lat","lon":-79.1},{"id":"900000006","name":"ok","lat":45.1,"lon":-79.1}]'
   , @inserted = @ins OUTPUT;
SET @n = (SELECT COUNT(*) FROM dbo.Spot WHERE spot_source = 'UTSI');
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF ISNULL(@ins, -1) <> 1 OR ISNULL(@n, 0) <> 1
   RAISERROR ('TEST 5 FAIL [%dms]: rows without id or coordinates must be skipped', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: rows without id or coordinates skipped'

ROLLBACK TRAN SI_Test5
GO
