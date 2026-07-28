SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_default_news_ids
-- (Default.aspx.cs -- FishTracker._Default.LoadFrontalNews: reads vDefaultNews ORDER BY ORD ASC
--  and consumes it positionally -- the first 2 rows are the big lead articles rendered WITH a
--  photo, the next 3 are the right-column small-news items).
--  fn_default_news_ids returns each shown news_id with with_photo = 1 (lead/photo slot, first 2
--  rows) or 0 (right-column slot). The flag is POSITIONAL (row <= 2), not photo presence.
-- Each test is isolated in its own transaction and rolls back (no seed news exists, so within a
-- test transaction the inserted rows are the only news the global vDefaultNews view can see).
--

PRINT 'Unit tests for fn_default_news_ids'
GO

-- TEST 1: two CA photo articles flagged with_photo=1, three CA non-photo articles flagged 0
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_default_news_ids] : photo leads flagged 1, right column flagged 0'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Photo1 uniqueidentifier = NEWID(), @Photo2 uniqueidentifier = NEWID()

        -- Two published CA articles WITH a photo -> lead slots
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@Photo1, N'__TEST_DN_PHOTO_A__', N'UnitTester', 1, 'CA', 0x01, '2026-03-10', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@Photo2, N'__TEST_DN_PHOTO_B__', N'UnitTester', 1, 'CA', 0x01, '2026-03-09', GETUTCDATE())

        -- Three published articles WITHOUT a photo -> right column. The view fills the right
        -- column from CA (nn=3) + US (nn=4) + other-country (nn=5), so spread across countries:
        -- the two CA photo leads already consume 2 of the "TOP 3 CA" slots, leaving room for one
        -- CA small, one US, one other. (Three CA smalls would collapse to just one right-column row.)
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_SMALL_1__', N'UnitTester', 1, 'CA', '2026-03-08', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_SMALL_2__', N'UnitTester', 1, 'US', '2026-03-07', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_SMALL_3__', N'UnitTester', 1, 'GB', '2026-03-06', GETUTCDATE())

        DECLARE @Total1 int, @PhotoCnt1 int, @SmallCnt1 int, @P1 bit, @P2 bit
        SELECT @Total1    = COUNT(*)                                           FROM dbo.fn_default_news_ids()
        SELECT @PhotoCnt1 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE with_photo = 1
        SELECT @SmallCnt1 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE with_photo = 0
        SELECT @P1 = with_photo FROM dbo.fn_default_news_ids() WHERE news_id = @Photo1
        SELECT @P2 = with_photo FROM dbo.fn_default_news_ids() WHERE news_id = @Photo2

        IF @Total1 = 5 AND @PhotoCnt1 = 2 AND @SmallCnt1 = 3 AND @P1 = 1 AND @P2 = 1
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 1 FAIL [%dms]: expected 2 photo leads (flag 1) and 3 right-column (flag 0)', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: two photo articles flagged 1, three right-column flagged 0'

ROLLBACK TRAN Test1
GO

-- TEST 2: flag is positional -- with no photo articles at all, the first 2 rows are still flagged 1
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_default_news_ids] : flag is positional, not photo-presence'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        -- Three published CA articles, none with a photo
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_NP_1__', N'UnitTester', 1, 'CA', '2026-04-03', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_NP_2__', N'UnitTester', 1, 'CA', '2026-04-02', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_NP_3__', N'UnitTester', 1, 'CA', '2026-04-01', GETUTCDATE())

        DECLARE @Total2 int, @PhotoCnt2 int, @SmallCnt2 int
        SELECT @Total2    = COUNT(*)                                           FROM dbo.fn_default_news_ids()
        SELECT @PhotoCnt2 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE with_photo = 1
        SELECT @SmallCnt2 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE with_photo = 0

        -- Positional: 3 rows -> first 2 flagged 1 (lead area), last 1 flagged 0
        IF @Total2 = 3 AND @PhotoCnt2 = 2 AND @SmallCnt2 = 1
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 2 FAIL [%dms]: expected first 2 of 3 rows flagged 1 by position', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: with no photos, the first 2 rows are still flagged 1 (positional)'

ROLLBACK TRAN Test2
GO

