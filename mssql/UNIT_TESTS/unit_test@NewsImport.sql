SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.sp_news_import
-- (docapi POST /api/v1/news/import -- creates a news article from the fn_news_json interchange JSON).
-- Each test is isolated in its own named transaction and rolled back. Uses real tables
-- dbo.news / dbo.lake / dbo.fish / dbo.fish_family.
--

PRINT 'Unit tests for sp_news_import'
GO

-- TEST 1: a full interchange document creates a PUBLISHED article with every scalar field mapped
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [sp_news_import] : full document mapped, published'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @lake1 uniqueidentifier = NEWID()
        INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@lake1, 1, N'__TEST_NI_LAKE_T1__')
        DECLARE @fam1 uniqueidentifier = NEWID(), @fish1 uniqueidentifier = NEWID()
        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@fam1, N'__TEST_NI_FAM_T1__', -965, GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@fish1, N'__TEST_NI_FISH_T1__', N'Testus importus', @fam1, GETUTCDATE(), GETUTCDATE())

        DECLARE @json nvarchar(max) =
            N'{"title":"__TEST_NI_TITLE_T1__","author":"Don Daniels","authorLink":"http://a",' +
            N'"source":"campbellrivermirror","sourceLink":"http://s","videoLink":"http://v",' +
            N'"paragraph0":"p0","paragraph1":"p1","paragraph2":"p2","country":"CA","date":"2026-07-29",' +
            N'"lakeId":"' + CONVERT(varchar(36), @lake1) + N'","fish1Id":"' + CONVERT(varchar(36), @fish1) + N'",' +
            N'"fish2Id":null,"fish3Id":null,"photo0":null,"photoAuthor0":null,"photoAlt0":null,' +
            N'"photo1":null,"photoAuthor1":null,"photoAlt1":null,"photo2":null,"photoAuthor2":null,"photoAlt2":null}'

        DECLARE @r TABLE (news_id uniqueidentifier)
        INSERT INTO @r EXEC dbo.sp_news_import @json
        DECLARE @nid uniqueidentifier = (SELECT news_id FROM @r)

        IF EXISTS (
            SELECT 1 FROM dbo.news
            WHERE news_id = @nid
              AND news_title = N'__TEST_NI_TITLE_T1__'
              AND news_author = N'Don Daniels'
              AND news_source = N'campbellrivermirror'
              AND news_source_link = N'http://s'
              AND news_video_link = N'http://v'
              AND news_paragraph0 = N'p0' AND news_paragraph2 = N'p2'
              AND country = 'CA'
              AND CONVERT(varchar(10), news_stamp, 23) = '2026-07-29'
              AND news_publish = 1
              AND lake_id = @lake1
              AND fish1_id = @fish1 AND fish2_id IS NULL AND fish3_id IS NULL)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 1 FAIL [%dms]: imported article missing/incorrect fields', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: full document imported as a published article with all fields mapped'

ROLLBACK TRAN Test1
GO

-- TEST 2: a base64 photo is decoded back to the original bytes
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [sp_news_import] : base64 photo decoded to bytes'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        -- 0x0102030405 encodes to base64 "AQIDBAU="
        DECLARE @json2 nvarchar(max) =
            N'{"title":"__TEST_NI_TITLE_T2__","author":"UnitTester","photo0":"AQIDBAU=",' +
            N'"photoAuthor0":"Kari","photoAlt0":"pier"}'

        DECLARE @r2 TABLE (news_id uniqueidentifier)
        INSERT INTO @r2 EXEC dbo.sp_news_import @json2
        DECLARE @nid2 uniqueidentifier = (SELECT news_id FROM @r2)

        IF EXISTS (
            SELECT 1 FROM dbo.news
            WHERE news_id = @nid2
              AND news_photo0 = 0x0102030405
              AND news_photo_author0 = N'Kari'
              AND news_photo_alt0 = N'pier'
              AND news_photo1 IS NULL AND news_photo2 IS NULL)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 2 FAIL [%dms]: photo not decoded to the original bytes', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: base64 photo decoded back to the original bytes (author/alt carried)'

ROLLBACK TRAN Test2
GO

-- TEST 3: round-trip -- fn_news_json export then sp_news_import reproduces the article (bytes + fields)
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [sp_news_import] : round-trips fn_news_json export'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        -- seed a source article with a photo
        DECLARE @src uniqueidentifier = NEWID()
        DECLARE @pic varbinary(max) = 0xCAFEBABE1234
        INSERT INTO dbo.news (news_id, news_title, news_author, news_source, news_publish, news_stamp, stamp,
                              country, news_photo0, news_photo_author0)
        VALUES (@src, N'__TEST_NI_SRC_T3__', N'Jane Roe', N'sourceMag', 1, '2026-02-02', GETUTCDATE(),
                'US', @pic, N'Photographer X')

        -- export, then rename (news_title is UNIQUE) so the import is a distinct new article
        DECLARE @exported nvarchar(max) = dbo.fn_news_json(@src)
        DECLARE @toImport nvarchar(max) = JSON_MODIFY(@exported, '$.title', N'__TEST_NI_DST_T3__')

        DECLARE @r3 TABLE (news_id uniqueidentifier)
        INSERT INTO @r3 EXEC dbo.sp_news_import @toImport
        DECLARE @nid3 uniqueidentifier = (SELECT news_id FROM @r3)

        IF EXISTS (
            SELECT 1 FROM dbo.news
            WHERE news_id = @nid3
              AND news_title = N'__TEST_NI_DST_T3__'
              AND news_author = N'Jane Roe'
              AND news_source = N'sourceMag'
              AND country = 'US'
              AND CONVERT(varchar(10), news_stamp, 23) = '2026-02-02'
              AND news_photo0 = @pic
              AND news_photo_author0 = N'Photographer X'
              AND news_publish = 1)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 3 FAIL [%dms]: round-trip did not reproduce the article', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_news_json export re-imported to an identical article (photo bytes + fields)'

ROLLBACK TRAN Test3
GO

-- TEST 4: a minimal document (title + author only) inserts with null photos/fish/lake and a defaulted date
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [sp_news_import] : minimal document, defaults'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @json4 nvarchar(max) = N'{"title":"__TEST_NI_TITLE_T4__","author":"Solo"}'

        DECLARE @r4 TABLE (news_id uniqueidentifier)
        INSERT INTO @r4 EXEC dbo.sp_news_import @json4
        DECLARE @nid4 uniqueidentifier = (SELECT news_id FROM @r4)

        IF EXISTS (
            SELECT 1 FROM dbo.news
            WHERE news_id = @nid4
              AND news_title = N'__TEST_NI_TITLE_T4__' AND news_author = N'Solo'
              AND news_photo0 IS NULL AND news_photo1 IS NULL AND news_photo2 IS NULL
              AND lake_id IS NULL AND fish1_id IS NULL
              AND news_stamp IS NOT NULL
              AND news_publish = 1)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 4 FAIL [%dms]: minimal import did not apply the expected defaults', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: minimal document inserted with null media and a defaulted date'

ROLLBACK TRAN Test4
GO
