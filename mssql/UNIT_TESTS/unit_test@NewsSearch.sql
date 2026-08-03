SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_news_search
-- (docapi -- com.fishfind.docapi.repo.JdbcNewsQueryRepository.search, reached from
--  NewsController GET /api/v1/news/search?q=...). Returns up to 100 PUBLISHED news articles matching a
--  term across the headline, source, paragraphs, photo alts, and the names of the up-to-3 mentioned
--  fishes. Only published news is returned; a NULL/empty term yields the latest 100 published.
--
-- Each test is isolated in its own transaction and rolls back, so no state survives the run.
--

PRINT 'Unit tests for fn_news_search'
GO

-- TEST 1: a published article is found by a term in its headline
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_news_search] : match by headline'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Id1 uniqueidentifier = NEWID()
        INSERT INTO dbo.news (news_id, news_title, news_author, news_source, news_publish, country,
                              news_paragraph0, news_stamp, stamp)
        VALUES (@Id1, N'__TEST_NS_ZQXHEADLINE__', N'UnitTester', N'unitsource', 1, 'CA',
                N'Body text.', SYSUTCDATETIME(), GETUTCDATE())

        IF EXISTS (SELECT 1 FROM dbo.fn_news_search(N'ZQXHEADLINE') WHERE news_id = @Id1)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_search found the article by its headline'
    ELSE
        RAISERROR ('TEST 1 FAIL [%dms]: fn_news_search did not match by headline', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test1
GO

-- TEST 2: an article is found by a MENTIONED FISH's name even when the headline does not contain it
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_news_search] : match by mentioned fish name'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @fid uniqueidentifier, @fname varchar(32)
        SELECT TOP 1 @fid = fish_id, @fname = fish_name FROM dbo.fish ORDER BY fish_id

        DECLARE @Id2 uniqueidentifier = NEWID()
        -- headline deliberately contains NO fish name; the only match path is the fish join
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country,
                              fish1_id, news_stamp, stamp)
        VALUES (@Id2, N'__TEST_NS_NOFISHINTITLE__', N'UnitTester', 1, 'CA',
                @fid, SYSUTCDATETIME(), GETUTCDATE())

        -- newest first, so this just-inserted row is within TOP 100 for its fish's name
        IF @fid IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.fn_news_search(@fname) WHERE news_id = @Id2)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_search matched by a mentioned fish name'
    ELSE
        RAISERROR ('TEST 2 FAIL [%dms]: fn_news_search did not match by the mentioned fish name', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test2
GO

-- TEST 3: an UNPUBLISHED draft is never returned, even on an exact term match
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_news_search] : unpublished draft is hidden'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Id3 uniqueidentifier = NEWID()
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (@Id3, N'__TEST_NS_ZQYDRAFT__', N'UnitTester', 0, 'CA', SYSUTCDATETIME(), GETUTCDATE())

        IF NOT EXISTS (SELECT 1 FROM dbo.fn_news_search(N'ZQYDRAFT') WHERE news_id = @Id3)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_search hid the unpublished draft'
    ELSE
        RAISERROR ('TEST 3 FAIL [%dms]: fn_news_search must not return an unpublished draft', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test3
GO

-- TEST 4: a NULL term returns the latest published articles (incl. a just-published row), capped at 100
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [fn_news_search] : NULL term returns latest published (<=100)'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Id4 uniqueidentifier = NEWID()
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (@Id4, N'__TEST_NS_NULLQ__', N'UnitTester', 1, 'CA', SYSUTCDATETIME(), GETUTCDATE())

        DECLARE @cnt int = (SELECT COUNT(*) FROM dbo.fn_news_search(NULL))

        IF @cnt > 0 AND @cnt <= 100
           AND EXISTS (SELECT 1 FROM dbo.fn_news_search(NULL) WHERE news_id = @Id4)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_search returned the latest published, capped at 100'
    ELSE
        RAISERROR ('TEST 4 FAIL [%dms]: fn_news_search NULL-term behaviour is wrong', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test4
GO