-- TEST 3: unpublished (draft) news is excluded
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_default_news_ids] : draft news excluded'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Pub3 uniqueidentifier = NEWID(), @Draft3 uniqueidentifier = NEWID()

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@Pub3, N'__TEST_DN_PUB__', N'UnitTester', 1, 'CA', 0x01, '2026-05-02', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@Draft3, N'__TEST_DN_DRAFT__', N'UnitTester', 0, 'CA', 0x01, '2026-05-03', GETUTCDATE())

        DECLARE @Total3 int, @HasDraft3 int
        SELECT @Total3    = COUNT(*)                                          FROM dbo.fn_default_news_ids()
        SELECT @HasDraft3 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE news_id = @Draft3

        IF @Total3 = 1 AND @HasDraft3 = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 3 FAIL [%dms]: draft news should be excluded, only the published row returned', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unpublished draft excluded; only the published article returned'

ROLLBACK TRAN Test3
GO

-- TEST 4: capped at 5 rows -- exactly 2 flagged 1 and 3 flagged 0 even with surplus candidates
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [fn_default_news_ids] : capped at 5 (2 photo + 3 right column)'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        -- Two CA photo articles
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_C_PHOTO_1__', N'UnitTester', 1, 'CA', 0x01, '2026-06-10', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_DN_C_PHOTO_2__', N'UnitTester', 1, 'CA', 0x01, '2026-06-09', GETUTCDATE())

        -- Surplus non-photo articles across CA/US/other (3 each). The page caps at 5 total, so with
        -- 2 photo leads only 3 right-column rows survive, drawn from the country ladder (nn=3/4/5).
        DECLARE @i4 int = 1
        WHILE @i4 <= 3
        BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__TEST_DN_C_CA_' + CAST(@i4 AS nvarchar(2)) + N'__', N'UnitTester', 1, 'CA',
                    DATEADD(DAY, -@i4, '2026-06-08'), GETUTCDATE())
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__TEST_DN_C_US_' + CAST(@i4 AS nvarchar(2)) + N'__', N'UnitTester', 1, 'US',
                    DATEADD(DAY, -@i4, '2026-06-08'), GETUTCDATE())
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__TEST_DN_C_GB_' + CAST(@i4 AS nvarchar(2)) + N'__', N'UnitTester', 1, 'GB',
                    DATEADD(DAY, -@i4, '2026-06-08'), GETUTCDATE())
            SET @i4 = @i4 + 1
        END

        DECLARE @Total4 int, @PhotoCnt4 int, @SmallCnt4 int
        SELECT @Total4    = COUNT(*)                                           FROM dbo.fn_default_news_ids()
        SELECT @PhotoCnt4 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE with_photo = 1
        SELECT @SmallCnt4 = COUNT(*) FROM dbo.fn_default_news_ids() WHERE with_photo = 0

        IF @Total4 = 5 AND @PhotoCnt4 = 2 AND @SmallCnt4 = 3
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 4 FAIL [%dms]: expected exactly 5 rows (2 photo + 3 right column)', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: capped at 5 rows -- 2 flagged 1 and 3 flagged 0'

ROLLBACK TRAN Test4
GO

--
-- dbo.fn_default_news_json -- the per-item JSON document (info + photo for a lead, compact for a
-- right-column item). @with_photo selects the shape; the caller passes the flag from
-- fn_default_news_ids.
--

