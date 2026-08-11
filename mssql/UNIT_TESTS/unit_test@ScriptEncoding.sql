SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for the INTEGRITY OF THE BUILD ITSELF: every scriptNN_*.sql source is UTF-8, so the
  database must be loaded with a UTF-8 code page (sqlcmd -f 65001, see dbcreator.cmd /
  scriptrunlocal.bat). Loaded in the default ANSI code page instead, every non-ASCII byte is
  misread and lands in the object definition corrupted -- N'etang' with an accent becomes
  N'Ã©tang', an em dash becomes â€", and so on.

  This matters because dbo.ProduceWBVariant carries a list of FRENCH water-body words as literals,
  and because dbo.spClear-style comments carry em dashes. The corruption is silent: nothing errors,
  the text is simply wrong in the database.

  Note the workaround already in dbo.water_body's seed data (script08_Data.sql), which spells every
  accented value as nchar(233) / nchar(201) / nchar(251) instead of typing the character -- that is
  this same bug, worked around by hand years ago. TEST 3 pins that data down so the code-page change
  cannot disturb it.

  EVERY literal in THIS file is plain ASCII and accented characters are built with NCHAR(), so the
  tests mean the same thing whichever code page this file is itself read in. Written any other way a
  corrupted expectation would silently match a corrupted definition and the tests would pass while
  the bug was live.

  Uses real catalog views (sys.sql_modules) and the real dbo.water_body table. Read-only.

  TEST 1 - no object definition contains the UTF-8-read-as-ANSI signature
  TEST 2 - the French literals in dbo.ProduceWBVariant decoded correctly
  TEST 3 - the nchar()-escaped water_body seed data is intact (control)
*/
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------------------
-- TEST 1: no programmable object anywhere in the database carries mojibake
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test01NoMojibakeInDefs
    DECLARE @test_name sysname = N'Test01NoMojibakeInDefs [build] : no object definition holds UTF-8-read-as-ANSI text'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @bad int, @sample sysname, @err nvarchar(2048), @msg nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : the markers left behind when UTF-8 bytes are read as CP1252.
--    0xC3 -> NCHAR(195) 'A-tilde'  (leading byte of the accented latin letters)
--    0xC2 -> NCHAR(194) 'A-circumflex'
--    0xCC -> NCHAR(204) 'I-grave'  (leading byte of the combining accents)
--    0xE2 0x80 -> NCHAR(226) + NCHAR(8364)  (leading bytes of the dashes and curly quotes)

DECLARE @c3 nchar(1) = NCHAR(195), @c2 nchar(1) = NCHAR(194), @cc nchar(1) = NCHAR(204);
DECLARE @e280 nchar(2) = NCHAR(226) + NCHAR(8364);

-- 2. execute unit test

SELECT @bad = COUNT(*)
  FROM sys.sql_modules m
  JOIN sys.objects o ON o.object_id = m.object_id
 WHERE o.is_ms_shipped = 0
   AND ( m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @c3   + N'%'
      OR m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @c2   + N'%'
      OR m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @cc   + N'%'
      OR m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @e280 + N'%' );

SELECT TOP 1 @sample = OBJECT_NAME(m.object_id)
  FROM sys.sql_modules m
  JOIN sys.objects o ON o.object_id = m.object_id
 WHERE o.is_ms_shipped = 0
   AND ( m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @c3   + N'%'
      OR m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @c2   + N'%'
      OR m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @cc   + N'%'
      OR m.definition COLLATE Latin1_General_BIN2 LIKE N'%' + @e280 + N'%' )
 ORDER BY OBJECT_NAME(m.object_id);

END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err IS NOT NULL
BEGIN
    SET @msg = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err;
    RAISERROR (@msg, 16, -1)
END
ELSE IF ISNULL(@bad, -1) <> 0
BEGIN
    SET @msg = N'TEST 1 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + CAST(@bad AS varchar)
             + N' object definition(s) were loaded in the wrong code page (e.g. ' + ISNULL(@sample, N'?')
             + N') - sqlcmd needs -f 65001 when reading the UTF-8 scripts';
    RAISERROR (@msg, 16, -1)
END
ELSE
    print 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: no object definition carries UTF-8-read-as-ANSI text'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test01NoMojibakeInDefs
GO
-- ---------------------------------------------------------------------------------------
-- TEST 2: the French water-body words in dbo.ProduceWBVariant survived the load
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test02FrenchLiteralsIntact
    DECLARE @test_name sysname = N'Test02FrenchLiteralsIntact [ProduceWBVariant] : French literals decoded correctly'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @def nvarchar(max), @etang int, @reservoir int, @moji int, @err nvarchar(2048), @msg nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : e-acute is NCHAR(233); the ANSI misreading of it is
