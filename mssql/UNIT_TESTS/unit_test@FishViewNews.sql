SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_fish_view_news
-- (Resources/wfFishViewer.aspx.cs -- FishTracker.Resources.wfFishViewer.LoadNews:
--  the "Last news" section listing up to 10 published news mentioning the fish in any
--  of the up-to-3 assigned slots news.fish1_id / fish2_id / fish3_id).
-- Mirrors dbo.fn_river_view_news: @col (1 = left / 0 = right) splits the rows into the
-- page's two columns, so totals below sum both columns.
-- Each test is isolated in its own transaction.
--

PRINT 'Unit tests for fn_fish_view_news'
GO

-- TEST 1: published news with the fish in slot 1 is returned
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_fish_view_news] : slot-1 news returned with title and source'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @TestFamilyId1 uniqueidentifier = NEWID()
        DECLARE @TestFishId1 uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@TestFamilyId1, N'__TEST_FAMILY_NEWS_T1__', -991, GETUTCDATE())

        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@TestFishId1, N'__TEST_FISH_NEWS_T1__', N'Testus novellus', @TestFamilyId1, GETUTCDATE(), GETUTCDATE())

        INSERT INTO dbo.news (news_id, news_title, news_author, news_source, news_publish, fish1_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_SLOT1__', N'UnitTester', N'UnitTest Gazette', 1, @TestFishId1, '2026-01-01', GETUTCDATE())

        DECLARE @Cnt1 int, @Title1 sysname, @Source1 nvarchar(255)
        SELECT @Cnt1 = (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId1, 1))
                     + (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId1, 0))
        SELECT @Title1 = news_title, @Source1 = news_source FROM dbo.fn_fish_view_news(@TestFishId1, 1)

        IF @Cnt1 = 1 AND @Title1 = N'__TEST_NEWS_SLOT1__' AND @Source1 = N'UnitTest Gazette'
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 1 FAIL [%dms]: slot-1 news not returned correctly', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_fish_view_news returned the slot-1 news with title and source'

ROLLBACK TRAN Test1
GO

-- TEST 2: fish is also matched via slot 2 and slot 3
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_fish_view_news] : slot-2 and slot-3 assignments matched'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @TestFamilyId2 uniqueidentifier = NEWID()
        DECLARE @TestFishId2 uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@TestFamilyId2, N'__TEST_FAMILY_NEWS_T2__', -992, GETUTCDATE())

        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@TestFishId2, N'__TEST_FISH_NEWS_T2__', N'Testus novellus', @TestFamilyId2, GETUTCDATE(), GETUTCDATE())

        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish1_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_SLOT1_T2__', N'UnitTester', 1, @TestFishId2, '2026-01-01', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish2_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_SLOT2_T2__', N'UnitTester', 1, @TestFishId2, '2026-01-02', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish3_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_SLOT3_T2__', N'UnitTester', 1, @TestFishId2, '2026-01-03', GETUTCDATE())

        DECLARE @Cnt2 int
        SELECT @Cnt2 = (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId2, 1))
                     + (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId2, 0))

        IF @Cnt2 = 3
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 2 FAIL [%dms]: slot-2 and slot-3 not matched correctly', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: slot-2 and slot-3 assignments are matched too (3 rows total)'

ROLLBACK TRAN Test2
GO

-- TEST 3: unpublished news excluded; unrelated fish gets no rows
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_fish_view_news] : unpublished news excluded, unrelated fish empty'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @TestFamilyId3 uniqueidentifier = NEWID()
        DECLARE @TestFishId3 uniqueidentifier = NEWID()
        DECLARE @OtherFishId3 uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@TestFamilyId3, N'__TEST_FAMILY_NEWS_T3__', -993, GETUTCDATE())

        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@TestFishId3, N'__TEST_FISH_NEWS_T3__', N'Testus novellus', @TestFamilyId3, GETUTCDATE(), GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@OtherFishId3, N'__TEST_FISH_OTHER_T3__', N'Otherush inexistus', @TestFamilyId3, GETUTCDATE(), GETUTCDATE())

        -- Published news for test fish
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish1_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_PUB_T3__', N'UnitTester', 1, @TestFishId3, '2026-01-01', GETUTCDATE())
        -- Unpublished (draft) news for test fish
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish1_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_DRAFT_T3__', N'UnitTester', 0, @TestFishId3, '2026-01-04', GETUTCDATE())

        DECLARE @Cnt3 int, @CntOther3 int
        SELECT @Cnt3 = (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId3, 1))
                     + (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId3, 0))
        SELECT @CntOther3 = (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@OtherFishId3, 1))
                         + (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@OtherFishId3, 0))

        IF @Cnt3 = 1 AND @CntOther3 = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 3 FAIL [%dms]: unpublished/unrelated filtering incorrect', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unpublished draft excluded; unrelated fish has no rows'

ROLLBACK TRAN Test3
GO

-- TEST 4: result capped at 10 rows total, keeps the newest by news_stamp
BEGIN TRAN Test4
    DECLARE @test_name sysname = N'Test4 [fn_fish_view_news] : capped at 10 rows, oldest excluded'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @TestFamilyId4 uniqueidentifier = NEWID()
        DECLARE @TestFishId4 uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@TestFamilyId4, N'__TEST_FAMILY_NEWS_T4__', -994, GETUTCDATE())

        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@TestFishId4, N'__TEST_FISH_NEWS_T4__', N'Testus novellus', @TestFamilyId4, GETUTCDATE(), GETUTCDATE())

        -- Insert 12 published news items
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish1_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_OLD1__', N'UnitTester', 1, @TestFishId4, '2026-01-01', GETUTCDATE())
        INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish1_id, news_stamp, stamp)
        VALUES (NEWID(), N'__TEST_NEWS_OLD2__', N'UnitTester', 1, @TestFishId4, '2026-01-02', GETUTCDATE())

        DECLARE @i4 int = 1
        WHILE @i4 <= 10
        BEGIN
            INSERT INTO dbo.news (news_id, news_title, news_author, news_publish, fish1_id, news_stamp, stamp)
            VALUES (NEWID(), N'__TEST_NEWS_BULK_' + CAST(@i4 AS nvarchar(2)) + N'__', N'UnitTester', 1,
                    @TestFishId4, DATEADD(DAY, @i4, '2026-02-01'), GETUTCDATE())
            SET @i4 = @i4 + 1
        END

        DECLARE @Cnt4 int, @CntOld4 int
        SELECT @Cnt4 = (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId4, 1))
                     + (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId4, 0))
        SELECT @CntOld4 = (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId4, 1) WHERE news_title IN (N'__TEST_NEWS_OLD1__', N'__TEST_NEWS_OLD2__'))
                        + (SELECT COUNT(*) FROM dbo.fn_fish_view_news(@TestFishId4, 0) WHERE news_title IN (N'__TEST_NEWS_OLD1__', N'__TEST_NEWS_OLD2__'))

        IF @Cnt4 = 10 AND @CntOld4 = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 4 FAIL [%dms]: capping and ordering not working correctly', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: capped at 10 rows and the 2 oldest fell off'

ROLLBACK TRAN Test4
GO
