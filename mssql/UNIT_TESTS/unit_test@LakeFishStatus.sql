SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the per-water-body fish "status" flag (lake_fish.status bitmask):
    bit 0 (value  1) = At Risk         -> shown in RED    on the river view + EditLakeFish list
    bit 1 (value  2) = Invasive        -> shown in ORANGE on the river view + EditLakeFish list
    bit 2 (value  4) = Special Concern -> shown in GOLD   on the river view + EditLakeFish list
    bit 3 (value  8) = Threatened      -> shown in PURPLE on the river view + EditLakeFish list
    bit 4 (value 16) = Non-native      -> shown in BLUE   on the river view + EditLakeFish list

  The column has no CHECK constraint (plain tinyint) and neither dbo.fn_lake_fish nor
  dbo.fn_EditLakeFish interpret the value — all bit meaning lives in the C# (StatusFontColor /
  ProduceRVFishChip), so these tests only need to prove each value round-trips unchanged.

  Callers:
    - dbo.spAddFish (FishTracker.Editor.EditLakeFish.btSaveFish_Click) writes @status.
    - dbo.fn_lake_fish (EditLakeFish.LoadPage) exposes status in its XML.
    - dbo.fn_EditLakeFish (Resources.wfRiverViewer.LoadFish) returns status in its table.

  TEST 1 - spAddFish stores the status bitmask on lake_fish
  TEST 2 - fn_lake_fish emits the status attribute in its XML
  TEST 3 - fn_EditLakeFish returns the status column
  TEST 4 - spAddFish stores a Special Concern status (4)
  TEST 5 - fn_lake_fish emits a Threatened status (8) in its XML
  TEST 6 - fn_EditLakeFish returns a Non-native status (16)
*/
PRINT 'Unit tests for lake_fish.status (At Risk / Invasive)';
GO
-- ============================================================================
-- TEST 1: spAddFish stores the status bitmask on lake_fish
-- ============================================================================
BEGIN TRAN LFS_Test1
    declare @test_name sysname = N'LFS_Test1 [spAddFish] : stores status bitmask'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Status1 tinyint;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake1     uniqueidentifier = NEWID();
DECLARE @Family1   uniqueidentifier = NEWID();
DECLARE @Fish1     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake1, 1, N'ut-lake-lfs1');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family1, N'ut-family-lfs1', 900101, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish1, N'Carp-lfs1', N'Cyprinus ut-lfs1', @Family1, SYSUTCDATETIME(), SYSUTCDATETIME());
DECLARE @Sid1 int = (SELECT sid FROM dbo.fish WHERE fish_id = @Fish1);

-- 2. execute unit test : at risk (1) + invasive (2) = 3
EXEC dbo.spAddFish @Lake1, @Sid1, N'http://ut/lfs1', 0, 3, N'';
SELECT @Status1 = status FROM dbo.lake_fish WHERE lake_id = @Lake1 AND fish_id = @Fish1;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Status1 IS NULL OR @Status1 <> 3
   RAISERROR ('TEST 1 FAIL [%dms]: expected lake_fish.status = 3', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spAddFish stored the status bitmask (3)'

ROLLBACK TRAN LFS_Test1
GO
-- ============================================================================
-- TEST 2: fn_lake_fish emits the status attribute in its XML
-- ============================================================================
BEGIN TRAN LFS_Test2
    declare @test_name sysname = N'LFS_Test2 [fn_lake_fish] : emits status attribute'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @XmlStatus int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake2     uniqueidentifier = NEWID();
DECLARE @Family2   uniqueidentifier = NEWID();
DECLARE @Fish2     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake2, 1, N'ut-lake-lfs2');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family2, N'ut-family-lfs2', 900102, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish2, N'Pike-lfs2', N'Esox ut-lfs2', @Family2, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.fish_zoo (fish_id) VALUES (@Fish2);
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, status, sid, lake_fish_id)
VALUES (@Lake2, @Fish2, SYSUTCDATETIME(), N'http://ut/lfs2', 2, 900202, NEWID());

-- 2. execute unit test
DECLARE @Doc2 xml = dbo.fn_lake_fish(@Lake2);
SELECT @XmlStatus = @Doc2.value('(//fish/@status)[1]', 'int');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @XmlStatus IS NULL OR @XmlStatus <> 2
   RAISERROR ('TEST 2 FAIL [%dms]: expected fish/@status = 2 in fn_lake_fish XML', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_fish emitted status=2'

ROLLBACK TRAN LFS_Test2
GO
-- ============================================================================
-- TEST 3: fn_EditLakeFish returns the status column
-- ============================================================================
BEGIN TRAN LFS_Test3
    declare @test_name sysname = N'LFS_Test3 [fn_EditLakeFish] : returns status column'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @EditStatus int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake3     uniqueidentifier = NEWID();
DECLARE @Family3   uniqueidentifier = NEWID();
DECLARE @Fish3     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake3, 1, N'ut-lake-lfs3');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family3, N'ut-family-lfs3', 900103, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish3, N'Bass-lfs3', N'Micropterus ut-lfs3', @Family3, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.fish_zoo (fish_id) VALUES (@Fish3);
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, status, sid, lake_fish_id)
VALUES (@Lake3, @Fish3, SYSUTCDATETIME(), N'http://ut/lfs3', 1, 900203, NEWID());