-- TEST 5: type 1 (lead) JSON carries the full info + the photo as base64 + the mentioned fishes
BEGIN TRAN Test5
    DECLARE @test_name sysname = N'Test5 [fn_default_news_json] : type-1 lead JSON has info, photo, fishes'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @Fam5 uniqueidentifier = NEWID(), @F5a uniqueidentifier = NEWID(), @F5b uniqueidentifier = NEWID()
        DECLARE @Lake5 uniqueidentifier = NEWID(), @N5 uniqueidentifier = NEWID()
        DECLARE @Bytes5 varbinary(max) = CONVERT(varbinary(max), REPLICATE(CAST(0xAB AS varbinary(1)), 200))
        DECLARE @ExpB64 varchar(max) = CAST('' AS xml).value('xs:base64Binary(sql:variable("@Bytes5"))', 'varchar(max)')

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@Fam5, N'__TEST_DNJ_FAM5__', -8801, GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@F5a, N'__TEST_DNJ_Walleye__', N'__TEST_DNJ_vitreus__', @Fam5, GETUTCDATE(), GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@F5b, N'__TEST_DNJ_Pike__', N'__TEST_DNJ_lucius__', @Fam5, GETUTCDATE(), GETUTCDATE())
        INSERT INTO dbo.lake (lake_id, lake_name) VALUES (@Lake5, N'__TEST_DNJ_Lake__')

        INSERT INTO dbo.news (news_id, news_title, news_author, news_author_link, news_source, news_source_link,
            news_publish, country, news_photo0, news_photo_author0, news_photo_alt0, news_paragraph0, news_paragraph1,
            lake_id, fish1_id, fish2_id, news_stamp, stamp)
        VALUES (@N5, N'__TEST_DNJ_LEAD__', N'Jane Doe', N'http://a/author', N'Angler Times', N'http://a/src',
            1, 'CA', @Bytes5, N'Photog', N'a fish photo', N'First line' + CHAR(10) + N'second', N'Para one',
            @Lake5, @F5a, @F5b, '2026-07-10', GETUTCDATE())

        DECLARE @Json5 nvarchar(max) = dbo.fn_default_news_json(@N5, 1)
        DECLARE @FishCnt5 int = (SELECT COUNT(*) FROM OPENJSON(@Json5, '$.fishes'))

        IF @Json5 IS NOT NULL
           AND JSON_VALUE(@Json5, '$.title')      = N'__TEST_DNJ_LEAD__'
           AND JSON_VALUE(@Json5, '$.flag')       = N'CA.png'
           AND JSON_VALUE(@Json5, '$.source')     = N'Angler Times'
           AND JSON_VALUE(@Json5, '$.credit')     = N'Photog'
           AND JSON_VALUE(@Json5, '$.lake_name')  = N'__TEST_DNJ_Lake__'
           AND JSON_VALUE(@Json5, '$.with_photo') = N'true'
           AND JSON_VALUE(@Json5, '$.photo')      = @ExpB64
           AND @FishCnt5 = 2
           AND JSON_VALUE(@Json5, '$.fishes[0].name') = N'__TEST_DNJ_Walleye__'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 5 FAIL [%dms]: type-1 JSON missing expected info/photo/fishes', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: type-1 lead JSON has info, base64 photo, and both fishes'

ROLLBACK TRAN Test5
GO

-- TEST 6: type 0 (right-column) JSON is compact -- title/date/source/link/snippet, no photo
BEGIN TRAN Test6
    DECLARE @test_name sysname = N'Test6 [fn_default_news_json] : type-0 compact JSON, source falls back to author, no photo'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @N6 uniqueidentifier = NEWID()
        -- news_source is NULL so source must fall back to news_author; paragraph0 has a newline
        INSERT INTO dbo.news (news_id, news_title, news_author, news_source, news_source_link,
            news_publish, country, news_paragraph0, news_stamp, stamp)
        VALUES (@N6, N'__TEST_DNJ_SMALL__', N'Bob Smith', NULL, N'http://a/small',
            1, 'US', N'Snippet first line' + CHAR(13) + CHAR(10) + N'rest of body', '2026-07-09', GETUTCDATE())

        DECLARE @Json6 nvarchar(max) = dbo.fn_default_news_json(@N6, 0)

        IF @Json6 IS NOT NULL
           AND JSON_VALUE(@Json6, '$.title')      = N'__TEST_DNJ_SMALL__'
           AND JSON_VALUE(@Json6, '$.source')     = N'Bob Smith'          -- fell back to author
           AND JSON_VALUE(@Json6, '$.link')       = N'http://a/small'
           AND JSON_VALUE(@Json6, '$.snippet')    = N'Snippet first line' -- first line only, CR stripped
           AND JSON_VALUE(@Json6, '$.with_photo') = N'false'
           AND JSON_VALUE(@Json6, '$.photo')      IS NULL                 -- no photo key on the compact shape
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 6 FAIL [%dms]: type-0 compact JSON incorrect (source fallback / snippet / no photo)', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: type-0 JSON is compact, source falls back to author, first-line snippet, no photo'

