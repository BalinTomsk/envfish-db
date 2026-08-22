/*
  Unit tests for the per-tab JSON UPDATE procedures dbo.sp_update_lake_<tab> (write-back counterpart
  of the fn_lake_<tab>_json exports). Each test asserts the core contract: a key present in the JSON
  updates its column; a column whose key is ABSENT is left unchanged (partial update).

  Real tables only; each test is its own named transaction, rolled back in its own GO batch.
  SET QUOTED_IDENTIFIER ON: dbo.lake / dbo.regulations carry filtered indexes.
*/
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO
-- ---------------------------------------------------------------------------- TEST 1: description partial update
BEGIN TRAN TestLakeUpd1
    DECLARE @tn sysname = N'TestLakeUpd1 [sp_update_lake_description]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, depth) VALUES (@L, 1, N'Before', 5);
EXEC dbo.sp_update_lake_description @L, N'{"lakeName":"After","noFish":true}';
DECLARE @nm nvarchar(64), @dp int, @nf bit;
SELECT @nm = lake_name, @dp = depth, @nf = noFish FROM dbo.lake WHERE lake_id = @L;
IF @nm = N'After' AND @dp = 5 AND @nf = 1 SET @ok = 1;   -- name+noFish changed, depth (absent) unchanged
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 1 PASS [' + CAST(@ms AS varchar) + 'ms]: description updates present keys, leaves absent ones';
ELSE BEGIN DECLARE @dbg1 varchar(400) = 'name=['+ISNULL(@nm,'<null>')+'] depth=['+ISNULL(CAST(@dp AS varchar(20)),'<null>')+'] noFish=['+ISNULL(CAST(@nf AS varchar(5)),'<null>')+']'; RAISERROR('TEST 1 FAIL [%dms]: %s', 16, -1, @ms, @dbg1); END
ROLLBACK TRAN TestLakeUpd1
GO
-- ---------------------------------------------------------------------------- TEST 2: view partial update
BEGIN TRAN TestLakeUpd2
    DECLARE @tn sysname = N'TestLakeUpd2 [sp_update_lake_view]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name, descript) VALUES (@L, 1, N'Keep', N'old');
