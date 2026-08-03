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

-- TEST 5: sp_news_doc_add inserts a PUBLISHED article and fn_news_doc round-trips its fields
BEGIN TRAN Test5
    DECLARE @test_name sysname = N'Test5 [sp_news_doc_add] : add then fn_news_doc round-trips the fields'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @doc5 nvarchar(max) = N'{'
            + N'"title":"__TEST_ND_ADD__","author":"UnitTester","author_link":"http://a",'
            + N'"source":"unitsource","source_link":"http://s","video_link":"http://v",'
            + N'"credit":"Cr","photo_alt":"Alt","paragraph0":"P0","paragraph1":"P1","paragraph2":"P2",'
            + N'"country":"CA","date":"2026-05-01","lake_id":null,"photo":null,"fishes":[]}'

        DECLARE @ret5 TABLE (news_id uniqueidentifier)
        INSERT INTO @ret5 EXEC dbo.sp_news_doc_add @doc5
        DECLARE @newId5 uniqueidentifier = (SELECT TOP 1 news_id FROM @ret5)

        DECLARE @back5 nvarchar(max) = dbo.fn_news_doc(@newId5)

        IF @newId5 IS NOT NULL
           AND @back5 IS NOT NULL AND ISJSON(@back5) = 1
           AND JSON_VALUE(@back5, '$.title')       = N'__TEST_ND_ADD__'
           AND JSON_VALUE(@back5, '$.author')      = N'UnitTester'
           AND JSON_VALUE(@back5, '$.source')      = N'unitsource'
           AND JSON_VALUE(@back5, '$.country')     = N'CA'
           AND JSON_VALUE(@back5, '$.date')        = N'2026-05-01'
           AND JSON_VALUE(@back5, '$.paragraph0')  = N'P0'
           AND JSON_VALUE(@back5, '$.paragraph2')  = N'P2'
           AND JSON_VALUE(@back5, '$.credit')      = N'Cr'
           -- inserted PUBLISHED, else fn_news_doc would return NULL
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_news_doc_add created a published article that round-trips'
    ELSE
        RAISERROR ('TEST 5 FAIL [%dms]: sp_news_doc_add did not round-trip via fn_news_doc', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test5
GO

-- TEST 6: sp_news_doc_add maps the base64 lead photo and up-to-3 fishes
BEGIN TRAN Test6
    DECLARE @test_name sysname = N'Test6 [sp_news_doc_add] : base64 photo and fishes are stored'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        -- two real fish ids (fn_news_doc only returns fishes that JOIN dbo.fish)
        DECLARE @f1 uniqueidentifier, @f2 uniqueidentifier
        SELECT TOP 1 @f1 = fish_id FROM dbo.fish ORDER BY fish_id
        SELECT TOP 1 @f2 = fish_id FROM dbo.fish WHERE fish_id <> @f1 ORDER BY fish_id

        -- a real (> 100 byte) lead photo, base64-encoded like fn_news_json emits
        DECLARE @bin varbinary(max) = CAST(REPLICATE(CAST(0x41 AS varchar(max)), 300) AS varbinary(max))
        DECLARE @b64 varchar(max) = (SELECT @bin AS '*' FOR XML PATH(''), BINARY BASE64)

        DECLARE @doc6 nvarchar(max) = N'{'
            + N'"title":"__TEST_ND_ADD_PF__","author":"UnitTester","country":"CA","date":"2026-05-02",'
            + N'"photo":"' + @b64 + N'",'
            + N'"fishes":[{"id":"' + CAST(@f1 AS varchar(36)) + N'"},{"id":"' + CAST(@f2 AS varchar(36)) + N'"}]}'

        DECLARE @ret6 TABLE (news_id uniqueidentifier)
        INSERT INTO @ret6 EXEC dbo.sp_news_doc_add @doc6
        DECLARE @newId6 uniqueidentifier = (SELECT TOP 1 news_id FROM @ret6)

        DECLARE @back6 nvarchar(max) = dbo.fn_news_doc(@newId6)
        DECLARE @fcount int = (SELECT COUNT(*) FROM OPENJSON(@back6, '$.fishes'))

        IF @back6 IS NOT NULL
           AND JSON_VALUE(@back6, '$.photo') IS NOT NULL   -- real photo embedded
           AND @fcount = 2                                 -- both fishes resolved and returned
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_news_doc_add stored the base64 photo and both fishes'
    ELSE
        RAISERROR ('TEST 6 FAIL [%dms]: sp_news_doc_add photo/fishes mapping is wrong', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test6
GO

-- TEST 7: sp_news_doc_add rejects a document with no title (news_title is required)
BEGIN TRAN Test7
    DECLARE @test_name sysname = N'Test7 [sp_news_doc_add] : missing title is rejected'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    SET NOCOUNT ON
    SET @tStart = SYSUTCDATETIME()
    BEGIN TRY
        DECLARE @ret7 TABLE (news_id uniqueidentifier)
        INSERT INTO @ret7 EXEC dbo.sp_news_doc_add N'{"author":"UnitTester","paragraph0":"no title here"}'
        -- reaching here means no error was raised -> the guard failed
    END TRY
    BEGIN CATCH
        SET @result = 1   -- expected: a titleless document must raise
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_news_doc_add rejected a titleless document'
    ELSE
        RAISERROR ('TEST 7 FAIL [%dms]: sp_news_doc_add must reject a document with no title', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test7
GO

-- TEST 8: sp_news_doc_update replaces fields and preserves the lead photo when the body omits it
BEGIN TRAN Test8
    DECLARE @test_name sysname = N'Test8 [sp_news_doc_update] : replaces fields, keeps photo when omitted'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @bin8 varbinary(max) = CAST(REPLICATE(CAST(0x42 AS varchar(max)), 300) AS varbinary(max))
        DECLARE @b648 varchar(max) = (SELECT @bin8 AS '*' FOR XML PATH(''), BINARY BASE64)

        -- add with a real photo
        DECLARE @docAdd8 nvarchar(max) = N'{"title":"__TEST_ND_UPD_A__","author":"UnitTester","country":"CA",'
            + N'"date":"2026-05-03","paragraph0":"orig","photo":"' + @b648 + N'"}'
        DECLARE @ret8 TABLE (news_id uniqueidentifier)
        INSERT INTO @ret8 EXEC dbo.sp_news_doc_add @docAdd8
        DECLARE @newId8 uniqueidentifier = (SELECT TOP 1 news_id FROM @ret8)

        -- update with NO photo key -> title/paragraph replaced, photo preserved
        DECLARE @docUpd8 nvarchar(max) = N'{"title":"__TEST_ND_UPD_B__","author":"UnitTester2","country":"US",'
            + N'"date":"2026-06-04","paragraph0":"changed"}'
        EXEC dbo.sp_news_doc_update @newId8, @docUpd8

        DECLARE @back8 nvarchar(max) = dbo.fn_news_doc(@newId8)

        IF @back8 IS NOT NULL
           AND JSON_VALUE(@back8, '$.title')      = N'__TEST_ND_UPD_B__'   -- replaced
           AND JSON_VALUE(@back8, '$.author')     = N'UnitTester2'         -- replaced
           AND JSON_VALUE(@back8, '$.country')    = N'US'                  -- replaced
           AND JSON_VALUE(@back8, '$.date')       = N'2026-06-04'          -- replaced
           AND JSON_VALUE(@back8, '$.paragraph0') = N'changed'             -- replaced
           AND JSON_VALUE(@back8, '$.photo') IS NOT NULL                   -- preserved (body omitted it)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 1
        PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: sp_news_doc_update replaced fields and kept the photo'
    ELSE
        RAISERROR ('TEST 8 FAIL [%dms]: sp_news_doc_update replace/preserve behaviour is wrong', 16, -1, @ElapsedMs)
ROLLBACK TRAN Test8
GO
