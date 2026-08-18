SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_fish_code_latin_json (regional fish CODE -> latin name, per province).

  Caller: FishTracker.WebService.TFishService.Page_Load -- ~/WebService/Fish/?province=AB&codes=...
  The page parses the query string into a JSON array and writes the returned string straight to
  the response body, so the function owns the contract: [{"code","latin"}], in the requested
  order, code echoing what was asked, and a code that matches nothing still present with latin
  null so it never silently disappears from the caller's list.

  Two properties of dbo.fish_code drive most of these tests:
    * code is char(16) and therefore BLANK-PADDED -- every stored value is 16 bytes wide, so it
      must be RTRIMmed on the way out or the document carries "BURB            ";
    * the primary key is (fish_id, country, state, code), so ONE CODE MAY NAME SEVERAL SPECIES.
      On the live database BC 'RB' is both Rock Bass and Rainbow Trout, 'LS' both Lake Sturgeon
      and Largescale Sucker, 'WS' both White Sturgeon and White Sucker. The function returns one
      element per match rather than an arbitrary TOP 1.

  Uses the real dbo.fish and dbo.fish_code tables. Each test runs in its own named transaction,
  rolled back at the end of its own GO batch - database state fully restored.

  TEST 1 - codes resolve to latin names, in the requested order, code echoed
  TEST 2 - the stored char(16) padding never reaches the document
  TEST 3 - an unmatched code keeps its slot with latin null (1:1 with the request preserved)
  TEST 4 - the province scopes the lookup: the same code in another province is not returned
  TEST 5 - an ambiguous code yields one element PER match, not an arbitrary single winner
  TEST 6 - @codes NULL publishes the whole province, ordered by code
  TEST 7 - @country NULL means any country; a wrong country matches nothing
  TEST 8 - guards: missing state, non-array @codes, blank element, empty array -> '[]', never NULL
*/

-- ===================================================================================
-- TEST 1: the headline case
-- ===================================================================================
BEGIN TRAN Test01FishCodeBasic
    DECLARE @test_name sysname = N'Test01FishCodeBasic [fn_fish_code_latin_json] : codes resolve in order'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @c0 nvarchar(32), @l0 nvarchar(64), @c1 nvarchar(32), @l1 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @f1 uniqueidentifier = NEWID(), @f2 uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES
  (@f1, 'UT FCJ Burbot',  'Ut fcj lota'),
  (@f2, 'UT FCJ Walleye', 'Ut fcj stizostedion');
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES
  (@f1, 'CA', 'ZZ', 'UTBURB'),
  (@f2, 'CA', 'ZZ', 'UTWALL');

SET @json = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["UTWALL","UTBURB"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @c0 = JSON_VALUE(@json, '$[0].code');  SET @l0 = JSON_VALUE(@json, '$[0].latin');
SET @c1 = JSON_VALUE(@json, '$[1].code');  SET @l1 = JSON_VALUE(@json, '$[1].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 2 AND @c0 = N'UTWALL' AND @l0 = N'Ut fcj stizostedion'
        AND @c1 = N'UTBURB' AND @l1 = N'Ut fcj lota'
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: both codes resolved to their latin names in the requested order';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: n=%d [0]=%s/%s [1]=%s/%s', 16, -1, @ElapsedMs, @n, @c0, @l0, @c1, @l1);

ROLLBACK TRAN Test01FishCodeBasic
GO

-- ===================================================================================
-- TEST 2: char(16) padding. The stored value is 16 bytes wide; the document must not
--         carry the trailing blanks, and a caller must not have to trim them.
-- ===================================================================================
BEGIN TRAN Test02FishCodePadding
    DECLARE @test_name sysname = N'Test02FishCodePadding [fn_fish_code_latin_json] : char(16) padding trimmed'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @byList nvarchar(MAX), @byAll nvarchar(MAX), @stored int, @cList nvarchar(32), @cAll nvarchar(32);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @f uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES (@f, 'UT FCJ Pad', 'Ut fcj pad');
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES (@f, 'CA', 'ZZ', 'UTPAD');

SELECT @stored = DATALENGTH(code) FROM dbo.fish_code WHERE fish_id = @f;   -- expect 16

SET @byList = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["UTPAD"]');
SET @byAll  = dbo.fn_fish_code_latin_json('CA', 'ZZ', NULL);

SET @cList = JSON_VALUE(@byList, '$[0].code');
SELECT @cAll = JSON_VALUE(value, '$.code') FROM OPENJSON(@byAll) WHERE JSON_VALUE(value, '$.latin') = N'Ut fcj pad';

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @stored = 16 AND @cList = N'UTPAD' AND @cAll = N'UTPAD'
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the 16-byte stored code emerged trimmed in both modes';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: stored bytes=%d list code=[%s] all code=[%s]', 16, -1, @ElapsedMs, @stored, @cList, @cAll);

