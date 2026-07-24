SET QUOTED_IDENTIFIER ON
GO
--
-- Unit tests for dbo.fn_fish_image_gallery
-- (Editor/FishGeneral.aspx.cs -- FishTracker.Editor.FishGeneral.BuildFishGallery:
--  lists every image of a fish -- id + gender/juvenile -- for the editor picture gallery).
-- Each test is isolated in its own named transaction and rolled back.
-- Uses real tables: dbo.fish, dbo.fish_family, dbo.fish_image.
--

PRINT 'Unit tests for fn_fish_image_gallery'
GO

-- TEST 1: returns all images of a fish with gender/juvenile flags
BEGIN TRAN Test1
    DECLARE @test_name sysname = N'Test1 [fn_fish_image_gallery] : returns all images with gender/juvenile'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @FamId1 uniqueidentifier = NEWID()
        DECLARE @FishId1 uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@FamId1, N'__TEST_FAM_GAL_T1__', -981, GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@FishId1, N'__TEST_FISH_GAL_T1__', N'Testus galleria', @FamId1, GETUTCDATE(), GETUTCDATE())

        -- two images: one adult male (gender=1, juvenile=0), one juvenile female (gender=0, juvenile=1)
        INSERT INTO dbo.fish_image (fish_id, fish_image_gender, fish_image_juvenile, fish_image_pic,
                                    fish_image_source, fish_image_author, fish_image_link, fish_image_hash, fish_image_stamp)
        VALUES (@FishId1, 1, 0, 0xAA01, N's', N'a', N'l', HASHBYTES('SHA1', 0xAA01), GETUTCDATE())
        INSERT INTO dbo.fish_image (fish_id, fish_image_gender, fish_image_juvenile, fish_image_pic,
                                    fish_image_source, fish_image_author, fish_image_link, fish_image_hash, fish_image_stamp)
        VALUES (@FishId1, 0, 1, 0xAA02, N's', N'a', N'l', HASHBYTES('SHA1', 0xAA02), GETUTCDATE())

        DECLARE @cnt1 int = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishId1))
        DECLARE @male int   = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishId1) WHERE fish_image_gender = 1 AND fish_image_juvenile = 0)
        DECLARE @juv int    = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishId1) WHERE fish_image_gender = 0 AND fish_image_juvenile = 1)

        IF @cnt1 = 2 AND @male = 1 AND @juv = 1
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 1 FAIL [%dms]: gallery did not return both images with correct flags', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: returned both images with correct gender/juvenile flags'

ROLLBACK TRAN Test1
GO

-- TEST 2: a fish with no images returns zero rows
BEGIN TRAN Test2
    DECLARE @test_name sysname = N'Test2 [fn_fish_image_gallery] : fish with no images returns empty'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @FamId2 uniqueidentifier = NEWID()
        DECLARE @FishId2 uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@FamId2, N'__TEST_FAM_GAL_T2__', -982, GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@FishId2, N'__TEST_FISH_GAL_T2__', N'Testus vacuus', @FamId2, GETUTCDATE(), GETUTCDATE())

        DECLARE @cnt2 int = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishId2))

        IF @cnt2 = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 2 FAIL [%dms]: fish with no images did not return empty', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fish with no images returned zero rows'

ROLLBACK TRAN Test2
GO

-- TEST 3: only the requested fish's images are returned (isolation from other fish)
BEGIN TRAN Test3
    DECLARE @test_name sysname = N'Test3 [fn_fish_image_gallery] : returns only the requested fish images'
    DECLARE @tStart datetime2, @ElapsedMs int
    DECLARE @result bit = 0
    BEGIN TRY SET NOCOUNT ON
        SET @tStart = SYSUTCDATETIME()

        DECLARE @FamId3 uniqueidentifier = NEWID()
        DECLARE @FishA uniqueidentifier = NEWID()
        DECLARE @FishB uniqueidentifier = NEWID()

        INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created)
        VALUES (@FamId3, N'__TEST_FAM_GAL_T3__', -983, GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@FishA, N'__TEST_FISH_GAL_T3A__', N'Testus alfa', @FamId3, GETUTCDATE(), GETUTCDATE())
        INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
        VALUES (@FishB, N'__TEST_FISH_GAL_T3B__', N'Testus beta', @FamId3, GETUTCDATE(), GETUTCDATE())

        -- 2 images for A, 1 for B
        INSERT INTO dbo.fish_image (fish_id, fish_image_gender, fish_image_juvenile, fish_image_pic,
                                    fish_image_source, fish_image_author, fish_image_link, fish_image_hash, fish_image_stamp)
        VALUES (@FishA, 1, 0, 0xBB01, N's', N'a', N'l', HASHBYTES('SHA1', 0xBB01), GETUTCDATE())
        INSERT INTO dbo.fish_image (fish_id, fish_image_gender, fish_image_juvenile, fish_image_pic,
                                    fish_image_source, fish_image_author, fish_image_link, fish_image_hash, fish_image_stamp)
        VALUES (@FishA, 0, 0, 0xBB02, N's', N'a', N'l', HASHBYTES('SHA1', 0xBB02), GETUTCDATE())
        INSERT INTO dbo.fish_image (fish_id, fish_image_gender, fish_image_juvenile, fish_image_pic,
                                    fish_image_source, fish_image_author, fish_image_link, fish_image_hash, fish_image_stamp)
        VALUES (@FishB, 1, 1, 0xBB03, N's', N'a', N'l', HASHBYTES('SHA1', 0xBB03), GETUTCDATE())

        DECLARE @cntA int = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishA))
        DECLARE @cntB int = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishB))
        -- ensure no B image leaks into A's result
        DECLARE @leak int = (SELECT COUNT(*) FROM dbo.fn_fish_image_gallery(@FishA)
                             WHERE fish_image_id IN (SELECT fish_image_id FROM dbo.fish_image WHERE fish_id = @FishB))

        IF @cntA = 2 AND @cntB = 1 AND @leak = 0
            SET @result = 1

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE() AS ErrorState
             , @test_name AS ErrorProcedure, ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage
    END CATCH
    SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME())

    IF @result = 0
        RAISERROR ('TEST 3 FAIL [%dms]: gallery leaked another fish''s images or wrong counts', 16, -1, @ElapsedMs)
    ELSE
        PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: returned only the requested fish images (no leak)'

ROLLBACK TRAN Test3
GO
