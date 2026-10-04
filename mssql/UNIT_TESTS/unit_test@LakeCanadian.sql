SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_lake_canadian_ids_json(@lake_ids):
    which of the given water bodies count as Canadian -- the rule the FishFind MCP server applies to every
    tool: the water body has a CGNDB code, OR its source (Tributaries side 16) OR its mouth (side 32) is in
    country 'CA'. Served by docapi's McpToolCatalog via JdbcRiverQueryRepository.canadianIds.

  Fixture notes: inserting a lake creates its source/mouth Tributaries rows by trigger; fixtures UPDATE
  them. CGNDB values start with 'Z' (char(5)) so they never collide with seed codes.

  TEST 1 - CGNDB code, no country anywhere          -> Canadian
  TEST 2 - source in US, mouth in CA                -> Canadian (either end is enough)
  TEST 3 - source and mouth in US, no CGNDB         -> not Canadian
  TEST 4 - mixed list                               -> exactly the Canadian ids, each once
  TEST 5 - NULL, empty, not JSON, unknown id        -> []
*/
PRINT 'Unit tests for fn_lake_canadian_ids_json (Canadian water bodies)';
GO
-- ============================================================================
-- TEST 1: a CGNDB code alone makes a water body Canadian
-- ============================================================================
BEGIN TRAN LCA_Test1
    declare @test_name sysname = N'LCA_Test1 [fn_lake_canadian_ids_json] : CGNDB only'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name, CGNDB) VALUES (@L, 1, N'Utlca Code Lake', 'ZLCA1');

SET @json = dbo.fn_lake_canadian_ids_json(N'["' + CONVERT(nvarchar(36), @L) + N'"]');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
  OR TRY_CONVERT(uniqueidentifier, JSON_VALUE(@json, '$[0]')) <> @L
   RAISERROR ('TEST 1 FAIL [%dms]: a CGNDB code alone must count as Canadian', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CGNDB code alone is Canadian'

ROLLBACK TRAN LCA_Test1
GO
-- ============================================================================
-- TEST 2: source in the US, mouth in Canada
-- ============================================================================
BEGIN TRAN LCA_Test2
    declare @test_name sysname = N'LCA_Test2 [fn_lake_canadian_ids_json] : mouth in CA'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlca Border River');
UPDATE dbo.Tributaries SET Country = 'US', State = 'MN' WHERE Main_Lake_id = @L AND side = 16;
UPDATE dbo.Tributaries SET Country = 'CA', State = 'ON' WHERE Main_Lake_id = @L AND side = 32;

SET @json = dbo.fn_lake_canadian_ids_json(N'["' + CONVERT(nvarchar(36), @L) + N'"]');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 1
   RAISERROR ('TEST 2 FAIL [%dms]: a Canadian mouth must be enough', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US source + CA mouth is Canadian'

ROLLBACK TRAN LCA_Test2
GO
-- ============================================================================
-- TEST 3: entirely in the US, no CGNDB
-- ============================================================================
BEGIN TRAN LCA_Test3
    declare @test_name sysname = N'LCA_Test3 [fn_lake_canadian_ids_json] : US only'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @L uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@L, 2, N'Utlca US River');
UPDATE dbo.Tributaries SET Country = 'US', State = 'MN' WHERE Main_Lake_id = @L AND side IN (16, 32);

SET @json = dbo.fn_lake_canadian_ids_json(N'["' + CONVERT(nvarchar(36), @L) + N'"]');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(@json, N'x') <> N'[]'
   RAISERROR ('TEST 3 FAIL [%dms]: a US-only water body must not be Canadian', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US-only water body excluded'

ROLLBACK TRAN LCA_Test3
GO
-- ============================================================================
-- TEST 4: a mixed list returns exactly the Canadian ids, each once
-- ============================================================================
BEGIN TRAN LCA_Test4
    declare @test_name sysname = N'LCA_Test4 [fn_lake_canadian_ids_json] : mixed list'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(max);
DECLARE @Ca uniqueidentifier = NEWID(), @Us uniqueidentifier = NEWID(), @Code uniqueidentifier = NEWID();
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Ca, 1, N'Utlca CA Lake'), (@Us, 1, N'Utlca US Lake');
INSERT INTO dbo.Lake (Lake_id, locType, lake_name, CGNDB) VALUES (@Code, 1, N'Utlca Code Two', 'ZLCA2');
UPDATE dbo.Tributaries SET Country = 'CA', State = 'QC' WHERE Main_Lake_id = @Ca AND side = 16;
UPDATE dbo.Tributaries SET Country = 'US', State = 'NY' WHERE Main_Lake_id = @Us AND side IN (16, 32);

SET @json = dbo.fn_lake_canadian_ids_json(N'["' + CONVERT(nvarchar(36), @Ca) + N'","' + CONVERT(nvarchar(36), @Us)
          + N'","' + LOWER(CONVERT(nvarchar(36), @Code)) + N'","' + CONVERT(nvarchar(36), @Ca) + N'"]');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   (SELECT COUNT(*) FROM OPENJSON(@json)) <> 2
  OR NOT EXISTS (SELECT 1 FROM OPENJSON(@json) WHERE TRY_CONVERT(uniqueidentifier, value) = @Ca)
  OR NOT EXISTS (SELECT 1 FROM OPENJSON(@json) WHERE TRY_CONVERT(uniqueidentifier, value) = @Code)
   RAISERROR ('TEST 4 FAIL [%dms]: exactly the 2 Canadian ids, each once', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: mixed list -> the 2 Canadian ids'

ROLLBACK TRAN LCA_Test4
GO
-- ============================================================================
-- TEST 5: degenerate input yields an empty array, never an error
-- ============================================================================
BEGIN TRAN LCA_Test5
    declare @test_name sysname = N'LCA_Test5 [fn_lake_canadian_ids_json] : bad input'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @a nvarchar(max), @b nvarchar(max), @c nvarchar(max), @d nvarchar(max);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @a = dbo.fn_lake_canadian_ids_json(NULL);
SET @b = dbo.fn_lake_canadian_ids_json(N'[]');
SET @c = dbo.fn_lake_canadian_ids_json(N'not json');
SET @d = dbo.fn_lake_canadian_ids_json(N'["' + CONVERT(nvarchar(36), NEWID()) + N'","garbage"]');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF   ISNULL(@a, N'x') <> N'[]' OR ISNULL(@b, N'x') <> N'[]' OR ISNULL(@c, N'x') <> N'[]' OR ISNULL(@d, N'x') <> N'[]'
   RAISERROR ('TEST 5 FAIL [%dms]: null/empty/non-JSON/unknown must all give []', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: bad input -> empty array'

ROLLBACK TRAN LCA_Test5
GO
