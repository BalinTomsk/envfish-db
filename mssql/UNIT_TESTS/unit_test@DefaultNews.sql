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