-- 2. execute unit test
SELECT @EditStatus = status FROM dbo.fn_EditLakeFish(@Lake3) WHERE fish_id = @Fish3;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @EditStatus IS NULL OR @EditStatus <> 1
   RAISERROR ('TEST 3 FAIL [%dms]: expected fn_EditLakeFish status = 1', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_EditLakeFish returned status=1'

ROLLBACK TRAN LFS_Test3
GO
-- ============================================================================
-- TEST 4: spAddFish stores a Special Concern status (4)
-- ============================================================================
BEGIN TRAN LFS_Test4
    declare @test_name sysname = N'LFS_Test4 [spAddFish] : stores Special Concern status (4)'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @Status4 tinyint;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake4     uniqueidentifier = NEWID();
DECLARE @Family4   uniqueidentifier = NEWID();
DECLARE @Fish4     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake4, 1, N'ut-lake-lfs4');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family4, N'ut-family-lfs4', 900104, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish4, N'Trout-lfs4', N'Salmo ut-lfs4', @Family4, SYSUTCDATETIME(), SYSUTCDATETIME());
DECLARE @Sid4 int = (SELECT sid FROM dbo.fish WHERE fish_id = @Fish4);

-- 2. execute unit test : Special Concern = 4
EXEC dbo.spAddFish @Lake4, @Sid4, N'http://ut/lfs4', 0, 4, N'';
SELECT @Status4 = status FROM dbo.lake_fish WHERE lake_id = @Lake4 AND fish_id = @Fish4;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @Status4 IS NULL OR @Status4 <> 4
   RAISERROR ('TEST 4 FAIL [%dms]: expected lake_fish.status = 4', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: spAddFish stored the Special Concern status (4)'

ROLLBACK TRAN LFS_Test4
GO
-- ============================================================================
-- TEST 5: fn_lake_fish emits a Threatened status (8) in its XML
-- ============================================================================
BEGIN TRAN LFS_Test5
    declare @test_name sysname = N'LFS_Test5 [fn_lake_fish] : emits Threatened status (8)'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @XmlStatus5 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake5     uniqueidentifier = NEWID();
DECLARE @Family5   uniqueidentifier = NEWID();
DECLARE @Fish5     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake5, 1, N'ut-lake-lfs5');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family5, N'ut-family-lfs5', 900105, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish5, N'Sturgeon-lfs5', N'Acipenser ut-lfs5', @Family5, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.fish_zoo (fish_id) VALUES (@Fish5);
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, status, sid, lake_fish_id)
VALUES (@Lake5, @Fish5, SYSUTCDATETIME(), N'http://ut/lfs5', 8, 900205, NEWID());

-- 2. execute unit test
DECLARE @Doc5 xml = dbo.fn_lake_fish(@Lake5);
SELECT @XmlStatus5 = @Doc5.value('(//fish/@status)[1]', 'int');

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @XmlStatus5 IS NULL OR @XmlStatus5 <> 8
   RAISERROR ('TEST 5 FAIL [%dms]: expected fish/@status = 8 in fn_lake_fish XML', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_lake_fish emitted status=8'

ROLLBACK TRAN LFS_Test5
GO
-- ============================================================================
-- TEST 6: fn_EditLakeFish returns a Non-native status (16)
-- ============================================================================
BEGIN TRAN LFS_Test6
    declare @test_name sysname = N'LFS_Test6 [fn_EditLakeFish] : returns Non-native status (16)'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @EditStatus6 int;
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test
DECLARE @Lake6     uniqueidentifier = NEWID();
DECLARE @Family6   uniqueidentifier = NEWID();
DECLARE @Fish6     uniqueidentifier = NEWID();
INSERT INTO dbo.Lake (Lake_id, locType, lake_name) VALUES (@Lake6, 1, N'ut-lake-lfs6');
INSERT INTO dbo.fish_family (Family_id, Family_name, fid, created) VALUES (@Family6, N'ut-family-lfs6', 900106, SYSUTCDATETIME());
INSERT INTO dbo.fish (fish_id, fish_name, fish_latin, family_Id, created, stamp)
VALUES (@Fish6, N'Goby-lfs6', N'Neogobius ut-lfs6', @Family6, SYSUTCDATETIME(), SYSUTCDATETIME());
INSERT INTO dbo.fish_zoo (fish_id) VALUES (@Fish6);
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, created, link, status, sid, lake_fish_id)
VALUES (@Lake6, @Fish6, SYSUTCDATETIME(), N'http://ut/lfs6', 16, 900206, NEWID());

-- 2. execute unit test
SELECT @EditStatus6 = status FROM dbo.fn_EditLakeFish(@Lake6) WHERE fish_id = @Fish6;

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , @test_name     AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification
IF @EditStatus6 IS NULL OR @EditStatus6 <> 16
   RAISERROR ('TEST 6 FAIL [%dms]: expected fn_EditLakeFish status = 16', 16, -1, @ElapsedMs)
ELSE
    print 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fn_EditLakeFish returned status=16'

ROLLBACK TRAN LFS_Test6
GO
