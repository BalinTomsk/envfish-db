SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for dbo.fn_fish_latin_json (batch common-name -> latin-name lookup).

  Caller: FishTracker.WebService.TFishService.Page_Load -- ~/WebService/Fish/?fishes=...
  The page parses the query string into a JSON array and writes the returned string straight
  to the response body, so the function owns the contract: one element per requested name,
  in the requested order, each carrying query + name + latin, with name/latin null when the
  name resolves to nothing. The array is therefore always 1:1 with the request.

  Uses the real dbo.fish table. Each test runs in its own named transaction, rolled back at
  the end of its own GO batch - database state fully restored.

  TEST 1 - a two-name request returns two results, in the order asked, with latin names
  TEST 2 - an unresolved name yields name/latin null rather than vanishing (1:1 preserved)
  TEST 3 - "query" echoes what was asked, even when the match is a longer name ("Walley")
  TEST 4 - a name containing a COMMA survives, which is why the argument is a JSON array
           (762 of the 1041 live species names contain one)
  TEST 5 - an exact common-name hit wins over a longer name that merely contains the term
  TEST 6 - a blank element matches nothing, rather than '%%' matching an arbitrary species
  TEST 7 - LIKE metacharacters in an element are literals, not wildcards
  TEST 8 - a non-array argument (object, garbage, NULL, empty array) yields '[]', never NULL
*/

-- ===================================================================================
-- TEST 1: the headline case -- names in, latin names out, order preserved
-- ===================================================================================
BEGIN TRAN Test01FishLatinBatch
    DECLARE @test_name sysname = N'Test01FishLatinBatch [fn_fish_latin_json] : batch lookup returns latin names in order'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @l0 nvarchar(64), @l1 nvarchar(64), @q0 nvarchar(64), @q1 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLA Walleye', 'Ut fla stizostedion', 1),
  (NEWID(), 'UT FLA Burbot',  'Ut fla lota',         1);

