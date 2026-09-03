SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_news_ref_names_json
-- (docapi -- com.fishfind.docapi.repo.MySqlNewsQueryRepository.defaultNews, serving
--  GET /api/v1/news/default. The news rows live in MySQL, which holds only the `news` table, so
--  news.lake_id / fish1_id / fish2_id / fish3_id come back as bare guids and this function resolves
--  them to the display names Default.aspx renders as the article's tag row -- in ONE round trip for
--  the whole home page.)
--
-- Contract under test: {"lakes":[{"id","name"}],"fishes":[{"id","name","latin"}]}, never NULL,
-- always 1:1 with the request and in the requested order; an unresolved id keeps its element with a
-- null name rather than vanishing.
--
-- Each test is isolated in its own transaction and rolls back -- database state fully restored.
--
-- TEST 1 - a lake id and two fish ids resolve to names + latin names, in the order asked
-- TEST 2 - an unknown id keeps its element with name null (1:1 with the request preserved)
-- TEST 3 - empty arrays still return both halves, as empty arrays, never NULL
-- TEST 4 - NULL / blank / non-array arguments are treated as empty lists rather than raising
-- TEST 5 - a malformed guid string resolves to nothing instead of raising a conversion error
-- TEST 6 - a duplicated id yields one element per request slot, not one per distinct id
--

PRINT 'Unit tests for fn_news_ref_names_json'
GO

-- ===================================================================================
-- TEST 1: the headline case -- ids in, display names out, order preserved
-- ===================================================================================
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_news_ref_names_json] : ids resolve to names in the requested order'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Lake1 uniqueidentifier = NEWID()
        DECLARE @Fish1 uniqueidentifier = NEWID(), @Fish2 uniqueidentifier = NEWID()

        INSERT INTO dbo.lake (lake_id, lake_name) VALUES (@Lake1, N'__TEST_NRN_Lake__')
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type) VALUES
            (@Fish1, N'__TEST_NRN_Muskellunge__', N'Ut nrn masquinongy', 1),
            (@Fish2, N'__TEST_NRN_Walleye__',     N'Ut nrn vitreum',     1)

        DECLARE @json nvarchar(max) = dbo.fn_news_ref_names_json(
            N'["' + CAST(@Lake1 AS nvarchar(36)) + N'"]',
            N'["' + CAST(@Fish1 AS nvarchar(36)) + N'","' + CAST(@Fish2 AS nvarchar(36)) + N'"]')

        DECLARE @LakeName1 nvarchar(128) = JSON_VALUE(@json, '$.lakes[0].name')
        DECLARE @FishName0 nvarchar(128) = JSON_VALUE(@json, '$.fishes[0].name')
        DECLARE @FishLat0  nvarchar(128) = JSON_VALUE(@json, '$.fishes[0].latin')
        DECLARE @FishName1 nvarchar(128) = JSON_VALUE(@json, '$.fishes[1].name')
        DECLARE @LakeCnt1  int = (SELECT COUNT(*) FROM OPENJSON(@json, '$.lakes'))
        DECLARE @FishCnt1  int = (SELECT COUNT(*) FROM OPENJSON(@json, '$.fishes'))

        IF @LakeCnt1 = 1 AND @FishCnt1 = 2
           AND @LakeName1 = N'__TEST_NRN_Lake__'
           AND @FishName0 = N'__TEST_NRN_Muskellunge__' AND @FishLat0 = N'Ut nrn masquinongy'
           AND @FishName1 = N'__TEST_NRN_Walleye__'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 1 FAIL [%dms]: lake/fish ids did not resolve to their names in order', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: one lake + two fishes resolved, order preserved'

ROLLBACK TRAN Test1
GO

-- ===================================================================================
-- TEST 2: an unresolved id must NOT vanish -- the array stays 1:1 with the request
-- ===================================================================================
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_news_ref_names_json] : unknown id keeps its slot with a null name'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Known uniqueidentifier = NEWID()
        DECLARE @Missing nvarchar(36) = CAST(NEWID() AS nvarchar(36))

        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
        VALUES (@Known, N'__TEST_NRN_Burbot__', N'Ut nrn lota', 1)

        DECLARE @json nvarchar(max) = dbo.fn_news_ref_names_json(
            N'["' + @Missing + N'"]',
            N'["' + @Missing + N'","' + CAST(@Known AS nvarchar(36)) + N'"]')

        DECLARE @LakeCnt2 int = (SELECT COUNT(*) FROM OPENJSON(@json, '$.lakes'))
        DECLARE @FishCnt2 int = (SELECT COUNT(*) FROM OPENJSON(@json, '$.fishes'))
        -- JSON_VALUE returns SQL NULL for a JSON null, so IS NULL is the right assertion here.
        DECLARE @NullLake  nvarchar(128) = JSON_VALUE(@json, '$.lakes[0].name')
        DECLARE @NullFish  nvarchar(128) = JSON_VALUE(@json, '$.fishes[0].name')
        DECLARE @KnownName nvarchar(128) = JSON_VALUE(@json, '$.fishes[1].name')
        -- The id must still be echoed back, so the caller can map the slot to what it asked for.
        DECLARE @EchoedId  nvarchar(64)  = JSON_VALUE(@json, '$.fishes[0].id')

        IF @LakeCnt2 = 1 AND @FishCnt2 = 2
           AND @NullLake IS NULL AND @NullFish IS NULL
           AND @KnownName = N'__TEST_NRN_Burbot__'
           AND @EchoedId = @Missing
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 2 FAIL [%dms]: an unresolved id was dropped instead of kept with a null name', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown ids keep their slot, id echoed, name null'