ROLLBACK TRAN Test6
GO

-- TEST 7: type 1 photo guard (blob <= 100 bytes -> photo null) and empty fishes -> []
BEGIN TRAN Test7
    DECLARE @test_name sysname = N'Test7 [fn_default_news_json] : tiny photo nulled, no fishes -> empty array'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @N7 uniqueidentifier = NEWID()
        -- 10-byte blob (<= 100) must be treated as "no real image" and emitted as null
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_photo0, news_stamp, stamp)
        VALUES (@N7, N'__TEST_DNJ_TINY__', N'UT', 1, 'CA',
            CONVERT(varbinary(max), REPLICATE(CAST(0x01 AS varbinary(1)), 10)), '2026-07-08', GETUTCDATE())

        DECLARE @Json7 nvarchar(max) = dbo.fn_default_news_json(@N7, 1)

        IF @Json7 IS NOT NULL
           AND JSON_VALUE(@Json7, '$.photo')  IS NULL         -- tiny blob nulled by the > 100 guard
           AND JSON_QUERY(@Json7, '$.fishes') = N'[]'         -- no fishes -> empty JSON array (not null)
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 7 FAIL [%dms]: expected tiny photo -> null and empty fishes -> []', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: tiny photo blob nulled and fishes rendered as an empty array'

ROLLBACK TRAN Test7
GO

-- TEST 8: type 0 snippet falls back to paragraph1 when paragraph0 is empty (no newline -> whole line)
BEGIN TRAN Test8
    DECLARE @test_name sysname = N'Test8 [fn_default_news_json] : type-0 snippet falls back to paragraph1'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @N8 uniqueidentifier = NEWID()
        INSERT INTO dbo.news (news_id, news_title, news_author, news_source, news_publish, country,
            news_paragraph0, news_paragraph1, news_stamp, stamp)
        VALUES (@N8, N'__TEST_DNJ_FB__', N'UT', N'Real Source', 1, 'GB',
            N'', N'Only paragraph one', '2026-07-07', GETUTCDATE())

        DECLARE @Json8 nvarchar(max) = dbo.fn_default_news_json(@N8, 0)

        IF @Json8 IS NOT NULL
           AND JSON_VALUE(@Json8, '$.source')  = N'Real Source'          -- source present, no fallback
           AND JSON_VALUE(@Json8, '$.snippet') = N'Only paragraph one'   -- from paragraph1
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 8 FAIL [%dms]: snippet should fall back to paragraph1', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: snippet falls back to paragraph1 and explicit source is kept'

ROLLBACK TRAN Test8
GO

--
-- dbo.fn_news_list -- the paged "latest news" list behind News.aspx: country filter, CA padding
-- to 100 for a thin non-CA country, and modern OFFSET/FETCH pagination with a windowed total.
--