SET @json = dbo.fn_fish_latin_json(N'["UT FLA Walleye","UT FLA Burbot"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @q0 = JSON_VALUE(@json, '$[0].query');  SET @l0 = JSON_VALUE(@json, '$[0].latin');
SET @q1 = JSON_VALUE(@json, '$[1].query');  SET @l1 = JSON_VALUE(@json, '$[1].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 2 AND @q0 = N'UT FLA Walleye' AND @l0 = N'Ut fla stizostedion'
        AND @q1 = N'UT FLA Burbot'   AND @l1 = N'Ut fla lota'
    PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: two names resolved to their latin names in the requested order';
ELSE
    RAISERROR ('TEST 1 FAIL [%dms]: n=%d [0]=%s/%s [1]=%s/%s', 16, -1, @ElapsedMs, @n, @q0, @l0, @q1, @l1);

ROLLBACK TRAN Test01FishLatinBatch
GO

-- ===================================================================================
-- TEST 2: an unknown name keeps its slot. Dropping it would silently shift every later
--         element, so a caller zipping the result against its request would mis-pair
--         every species after the first miss.
-- ===================================================================================
BEGIN TRAN Test02FishLatinMiss
    DECLARE @test_name sysname = N'Test02FishLatinMiss [fn_fish_latin_json] : unresolved name keeps its slot as null'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @q1 nvarchar(64), @name1 nvarchar(64), @latin1 nvarchar(64), @l2 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLA First',  'Ut fla one',   1),
  (NEWID(), 'UT FLA Third',  'Ut fla three', 1);

SET @json = dbo.fn_fish_latin_json(N'["UT FLA First","UT FLA NoSuchSpecies","UT FLA Third"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @q1    = JSON_VALUE(@json, '$[1].query');
SET @name1 = JSON_VALUE(@json, '$[1].name');
SET @latin1= JSON_VALUE(@json, '$[1].latin');
SET @l2    = JSON_VALUE(@json, '$[2].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 3 AND @q1 = N'UT FLA NoSuchSpecies' AND @name1 IS NULL AND @latin1 IS NULL
        AND @l2 = N'Ut fla three'
    PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the unresolved name held its slot as null and later elements stayed aligned';
ELSE
    RAISERROR ('TEST 2 FAIL [%dms]: n=%d [1]query=%s name=%s latin=%s [2]latin=%s', 16, -1, @ElapsedMs, @n, @q1, @name1, @latin1, @l2);

ROLLBACK TRAN Test02FishLatinMiss
GO

-- ===================================================================================
-- TEST 3: "query" echoes the requested spelling, not the matched name. This is the
--         reported case: "Walley" (no trailing e) must resolve to "Walleye" while the
--         caller can still see which of its inputs produced the row.
-- ===================================================================================
BEGIN TRAN Test03FishLatinEchoesQuery
    DECLARE @test_name sysname = N'Test03FishLatinEchoesQuery [fn_fish_latin_json] : query echoes the requested spelling'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @q nvarchar(64), @name nvarchar(64), @latin nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
VALUES (NEWID(), 'UT FLA Walleye', 'Ut fla stizostedion', 1);

SET @json = dbo.fn_fish_latin_json(N'["UT FLA Walley"]');   -- deliberately missing the final e

SET @q     = JSON_VALUE(@json, '$[0].query');
SET @name  = JSON_VALUE(@json, '$[0].name');
SET @latin = JSON_VALUE(@json, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @q = N'UT FLA Walley' AND @name = N'UT FLA Walleye' AND @latin = N'Ut fla stizostedion'
    PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a partial spelling resolved while query echoed what was asked';
ELSE
    RAISERROR ('TEST 3 FAIL [%dms]: query=%s name=%s latin=%s', 16, -1, @ElapsedMs, @q, @name, @latin);

ROLLBACK TRAN Test03FishLatinEchoesQuery
GO

-- ===================================================================================
-- TEST 4: a comma inside a name. This is the reason the argument is a JSON array and not
--         a comma-delimited string: 762 of the 1041 live species names carry a comma, so a
--         delimited argument would split most of the catalogue into two meaningless halves.
-- ===================================================================================
BEGIN TRAN Test04FishLatinCommaInName
    DECLARE @test_name sysname = N'Test04FishLatinCommaInName [fn_fish_latin_json] : a comma inside a name survives'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @q0 nvarchar(64), @l0 nvarchar(64), @l1 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLA Bass, Guadalupe', 'Ut fla micropterus', 1),
  (NEWID(), 'UT FLA Burbot',          'Ut fla lota',        1);

SET @json = dbo.fn_fish_latin_json(N'["UT FLA Bass, Guadalupe","UT FLA Burbot"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @q0 = JSON_VALUE(@json, '$[0].query');
SET @l0 = JSON_VALUE(@json, '$[0].latin');
SET @l1 = JSON_VALUE(@json, '$[1].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 2 AND @q0 = N'UT FLA Bass, Guadalupe' AND @l0 = N'Ut fla micropterus' AND @l1 = N'Ut fla lota'
    PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a comma-bearing name stayed one element and resolved correctly';
ELSE
    RAISERROR ('TEST 4 FAIL [%dms]: n=%d query0=%s latin0=%s latin1=%s', 16, -1, @ElapsedMs, @n, @q0, @l0, @l1);

ROLLBACK TRAN Test04FishLatinCommaInName
GO

-- ===================================================================================
-- TEST 5: only the best match comes back, and "best" means the exact common name -- not
--         the alphabetically first one that happens to contain the term.
-- ===================================================================================
BEGIN TRAN Test05FishLatinExactWins
    DECLARE @test_name sysname = N'Test05FishLatinExactWins [fn_fish_latin_json] : exact name beats a longer partial match'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @name nvarchar(64), @latin nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLA Aaa Sturgeon', 'Ut fla stur aaa',  1),   -- sorts first alphabetically
  (NEWID(), 'UT FLA Sturgeon',     'Ut fla stur real', 1);   -- the exact name asked for

SET @json = dbo.fn_fish_latin_json(N'["UT FLA Sturgeon"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @name  = JSON_VALUE(@json, '$[0].name');
SET @latin = JSON_VALUE(@json, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 1 AND @name = N'UT FLA Sturgeon' AND @latin = N'Ut fla stur real'
    PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: one row returned, and it was the exact name rather than the alphabetically first';
ELSE
    RAISERROR ('TEST 5 FAIL [%dms]: n=%d name=%s latin=%s', 16, -1, @ElapsedMs, @n, @name, @latin);

ROLLBACK TRAN Test05FishLatinExactWins
GO

-- ===================================================================================
-- TEST 6: a blank element resolves to nothing. Without the guard, '%' + '' + '%' matches
--         every row and TOP 1 would hand back an arbitrary species as if it were the
--         answer -- a wrong result presented as a right one.
-- ===================================================================================
BEGIN TRAN Test06FishLatinBlankElement
    DECLARE @test_name sysname = N'Test06FishLatinBlankElement [fn_fish_latin_json] : a blank element matches nothing'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @n int, @name0 nvarchar(64), @name1 nvarchar(64), @latin2 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
VALUES (NEWID(), 'UT FLA Blankguard', 'Ut fla blank', 1);

SET @json = dbo.fn_fish_latin_json(N'["","   ","UT FLA Blankguard"]');

SELECT @n = COUNT(*) FROM OPENJSON(@json);
SET @name0  = JSON_VALUE(@json, '$[0].name');
SET @name1  = JSON_VALUE(@json, '$[1].name');
SET @latin2 = JSON_VALUE(@json, '$[2].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @n = 3 AND @name0 IS NULL AND @name1 IS NULL AND @latin2 = N'Ut fla blank'
    PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty and whitespace elements resolved to null instead of an arbitrary species';
ELSE
    RAISERROR ('TEST 6 FAIL [%dms]: n=%d name0=%s name1=%s latin2=%s', 16, -1, @ElapsedMs, @n, @name0, @name1, @latin2);

ROLLBACK TRAN Test06FishLatinBlankElement
GO

-- ===================================================================================
-- TEST 7: LIKE metacharacters inside an element are literals. An unescaped '%' would
--         match everything and TOP 1 would return a species the caller never asked about.
-- ===================================================================================
BEGIN TRAN Test07FishLatinWildcard
    DECLARE @test_name sysname = N'Test07FishLatinWildcard [fn_fish_latin_json] : wildcards in an element are literals'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @name0 nvarchar(64), @name1 nvarchar(64), @latin1 nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
VALUES (NEWID(), 'UT FLA 50% Perch', 'Ut fla perca pct', 1);

SET @json = dbo.fn_fish_latin_json(N'["%","UT FLA 50% Perch"]');

SET @name0  = JSON_VALUE(@json, '$[0].name');   -- literal '%' matches the 50% row only
SET @name1  = JSON_VALUE(@json, '$[1].name');
SET @latin1 = JSON_VALUE(@json, '$[1].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @name0 = N'UT FLA 50% Perch' AND @name1 = N'UT FLA 50% Perch' AND @latin1 = N'Ut fla perca pct'
    PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a percent sign was searched as a literal, not as match-everything';
ELSE
    RAISERROR ('TEST 7 FAIL [%dms]: name0=%s name1=%s latin1=%s', 16, -1, @ElapsedMs, @name0, @name1, @latin1);

ROLLBACK TRAN Test07FishLatinWildcard
GO

-- ===================================================================================
-- TEST 8: the argument guard. OPENJSON over a JSON object yields property names, and
--         CAST(key AS int) in the ORDER BY would then fail with a conversion error rather
--         than returning a document -- so anything that is not an array is refused up
--         front. The caller writes the result straight to the response body, so every one
--         of these must still be a parseable array.
-- ===================================================================================
BEGIN TRAN Test08FishLatinBadArgument
    DECLARE @test_name sysname = N'Test08FishLatinBadArgument [fn_fish_latin_json] : non-array arguments yield []'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @obj nvarchar(MAX), @garbage nvarchar(MAX), @null_ nvarchar(MAX), @empty nvarchar(MAX), @blank nvarchar(MAX);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

SET @obj     = dbo.fn_fish_latin_json(N'{"name":"Burbot"}');
SET @garbage = dbo.fn_fish_latin_json(N'not json at all');
SET @null_   = dbo.fn_fish_latin_json(NULL);
SET @empty   = dbo.fn_fish_latin_json(N'[]');
SET @blank   = dbo.fn_fish_latin_json(N'');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @obj = N'[]' AND @garbage = N'[]' AND @null_ = N'[]' AND @empty = N'[]' AND @blank = N'[]'
    PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: object, garbage, NULL, empty array and blank all returned []';
ELSE
    RAISERROR ('TEST 8 FAIL [%dms]: obj=%s garbage=%s null=%s empty=%s blank=%s', 16, -1, @ElapsedMs, @obj, @garbage, @null_, @empty, @blank);

ROLLBACK TRAN Test08FishLatinBadArgument
GO

-- ===================================================================================
-- TEST 9: the same exact-latin-name bug as fn_fish_list_json TEST 15, but here it is
--         worse: fn_fish_latin_json returns only ONE row per query (TOP 1), so the wrong
--         tiebreak doesn't just mis-order results, it silently returns the WRONG SPECIES
--         with no signal anything went wrong. Confirmed on live data: batch-looking-up
--         the exact binomial "Esox lucius" (Northern Pike) returned "Muskellunge, Tiger"
--         ("Esox lucius x E. masquinongy") instead -- a real risk for any caller (e.g. the
--         add-fish skill's pre-check) that trusts the returned name at face value.
-- ===================================================================================
BEGIN TRAN Test09FishLatinExactWins
    DECLARE @test_name sysname = N'Test09FishLatinExactWins [fn_fish_latin_json] : exact latin name beats a compound-latin substring'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @json nvarchar(MAX), @name nvarchar(64), @latin nvarchar(64);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
  (NEWID(), 'UT FLA Aaa Hybrid', 'Ut fla pikeus x other', 1),  -- substring-only match, sorts first alphabetically
  (NEWID(), 'UT FLA Zzz Exact',  'Ut fla pikeus',         1);  -- the exact binomial being looked up

SET @json = dbo.fn_fish_latin_json(N'["Ut fla pikeus"]');

SET @name  = JSON_VALUE(@json, '$[0].name');
SET @latin = JSON_VALUE(@json, '$[0].latin');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
         , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

IF @name = N'UT FLA Zzz Exact' AND @latin = N'Ut fla pikeus'
    PRINT 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: the exact latin-name match was returned, not the alphabetically-earlier substring match';
ELSE
    RAISERROR ('TEST 9 FAIL [%dms]: expected name=UT FLA Zzz Exact latin=Ut fla pikeus, got name=%s latin=%s', 16, -1, @ElapsedMs, @name, @latin);

ROLLBACK TRAN Test09FishLatinExactWins
GO