ROLLBACK TRAN Test2
GO

-- ===================================================================================
-- TEST 3: empty request -- both halves present and empty, never NULL
-- ===================================================================================
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_news_ref_names_json] : empty arrays return both halves empty'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @json nvarchar(max) = dbo.fn_news_ref_names_json(N'[]', N'[]')

        IF @json IS NOT NULL AND ISJSON(@json) = 1
           AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.lakes')) = 0
           AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.fishes')) = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 3 FAIL [%dms]: an empty request must still return both halves as empty arrays', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: empty request returns valid JSON with two empty arrays'

ROLLBACK TRAN Test3
GO

-- ===================================================================================
-- TEST 4: NULL / blank / non-array arguments degrade to an empty list, they never raise.
--         An article with no lake and no fishes is normal and must not fail the home page.
-- ===================================================================================
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [fn_news_ref_names_json] : NULL/blank/non-array arguments are empty lists'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @jNull  nvarchar(max) = dbo.fn_news_ref_names_json(NULL, NULL)
        DECLARE @jBlank nvarchar(max) = dbo.fn_news_ref_names_json(N'', N'')
        DECLARE @jObj   nvarchar(max) = dbo.fn_news_ref_names_json(N'{"id":"x"}', N'not json at all')

        IF @jNull IS NOT NULL AND @jBlank IS NOT NULL AND @jObj IS NOT NULL
           AND ISJSON(@jNull) = 1 AND ISJSON(@jBlank) = 1 AND ISJSON(@jObj) = 1
           AND (SELECT COUNT(*) FROM OPENJSON(@jNull,  '$.lakes'))  = 0
           AND (SELECT COUNT(*) FROM OPENJSON(@jNull,  '$.fishes')) = 0
           AND (SELECT COUNT(*) FROM OPENJSON(@jBlank, '$.fishes')) = 0
           AND (SELECT COUNT(*) FROM OPENJSON(@jObj,   '$.lakes'))  = 0
           AND (SELECT COUNT(*) FROM OPENJSON(@jObj,   '$.fishes')) = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 4 FAIL [%dms]: a NULL/blank/non-array argument must degrade to an empty list', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: NULL, blank and non-array arguments all yield empty lists'

ROLLBACK TRAN Test4
GO

-- ===================================================================================
-- TEST 5: a malformed guid resolves to nothing rather than raising a conversion error
--         (TRY_CAST, not CAST -- news.lake_id is CHAR(36) in MySQL, so a bad value can reach here)
-- ===================================================================================
BEGIN TRAN Test5
    DECLARE @test_name sysname = N'Test5 [fn_news_ref_names_json] : malformed guid resolves to null, does not raise'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @json nvarchar(max) = dbo.fn_news_ref_names_json(N'["not-a-guid"]', N'["",""]')

        IF @json IS NOT NULL
           AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.lakes'))  = 1
           AND (SELECT COUNT(*) FROM OPENJSON(@json, '$.fishes')) = 2
           AND JSON_VALUE(@json, '$.lakes[0].name')  IS NULL
           AND JSON_VALUE(@json, '$.fishes[0].name') IS NULL
           AND JSON_VALUE(@json, '$.lakes[0].id')    = N'not-a-guid'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 5 FAIL [%dms]: a malformed guid must resolve to null, not raise', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: malformed and blank ids resolve to null without raising'

ROLLBACK TRAN Test5
GO

-- ===================================================================================
-- TEST 6: 1:1 means per REQUEST SLOT, not per distinct id -- an article may legitimately
--         name the same species twice, and the caller maps slots back by position.
-- ===================================================================================
BEGIN TRAN Test6
    DECLARE @test_name sysname = N'Test6 [fn_news_ref_names_json] : a duplicated id yields one element per slot'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Fish uniqueidentifier = NEWID()
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, water_type)
        VALUES (@Fish, N'__TEST_NRN_Pike__', N'Ut nrn lucius', 1)

        DECLARE @id nvarchar(36) = CAST(@Fish AS nvarchar(36))
        DECLARE @json nvarchar(max) = dbo.fn_news_ref_names_json(N'[]', N'["' + @id + N'","' + @id + N'"]')

        IF (SELECT COUNT(*) FROM OPENJSON(@json, '$.fishes')) = 2
           AND JSON_VALUE(@json, '$.fishes[0].name') = N'__TEST_NRN_Pike__'
           AND JSON_VALUE(@json, '$.fishes[1].name') = N'__TEST_NRN_Pike__'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 6 FAIL [%dms]: a duplicated id must keep both request slots', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: a duplicated id returns one element per requested slot'

ROLLBACK TRAN Test6
GO
