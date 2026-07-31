SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_news_json
-- (News.aspx.cs admin "Save JSON" download link -- exports a news article as a JSON object
--  carrying every field needed to re-create it on ~/Editor/AddNews.aspx).
-- Each test is isolated in its own named transaction and rolled back.
-- Uses real table dbo.news.
--

PRINT 'Unit tests for fn_news_json'
GO

-- TEST 1: returns the core AddNews fields (title/author/source/links/paragraphs/country/date)
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_news_json] : core fields exported'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @nid1 uniqueidentifier = NEWID()
        INSERT INTO dbo.news (news_id, news_title, news_author, news_author_link, news_source, news_source_link,
                              news_video_link, news_paragraph0, news_paragraph1, news_paragraph2,
                              country, news_publish, news_stamp, stamp)
        VALUES (@nid1, N'__TEST_NJ_TITLE__', N'Don Daniels', N'http://author', N'campbellrivermirror', N'http://src',
                N'http://youtu.be/x', N'para zero', N'para one', N'para two',
                'CA', 1, '2026-07-29', GETUTCDATE())

        DECLARE @json1 nvarchar(max) = dbo.fn_news_json(@nid1)

        IF JSON_VALUE(@json1, '$.title')      = N'__TEST_NJ_TITLE__'
       AND JSON_VALUE(@json1, '$.author')     = N'Don Daniels'
       AND JSON_VALUE(@json1, '$.source')     = N'campbellrivermirror'
       AND JSON_VALUE(@json1, '$.sourceLink') = N'http://src'
       AND JSON_VALUE(@json1, '$.authorLink') = N'http://author'
       AND JSON_VALUE(@json1, '$.videoLink')  = N'http://youtu.be/x'
       AND JSON_VALUE(@json1, '$.paragraph0') = N'para zero'
       AND JSON_VALUE(@json1, '$.paragraph1') = N'para one'
       AND JSON_VALUE(@json1, '$.paragraph2') = N'para two'
       AND JSON_VALUE(@json1, '$.country')    = N'CA'
       AND JSON_VALUE(@json1, '$.date')       = N'2026-07-29'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 1 FAIL [%dms]: exported JSON missing/incorrect core fields', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: exported all core AddNews fields correctly'

ROLLBACK TRAN Test1
GO

-- TEST 2: lake_id and fish GUIDs are exported; unset ones are present as null (stable shape)
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_news_json] : lake/fish GUIDs and null shape'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @nid2 uniqueidentifier = NEWID()

        -- own lake fixture
        DECLARE @lake2 uniqueidentifier = NEWID()
        INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@lake2, 1, N'__TEST_NJ_LAKE__')

        -- own fish fixture (fish FKs fish_family)
        DECLARE @fam2 uniqueidentifier = NEWID()
        DECLARE @fish2 uniqueidentifier = NEWID()
        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@fam2, N'__TEST_NJ_FAM__', -975, GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@fish2, N'__TEST_NJ_FISH__', N'Testus jsonicus', @fam2, GETUTCDATE(), GETUTCDATE())

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, news_stamp, stamp,
                              lake_id, fish1_id)
        VALUES (@nid2, N'__TEST_NJ_GUIDS__', N'UnitTester', 1, '2026-01-01', GETUTCDATE(),
                @lake2, @fish2)

        DECLARE @json2 nvarchar(max) = dbo.fn_news_json(@nid2)

        -- lakeId + fish1Id populated; fish2Id/fish3Id present but null
        IF LOWER(JSON_VALUE(@json2, '$.lakeId'))  = LOWER(CONVERT(varchar(36), @lake2))
       AND LOWER(JSON_VALUE(@json2, '$.fish1Id')) = LOWER(CONVERT(varchar(36), @fish2))
       AND JSON_VALUE(@json2, '$.fish2Id') IS NULL
       AND JSON_VALUE(@json2, '$.fish3Id') IS NULL
       -- key still present in the document even though null (INCLUDE_NULL_VALUES)
       AND @json2 LIKE '%"fish2Id":null%'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 2 FAIL [%dms]: lake/fish GUIDs or null shape incorrect', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: lake/fish GUIDs exported; unset fish slots kept as null'

ROLLBACK TRAN Test2
GO

-- TEST 4: paragraph photo is embedded as base64 (with author/alt), decodes back to the same bytes
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [fn_news_json] : photo embedded as base64'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @nid4 uniqueidentifier = NEWID()
        DECLARE @pic varbinary(max) = 0xDEADBEEF01

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, news_stamp, stamp,
                              news_photo0, news_photo_author0, news_photo_alt0)
        VALUES (@nid4, N'__TEST_NJ_PHOTO__', N'UnitTester', 1, '2026-01-01', GETUTCDATE(),
                @pic, N'Kari Fredheim', N'pier at dusk')

        DECLARE @json4 nvarchar(max) = dbo.fn_news_json(@nid4)
        DECLARE @b64 nvarchar(max) = JSON_VALUE(@json4, '$.photo0')

        -- base64 in JSON decodes back to the original bytes; author/alt carried alongside
        IF @b64 IS NOT NULL
       AND CAST('' AS xml).value('xs:base64Binary(sql:variable("@b64"))', 'varbinary(max)') = @pic
       AND JSON_VALUE(@json4, '$.photoAuthor0') = N'Kari Fredheim'
       AND JSON_VALUE(@json4, '$.photoAlt0')    = N'pier at dusk'
       -- an absent photo slot is still present in the document as null
       AND @json4 LIKE '%"photo1":null%'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 4 FAIL [%dms]: photo not embedded/decoded correctly', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: photo embedded as base64 and decoded back to original bytes'

ROLLBACK TRAN Test4
GO

-- TEST 3: unknown news_id returns NULL
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_news_json] : unknown id returns NULL'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @json3 nvarchar(max) = dbo.fn_news_json(NEWID())

        IF @json3 IS NULL
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 3 FAIL [%dms]: unknown news_id did not return NULL', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown news_id returned NULL'

ROLLBACK TRAN Test3
GO