-- TEST 9: @country NULL -> all countries newest-first; drafts excluded; pagination + total correct
BEGIN TRAN Test9
    DECLARE @test_name sysname = N'Test9 [fn_news_list] : all countries, newest-first, paged, drafts excluded'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @i9 int
        SET @i9 = 1  -- 3 US (oldest stamps)
        WHILE @i9 <= 3 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T9_US_' + CAST(@i9 AS varchar(3)) + N'__', N'UT', 1, 'US', DATEADD(DAY, @i9, '2026-01-01'), GETUTCDATE())
            SET @i9 += 1 END
        SET @i9 = 1  -- 5 CA (middle stamps)
        WHILE @i9 <= 5 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T9_CA_' + CAST(@i9 AS varchar(3)) + N'__', N'UT', 1, 'CA', DATEADD(DAY, @i9, '2026-02-01'), GETUTCDATE())
            SET @i9 += 1 END
        SET @i9 = 1  -- 2 GB (newest stamps)
        WHILE @i9 <= 2 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T9_GB_' + CAST(@i9 AS varchar(3)) + N'__', N'UT', 1, 'GB', DATEADD(DAY, @i9, '2026-03-01'), GETUTCDATE())
            SET @i9 += 1 END
        -- an unpublished US draft must NOT appear
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
        VALUES (NEWID(), N'__T9_DRAFT__', N'UT', 0, 'US', '2026-09-09', GETUTCDATE())

        DECLARE @Total9 int   = (SELECT TOP 1 total FROM dbo.fn_news_list(NULL, 0, 4))
        DECLARE @P0Cnt9 int   = (SELECT COUNT(*)   FROM dbo.fn_news_list(NULL, 0, 4))
        DECLARE @P0Min9 int   = (SELECT MIN(rn)    FROM dbo.fn_news_list(NULL, 0, 4))
        DECLARE @TopFlag9 char(2) = (SELECT flag   FROM dbo.fn_news_list(NULL, 0, 1))   -- newest overall
        DECLARE @P2Cnt9 int   = (SELECT COUNT(*)   FROM dbo.fn_news_list(NULL, 8, 4))   -- rn 9,10
        DECLARE @P2Min9 int   = (SELECT MIN(rn)    FROM dbo.fn_news_list(NULL, 8, 4))

        IF @Total9 = 10 AND @P0Cnt9 = 4 AND @P0Min9 = 1 AND @TopFlag9 = 'GB'
           AND @P2Cnt9 = 2 AND @P2Min9 = 9
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 9 FAIL [%dms]: all-countries paging/total/draft-exclusion incorrect', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: all countries newest-first, total=10 (draft excluded), pages slice correctly'

ROLLBACK TRAN Test9
GO

-- TEST 10: @country=US (3 own < 100) -> US block first, then CA padding; total = 3 + 5
BEGIN TRAN Test10
    DECLARE @test_name sysname = N'Test10 [fn_news_list] : thin non-CA country padded with CA at the end'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @i10 int
        SET @i10 = 1
        WHILE @i10 <= 3 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T10_US_' + CAST(@i10 AS varchar(3)) + N'__', N'UT', 1, 'US', DATEADD(DAY, @i10, '2026-01-01'), GETUTCDATE())
            SET @i10 += 1 END
        SET @i10 = 1
        WHILE @i10 <= 5 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T10_CA_' + CAST(@i10 AS varchar(3)) + N'__', N'UT', 1, 'CA', DATEADD(DAY, @i10, '2026-02-01'), GETUTCDATE())
            SET @i10 += 1 END

        DECLARE @Total10 int   = (SELECT TOP 1 total FROM dbo.fn_news_list('US', 0, 50))
        DECLARE @OwnCnt10 int  = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 50) WHERE block_ord = 0)
        DECLARE @PadCnt10 int  = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 50) WHERE block_ord = 1)
        DECLARE @OwnFlag10 int = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 50) WHERE block_ord = 0 AND flag <> 'US')
        DECLARE @PadFlag10 int = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 50) WHERE block_ord = 1 AND flag <> 'CA')
        DECLARE @OwnMaxRn int  = (SELECT MAX(rn) FROM dbo.fn_news_list('US', 0, 50) WHERE block_ord = 0)
        DECLARE @PadMinRn int  = (SELECT MIN(rn) FROM dbo.fn_news_list('US', 0, 50) WHERE block_ord = 1)

        -- total 8, 3 own US first (rn 1..3), 5 CA padding after (rn from 4), correct flags
        IF @Total10 = 8 AND @OwnCnt10 = 3 AND @PadCnt10 = 5 AND @OwnFlag10 = 0 AND @PadFlag10 = 0
           AND @OwnMaxRn = 3 AND @PadMinRn = 4
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 10 FAIL [%dms]: US block + CA padding ordering/total incorrect', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US news first then CA padding at the end, total=8'

ROLLBACK TRAN Test10
GO