--    NCHAR(195) + NCHAR(169)

DECLARE @eacute nchar(1) = NCHAR(233);
DECLARE @mojibake nchar(2) = NCHAR(195) + NCHAR(169);

-- 2. execute unit test

SET @def = OBJECT_DEFINITION(OBJECT_ID('dbo.ProduceWBVariant'));

SELECT @etang     = CHARINDEX(@eacute + N'tang',      @def COLLATE Latin1_General_BIN2)
     , @reservoir = CHARINDEX(N'r' + @eacute + N'servoir', @def COLLATE Latin1_General_BIN2)
     , @moji      = CHARINDEX(@mojibake,               @def COLLATE Latin1_General_BIN2);

END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err IS NOT NULL
BEGIN
    SET @msg = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err;
    RAISERROR (@msg, 16, -1)
END
ELSE IF @def IS NULL
BEGIN
    SET @msg = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: dbo.ProduceWBVariant not found';
    RAISERROR (@msg, 16, -1)
END
ELSE IF ISNULL(@etang, 0) = 0 OR ISNULL(@reservoir, 0) = 0 OR ISNULL(@moji, -1) <> 0
BEGIN
    SET @msg = N'TEST 2 FAIL [' + CAST(@ElapsedMs AS varchar)
             + N'ms]: expected the accented French words intact and no mojibake, got etang@'
             + CAST(ISNULL(@etang, 0) AS varchar) + N' reservoir@' + CAST(ISNULL(@reservoir, 0) AS varchar)
             + N' mojibake@' + CAST(ISNULL(@moji, -1) AS varchar);
    RAISERROR (@msg, 16, -1)
END
ELSE
    print 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: French water-body literals decoded correctly in the definition'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test02FrenchLiteralsIntact
GO
-- ---------------------------------------------------------------------------------------
-- TEST 3: control - the nchar()-escaped seed data is intact and still resolves
-- ---------------------------------------------------------------------------------------
BEGIN TRAN Test03SeedDataIntact
    DECLARE @test_name sysname = N'Test03SeedDataIntact [water_body] : nchar()-escaped seed data unaffected'
DECLARE @tStart datetime2, @ElapsedMs int;
DECLARE @fr sysname, @type int, @moji3 int, @err nvarchar(2048), @msg nvarchar(4000);
BEGIN TRY  SET NOCOUNT ON;
SET @tStart = SYSUTCDATETIME();

-- 1. prepare data for unit test : script08_Data.sql spells Reservoir's French name as
--    N'R' + nchar(233) + N'servoir', which is immune to the code page. It must stay that way,
--    and GetWaterType must still resolve the accented word to the reservoir locType (8192).

DECLARE @reservoirFr sysname = N'R' + NCHAR(233) + N'servoir';

-- 2. execute unit test

SELECT @fr = fr FROM dbo.water_body WHERE en = 'Reservoir';
SET @type = dbo.GetWaterType(@reservoirFr);
SET @moji3 = CHARINDEX(NCHAR(195), @fr COLLATE Latin1_General_BIN2);

END TRY
BEGIN CATCH
    SET @err = ERROR_MESSAGE();
    IF XACT_STATE() = -1 ROLLBACK TRAN;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());

-- 3. result verification

IF @err IS NOT NULL
BEGIN
    SET @msg = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: ' + @err;
    RAISERROR (@msg, 16, -1)
END
ELSE IF @fr IS NULL OR @fr COLLATE Latin1_General_BIN2 <> @reservoirFr COLLATE Latin1_General_BIN2
     OR ISNULL(@moji3, -1) <> 0 OR ISNULL(@type, -1) <> 8192
BEGIN
    SET @msg = N'TEST 3 FAIL [' + CAST(@ElapsedMs AS varchar) + N'ms]: expected the escaped French name intact and locType 8192, got fr='
             + ISNULL(@fr, N'NULL') + N' locType=' + ISNULL(CAST(@type AS varchar), 'NULL')
             + N' mojibake@' + CAST(ISNULL(@moji3, -1) AS varchar);
    RAISERROR (@msg, 16, -1)
END
ELSE
    print 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: nchar()-escaped seed data intact and still resolves to its locType'

IF @@TRANCOUNT > 0 ROLLBACK TRAN Test03SeedDataIntact
GO