EXEC dbo.sp_update_lake_view @L, N'{"description":"new"}';
DECLARE @nm nvarchar(64), @ds nvarchar(max);
SELECT @nm = lake_name, @ds = descript FROM dbo.lake WHERE lake_id = @L;
IF @nm = N'Keep' AND @ds = N'new' SET @ok = 1;
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 2 PASS [' + CAST(@ms AS varchar) + 'ms]: view updates descript, leaves name';
ELSE RAISERROR('TEST 2 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd2
GO
-- ---------------------------------------------------------------------------- TEST 3: stats upsert + partial
BEGIN TRAN TestLakeUpd3
    DECLARE @tn sysname = N'TestLakeUpd3 [sp_update_lake_stats]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'S');
EXEC dbo.sp_update_lake_stats @L, 6, N'{"waterDegree":20,"coldCool":true}';   -- upsert (no row yet)
EXEC dbo.sp_update_lake_stats @L, 6, N'{"ph":7.5}';                            -- partial (waterDegree kept)
DECLARE @wd float, @ph float, @cc bit;
SELECT @wd = water_degree, @ph = PH, @cc = cold_cool FROM dbo.Lake_State WHERE Lake_id = @L AND [month] = 6;
IF @wd = 20 AND @ph = 7.5 AND @cc = 1 SET @ok = 1;
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 3 PASS [' + CAST(@ms AS varchar) + 'ms]: stats upserts the month then partially updates it';
ELSE BEGIN DECLARE @dbg3 varchar(400) = 'wd=['+ISNULL(CAST(@wd AS varchar(30)),'<null>')+'] ph=['+ISNULL(CAST(@ph AS varchar(30)),'<null>')+'] cc=['+ISNULL(CAST(@cc AS varchar(5)),'<null>')+']'; RAISERROR('TEST 3 FAIL [%dms]: %s', 16, -1, @ms, @dbg3); END
ROLLBACK TRAN TestLakeUpd3
GO
-- ---------------------------------------------------------------------------- TEST 4: maps partial update
BEGIN TRAN TestLakeUpd4
    DECLARE @tn sysname = N'TestLakeUpd4 [sp_update_lake_maps]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'M');
DECLARE @pic varbinary(max) = 0x255044462D;
INSERT INTO dbo.lake_map (lake_map_ownerid, lake_map_pic, lake_map_source, lake_map_author, lake_map_link, lake_map_label, lake_map_hash, lake_map_stamp)
    VALUES (@L, @pic, N'src', N'auth', N'', N'old.pdf', HASHBYTES('MD5', @pic), '2026-01-01');
DECLARE @mid int = SCOPE_IDENTITY();
EXEC dbo.sp_update_lake_maps @mid, N'{"label":"new.pdf"}';
DECLARE @lbl nvarchar(256), @src nvarchar(255);
SELECT @lbl = lake_map_label, @src = lake_map_source FROM dbo.lake_map WHERE lake_map_id = @mid;
IF @lbl = N'new.pdf' AND @src = N'src' SET @ok = 1;   -- label changed, source unchanged, pic untouched
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 4 PASS [' + CAST(@ms AS varchar) + 'ms]: maps updates label, leaves source';
ELSE RAISERROR('TEST 4 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd4
GO
-- ---------------------------------------------------------------------------- TEST 5: source (side 16)
BEGIN TRAN TestLakeUpd5
    DECLARE @tn sysname = N'TestLakeUpd5 [sp_update_lake_source]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'Src');   -- TR_Lake_INS makes side 16/32
EXEC dbo.sp_update_lake_source @L, N'{"lat":45.5,"city":"Kitchener"}';
DECLARE @lat float, @city nvarchar(64);
SELECT @lat = lat, @city = city FROM dbo.Tributaries WHERE Main_Lake_id = @L AND side = 16;
IF @lat = 45.5 AND @city = N'Kitchener' SET @ok = 1;
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 5 PASS [' + CAST(@ms AS varchar) + 'ms]: source updates the side-16 row';
ELSE RAISERROR('TEST 5 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd5
GO
-- ---------------------------------------------------------------------------- TEST 6: mouth (side 32)
BEGIN TRAN TestLakeUpd6
    DECLARE @tn sysname = N'TestLakeUpd6 [sp_update_lake_mouth]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'Mth');
EXEC dbo.sp_update_lake_mouth @L, N'{"elevation":250}';
DECLARE @el int;
SELECT @el = elevation FROM dbo.Tributaries WHERE Main_Lake_id = @L AND side = 32;
IF @el = 250 SET @ok = 1;
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 6 PASS [' + CAST(@ms AS varchar) + 'ms]: mouth updates the side-32 row';
ELSE RAISERROR('TEST 6 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd6
GO
-- ---------------------------------------------------------------------------- TEST 7: tributary by id
BEGIN TRAN TestLakeUpd7
    DECLARE @tn sysname = N'TestLakeUpd7 [sp_update_lake_tributary]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID(), @P uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'T');
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@P, 2, N'TP');   -- FK target
INSERT INTO dbo.Tributaries (Main_Lake_id, Lake_id, side, Tributaries_stamp) VALUES (@L, @P, 4, '2026-01-01');
DECLARE @tid int = SCOPE_IDENTITY();
EXEC dbo.sp_update_lake_tributary @tid, N'{"coast":"L","city":"Guelph"}';
DECLARE @co varchar(1), @ci nvarchar(64), @sd int;
SELECT @co = coast, @ci = city, @sd = side FROM dbo.Tributaries WHERE id = @tid;
IF @co = 'L' AND @ci = N'Guelph' AND @sd = 4 SET @ok = 1;   -- side (absent) unchanged
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 7 PASS [' + CAST(@ms AS varchar) + 'ms]: tributary updates by id, keeps side';
ELSE RAISERROR('TEST 7 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd7
GO
-- ---------------------------------------------------------------------------- TEST 8: fishing by (lake,fish)
BEGIN TRAN TestLakeUpd8
    DECLARE @tn sysname = N'TestLakeUpd8 [sp_update_lake_fishing]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID(), @F uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'F');
INSERT INTO dbo.lake_fish (lake_Id, fish_Id, note, stamp) VALUES (@L, @F, N'old', '2026-01-01');
EXEC dbo.sp_update_lake_fishing @L, @F, N'{"note":"new","status":2}';
DECLARE @no nvarchar(1024), @st tinyint;
SELECT @no = note, @st = status FROM dbo.lake_fish WHERE lake_id = @L AND fish_id = @F;
IF @no = N'new' AND @st = 2 SET @ok = 1;
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 8 PASS [' + CAST(@ms AS varchar) + 'ms]: fishing updates note + status';
ELSE RAISERROR('TEST 8 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd8
GO
-- ---------------------------------------------------------------------------- TEST 9: regulation by id
BEGIN TRAN TestLakeUpd9
    DECLARE @tn sysname = N'TestLakeUpd9 [sp_update_lake_regulation]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID(), @R uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'R');
INSERT INTO dbo.regulations (regulations_id, regulations_part, resident_type, state, Lake_id, reg_year, regulations_sport)
    VALUES (@R, N'', 0, 'ON', @L, 2026, 4);
EXEC dbo.sp_update_lake_regulation @R, N'{"sport":9,"minLengthCm":45.5}';
DECLARE @sp int, @ml decimal(5,1), @yr smallint;
SELECT @sp = regulations_sport, @ml = min_length_cm, @yr = reg_year FROM dbo.regulations WHERE regulations_id = @R;
IF @sp = 9 AND @ml = 45.5 AND @yr = 2026 SET @ok = 1;   -- year (absent) unchanged
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 9 PASS [' + CAST(@ms AS varchar) + 'ms]: regulation updates sport + minLengthCm, keeps year';
ELSE RAISERROR('TEST 9 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd9
GO
-- ---------------------------------------------------------------------------- TEST 10: weather (today forecast row)
BEGIN TRAN TestLakeUpd10
    DECLARE @tn sysname = N'TestLakeUpd10 [sp_update_lake_weather]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @stId uniqueidentifier = NEWID(); DECLARE @sid int = ABS(CHECKSUM(NEWID())) % 1000000 + 1;
INSERT INTO dbo.WaterStation (MLI, id, lat, lon, country, locDesc, locType, locName, county, sid, lakeName, stamp, supported, backoffstate, backoff_daily_503_count, backoff_weekly_503_count)
    VALUES (N'UT-WS', @stId, 45.0, -79.0, 'CA', 'd', 2, 'n', N'c', @sid, N'ln', SYSUTCDATETIME(), 1, 0, 0, 0);
INSERT INTO dbo.weather_Forecast (link, mli, dt, tmHigh, tmLow, gpfDay, gpfNight, humidity, shortText)
    VALUES (@stId, N'UT-WS', CAST(GETDATE() AS date), 20, 10, 0, 0, 40, 'Clear');
EXEC dbo.sp_update_lake_weather @sid, N'{"humidity":55,"conditions":"Cloudy"}';
DECLARE @hu float, @sh varchar(64), @th float;
SELECT @hu = humidity, @sh = shortText, @th = tmHigh FROM dbo.weather_Forecast WHERE link = @stId AND dt = CAST(GETDATE() AS date);
IF @hu = 55 AND @sh = 'Cloudy' AND @th = 20 SET @ok = 1;   -- tmHigh (absent) unchanged
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 10 PASS [' + CAST(@ms AS varchar) + 'ms]: weather updates today forecast, keeps tmHigh';
ELSE BEGIN DECLARE @dbg10 varchar(400) = 'hu=['+ISNULL(CAST(@hu AS varchar(30)),'<null>')+'] sh=['+ISNULL(@sh,'<null>')+'] th=['+ISNULL(CAST(@th AS varchar(30)),'<null>')+']'; RAISERROR('TEST 10 FAIL [%dms]: %s', 16, -1, @ms, @dbg10); END
ROLLBACK TRAN TestLakeUpd10
GO
-- ---------------------------------------------------------------------------- TEST 11: fishing view (lake rule fields)
BEGIN TRAN TestLakeUpd11
    DECLARE @tn sysname = N'TestLakeUpd11 [sp_update_lake_fishing_view]';
DECLARE @tStart datetime2, @ms int, @ok int = 0;
BEGIN TRY SET NOCOUNT ON; SET @tStart = SYSUTCDATETIME();
DECLARE @L uniqueidentifier = NEWID();
INSERT INTO dbo.lake (lake_id, locType, lake_name) VALUES (@L, 1, N'FV');
EXEC dbo.sp_update_lake_fishing_view @L, N'{"regulations":"No live bait","linkReg":"http://x"}';
DECLARE @rg nvarchar(255), @lr nvarchar(255);
SELECT @rg = regulations, @lr = link_reg FROM dbo.lake WHERE lake_id = @L;
IF @rg = N'No live bait' AND @lr = N'http://x' SET @ok = 1;
END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @tn AS p, ERROR_LINE() AS ln, ERROR_MESSAGE() AS m; END CATCH
SET @ms = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 11 PASS [' + CAST(@ms AS varchar) + 'ms]: fishing-view updates lake regulations + link_reg';
ELSE RAISERROR('TEST 11 FAIL [%dms]', 16, -1, @ms);
ROLLBACK TRAN TestLakeUpd11
GO
