SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.Lake_Shape and dbo.sp_add_lake_shape
  TEST 1 - Lake_Shape has no hash / box column and no TR_UPD_Lake_Shape  -> all gone
  TEST 2 - a multi-row INSERT of shapes                                   -> both rows stored
  TEST 3 - sp_add_lake_shape called twice with the same line              -> one line for the water body
*/
print 'Unit tests for Lake_Shape / sp_add_lake_shape'
GO
-- ============================================================================
-- TEST 1: the hash / box columns and their trigger are gone
-- ============================================================================
BEGIN TRAN LS_Test1
    declare @test_name sysname = N'LS_Test1 [Lake_Shape] : no hash, box or trigger'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @left int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @left = CASE WHEN COL_LENGTH('dbo.Lake_Shape', 'Lake_Shape_hash') IS NULL THEN 0 ELSE 1 END
          + CASE WHEN COL_LENGTH('dbo.Lake_Shape', 'Lake_Shape_idx')  IS NULL THEN 0 ELSE 1 END
          + CASE WHEN OBJECT_ID('dbo.TR_UPD_Lake_Shape', 'TR')         IS NULL THEN 0 ELSE 1 END;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @left IS NULL OR @left <> 0
   RAISERROR ('TEST 1 FAIL [%dms]: hash / box column or TR_UPD_Lake_Shape still exists', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no hash, box or trigger'

ROLLBACK TRAN LS_Test1
GO
-- ============================================================================
-- TEST 2: several shapes in one INSERT
-- ============================================================================
BEGIN TRAN LS_Test2
    declare @test_name sysname = N'LS_Test2 [Lake_Shape] : multi-row insert'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @n int;
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utls River');
INSERT INTO dbo.Lake_Shape (lake_id, Lake_Shape_shape, Lake_Shape_type)
VALUES (@L, geography::STGeomFromText('LINESTRING(-66.5 46.1, -66.4 46.2)', 4326), 1),
       (@L, geography::STGeomFromText('POLYGON((-66.5 46.1, -66.4 46.1, -66.4 46.2, -66.5 46.1))', 4326), 2);
SET @n = (SELECT COUNT(*) FROM dbo.Lake_Shape WHERE lake_id = @L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n IS NULL OR @n <> 2
   RAISERROR ('TEST 2 FAIL [%dms]: one INSERT of 2 shapes must store 2 rows', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: one INSERT stores 2 shapes'

ROLLBACK TRAN LS_Test2
GO
-- ============================================================================
-- TEST 3: sp_add_lake_shape twice with the same line keeps one line
-- ============================================================================
BEGIN TRAN LS_Test3
    declare @test_name sysname = N'LS_Test3 [sp_add_lake_shape] : repeat call'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @n int;
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utls Repeat River');
EXEC dbo.sp_add_lake_shape @L, 46.1, -66.5, 46.3, -66.3, 'NB', NULL, N'-66.5 46.1, -66.4 46.2, -66.3 46.3', 3;
EXEC dbo.sp_add_lake_shape @L, 46.1, -66.5, 46.3, -66.3, 'NB', NULL, N'-66.5 46.1, -66.4 46.2, -66.3 46.3', 3;
SET @n = (SELECT COUNT(*) FROM dbo.Lake_Shape WHERE lake_id = @L);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n IS NULL OR @n <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: a repeated call must keep one line', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: repeated call keeps one line'

ROLLBACK TRAN LS_Test3
GO