-- TEST 11: @country=CA -> no padding block, other countries excluded
BEGIN TRAN Test11
    DECLARE @test_name sysname = N'Test11 [fn_news_list] : CA requested is never padded and excludes others'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @i11 int
        SET @i11 = 1
        WHILE @i11 <= 5 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T11_CA_' + CAST(@i11 AS varchar(3)) + N'__', N'UT', 1, 'CA', DATEADD(DAY, @i11, '2026-02-01'), GETUTCDATE())
            SET @i11 += 1 END
        SET @i11 = 1  -- US rows must be excluded when CA is asked
        WHILE @i11 <= 3 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T11_US_' + CAST(@i11 AS varchar(3)) + N'__', N'UT', 1, 'US', DATEADD(DAY, @i11, '2026-01-01'), GETUTCDATE())
            SET @i11 += 1 END

        DECLARE @Total11 int  = (SELECT TOP 1 total FROM dbo.fn_news_list('CA', 0, 50))
        DECLARE @PadCnt11 int = (SELECT COUNT(*) FROM dbo.fn_news_list('CA', 0, 50) WHERE block_ord = 1)
        DECLARE @NonCa11 int  = (SELECT COUNT(*) FROM dbo.fn_news_list('CA', 0, 50) WHERE flag <> 'CA')

        IF @Total11 = 5 AND @PadCnt11 = 0 AND @NonCa11 = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 11 FAIL [%dms]: CA request should not pad and should exclude other countries', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CA request returns only CA, no padding block'

ROLLBACK TRAN Test11
GO

-- TEST 12: padding is capped so the padded list tops out at exactly 100 (own 2 + 98 CA)
BEGIN TRAN Test12
    DECLARE @test_name sysname = N'Test12 [fn_news_list] : CA padding capped at 100 total'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @i12 int
        SET @i12 = 1  -- 2 US
        WHILE @i12 <= 2 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T12_US_' + CAST(@i12 AS varchar(3)) + N'__', N'UT', 1, 'US', DATEADD(DAY, @i12, '2026-01-01'), GETUTCDATE())
            SET @i12 += 1 END
        SET @i12 = 1  -- 105 CA (more than enough to fill)
        WHILE @i12 <= 105 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T12_CA_' + CAST(@i12 AS varchar(3)) + N'__', N'UT', 1, 'CA', DATEADD(DAY, @i12, '2026-02-01'), GETUTCDATE())
            SET @i12 += 1 END

        DECLARE @Total12 int  = (SELECT TOP 1 total FROM dbo.fn_news_list('US', 0, 200))
        DECLARE @OwnCnt12 int = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 200) WHERE block_ord = 0)
        DECLARE @PadCnt12 int = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 200) WHERE block_ord = 1)

        -- 2 own + 98 CA padding = exactly 100
        IF @Total12 = 100 AND @OwnCnt12 = 2 AND @PadCnt12 = 98
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 12 FAIL [%dms]: padded list should cap at 100 (2 own + 98 CA)', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 12 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: CA padding tops the list at exactly 100'

ROLLBACK TRAN Test12
GO

-- TEST 13: a country with >= 100 of its own news is NOT padded
BEGIN TRAN Test13
    DECLARE @test_name sysname = N'Test13 [fn_news_list] : country with >= 100 own news is not padded'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @i13 int
        SET @i13 = 1  -- 100 US
        WHILE @i13 <= 100 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T13_US_' + CAST(@i13 AS varchar(3)) + N'__', N'UT', 1, 'US', DATEADD(DAY, @i13, '2026-01-01'), GETUTCDATE())
            SET @i13 += 1 END
        SET @i13 = 1  -- 5 CA that must NOT be pulled in
        WHILE @i13 <= 5 BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, country, news_stamp, stamp)
            VALUES (NEWID(), N'__T13_CA_' + CAST(@i13 AS varchar(3)) + N'__', N'UT', 1, 'CA', DATEADD(DAY, @i13, '2026-02-01'), GETUTCDATE())
            SET @i13 += 1 END

        DECLARE @Total13 int  = (SELECT TOP 1 total FROM dbo.fn_news_list('US', 0, 200))
        DECLARE @PadCnt13 int = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 200) WHERE block_ord = 1)
        DECLARE @NonUs13 int  = (SELECT COUNT(*) FROM dbo.fn_news_list('US', 0, 200) WHERE flag <> 'US')

        IF @Total13 = 100 AND @PadCnt13 = 0 AND @NonUs13 = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 13 FAIL [%dms]: a full (>= 100) country must not be CA-padded', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 13 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: US with 100 own news is not padded with CA'

ROLLBACK TRAN Test13
GO