ROLLBACK TRAN Test02FishCodePadding
GO

-- ===================================================================================
-- TEST 3: an unknown code holds its slot. Dropping it would shift every later element
--         and mis-pair the caller's list after the first miss.
-- ===================================================================================
BEGIN TRAN Test03FishCodeMiss
    DECLARE @test_name sysname = N'Test03FishCodeMiss [fn_fish_code_latin_json] : unmatched code keeps its slot'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @c1 nvarchar(32), @l1 nvarchar(64), @l2 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @a uniqueidentifier = NEWID(), @b uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES
  (@a, 'UT FCJ First', 'Ut fcj one'), (@b, 'UT FCJ Third', 'Ut fcj three');
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES
  (@a, 'CA', 'ZZ', 'UTONE'), (@b, 'CA', 'ZZ', 'UTTHREE');

SET @json = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["UTONE","UTNOPE","UTTHREE"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @c1 = JSON_VALUE(@json, '$[1].code');
SET @l1 = JSON_VALUE(@json, '$[1].latin');
SET @l2 = JSON_VALUE(@json, '$[2].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 3 AND @c1 = N'UTNOPE' AND @l1 IS NULL AND @l2 = N'Ut fcj three'
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the unmatched code stayed in place as null and later elements kept alignment';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: n=%d [1]=%s/%s [2]latin=%s', 16, -1, @ElapsedMs, @n, @c1, @l1, @l2);

ROLLBACK TRAN Test03FishCodeMiss
GO

-- ===================================================================================
-- TEST 4: the province scopes the lookup. The same code in a different province must
--         not leak in -- that is the whole reason province is a required argument.
-- ===================================================================================
BEGIN TRAN Test04FishCodeProvinceScope
    DECLARE @test_name sysname = N'Test04FishCodeProvinceScope [fn_fish_code_latin_json] : province scopes the lookup'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @inZZ nvarchar(MAX), @inYY nvarchar(MAX), @nZZ int, @nYY int, @lZZ nvarchar(64), @lYY nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @z uniqueidentifier = NEWID(), @y uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES
  (@z, 'UT FCJ ZZ fish', 'Ut fcj zzz'), (@y, 'UT FCJ YY fish', 'Ut fcj yyy');
-- same code, two provinces, different species
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES
  (@z, 'CA', 'ZZ', 'UTSHARED'), (@y, 'CA', 'YY', 'UTSHARED');

SET @inZZ = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["UTSHARED"]');
SET @inYY = dbo.fn_fish_code_latin_json('CA', 'YY', N'["UTSHARED"]');

SELECT @nZZ = COUNT(*) FROM OPENJSON(@inZZ);
SELECT @nYY = COUNT(*) FROM OPENJSON(@inYY);
SET @lZZ = JSON_VALUE(@inZZ, '$[0].latin');
SET @lYY = JSON_VALUE(@inYY, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @nZZ = 1 AND @lZZ = N'Ut fcj zzz' AND @nYY = 1 AND @lYY = N'Ut fcj yyy'
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the same code resolved differently per province, with no cross-leak';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: ZZ n=%d latin=%s ; YY n=%d latin=%s', 16, -1, @ElapsedMs, @nZZ, @lZZ, @nYY, @lYY);

ROLLBACK TRAN Test04FishCodeProvinceScope
GO

-- ===================================================================================
-- TEST 5: an ambiguous code. dbo.fish_code's key is (fish_id, country, state, code), so
--         one code may legitimately name several species -- on the live database BC 'RB'
--         is both Rock Bass and Rainbow Trout. Returning TOP 1 would hide half the answer
--         behind an arbitrary pick, so every match is returned.
-- ===================================================================================
BEGIN TRAN Test05FishCodeAmbiguous
    DECLARE @test_name sysname = N'Test05FishCodeAmbiguous [fn_fish_code_latin_json] : ambiguous code returns every match'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @latins nvarchar(400), @codes nvarchar(400);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @r1 uniqueidentifier = NEWID(), @r2 uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES
  (@r1, 'UT FCJ Rock Bass',     'Ut fcj ambloplites'),
  (@r2, 'UT FCJ Rainbow Trout', 'Ut fcj oncorhynchus');
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES
  (@r1, 'CA', 'ZZ', 'UTRB'), (@r2, 'CA', 'ZZ', 'UTRB');

SET @json = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["UTRB"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SELECT @latins = STRING_AGG(CAST(JSON_VALUE(value, '$.latin') AS nvarchar(MAX)), ',')
                   WITHIN GROUP (ORDER BY JSON_VALUE(value, '$.latin')) FROM OPENJSON(@json);
SELECT @codes  = STRING_AGG(CAST(JSON_VALUE(value, '$.code') AS nvarchar(MAX)), ',') FROM OPENJSON(@json);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 2 AND @latins = N'Ut fcj ambloplites,Ut fcj oncorhynchus' AND @codes = N'UTRB,UTRB'
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: an ambiguous code returned both species instead of an arbitrary one';
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: n=%d latins=[%s] codes=[%s]', 16, -1, @ElapsedMs, @n, @latins, @codes);

ROLLBACK TRAN Test05FishCodeAmbiguous
GO

-- ===================================================================================
-- TEST 6: no list supplied -> the whole province, ordered by code
-- ===================================================================================
BEGIN TRAN Test06FishCodeWholeProvince
    DECLARE @test_name sysname = N'Test06FishCodeWholeProvince [fn_fish_code_latin_json] : NULL codes publishes the province'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @mine nvarchar(400), @outOfOrder int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @p1 uniqueidentifier = NEWID(), @p2 uniqueidentifier = NEWID(), @p3 uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES
  (@p1, 'UT FCJ Prov A', 'Ut fcj prova'),
  (@p2, 'UT FCJ Prov B', 'Ut fcj provb'),
  (@p3, 'UT FCJ Prov C', 'Ut fcj provc');
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES
  (@p3, 'CA', 'ZZ', 'UTZC'), (@p1, 'CA', 'ZZ', 'UTZA'), (@p2, 'CA', 'ZZ', 'UTZB');

SET @json = dbo.fn_fish_code_latin_json('CA', 'ZZ', NULL);

SELECT @mine = STRING_AGG(CAST(JSON_VALUE(value, '$.code') AS nvarchar(MAX)), ',')
FROM OPENJSON(@json) WHERE JSON_VALUE(value, '$.code') LIKE N'UTZ%';

SELECT @outOfOrder = COUNT(*) FROM (
    SELECT JSON_VALUE(value, '$.code') AS c,
           LAG(JSON_VALUE(value, '$.code')) OVER (ORDER BY CAST([key] AS int)) AS prev
    FROM OPENJSON(@json)) q
WHERE q.prev IS NOT NULL AND q.c < q.prev;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @mine = N'UTZA,UTZB,UTZC' AND @outOfOrder = 0
    PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the whole province came back ordered by code';
ELSE
    RAISERROR ('TEST 6 FAIL [%dms]: mine=[%s] outOfOrder=%d', 16, -1, @ElapsedMs, @mine, @outOfOrder);

ROLLBACK TRAN Test06FishCodeWholeProvince
GO

-- ===================================================================================
-- TEST 7: country. NULL means any; a country that does not hold the code matches nothing.
--         Only 'CA' exists today, but country is part of the key, so this keeps the
--         lookup honest the moment another country's codes land.
-- ===================================================================================
BEGIN TRAN Test07FishCodeCountry
    DECLARE @test_name sysname = N'Test07FishCodeCountry [fn_fish_code_latin_json] : country filter'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @anyC nvarchar(MAX), @rightC nvarchar(MAX), @wrongC nvarchar(MAX);
DECLARE @lAny nvarchar(64), @lRight nvarchar(64), @lWrong nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

DECLARE @f uniqueidentifier = NEWID();
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin) VALUES (@f, 'UT FCJ Country', 'Ut fcj country');
INSERT INTO dbo.fish_code (fish_id, country, state, code) VALUES (@f, 'CA', 'ZZ', 'UTCTRY');

SET @anyC   = dbo.fn_fish_code_latin_json(NULL, 'ZZ', N'["UTCTRY"]');
SET @rightC = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["UTCTRY"]');
SET @wrongC = dbo.fn_fish_code_latin_json('US', 'ZZ', N'["UTCTRY"]');

SET @lAny   = JSON_VALUE(@anyC,   '$[0].latin');
SET @lRight = JSON_VALUE(@rightC, '$[0].latin');
SET @lWrong = JSON_VALUE(@wrongC, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @lAny = N'Ut fcj country' AND @lRight = N'Ut fcj country' AND @lWrong IS NULL
    PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: NULL country matched any, the right country matched, the wrong one did not';
ELSE
    RAISERROR ('TEST 7 FAIL [%dms]: any=%s right=%s wrong=%s', 16, -1, @ElapsedMs, @lAny, @lRight, @lWrong);

ROLLBACK TRAN Test07FishCodeCountry
GO

-- ===================================================================================
-- TEST 8: the guards. The caller writes the result straight to the response body, so
--         every one of these must still be a parseable array rather than NULL or an error.
--         A blank element matters especially: without the guard it would compare against
--         RTRIM(code) = '' and could match nothing meaningfully, but it must still occupy
--         its slot so the caller's list stays aligned.
-- ===================================================================================
BEGIN TRAN Test08FishCodeGuards
    DECLARE @test_name sysname = N'Test08FishCodeGuards [fn_fish_code_latin_json] : guards all yield []'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @noState nvarchar(MAX), @blankState nvarchar(MAX), @obj nvarchar(MAX), @garbage nvarchar(MAX), @empty nvarchar(MAX);
DECLARE @blankEl nvarchar(MAX), @nBlank int, @lBlank nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @noState    = dbo.fn_fish_code_latin_json('CA', NULL, N'["UTX"]');
SET @blankState = dbo.fn_fish_code_latin_json('CA', '  ', N'["UTX"]');
SET @obj        = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'{"code":"UTX"}');
SET @garbage    = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'not json');
SET @empty      = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'[]');

SET @blankEl = dbo.fn_fish_code_latin_json('CA', 'ZZ', N'["","  "]');
SELECT @nBlank = COUNT(*) FROM OPENJSON(@blankEl);
SET @lBlank = JSON_VALUE(@blankEl, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @noState = N'[]' AND @blankState = N'[]' AND @obj = N'[]' AND @garbage = N'[]' AND @empty = N'[]'
   AND @nBlank = 2 AND @lBlank IS NULL
    PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: missing/blank state, non-array and empty array all gave [], blank elements resolved to null';
ELSE
    RAISERROR ('TEST 8 FAIL [%dms]: noState=%s blankState=%s obj=%s garbage=%s empty=%s blankCount=%d', 16, -1, @ElapsedMs, @noState, @blankState, @obj, @garbage, @empty, @nBlank);

ROLLBACK TRAN Test08FishCodeGuards
GO
