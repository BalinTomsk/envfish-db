SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the regulation read-side functions:
    dbo.fn_region_regulation_json  (docapi GET /api/v1/region/regulation/{country}[/{state}])
    dbo.fn_lake_regulation_json    (docapi GET /api/v1/river/regulation/{guid}; also LakeRegulation.aspx's
                                     "Save JSON" export)

  TEST 1 - fn_region_regulation_json(country, state) returns only that country+state's region rows
  TEST 2 - fn_region_regulation_json(country, NULL) returns only that country's whole-country rows,
           never a state-specific row
  TEST 3 - fn_lake_regulation_json includes the new country field
*/
PRINT 'Unit tests for regulation read functions';
GO
-- ============================================================================
-- TEST 1: fn_region_regulation_json(country, state) returns that scope's rows only
-- ============================================================================
BEGIN TRAN RR_Test1
    declare @test_name sysname = N'RR_Test1 [fn_region_regulation_json] : country+state scope'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Doc1 nvarchar(max);
DECLARE @Count1 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.regulations (country, state, reg_year, regulations_part, resident_type, regulations_sport)
VALUES (N'ZZ', N'YY', 2026, N'ut-rr1', 0, 7);

SET @Doc1 = dbo.fn_region_regulation_json('ZZ', 'YY');
SELECT @Count1 = COUNT(*) FROM OPENJSON(JSON_QUERY(@Doc1, '$.regulations'))
    WITH (part nvarchar(255) '$.part', sport int '$.sport') WHERE part = N'ut-rr1' AND sport = 7;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF JSON_VALUE(@Doc1, '$.country') <> N'ZZ' OR JSON_VALUE(@Doc1, '$.state') <> N'YY' OR @Count1 <> 1
   RAISERROR ('TEST 1 FAIL [%dms]: expected the ZZ/YY rule back with sport=7', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: country+state scope returned the right row'

ROLLBACK TRAN RR_Test1
GO
-- ============================================================================
-- TEST 2: fn_region_regulation_json(country, NULL) returns only whole-country rows
-- ============================================================================
BEGIN TRAN RR_Test2
    declare @test_name sysname = N'RR_Test2 [fn_region_regulation_json] : whole-country scope excludes state rows'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Doc2 nvarchar(max);
DECLARE @HasStateRow int, @HasCountryRow int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- one province-specific rule and one whole-country rule for the same made-up country
INSERT INTO dbo.regulations (country, state, reg_year, regulations_part, resident_type, regulations_sport)
VALUES (N'ZZ', N'XX', 2026, N'ut-rr2-state', 0, 1);
INSERT INTO dbo.regulations (country, state, reg_year, regulations_part, resident_type, regulations_sport)
VALUES (N'ZZ', NULL, 2026, N'ut-rr2-country', 0, 2);

SET @Doc2 = dbo.fn_region_regulation_json('ZZ', NULL);
SELECT @HasCountryRow = COUNT(*) FROM OPENJSON(JSON_QUERY(@Doc2, '$.regulations'))
    WITH (part nvarchar(255) '$.part') WHERE part = N'ut-rr2-country';
SELECT @HasStateRow = COUNT(*) FROM OPENJSON(JSON_QUERY(@Doc2, '$.regulations'))
    WITH (part nvarchar(255) '$.part') WHERE part = N'ut-rr2-state';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @HasCountryRow <> 1 OR @HasStateRow <> 0
   RAISERROR ('TEST 2 FAIL [%dms]: expected the whole-country row only, not the ON-specific one', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: whole-country scope excluded the state-specific row'

ROLLBACK TRAN RR_Test2
GO
-- ============================================================================
-- TEST 3: fn_lake_regulation_json includes the country field
-- ============================================================================
BEGIN TRAN RR_Test3
    declare @test_name sysname = N'RR_Test3 [fn_lake_regulation_json] : includes country field'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Doc3 nvarchar(max);
DECLARE @Country3 nvarchar(10);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @Lake3 uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 2, N'ut-lake-rr3');
INSERT INTO dbo.regulations (country, state, Lake_id, reg_year, regulations_part, resident_type, regulations_sport)
VALUES (N'ZZ', N'YY', @Lake3, 2026, N'', 0, 3);

SET @Doc3 = dbo.fn_lake_regulation_json(@Lake3);
SELECT @Country3 = JSON_VALUE(JSON_QUERY(@Doc3, '$.regulations'), '$[0].country');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name        AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @Country3 <> N'ZZ'
   RAISERROR ('TEST 3 FAIL [%dms]: expected country=ZZ in the water-body regulation export', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_regulation_json emits the country field'

ROLLBACK TRAN RR_Test3
GO
