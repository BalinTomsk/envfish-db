SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_news_doc
-- (docapi -- com.fishfind.docapi.repo.NewsDocumentRepository.getDocument, reached from
--  NewsController GET /api/v1/news/{guid}. The repository runs "SELECT dbo.fn_news_doc(?)" and
--  maps a NULL scalar to HTTP 404, a JSON string to HTTP 200. The result is cached by
--  NewsQueryCache (last 25 documents), so the function must be a pure read.)
--
-- Visibility rule: only PUBLISHED news is returned. An unpublished draft returns NULL and
-- therefore 404s, matching the guest visibility rule already used by fn_news_list and
-- fn_default_news_ids -- a public endpoint must never leak an unpublished draft.
--
-- Each test is isolated in its own transaction and rolls back, so no state survives the run.
--

PRINT 'Unit tests for fn_news_doc'
GO

-- TEST 1: a published news article is returned as a JSON document carrying its own fields
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_news_doc] : published news returns its JSON document'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Id1 uniqueidentifier = NEWID()

        INSERT INTO dbo.news (news_id, news_title, news_author, news_source, news_publish, country,
                              news_paragraph0, news_stamp, stamp)
        VALUES (@Id1, N'__TEST_ND_PUBLISHED__', N'UnitTester', N'unitsource', 1, 'CA',
                N'First paragraph body.', '2026-04-01', GETUTCDATE())

        DECLARE @Json1 nvarchar(max) = dbo.fn_news_doc(@Id1)

        IF @Json1 IS NOT NULL
           AND ISJSON(@Json1) = 1
           AND JSON_VALUE(@Json1, '$.title')      = N'__TEST_ND_PUBLISHED__'
           AND JSON_VALUE(@Json1, '$.author')     = N'UnitTester'
           AND JSON_VALUE(@Json1, '$.source')     = N'unitsource'
           AND JSON_VALUE(@Json1, '$.country')    = N'CA'
           AND JSON_VALUE(@Json1, '$.date')       = N'2026-04-01'
           AND JSON_VALUE(@Json1, '$.paragraph0') = N'First paragraph body.'
           AND LOWER(JSON_VALUE(@Json1, '$.news_id')) = LOWER(CAST(@Id1 AS nvarchar(36)))
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_doc returned the published article as JSON'
    ELSE
        RAISERROR ('TEST 1 FAIL [%dms]: fn_news_doc did not return the published article JSON', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test1
GO

-- TEST 2: an unknown news_id returns NULL (docapi maps NULL -> 404)
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_news_doc] : unknown news_id returns NULL'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Json2 nvarchar(max) = dbo.fn_news_doc(NEWID())

        IF @Json2 IS NULL
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_doc returned NULL for an unknown news_id'
    ELSE
        RAISERROR ('TEST 2 FAIL [%dms]: fn_news_doc must return NULL for an unknown news_id', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test2
GO

-- TEST 3: an UNPUBLISHED draft returns NULL -- a public endpoint must not leak drafts
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_news_doc] : unpublished draft returns NULL'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Id3 uniqueidentifier = NEWID()

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (@Id3, N'__TEST_ND_DRAFT__', N'UnitTester', 0, 'CA', '2026-04-02', GETUTCDATE())

        DECLARE @Json3 nvarchar(max) = dbo.fn_news_doc(@Id3)

        IF @Json3 IS NULL
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_doc hid an unpublished draft'
    ELSE
        RAISERROR ('TEST 3 FAIL [%dms]: fn_news_doc must return NULL for an unpublished draft', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test3
GO

-- TEST 4: a real (> 100 byte) lead photo is embedded, and a tiny placeholder is reported as absent
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [fn_news_doc] : real photo embedded, tiny placeholder omitted'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @IdBig uniqueidentifier = NEWID(), @IdTiny uniqueidentifier = NEWID()
        DECLARE @BigPhoto varbinary(max) = CAST(REPLICATE(CAST(0x41 AS varchar(max)), 300) AS varbinary(max))

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@IdBig, N'__TEST_ND_BIGPHOTO__', N'UnitTester', 1, 'CA', @BigPhoto, '2026-04-03', GETUTCDATE())

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@IdTiny, N'__TEST_ND_TINYPHOTO__', N'UnitTester', 1, 'CA', 0x01, '2026-04-04', GETUTCDATE())

        DECLARE @JsonBig nvarchar(max) = dbo.fn_news_doc(@IdBig)
        DECLARE @JsonTiny nvarchar(max) = dbo.fn_news_doc(@IdTiny)

        -- photo is base64 in the JSON when the stored blob is a real image (> 100 bytes),
        -- and null when it is only a placeholder byte -- same > 100 rule as fn_default_news_json.
        IF @JsonBig IS NOT NULL AND @JsonTiny IS NOT NULL
           AND JSON_VALUE(@JsonBig,  '$.photo') IS NOT NULL
           AND JSON_VALUE(@JsonTiny, '$.photo') IS NULL
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_doc embedded a real photo and omitted a placeholder'
    ELSE
        RAISERROR ('TEST 4 FAIL [%dms]: fn_news_doc photo handling is wrong', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test4
GO
