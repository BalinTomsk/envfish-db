-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_NewGuidV7' AND type = 'P')
    DROP PROCEDURE dbo.sp_NewGuidV7
GO
-- sp_NewGuidV7 : RFC 9562 UUID version 7 -- a 48-bit big-endian Unix-epoch-millisecond timestamp
-- followed by random bits (version/variant nibbles set per spec). See the "Important" section in
-- database/CLAUDE.md: this database replicates peer-to-peer across several nodes, so a new row's
-- primary key must be safely generatable independently on any node. NEWSEQUENTIALID()'s
-- "sequential" property is per-machine only -- it does NOT interleave in timestamp order once rows
-- from different nodes are merged -- and NEWID() is fully random with no chronological locality at
-- all. A v7 GUID generated on any node sorts roughly by wall-clock time once merged (node clocks
-- are assumed reasonably synced), which is why it's the default choice for new primary keys in
-- this schema. Usage: DECLARE @id UNIQUEIDENTIFIER; EXEC dbo.sp_NewGuidV7 @id OUTPUT;
--
-- This is a stored procedure, not a function: NEWID() and CRYPT_GEN_RANDOM() are both rejected
-- inside ANY kind of user-defined function body -- scalar, inline, or multi-statement -- with
-- "Invalid use of a side-effecting operator". That restriction does not apply to stored procedures.
CREATE PROCEDURE dbo.sp_NewGuidV7
    @new_id UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @unixMs BIGINT   = DATEDIFF_BIG(MILLISECOND, '1970-01-01', SYSUTCDATETIME());
    DECLARE @tsHex  CHAR(12) = RIGHT(CONVERT(VARCHAR(16), CAST(@unixMs AS VARBINARY(8)), 2), 12);

    DECLARE @r    BINARY(16) = CAST(NEWID() AS BINARY(16));
    DECLARE @rHex CHAR(32)   = CONVERT(VARCHAR(32), @r, 2);

    -- time_hi_and_version (4 hex): version nibble '7' + 12 random bits
    DECLARE @verGroup CHAR(4) = '7' + SUBSTRING(@rHex, 3, 3);

    -- clock_seq_hi_and_reserved + clock_seq_low (4 hex): variant '10xx' (2 fixed + 2 random bits
    -- packed into one nibble via mod 4) + 12 more random bits
    DECLARE @variantNibble CHAR(1) = SUBSTRING('89AB', (CAST(SUBSTRING(@r, 1, 1) AS INT) % 4) + 1, 1);
    DECLARE @clockSeqGroup CHAR(4) = @variantNibble + SUBSTRING(@rHex, 6, 3);

    -- node (12 hex): remaining 48 random bits
    DECLARE @nodeGroup CHAR(12) = SUBSTRING(@rHex, 9, 12);

    SET @new_id = CAST(
        SUBSTRING(@tsHex, 1, 8) + '-' + SUBSTRING(@tsHex, 9, 4) + '-' +
        @verGroup + '-' + @clockSeqGroup + '-' + @nodeGroup
        AS UNIQUEIDENTIFIER);
END
GO
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spSaveUser' AND type = 'P')
    DROP PROCEDURE dbo.spSaveUser
GO
/*
    Register new User Account
*/
create PROCEDURE dbo.spSaveUser @ipaddr varchar(32), @agent varchar(128)
    , @addr varchar(32), @host varchar(255), @user varchar(255), @email varchar(255), @country char(2)
    , @postal varchar(16), @fname nvarchar(64), @lname nvarchar(64), @psw varchar(128)
AS
SET NOCOUNT ON
BEGIN TRY  
    INSERT INTO Users (userName, email, ipaddr, agent, addr, host, country, postal, firstName, lastName, psw, question, answer) 
        VALUES (@user, @email, @ipaddr, @agent, @addr, @host, @country, @postal, @fname, @lname, HashBytes('MD5', @psw + '*solt'), 'dog', 0x0024);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO

/*
DECLARE @userId uniqueidentifier

EXEC dbo.spAddUser 'guest',   'password',   'Mr.', 'John', 'Doe', 'tn@mail.ru',            'N2M5L3', 1, 'kon',  'palto', 15198045308, @userId OUT
EXEC dbo.spAddUser 'BassPro', 'Toronto123', 'Mr.', 'John', 'Doe', 'LBarmalgeen@gmail.com', 'N2M5L5', 1, 'Bass', 'Pro',   15198045308, @userId OUT
UPDATE Users SET access = 3 WHERE id= @userId    -- 3- reseller, 255 - superadmin, 1 - normal user, 2 - typewriter
SELECT @userId
GO
*/
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spTestUser' AND type = 'P')
    DROP PROCEDURE dbo.spTestUser
GO

CREATE PROCEDURE spTestUser @userName  varchar(64), @psw varchar(128), @userId uniqueidentifier OUT
AS
SET NOCOUNT ON
BEGIN TRY
  SELECT @userId = ID FROM Users WHERE HashBytes('MD5', @psw + '*solt')= psw AND RTRIM(@userName) = userName
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spOAuthLoginOrCreateUser' AND type = 'P')
    DROP PROCEDURE dbo.spOAuthLoginOrCreateUser
GO

CREATE PROCEDURE dbo.spOAuthLoginOrCreateUser
      @provider        NVARCHAR(100)
    , @providerUserId  NVARCHAR(256)
    , @email           NVARCHAR(255)
    , @givenName       NVARCHAR(64) = NULL
    , @familyName      NVARCHAR(64) = NULL
    , @ipaddr          VARCHAR(32) = NULL
    , @agent           VARCHAR(128) = NULL
    , @addr            VARCHAR(32) = NULL
    , @host            VARCHAR(255) = NULL
    , @country         CHAR(2) = NULL
    , @postal          VARCHAR(16) = NULL
    , @userId          UNIQUEIDENTIFIER OUTPUT
    , @userName        NVARCHAR(256) OUTPUT
    , @isNewUser       BIT OUTPUT
AS
SET NOCOUNT ON

-- Ban enforcement. Done BEFORE the TRY block on purpose: a RAISERROR here propagates to the
-- caller (the inline OAuth/magic-link callbacks) as a real error, which they surface to the user
-- as the sign-in failure message. Inside the TRY it would be swallowed by the CATCH below.
DECLARE @banMsg VARCHAR(200) =
    'Your Fish Find account has been suspended. If you believe this is a mistake, contact support.';
DECLARE @banEmail VARCHAR(128) = LEFT(NULLIF(LTRIM(RTRIM(@email)), N''), 128);

-- (a) the email being signed in with is banned
IF @banEmail IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.BannedUser b WHERE b.email = @banEmail)
BEGIN
    RAISERROR(@banMsg, 16, 1);
    RETURN;
END

-- (b) a returning account (this provider+sub) whose stored email or phone is banned
IF EXISTS (
    SELECT 1
    FROM dbo.UserExternalLogin l
    INNER JOIN dbo.Users u ON u.id = l.userId
    INNER JOIN dbo.BannedUser b
        ON b.email = u.email OR (b.cell IS NOT NULL AND b.cell = u.cell)
    WHERE l.provider = NULLIF(LTRIM(RTRIM(@provider)), N'')
      AND l.providerUserId = NULLIF(LTRIM(RTRIM(@providerUserId)), N'')
      AND u.deleted = 0
)
BEGIN
    RAISERROR(@banMsg, 16, 1);
    RETURN;
END

BEGIN TRY
    SET @userId = NULL;
    SET @userName = NULL;
    SET @isNewUser = 0;

    SET @email          = NULLIF(LTRIM(RTRIM(@email)), N'');
    SET @provider       = NULLIF(LTRIM(RTRIM(@provider)), N'');
    SET @providerUserId = NULLIF(LTRIM(RTRIM(@providerUserId)), N'');

    -- Default the provider to Google when the caller omits it.
    IF @provider IS NULL SET @provider = N'Google';

    -- Every Users row needs a unique email. Providers that do not expose one (e.g. the
    -- Twitter/X OAuth2 API has no email scope) must pass a synthetic address from the
    -- caller (twitter_<id>@users.fishfind.info), so @email is still required here.
    IF @email IS NULL
    BEGIN
        RAISERROR('OAuth login requires an email claim.', 16, 1);
        RETURN;
    END

    IF @providerUserId IS NULL
    BEGIN
        RAISERROR('OAuth login requires a provider user id (sub).', 16, 1);
        RETURN;
    END

    DECLARE @displayName NVARCHAR(256) =
        NULLIF(LTRIM(RTRIM(ISNULL(@givenName, N'') + N' ' + ISNULL(@familyName, N''))), N'');

    --------------------------------------------------------------------------------
    -- 1) Known external login -> return its user, refresh the login row.
    --------------------------------------------------------------------------------
    SELECT TOP 1
          @userId   = u.id
        , @userName = u.userName
    FROM dbo.UserExternalLogin l
    INNER JOIN dbo.Users u ON u.id = l.userId
    WHERE l.provider = @provider
      AND l.providerUserId = @providerUserId
      AND u.deleted = 0;          -- a soft-deleted account is not reused; fall through to create a new one

    IF @userId IS NOT NULL
    BEGIN
        UPDATE dbo.UserExternalLogin
           SET lastLoginUtc = SYSUTCDATETIME()
             , email        = LEFT(@email, 128)
             , displayName  = @displayName
         WHERE provider = @provider
           AND providerUserId = @providerUserId;

        -- Self-heal: early Google logins stored the email as userName. If this user's
        -- userName is still exactly their email (i.e. never customized) and the provider
        -- now gives a real name, upgrade the userName to the display name on this login.
        IF DATALENGTH(@displayName) >= 3 AND @userName = @email
        BEGIN
            UPDATE dbo.Users
               SET userName = LEFT(@displayName, 64)
             WHERE id = @userId AND userName = @email;

            SET @userName = LEFT(@displayName, 64);
        END

        SET @isNewUser = 0;
        RETURN;
    END

    --------------------------------------------------------------------------------
    -- 2) No external login yet: link to an existing user with the same email,
    --    otherwise create a brand-new user.
    --------------------------------------------------------------------------------
    SELECT TOP 1
          @userId   = id
        , @userName = userName
    FROM dbo.Users
    WHERE email = @email
      AND deleted = 0;            -- ignore a soft-deleted row with this email; a new profile is created

    IF @userId IS NULL
    BEGIN
        SET @userId = NEWID();

        -- Show the provider's real display name (first + last, or @handle for X) as the
        -- userName for every provider. Fall back to the email only when the provider gave
        -- no usable name.
        IF DATALENGTH(@displayName) >= 3
            SET @userName = LEFT(@displayName, 64);
        ELSE
            SET @userName = @email;

        INSERT INTO dbo.Users
        (
              ID
            , userName
            , email
            , ipaddr
            , agent
            , addr
            , host
            , country
            , postal
            , firstName
            , lastName
            , psw
            , question
            , answer
            , authType
        )
        VALUES
        (
              @userId
            , @userName
            , @email
            , ISNULL(@ipaddr, '')
            , ISNULL(@agent, '')
            , ISNULL(@addr, '')
            , ISNULL(@host, '')
            , ISNULL(@country, 'CA')
            , ISNULL(@postal, '')
            , ISNULL(@givenName, '')
            , ISNULL(@familyName, '')
            , HASHBYTES('MD5', CONVERT(VARCHAR(36), NEWID()) + '*oauth')
            , 'oauth'
            , 0x0024
            , 'OAuth'
        );

        SET @isNewUser = 1;
    END

    -- Link the external login to the (new or existing) user.
    INSERT INTO dbo.UserExternalLogin
        ( userId, provider, providerUserId, email, displayName, lastLoginUtc )
    VALUES
        ( @userId, @provider, @providerUserId, LEFT(@email, 128), @displayName, SYSUTCDATETIME() );
END TRY
BEGIN CATCH
    SELECT
          ERROR_NUMBER()    AS ErrorNumber
        , ERROR_SEVERITY()  AS ErrorSeverity
        , ERROR_STATE()     AS ErrorState
        , ERROR_PROCEDURE() AS ErrorProcedure
        , ERROR_LINE()      AS ErrorLine
        , ERROR_MESSAGE()   AS ErrorMessage;
END CATCH
GO 
-------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spSaveSession' AND type = 'P')
    DROP PROCEDURE dbo.spSaveSession
GO

CREATE PROCEDURE dbo.spSaveSession @ipaddr varchar(32), @agent varchar(128)
    , @host varchar(32), @page varchar(MAX), @cookie varchar(64), @sessionId uniqueidentifier OUT
AS
SET NOCOUNT ON
BEGIN TRY
    IF @page LIKE '%PushStation.aspx'
        RETURN
  SET @sessionId = NULL
  DECLARE @tmp TABLE( id uniqueidentifier )
  IF @page NOT IN ('/Default.aspx', '/Resources/wfRiverViewer.aspx')
	  INSERT INTO SessionHandler(  ip4,  userAgent,  host,  startPage ) 
		OUTPUT INSERTED.ID INTO @tmp( id ) VALUES ( @ipaddr, @agent, @host, @page )
  IF EXISTS (SELECT * FROM @tmp ) 
    SELECT TOP 1 @sessionId = id FROM @tmp
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO

-------------------------------------- -------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spSaveWeatherState' AND type = 'P')
    DROP PROCEDURE dbo.spSaveWeatherState
GO

CREATE PROCEDURE spSaveWeatherState @condition varchar(255), @placeId int, @mli varchar(64) OUT
WITH EXEC AS CALLER
AS
BEGIN TRY
SET NOCOUNT ON
  SELECT @mli = mli FROM WaterStation WHERE  sid = @placeId
  UPDATE WaterStation SET condition=@condition, wheatherStamp = GETUTCDATE() WHERE sid = @placeId
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO

--------------------------------  direct push--------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spUpdateCurrentWaterState' AND type = 'P')
    DROP PROCEDURE dbo.spUpdateCurrentWaterState
GO

-- EXEC spPushSpeciesFromLakeToStation
CREATE PROCEDURE spUpdateCurrentWaterState @mli varchar(64), @stamp datetime, @elevation float, @sid bigint 
   , @temperature float, @conductance float, @ph float 
   , @turbidity float,   @oxygen float,      @discharge float
WITH EXEC AS CALLER
AS
BEGIN TRY  
  SET NOCOUNT ON
  IF @mli IS NOT NULL
  BEGIN
    INSERT INTO dbo.WaterData (mli, stamp, temperature, discharge, turbidity, oxygen, ph, elevation)
      VALUES (@mli, @stamp, @temperature, @discharge, @turbidity, @oxygen, CAST(@ph as float) * 10.0, @elevation)
    RETURN @@ROWCOUNT      
  END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
------------------------------------------------------------------------------

--  EXEC spStepPushSpeciesFromLakeToStation
-----------------------------------  related push--------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spStepPushSpeciesFromLakeToStation' AND type = 'P')
    DROP PROCEDURE dbo.spStepPushSpeciesFromLakeToStation
GO

CREATE PROCEDURE spStepPushSpeciesFromLakeToStation
WITH EXEC AS CALLER
AS
BEGIN TRY  
  SET NOCOUNT ON;
  DECLARE @return_value int = -1
    -- push fishes from lakes to station place with the same type
  INSERT dbo.fish_location (station_Id, fish_Id, today ) 
    SELECT id, fish_Id, (CASE WHEN today > 100 THEN 100 ELSE today END ) AS today FROM
    (
        select id, fish_Id, ( MAX((50 * spawnPeriod) + probability * ( today / 100)) ) AS today FROM
        (
            select id, fish_Id, today, spawnPeriod
                 , (CASE WHEN probability > 0.1 THEN ( probability - correction / way_correction ) ELSE probability END) AS probability FROM
            ( 
                select w.id, lf.fish_Id, probability, spawnPeriod,
                    (CASE probability_source_type WHEN 0 then 100 when 1 then 90 when 2 then 75 when 4 then 50 else 0 end) as today,
                    (CASE WHEN tributaries = 1 THEN 0 ELSE 0.1 END) AS correction,            -- probability correction
                    (CASE WHEN m.lake_id = lf.lake_Id THEN 1 ELSE 2 END) AS way_correction      -- outflow increase probability
                    FROM dbo.lake_fish lf
                    left join Tributaries m ON lf.lake_id = m.main_lake_id
                    left join Tributaries s ON lf.lake_id = s.main_lake_id
                    join lake l ON (m.lake_id = lf.lake_Id or s.lake_id = lf.lake_Id)
                    join 
                     (
                        SELECT fish_id, habitat, spawnPeriod, periodStart, periodEnd FROM 
                        (
                          SELECT fish_id, habitat, 0 AS spawnPeriod, periodStart, periodEnd 
                            FROM fish_rule WHERE -1 = periodStart AND -1 = periodEnd
                          UNION ALL
                          SELECT fish_id, habitat, 1 AS spawnPeriod, periodStart, periodEnd 
                            FROM fish_rule WHERE -1 <> periodStart AND -1 <> periodEnd
                        )e WHERE spawnPeriod = (CASE WHEN DATEPART( MM, getdate()) BETWEEN periodStart AND periodEnd THEN 1 ELSE 0 END)
                      )d
                        ON ( d.fish_id = lf.fish_id AND d.habitat = ( l.locType & d.habitat ) )
                    join dbo.WaterStation w ON (w.lakeId  = l.lake_id )

            )c
        )b  group by  id, fish_Id
    ) a
    WHERE NOT EXISTS (SELECT * FROM fish_location fl WHERE fl.station_Id = a.id AND fl.fish_Id = a.fish_Id)

    SET @return_value = @@ROWCOUNT;
    RETURN @return_value;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spGetPlaceByFish' AND xtype = 'P')
    DROP PROCEDURE dbo.spGetPlaceByFish
GO
-- SELECT sid, name, county, state, lat, lon, today FROM dbo.GetLocations( 'Burbot', 42, -80, 1 )
-- SELECT [name], county, state, lat, lon, today FROM dbo.GetLocations( 'Lake Chub', 42, -80, 1 )  ORDER BY state ASC
create PROCEDURE dbo.spGetPlaceByFish @fishName  varchar(64), @lat float, @lon float, @dist float
AS 
SET NOCOUNT ON
BEGIN TRY
  DECLARE @fishId uniqueidentifier
  DECLARE @tbl TABLE(  mli varchar(64) PRIMARY KEY, county varchar(64), state char(2), country char(2)
                     , location varchar(max), sid int, lat float, lon float, today int, lakeId uniqueidentifier)
  SELECT @fishId = fish_ID FROM dbo.fish WHERE fish_name like @fishName
  INSERT INTO @tbl 
    SELECT  w.mli, w.county, w.state, w.country, w.LocName, w.sid, w.lat, w.lon, f.today , w.lakeId
     FROM dbo.vWaterStation w 
       JOIN dbo.fish_location f ON ( f.station_Id = w.id )
       JOIN dbo.fish       s ON ( f.fish_Id    = s.fish_Id )
      WHERE ( w.lat between (@lat-@dist) AND (@lat+@dist) ) AND (w.lon between (@lon-@dist) AND (@lon+@dist) ) 
           AND s.fish_name like @fishName  
   -- delete  fishes ae not belong to watershield
   DELETE FROM @tbl WHERE country = 'CA' AND state = 'ON' 
      AND mli NOT IN (SELECT w.mli FROM dbo.WaterStation w, Lake_fish l  
       WHERE w.lakeId=l.lake_Id AND l.fish_Id = @fishId AND w.country = 'CA' AND w.state = 'ON')
   SELECT * FROM @tbl
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
-- exec spGetPlaceByFish 'Burbot', 41, -82, 3

----------------------------------------------------------------------------------------------------------------------------
-- 1. update fish probability based on catch probability - used in spTotalUpdateProbability
-- use fish_catch_probability to update probabilites in fish_location based on by month fish's activity 
-- by default we asume probability is 100% since it was registred in documents
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spTotalUpdateCatch' AND xtype = 'P')
    DROP PROCEDURE dbo.spTotalUpdateCatch
GO
----------------------------------------------------------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[spTotalUpdateCatch]
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY  
    DECLARE @return_value int = 0;

    ;WITH cte (today, station_Id, fish_Id) AS
    (
        SELECT
            ISNULL(fcp.probability, t.probability),
            t.station_Id,
            t.fish_Id
        FROM dbo.fish_location t
        INNER JOIN dbo.fish_catch_probability fcp
            ON t.fish_Id = fcp.fish_id
            AND fcp.month = DATEPART(MONTH, GETUTCDATE())
    )
    UPDATE t
        SET t.stamp = GETUTCDATE(),
            t.today = cte.today
    FROM dbo.fish_location t
    JOIN cte
        ON t.station_Id = cte.station_Id
        AND t.fish_Id = cte.fish_Id
    WHERE t.probability <> cte.today;

    SET @return_value = @@ROWCOUNT;
        
    RETURN @return_value;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO
----------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spTotalUpdateLunar' AND xtype = 'P')
    DROP PROCEDURE dbo.spTotalUpdateLunar
GO
----------------------------------------------------------------------------------------------------------------------------
-- 2. Combined Probability Update (Monthly × Lunar) - must be called after 1. [spTotalUpdateCatch]
-- whatever day of the month it is today, pull that row's probability and use it as the multiplier. Everything else stays the same.
-- if probability over 100% on next step count it as 100%
----------------------------------------------------------------------------------------------------------------------------
CREATE PROCEDURE [dbo].[spTotalUpdateLunar]
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY  
    DECLARE @return_value int = 0;

    UPDATE t
        SET t.today = ROUND(
                t.today * (lp.probability / 100.0)
            , 0),
            t.stamp = GETUTCDATE()
    FROM dbo.fish_location t
    INNER JOIN dbo.fish_lunar_catch_probability lp
        ON lp.fish_id = t.fish_Id
        AND lp.day    = DATEPART(DAY, GETUTCDATE())
    WHERE t.today <> ROUND(t.today * (lp.probability / 100.0), 0);

    SET @return_value = @@ROWCOUNT;
        
    RETURN @return_value;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Drop existing procedure if it exists
IF OBJECT_ID('dbo.sp_upsert_fish_temperature_probability', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_upsert_fish_temperature_probability;
GO

-- 3. update fish probability based on water temperature
-- if fish not in most comfort  temperature zone drop probaility 33% and 5% if out of middle zone
-- Update fish probability based on water temperature with bell curve (can only decrease)
CREATE PROCEDURE dbo.sp_upsert_fish_temperature_probability
AS
SET NOCOUNT ON;
BEGIN TRY
    ;WITH fish_temp_habitat AS
    (
        SELECT f.fish_id, ri.ri_min AS tmL, ri.ri_low AS tmL90, ri.ri_avg AS tmOptimal, ri.ri_high AS tmH90, ri.ri_max AS tmH
        FROM dbo.fish f
        INNER JOIN dbo.fish_Rule r ON r.fish_Id = f.fish_id
        INNER JOIN dbo.real_interval ri ON ri.ri_parent_id = r.id AND ri.ri_type = 17
        WHERE r.periodStart = -1 AND r.periodEnd = -1
    ),
    temperature_coefficients AS
    (
        SELECT
            fl.station_Id,
            fl.fish_Id,
            CAST(
                CASE
                    WHEN cws.temperature < fth.tmL OR cws.temperature > fth.tmH THEN 0.00
                    WHEN cws.temperature >= fth.tmL AND cws.temperature < ISNULL(fth.tmL90, fth.tmOptimal) THEN
                        0.80 + (0.10 * (CAST(cws.temperature AS FLOAT) - fth.tmL) / NULLIF(ISNULL(fth.tmL90, fth.tmOptimal) - fth.tmL, 0))
                    WHEN cws.temperature >= ISNULL(fth.tmL90, fth.tmOptimal) AND cws.temperature < fth.tmOptimal THEN
                        0.90 + (0.10 * (CAST(cws.temperature AS FLOAT) - ISNULL(fth.tmL90, fth.tmOptimal)) / NULLIF(fth.tmOptimal - ISNULL(fth.tmL90, fth.tmOptimal), 0))
                    WHEN cws.temperature = fth.tmOptimal THEN 1.00
                    WHEN cws.temperature > fth.tmOptimal AND cws.temperature <= ISNULL(fth.tmH90, fth.tmOptimal) THEN
                        1.00 - (0.10 * (CAST(cws.temperature AS FLOAT) - fth.tmOptimal) / NULLIF(ISNULL(fth.tmH90, fth.tmOptimal) - fth.tmOptimal, 0))
                    WHEN cws.temperature > ISNULL(fth.tmH90, fth.tmOptimal) AND cws.temperature <= fth.tmH THEN
                        0.90 - (0.10 * (CAST(cws.temperature AS FLOAT) - ISNULL(fth.tmH90, fth.tmOptimal)) / NULLIF(fth.tmH - ISNULL(fth.tmH90, fth.tmOptimal), 0))
                    ELSE 1.00
                END AS DECIMAL(5,2)
            ) AS koef
        FROM dbo.fish_location fl
        INNER JOIN dbo.WaterStation ws ON ws.id = fl.station_Id
        INNER JOIN dbo.CurrentWaterState cws ON cws.mli = ws.mli
        INNER JOIN fish_temp_habitat fth ON fth.fish_id = fl.fish_Id
        WHERE cws.temperature IS NOT NULL
          AND fth.tmL IS NOT NULL AND fth.tmH IS NOT NULL
    )
    UPDATE fl
    SET 
        fl.stamp = GETUTCDATE(),
        fl.today = CAST(ROUND(fl.today * tc.koef, 0) AS INT)
    FROM dbo.fish_location fl
    INNER JOIN temperature_coefficients tc ON fl.station_Id = tc.station_Id AND fl.fish_Id = tc.fish_Id
    WHERE tc.koef < 1.00;
END TRY
BEGIN CATCH
    THROW;
END CATCH;
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Drop existing procedure if it exists
IF OBJECT_ID('dbo.sp_upsert_fish_oxygen_probability', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_upsert_fish_oxygen_probability;
GO

-- 3. update fish probability based on oxygen in water
-- if fish not in most comfort  dissolved oxygen zone drop probaility 33% and 5% if out of middle zone
-- Calculate oxygen coefficients with bell curve: 80% -> 90% -> 100% -> 90% -> 80%
-- Update fish probability based on dissolved oxygen with bell curve (can only decrease)
-- This design ensures safe, conditional updates - only applying oxygen adjustments 
--    where both the environmental data exists AND the fish's oxygen tolerance is known.
CREATE PROCEDURE dbo.sp_upsert_fish_oxygen_probability
AS
SET NOCOUNT ON;
BEGIN TRY
    ;WITH fish_oxygen_habitat AS
    (
        SELECT f.fish_id, ri.ri_min AS oxL, ri.ri_low AS oxL90, ri.ri_avg AS oxOptimal, ri.ri_high AS oxH90, ri.ri_max AS oxH
        FROM dbo.fish f
        INNER JOIN dbo.fish_Rule r ON r.fish_Id = f.fish_id
        INNER JOIN dbo.real_interval ri ON ri.ri_parent_id = r.id AND ri.ri_type = 33
        WHERE r.periodStart = -1 AND r.periodEnd = -1
    ),
    oxygen_coefficients AS
    (
        SELECT
            fl.station_Id,
            fl.fish_Id,
            CAST(
                CASE
                    WHEN cws.oxygen < foh.oxL OR cws.oxygen > foh.oxH THEN 0.00
                    WHEN cws.oxygen >= foh.oxL AND cws.oxygen < ISNULL(foh.oxL90, foh.oxOptimal) THEN
                        0.80 + (0.10 * (CAST(cws.oxygen AS FLOAT) - foh.oxL) / NULLIF(ISNULL(foh.oxL90, foh.oxOptimal) - foh.oxL, 0))
                    WHEN cws.oxygen >= ISNULL(foh.oxL90, foh.oxOptimal) AND cws.oxygen < foh.oxOptimal THEN
                        0.90 + (0.10 * (CAST(cws.oxygen AS FLOAT) - ISNULL(foh.oxL90, foh.oxOptimal)) / NULLIF(foh.oxOptimal - ISNULL(foh.oxL90, foh.oxOptimal), 0))
                    WHEN cws.oxygen = foh.oxOptimal THEN 1.00
                    WHEN cws.oxygen > foh.oxOptimal AND cws.oxygen <= ISNULL(foh.oxH90, foh.oxOptimal) THEN
                        1.00 - (0.10 * (CAST(cws.oxygen AS FLOAT) - foh.oxOptimal) / NULLIF(ISNULL(foh.oxH90, foh.oxOptimal) - foh.oxOptimal, 0))
                    WHEN cws.oxygen > ISNULL(foh.oxH90, foh.oxOptimal) AND cws.oxygen <= foh.oxH THEN
                        0.90 - (0.10 * (CAST(cws.oxygen AS FLOAT) - ISNULL(foh.oxH90, foh.oxOptimal)) / NULLIF(foh.oxH - ISNULL(foh.oxH90, foh.oxOptimal), 0))
                    ELSE 1.00
                END AS DECIMAL(5,2)
            ) AS koef
        FROM dbo.fish_location fl
        INNER JOIN dbo.WaterStation ws ON ws.id = fl.station_Id
        INNER JOIN dbo.CurrentWaterState cws ON cws.mli = ws.mli
        INNER JOIN fish_oxygen_habitat foh ON foh.fish_id = fl.fish_Id
        WHERE cws.oxygen IS NOT NULL
          AND foh.oxL IS NOT NULL AND foh.oxH IS NOT NULL
    )
    UPDATE fl
    SET 
        fl.stamp = GETUTCDATE(),
        fl.today = CAST(ROUND(fl.today * oc.koef, 0) AS INT)
    FROM dbo.fish_location fl
    INNER JOIN oxygen_coefficients oc ON fl.station_Id = oc.station_Id AND fl.fish_Id = oc.fish_Id
    WHERE oc.koef < 1.00;
END TRY
BEGIN CATCH
    THROW;
END CATCH;
GO
----------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spTotalUpdateProbability' AND xtype = 'P')
    DROP PROCEDURE dbo.spTotalUpdateProbability
GO

-- EXEC spTotalUpdateProbability
----------------------------------------------------------------------------------------------------------------------------
CREATE PROCEDURE dbo.spTotalUpdateProbability
WITH EXEC AS CALLER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @return_value int = 0;

    BEGIN TRY
        BEGIN TRANSACTION;
        -- 1. reset probability to unknown state for week old probabilites
        UPDATE fish_location SET today = 100 WHERE stamp < DATEADD(DAY, -7, GETUTCDATE())  
        UPDATE [CurrentWaterState] SET temperature = NULL, oxygen = NULL
            WHERE stamp < DATEADD(DAY, -7, GETUTCDATE())  


        -- 2. update fish probability based on catch probability
        EXEC dbo.spTotalUpdateCatch

        -- 3. update fish probability based on lunar
        EXEC dbo.spTotalUpdateLunar

        -- update fish probability based on water temperature
        EXEC dbo.sp_upsert_fish_temperature_probability


        -- update fish probability based on oxygen
        EXEC dbo.sp_upsert_fish_oxygen_probability

        SET @return_value = @return_value + @@ROWCOUNT;

        COMMIT TRANSACTION;

        RETURN @return_value;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END              
GO
----------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_weather_save_city' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_weather_save_city
GO

CREATE PROCEDURE dbo.sp_weather_save_city @city_id int, @city_name nvarchar(32), @lat float, @lon float
                                        , @country char(2), @population int, @mli varchar(64)
WITH EXEC AS CALLER
AS
BEGIN TRY  
  SET NOCOUNT ON;
  DECLARE @return_value int = -1

    IF NOT EXISTS (SELECT * FROM city WHERE @city_name = place 
       AND @country = country  AND ( ABS(lat) BETWEEN ( ABS(CAST(@lat AS INT))-1 ) AND ( ABS(CAST(@lat AS INT))+1 ) ) 
                               AND ( ABS(lon) BETWEEN ( ABS(CAST(@lon AS INT))-1 ) AND ( ABS(CAST(@lon AS INT))+1 ) ) )
    BEGIN
        INSERT INTO city ( place,  state, lat, lon, country, region, city_id, population, stamp )
                VALUES ( @city_name, '  ', @lat, @lon, @country, -1, @city_id, @population, getutcdate()  )
    END ELSE
        IF EXISTS (SELECT * FROM city WHERE @city_name = place 
           AND @country = country  AND ( ABS(lat) BETWEEN ( ABS(CAST(@lat AS INT))-1 ) AND ( ABS(CAST(@lat AS INT))+1 ) ) 
                                   AND ( ABS(lon) BETWEEN ( ABS(CAST(@lon AS INT))-1 ) AND ( ABS(CAST(@lon AS INT))+1 ) ) )
        BEGIN
          UPDATE city SET city_id = @city_id WHERE @city_name = place AND @country = country
            AND ( ABS(lat) BETWEEN ( ABS(CAST(@lat AS INT))-1 ) AND ( ABS(CAST(@lat AS INT))+1 ) ) 
            AND ( ABS(lon) BETWEEN ( ABS(CAST(@lon AS INT))-1 ) AND ( ABS(CAST(@lon AS INT))+1 ) ) 
        END
    UPDATE WaterStation SET city_id = @city_id WHERE mli = @mli
    RETURN @@ROWCOUNT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spGetPlaceByFish_stale' AND xtype = 'P')
    DROP PROCEDURE dbo.spGetPlaceByFish_stale
GO

create PROCEDURE spGetPlaceByFish_stale @fishName  varchar(64), @lat float, @lon float, @dist float
AS     -- exec [dbo].[spGetPlaceByFish] 'burbot', 43, -81, 3
SET NOCOUNT ON    --lat, lon, today, location, sid, country, state, county
  DECLARE @fishId uniqueidentifier = (SELECT TOP 1 fish_id FROM fish WHERE fish_name like @fishName )
  DECLARE @tbl TABLE(  lat float, lon float, today int, location varchar(max), sid int
                     , country char(2), state char(2), county varchar(64))
  INSERT INTO @tbl 
   SELECT lat,  lon , today, LocName, sid, country, state, county FROM
   (
        SELECT  w.lat, w.lon, f.today, w.LocName, w.sid, w.country, w.state, w.county 
         FROM dbo.vWaterStation w 
           JOIN dbo.fish_location f ON ( f.station_Id = w.id )
           JOIN dbo.fish          s ON ( f.fish_Id    = s.fish_Id )
          WHERE  
 --           ( w.lat between (@lat-@dist) AND (@lat+@dist) ) AND (w.lon between (@lon-@dist) AND (@lon+@dist) ) AND 
               s.fish_id = @fishId
   )a
   SELECT lat, lon, today, location, sid, country, state, county FROM @tbl
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_tributary' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_tributary
GO

-- 1 - left, 2- right, 4 - inflows, 8 - outflows, 16 - source, 32 - mouth
CREATE PROCEDURE sp_add_tributary @Main_Lake_id uniqueidentifier, @Lake_id uniqueidentifier, @side int, @flow int, @lat float, @lon float, @level int
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON

    IF EXISTS (SELECT * FROM lake WHERE lake_id = @Lake_id AND locType in (1, 8, 8192))
    BEGIN
        INSERT INTO Tributaries (Main_Lake_id, Lake_id, side, lat, lon, elevation) values (@Lake_id, @Main_Lake_id, @side, @lat, @lon, @level);
    END
    ELSE
    BEGIN
        update  Tributaries SET Lake_id = @Main_Lake_id, lat = COALESCE(@lat, lat), lon = COALESCE(@lon, lon) , elevation = COALESCE(@level, elevation)  
            WHERE Main_Lake_id = @Lake_id AND side = 32
    END
    IF @@ROWCOUNT > 0
        UPDATE lake SET stamp = getdate() WHERE lake_id IN (@Main_Lake_id, @Lake_id)
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;        
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spSaveException' AND xtype = 'P')
    DROP PROCEDURE dbo.spSaveException
GO

create PROCEDURE spSaveException @ip varchar(64), @msg nvarchar(1024), @page_name sysname, @email sysname
AS
SET NOCOUNT ON
BEGIN TRY  
  INSERT INTO LogException( ip, msg, page_name, email ) values (@ip, @msg, @page_name, @email);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;          
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_fish_river' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_fish_river
GO

/******
 *  add the fish to the river or update existing with ner fact
 *  @fish_id     uniqueidentifier        - fish identifyer
 *  @lake_id     uniqueidentifier        - lake identifyer
 *  @link        nvarchar(512)          - http link to the source
 *  @created     datetime2              - date when information was entered
 *  @probability int                    - 0 - science documents (high priority), 1- site owner, 2 - paid fishers, 3 - unknown fishers
 *  @note        nvarchar(1024)         - note about fishing
 *
 *  Usage: exec sp_add_fish_river 'F124F917-D11F-4ED9-9B59-863D184CBFED', '1864853F-F9B7-41E7-A66C-3359961AB6A4', 'http://files.ontario.ca/environment-and-energy/fishing/mnr_e001331.pdf', '2014', 0
 *
 */
create PROCEDURE sp_add_fish_river @fish_id uniqueidentifier, @lake_id uniqueidentifier, @link nvarchar(512)
              , @created datetime2 = NULL, @probability int = 0, @note nvarchar(1024)  = null
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON
    IF @created Is NULL SET @created = '19000101'

    declare @init_prb int = CASE
        WHEN @probability IN (0,1) THEN 100
        WHEN @probability = 2 THEN 90
        WHEN @probability = 3 THEN 75 ELSE 50 END;

    declare @fish uniqueidentifier = ( select fish_id from fish where fish_id = @fish_id );
    declare @lake uniqueidentifier = ( select lake_id from lake where lake_id = @lake_id );

    if ( @fish IS NULL AND @lake IS NULL ) 
    BEGIN
        SET @fish = @lake_id;
        SET @lake = @fish_id;
    END ELSE
    BEGIN
      IF @fish IS NULL
        SET @fish = ( select fish_id from fish where fish_name = @fish_id );
      IF @lake IS NULL
        SET @lake = ( select lake_id from lake where lake_name = @lake_id );
    END
    SET @fish = ( select fish_id from fish where fish_id = @fish_id );
    SET @lake = ( select lake_id from lake where lake_id = @lake_id );

    if ( @fish IS NULL AND @lake IS NULL ) 
    BEGIN
        SET @fish = @lake_id;
        SET @lake = @fish_id;
    END

    IF NOT EXISTS (SELECT link FROM lake_fish WHERE @fish_id = fish_id AND @lake_id = lake_id AND probability_source_type = @probability)
    BEGIN
    INSERT INTO lake_fish (  lake_id,  fish_id, link,   created, probability, probability_source_type, note )
        VALUES            ( @lake_id, @fish_id, @link, @created, @init_prb,   @probability, @note);
    END
    ELSE
    BEGIN
        UPDATE lake_fish SET link = COALESCE(@link, link), note = COALESCE(@note, note), created = getdate()
            WHERE  lake_id = @lake_id AND fish_id = @fish_id AND probability_source_type > @probability;
    END

    SELECT l.lake_name, f.fish_name, l.lake_id, f.fish_id FROM lake l 
        JOIN lake_fish lf ON l.lake_id = lf.lake_Id 
        JOIN fish       f ON f.fish_id = lf.fish_Id 
        WHERE l.lake_id = @lake_id ORDER BY lf.created DESC
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO
---------------------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_regulation' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_regulation
GO

-- add regulation to river/lake
-- http://files.ontario.ca/environment-and-energy/fishing/mnr_e001331.pdf
-- 1 - Fish sanctuary - no fishing
/*
    @zone_id        int                         -- regulation zone 1-17 in Ontario
    @part           nvarchar(255)               -- 'Kenny, Gladman, Flett, Gooderham and Milne Twps. '
    @date_start     varchar(64)                 -- date, could be day of week or special event
    @date_end       varchar(64)                 -- date, could be day of week or special event
    @sport          nvarchar(255)               -- number of fishes for sport license 
    @reacr          nvarchar(255)               -- number of fishes for recreational license license 
    @code           int                         -- code
    @fish_id        uniqueidentifier
    @lake_id        uniqueidentifier
    @link           nvarchar(255)               -- http link to document
    @enter_year     int                         -- year when regualation was published

    EXEC sp_add_regulation 'ON', 10, 'Method: Bow and arrow during daylight hours only', 'May 1', 'July 31', NULL, NULL, NULL, 'D1814745-D6C3-4A95-8503-3C6DFB5B8B21'
        , NULL, 'https://files.ontario.ca/on-con-188/ONCON-188_MNRF_CR_ontario-fishing-regulations-summary-v2.pdf', 2019, 1

    EXEC sp_add_regulation 'ON', 1, '', 'January 1', 'December 31', NULL, NULL, NULL, 'a35109a0-63ba-4bf5-8a25-2e7e39b74f6e'
        , NULL, 'https://www.ontario.ca/page/sport-fishing-variation-order-fisheries-management-zone-1', 2019, 1

    EXEC sp_add_regulation 'ON', 1, '', 'January 1', 'December 31', '5, not more than 1 greater than 40 cm', '2, not more than 1 greater than 40'
        , NULL, 'a35109a0-63ba-4bf5-8a25-2e7e39b74f6e', NULL, 'https://www.ontario.ca/page/sport-fishing-variation-order-fisheries-management-zone-1', 2019, 1

-- select * from regulations
-- delete from regulations

*/

CREATE PROCEDURE dbo.sp_add_regulation @state char(2), @zone_id int, @part nvarchar(255), @date_start varchar(64), @date_end varchar(64)
        , @sport nvarchar(255), @reacr nvarchar(255), @code int
        , @fish_id uniqueidentifier, @lake_id uniqueidentifier, @link nvarchar(255), @enter_year int = NULL, @postview bit = 0
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON
    IF @enter_year IS NULL
    BEGIN
        SET @enter_year = DATEPART(YEAR, getdate());
    END
    IF @date_start IS NULL 
    BEGIN
        SET @date_start = CAST(DATEPART(YEAR, getdate()) AS varchar(4)) + '0101';
    END
    IF @date_end IS NULL 
    BEGIN
        SET @date_end = CAST(DATEPART(YEAR, getdate()) AS varchar(4)) + '1231';
    END;

    -- set zone to river
    IF @zone_id IS NOt NULL AND @lake_id IS NOT NULL
    BEGIN
        UPDATE Tributaries SET zone = @zone_id WHERE lake_id = @lake_id AND main_lake_id = @lake_id ANd side=32

        exec sp_add_fish_river @fish_id, @lake_id, @link, null, 0, '';
    END
    declare @start date = (SELECT TRY_PARSE(@date_start AS datetime USING 'en-US') );
    declare @end date = (SELECT TRY_PARSE(@date_end AS datetime USING 'en-US') );
    declare @regulations_start  varchar(64), @regulations_end varchar(64);

    declare @sportint int = TRY_CONVERT(int, @sport);
    declare @reacrint int = TRY_CONVERT(int, @reacr);

    IF @start IS NULL
        SET @regulations_start = @date_start;

    IF @end IS NULL
        SET @regulations_end = @date_end;

    declare @idstart int = (SELECT MAX(id) FROM regulations)

--    IF @start IS NOT NULL AND @end IS NOT NULL 
    BEGIN
        insert into regulations ( state, zone_id, fish_id, lake_id, regulations_start, regulations_date_start, regulations_end, regulations_date_end
                                , regulations_part, regulations_sport, regulations_sport_text, regulations_consr, regulations_consr_text, regulations_code, regulations_link) 
                    values      ( @state, @zone_id, @fish_id, @lake_id, @regulations_start, @start, @regulations_end, @end, @part, @sportint, @sport, @reacrint, @reacr, @code, @link);
    END
    If @postview = 1
        SELECT * FROM regulations WHERE @idstart < id OR @idstart IS NULL
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO
---------------------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_MergeLakes' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_MergeLakes
GO

create PROCEDURE dbo.sp_MergeLakes @fromLake uniqueidentifier, @toLake uniqueidentifier
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON
    IF NOT EXISTS(SELECT * FROM lake where lake_id=@fromLake)
        RETURN

     update WaterStation set lakeid= @toLake where lakeid = @fromLake 
    BEGIN
        delete from lake_fish where lake_id = @toLake
            AND fish_id in (SELECT fish_id FROM lake_fish WHERE lake_id = @fromLake)
        update lake_fish set lake_id = @toLake where lake_id = @fromLake 
    END
    BEGIN
        delete from lake_state where lake_id = @toLake
            AND month in (SELECT month FROM lake_state WHERE lake_id = @fromLake)
        update lake_fish set lake_id = @toLake where lake_id = @fromLake 
    END
    update spot set lake_id = @toLake where lake_id = @fromLake
    update zone_regulations set lake_id = @toLake where lake_id = @fromLake
    update lake SET source=@toLake where source=@fromLake
    update lake SET mouth=@toLake where mouth=@fromLake
    update news SET lake_id=@toLake where lake_id=@fromLake
    -- fish_spot was re-pointed on production but the line had never reached this script (drift
    -- found 2026-08-11 while retiring Parking_Spot, whose own line stood right below this one).
    update fish_spot SET  lake_id=@toLake where lake_id=@fromLake

    update t set t.phosphorus=COALESCE(s.phosphorus, t.phosphorus )
	           , t.PH=COALESCE(s.PH, t.PH )
	           , t.TDS=COALESCE(s.TDS, t.TDS )
	           , t.Conductivity=COALESCE(s.Conductivity, t.Conductivity )
	           , t.Alkalinity=COALESCE(s.Alkalinity, t.Alkalinity )
	           , t.Hardness=COALESCE(s.Hardness, t.Hardness )
	           , t.Sodium=COALESCE(s.Sodium, t.Sodium )
	           , t.Chloride=COALESCE(s.Chloride, t.Chloride )
	           , t.Bicarbonate=COALESCE(s.Bicarbonate, t.Bicarbonate )
	           , t.transparency=COALESCE(s.transparency, t.transparency )
	           , t.oxygen=COALESCE(s.oxygen, t.oxygen )
	           , t.Salinity=COALESCE(s.Salinity, t.Salinity )
	    FROM lake_state t, lake_state s WHERE t.lake_id = @toLake AND s.lake_id = @fromLake

    update t set t.link = s.link 
            , t.length=COALESCE(s.length, t.length )
            , t.depth=COALESCE(s.depth, t.depth )
            , t.width=COALESCE(s.width, t.width )

            , t.old_id=COALESCE(s.old_id, t.old_id )
            , t.basin=COALESCE(s.basin, t.basin )
            , t.descript=COALESCE(s.descript, t.descript )
            , t.IsFish=COALESCE(s.IsFish, t.IsFish )
            , t.regulations=COALESCE(s.regulations, t.regulations )
            , t.link_reg=COALESCE(s.link_reg, t.link_reg )
            , t.drainage=COALESCE(s.drainage, t.drainage )
            , t.Discharge=COALESCE(s.Discharge, t.Discharge )
            , t.watershield=COALESCE(s.watershield, t.watershield )
            , t.fishing=COALESCE(s.fishing, t.fishing )
            , t.Volume=COALESCE(s.Volume, t.Volume )
            , t.Shoreline=COALESCE(s.Shoreline, t.Shoreline )
            , t.surface=COALESCE(s.surface, t.surface )
            , t.isWell=COALESCE(s.isWell, t.isWell )
            , t.lake_road_access=COALESCE(s.lake_road_access, t.lake_road_access )
            , t.CGNDB = CASE WHEN t.CGNDB IS NULL THEN s.CGNDB ELSE t.CGNDB END
    FROM lake t, lake s WHERE t.lake_id = @toLake AND s.lake_id = @fromLake

    update t set
        t.location = COALESCE(f.location, t.location)
        , t.lat = COALESCE(f.lat, t.lat )
        , t.lon = COALESCE(f.lon, t.lon )
        , t.elevation = COALESCE(f.elevation, t.elevation )
        , t.State= COALESCE(f.State, t.State)
        , t.zone = COALESCE(f.zone, t.zone )
        , t.city = COALESCE(f.city, t.city)
        , t.Country = COALESCE(f.Country, t.Country)
        , t.county = COALESCE(f.county, t.county)
        , t.descript = COALESCE(f.descript, t.descript )
        , t.district = COALESCE(f.district, t.district )
        , t.municipality = COALESCE(f.municipality, t.municipality )
        , t.region = COALESCE(f.region, t.region )
        FROM tributaries t, tributaries f 
        where t.main_lake_id = @toLake AND t.lake_id = @toLake 
        AND f.main_lake_id = @fromLake AND f.lake_id = @fromLake

    update [dbo].[lake_image] set lake_image_ownerid = @toLake where lake_image_ownerid = @fromLake
    update tributaries set main_lake_id = @toLake where main_lake_id <> lake_id AND main_lake_id = @fromLake  AND side NOT IN( 32, 16 )
    update tributaries set lake_id = @toLake where main_lake_id <> lake_id AND lake_id = @fromLake

    update tributaries set lake_id = @toLake where main_lake_id <> lake_id AND lake_id = @fromLake

    delete from tributaries where main_lake_id = @fromLake
    delete from tributaries where lake_id = @fromLake
    delete from lake where lake_id = @fromLake 
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_update_fish_general' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_update_fish_general
GO

create PROCEDURE sp_update_fish_general @fish_id uniqueidentifier, @locked bit, @editor uniqueidentifier, @fish_description nvarchar(2048), @fish_uses nvarchar(2048)
AS
SET NOCOUNT ON
BEGIN TRY  
    UPDATE dbo.fish Set stamp = GETUTCDATE(), locked = @locked, editor=@editor, descrip = @fish_description, uses = @fish_uses
        WHERE fish_id =  @fish_Id;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_update_interval' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_update_interval
GO

create PROCEDURE dbo.sp_update_interval @parent_id uniqueidentifier, @type int, @min float, @max float, @low float=null, @avg float=null, @high float=null
AS
SET NOCOUNT ON
BEGIN TRY  
    IF @parent_id IS NOt NULL AND @type IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT * FROM real_interval WHERE ri_parent_id = @parent_id AND ri_type = @type)
        BEGIN
            INSERT INTO real_interval (ri_parent_id, ri_type, ri_min, ri_max, ri_low, ri_avg, ri_high, ri_stamp)
                VALUES (@parent_id, @type, @min, @max, @low, @avg, @high, getdate())
        END
        ELSE
        BEGIN
            UPDATE real_interval SET ri_max=@max, ri_min=@min, ri_low = @low, ri_high = @high, ri_avg = @avg, ri_stamp=getdate()
                WHERE ri_parent_id = @parent_id AND ri_type = @type
        END
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_update_fish' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_update_fish
GO

-- 1 - sport, 2 - Coarse, 4 - commersial, 8 - invading, 128 - migrate pattern (inverted logic by default)
create PROCEDURE dbo.sp_update_fish @fish_Id uniqueidentifier
   , @habitat int,  @feedsOver int
   , @veL float, @veH float, @locked bit, @editor uniqueidentifier
   , @depthMin   float, @depthMax float
   , @react_color int
AS
SET NOCOUNT ON
BEGIN TRY  
    declare @instance_id uniqueidentifier = (SELECT TOP 1 id FROM dbo.fish_Rule WHERE fish_Id = @fish_Id AND periodStart = -1 AND periodEnd = -1);
    if( @instance_id is not null )
    BEGIN
        UPDATE dbo.fish_Rule SET  locked=@locked, editor=@editor, habitat = @habitat,  feedsOver = @feedsOver WHERE @instance_id = id
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_update_fish_spawn' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_update_fish_spawn
GO

/*
* save period settings for fish spawn
* called from SavePeriodSpawn
*/
create PROCEDURE sp_update_fish_spawn @fish_id uniqueidentifier, @spawn_period_start int, @spawn_period_end int
   , @spawn_at int, @spawn_over int, @locked bit, @editor uniqueidentifier
   , @veL float, @veH float, @depthMin   float, @depthMax float
   
AS
SET NOCOUNT ON
BEGIN TRY  
  IF ( @spawn_period_start BETWEEN 1 AND 12 ) AND ( @spawn_period_end BETWEEN @spawn_period_start AND 12)
  BEGIN
    UPDATE dbo.fish Set stamp = GETUTCDATE() WHERE fish_id =  @fish_Id;

    declare @instance_id uniqueidentifier = (SELECT TOP 1 id FROM dbo.fish_Rule WHERE fish_Id = @fish_Id AND periodStart <> -1 AND periodEnd <> -1);
    if( @instance_id is null )
    BEGIN
        INSERT INTO fish_Rule (fish_Id, periodStart, periodEnd, id) values (@fish_id, @spawn_period_start, @spawn_period_end, newid())
        SET @instance_id = (SELECT TOP 1 id FROM dbo.fish_Rule WHERE fish_Id = @fish_Id AND periodStart <> -1 AND periodEnd <> -1);
    END

    IF  @instance_id IS NOt NULL
    BEGIN
        UPDATE dbo.fish_Rule 
            SET periodStart = @spawn_period_start, periodEnd = @spawn_period_end, stamp = GETUTCDATE(), habitat = @spawn_at, spawnsOver = @spawn_over, locked = @locked, editor=@editor
            FROM dbo.fish_Rule WHERE fish_Id = @fish_Id AND periodStart <> -1 AND periodEnd <> -1
    END
  END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_save_fish_spawn_general' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_save_fish_spawn_general
GO

/*
* save general settings for fish spawn
* called from SaveGeneralSpawn
*/
create PROCEDURE sp_save_fish_spawn_general @fish_id uniqueidentifier, @age_female int, @age_male int, @egg_min int, @egg_max int
                                           , @desc nvarchar(max), @location nvarchar(max), @strategy nvarchar(max)
AS
SET NOCOUNT ON
BEGIN TRY  
    IF( NOT EXISTS (SELECT * FROM fish_spawn WHERE fish_id = @fish_id ))
    BEGIN
        INSERT INTO fish_spawn (fish_id, fish_spawn_age_female, fish_spawn_age_male
                  , fish_spawn_eggs_min, fish_spawn_eggs_max, fish_spawn_description, fish_spawn_location, reproductive_strategy)
            VALUES (@fish_id, @age_female, @age_male, @egg_min, @egg_max, @desc, @location, @strategy);
    END
    ELSE
    BEGIN
        UPDATE fish_spawn SET fish_spawn_age_female = @age_female, fish_spawn_age_male = @age_male
        , fish_spawn_eggs_min = @egg_min, fish_spawn_eggs_max = @egg_max
        , fish_spawn_description = @desc, fish_spawn_location = @location, reproductive_strategy=@strategy
        , fish_spawn_stamp = getdate() WHERE fish_id = @fish_id
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
---------------------------------------------------------------------------------------------------------------------------------------------
-- dbo.sp_weather_forecast16 RETIRED (2026-08-11).
-- The OpenWeatherMap 16-day forecast writer. Two reasons it went:
--   * its INSERT omitted three NOT NULL columns of dbo.weather_Forecast (link, gpfDay, gpfNight),
--     so it could never insert a row - on production either;
--   * it called dbo.fn_direction_by_win_degree, a function that exists in no database.
-- No caller in any repository; forecasts are collected through dbo.ows_meteo / dbo.sp_ows_meteo
-- and read through dbo.fn_plot_weather / dbo.fn_station_weather_today today.
-- An older copy in scriptA100_fillForecast.sql (legacy column names maxWin/degree/direction) was
-- removed at the same time. The DROP is kept so an existing database sheds the dead procedure.
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_weather_forecast16' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_weather_forecast16
GO
---------------------------------------------------------------------------------------------------------------------------------------------
-- dbo.sp_weather_station RETIRED (2026-08-11).
-- It inserted into a table dbo.Weather_station that exists in NO database - not in a fresh build
-- and not on production - so every call has always ended in its own CATCH block, and its only
-- other statement (UPDATE WaterStation SET weather_station_id = ...) was already commented out.
-- No caller in any repository, and unlike UScode / fn_Parser there was nothing on production to
-- restore it from. Weather stations are handled by dbo.weather_gov_station +
-- dbo.sp_save_weather_gov_station and dbo.weather_station_coverage today.
-- The DROP is kept so an existing database sheds the dead procedure.
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_weather_station' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_weather_station
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spAddExtUser' AND xtype = 'P')
    DROP PROCEDURE dbo.spAddExtUser
GO

create PROCEDURE spAddExtUser @userName  varchar(64), @psw varchar(128),     @titul nvarchar(32)
    , @firstName nvarchar(64), @lastName nvarchar(64), @email varchar(128), @postal varchar(16)
    , @userId uniqueidentifier
AS
SET NOCOUNT ON
BEGIN TRY  
  DECLARE @hash bigint = NULL
  INSERT INTO Users( userName,  psw,                                 titul,  firstName,  lastName,  email
                   , postal,    access, question, answer, id ) 
            VALUES ( @userName, HashBytes('MD5', @psw + '*solt'),    @titul, @firstName, @lastName, @email
                   , @postal,   1,      N'Type your original email', HashBytes('MD5', @email + '+zuker'), @userId )
  SELECT @hash = CAST(psw AS bigint) FROM Users WHERE id =  @userId
  IF @hash IS NOT NULL
    SELECT @userId AS userId, @hash AS [hash]
  ELSE
    SELECT '00000000-0000-0000-0000-000000000000' AS userId, 0 AS [hash]
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spAddUser' AND xtype = 'P')
    DROP PROCEDURE dbo.spAddUser
GO

create PROCEDURE spAddUser @userName  varchar(64), @psw varchar(128),     @titul nvarchar(32)
    , @firstName nvarchar(64), @lastName nvarchar(64), @email varchar(128), @postal varchar(16)
    , @subs BIT, @question nvarchar(64), @answer nvarchar(64), @cell bigint, @userId uniqueidentifier OUT
AS
SET NOCOUNT ON
BEGIN TRY  
  SET @userId = NULL
  DECLARE @tmp TABLE( id uniqueidentifier )
  INSERT INTO Users( userName, psw, titul, firstName, lastName, email, postal, subs, question, answer, cell ) 
  OUTPUT INSERTED.ID INTO @tmp( id )
                     VALUES ( @userName, HashBytes('MD5', @psw + '*solt'), @titul, @firstName, @lastName, @email
                     , @postal, @subs, @question, HashBytes('MD5', @answer + '+zuker'), @cell )
  IF EXISTS (SELECT * FROM @tmp ) 
    SELECT TOP 1 @userId = id FROM @tmp
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spPushSpeciesFromLakeToStation' AND xtype = 'P')
    DROP PROCEDURE dbo.spPushSpeciesFromLakeToStation
GO

-- exec spPushSpeciesFromLakeToStation 
create PROCEDURE spPushSpeciesFromLakeToStation 
WITH EXEC AS CALLER
AS
BEGIN TRY  
  SET NOCOUNT ON;
  DECLARE @return_value int = -1
    -- push fishes from lakes to station place
    insert dbo.fish_location (station_Id, fish_Id, probability, today )
        select id, fish_Id, today, today FROM
        (
            select id, fish_Id, max(today) AS today FROM
            (
              select w.id, f.fish_Id, probability, 
                (CASE [probability_source_type] WHEN 0 then 100 when 1 then 90 when 2 then 75 when 4 then 50 else 0 end) as today
                from  [dbo].[lake_fish] f
                  join [dbo].[WaterStation] w on (w.[lakeId]  = f.[lake_id] )
            )b  group by  id, fish_Id
        ) a
        WHERE NOT EXISTS (SELECT * FROM fish_location fl WHERE fl.station_Id = a.id AND fl.fish_Id = a.fish_Id)
    SET @return_value = @@ROWCOUNT;
    RETURN @return_value;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'spSaveUser' AND xtype = 'P')
    DROP PROCEDURE dbo.spSaveUser
GO

create PROCEDURE spSaveUser @ipaddr varchar(32), @agent varchar(128)
    , @addr varchar(32), @host varchar(255), @user varchar(255), @email varchar(255), @country char(2)
    , @postal varchar(16), @fname nvarchar(64), @lname nvarchar(64), @psw varchar(128)
AS
SET NOCOUNT ON
BEGIN TRY  
    INSERT INTO Users (userName, email, ipaddr, agent, addr, host, country, postal, firstName, lastName, psw, question, answer) 
        VALUES (@user, @email, @ipaddr, @agent, @addr, @host, @country, @postal, @fname, @lname, HashBytes('MD5', @psw + '*solt'), 'dog', 0x0024);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_fish_image' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_fish_image
GO

/******
 * on page EditFishZoo save image to fish_image and set id to repalted form table: fish_zoo
 * depend on fn_river_view
 *
 * INPUT PARAMETERS:
 *
 *    @@lake_id   uniqueidentifier  - a lake guid
 *    @image      image             - actual image
 *    @tablename  sysname           - this table will be update to related id
 *    @colname    sysname           - this @tablename.column will be update to related id
 *
 *  Usage:
            EXEC sp_add_fish_image 'f83d9508-bf50-41b8-b22c-7accbb6713dd', 0xFF, N'fish_zoo', N'fish_zoo_image', 1, 0, N'source', N'author', N'www.ca', N'label', N'location', 40, -80, N'tag', '2026-01-01'
 */
/*
 select * from fish_image 
 delete from fish_image where fish_id = 'C2E8C307-F470-458B-8CEE-000999277126'
 update fish_zoo set [fish_zoo_image] = null
*/
CREATE PROCEDURE [dbo].[sp_add_fish_image]
    @fish_id   uniqueidentifier, @image varbinary(max), @tablename sysname, @colname sysname,
    @gender bit, @juvenile bit, @source nvarchar(255), @author nvarchar(255), @link nvarchar(255), @label nvarchar(255),
    @location nvarchar(255), @lat float, @lon float, @tag nvarchar(255), @stamp nvarchar(255)
AS
SET NOCOUNT ON
BEGIN TRY
    DECLARE @execsql nvarchar(500);
    DECLARE @imageId  int;
    DECLARE @newHash  varbinary(256);

    IF @fish_id IS NOT NULL
    BEGIN
        SET @newHash = HASHBYTES('SHA1', @image);

        -- reuse existing row if same image content
        SELECT @imageId = fish_image_id FROM dbo.fish_image WHERE fish_image_hash = @newHash;

        IF @imageId IS NULL
        BEGIN
            INSERT INTO dbo.fish_image
                ( fish_id, fish_image_pic, fish_image_gender, fish_image_juvenile, fish_image_source, fish_image_author,
                  fish_image_link, fish_image_label, fish_image_location, fish_image_lat, fish_image_lon,
                  fish_image_tag, fish_image_stamp, fish_image_hash )
            VALUES
                ( @fish_id, @image, @gender, @juvenile, @source, @author,
                  @link, @label, @location, @lat, @lon,
                  @tag, @stamp, @newHash );
            SET @imageId = SCOPE_IDENTITY();
        END

        IF @imageId IS NOT NULL
           AND EXISTS (SELECT * FROM sys.tables  WHERE name = @tablename)
           AND EXISTS (SELECT * FROM sys.columns WHERE name = @colname)
        BEGIN
            SET @execsql = N'UPDATE ' + @tablename + N' SET ' + @colname
                         + N' = ' + CAST(@imageId AS nvarchar(20))
                         + N' WHERE fish_id = ''' + CAST(@fish_id AS nvarchar(36)) + N'''';
            EXEC (@execsql);
        END
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity,
           ERROR_STATE() AS ErrorState, ERROR_PROCEDURE() AS ErrorProcedure,
           ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_lake_map' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_lake_map
GO

/******
 * Used by ~/Editor/LakeMap.aspx to attach a map / document / image / external link to a water body.
 * The relationship lives on the row itself (lake_map_ownerid), so a water body can own MANY rows.
 * Dedup is per (owner, hash): the same file/link is stored once per water body, but the same file
 * may be attached to different water bodies. (Lake PHOTOS live in lake_image, not here.)
 *
 *    @lake_id   uniqueidentifier  - the owning water body (lake/river) guid
 *    @image     varbinary(max)    - the file bytes (0x / empty for an external "Link" entry)
 *    @type      int               - format code: 0 link, 1 jpg, 2 png, 8 pdf, 9 word, 10 xls, ...
 *    @kind      int               - editor category: 4 link, 1 map, 2 document, 8 image
 *    @link      nvarchar          - external URL (the payload for a "Link" entry; metadata otherwise)
 *    @label     nvarchar          - original file name (drives MIME/extension when served back)
 *
 *  Usage:
 *      EXEC sp_add_lake_map 'fc0d917b-d053-11d8-92e2-080020a0f4c9', 0xFF, 1, 1, N'src', N'author', N'http://x', N'map.jpg', N'loc', 40, -80, N'tag', '2026-01-01'
 */
CREATE PROCEDURE [dbo].[sp_add_lake_map]
    @lake_id uniqueidentifier, @image varbinary(max), @type int, @kind int,
    @source nvarchar(255), @author nvarchar(255), @link nvarchar(255), @label nvarchar(255),
    @location nvarchar(255), @lat float, @lon float, @tag nvarchar(255), @stamp nvarchar(255)
AS
SET NOCOUNT ON
BEGIN TRY
    DECLARE @mapId int;
    DECLARE @newHash varbinary(256);

    IF @lake_id IS NOT NULL
    BEGIN
        -- hash file bytes AND the link text so multiple distinct links (each with empty @image)
        -- do not collide, while exact repeats of a file or link for the same owner are deduped
        SET @newHash = HASHBYTES('SHA1', ISNULL(@image, 0x) + CAST(ISNULL(@link, N'') AS varbinary(800)));

        SELECT @mapId = lake_map_id FROM dbo.lake_map
        WHERE lake_map_ownerid = @lake_id AND lake_map_hash = @newHash;

        IF @mapId IS NULL
        BEGIN
            INSERT INTO dbo.lake_map
                ( lake_map_ownerid, lake_map_pic, lake_map_source, lake_map_author,
                  lake_map_link, lake_map_label, lake_map_location, lake_map_lat, lake_map_lon,
                  lake_map_type, lake_map_kind, lake_map_tag, lake_map_hash, lake_map_stamp )
            VALUES
                ( @lake_id, ISNULL(@image, 0x), @source, @author,
                  @link, @label, @location, @lat, @lon,
                  @type, @kind, @tag, @newHash, @stamp );
            SET @mapId = SCOPE_IDENTITY();
        END
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity,
           ERROR_STATE() AS ErrorState, ERROR_PROCEDURE() AS ErrorProcedure,
           ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_fish_document' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_fish_document
GO

/******
 * Used by ~/Editor/FishEditor.aspx to attach (or replace) the single downloadable PDF document
 * of a fish species. ONE document per fish: any existing row for @fish_id is deleted first, then
 * the new bytes are inserted, so re-uploading simply replaces the old file.
 *
 *    @fish_id   uniqueidentifier  - the owning fish species guid
 *    @image     varbinary(max)    - the file bytes
 *    @label     nvarchar          - original file name (drives the download filename)
 *
 *  Usage:
 *      EXEC sp_add_fish_document '58FC0EFC-3728-4A7E-9622-43C9747078E8', 0x255044462D, N'guide.pdf'
 */
CREATE PROCEDURE [dbo].[sp_add_fish_document]
    @fish_id uniqueidentifier, @image varbinary(max), @label nvarchar(256)
AS
SET NOCOUNT ON
BEGIN TRY
    IF @fish_id IS NOT NULL AND @image IS NOT NULL
    BEGIN
        DELETE FROM dbo.fish_document WHERE fish_id = @fish_id;

        INSERT INTO dbo.fish_document ( fish_id, fish_document_pic, fish_document_label, fish_document_stamp )
        VALUES ( @fish_id, @image, @label, GETUTCDATE() );
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity,
           ERROR_STATE() AS ErrorState, ERROR_PROCEDURE() AS ErrorProcedure,
           ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_del_fish_document' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_del_fish_document
GO

/******
 * Used by ~/Editor/FishEditor.aspx to remove the PDF document attached to a fish species.
 *    @fish_id   uniqueidentifier  - the owning fish species guid
 */
CREATE PROCEDURE [dbo].[sp_del_fish_document]
    @fish_id uniqueidentifier
AS
SET NOCOUNT ON
BEGIN TRY
    IF @fish_id IS NOT NULL
        DELETE FROM dbo.fish_document WHERE fish_id = @fish_id;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity,
           ERROR_STATE() AS ErrorState, ERROR_PROCEDURE() AS ErrorProcedure,
           ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_lake_image' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_lake_image
GO

/******
 * Used by ~/Editor/LakeEditor.aspx (btnBriefUpload_Click) to attach a PHOTO to a water body.
 * A water body can own MANY photos (gallery); the relationship is on the row (lake_image_ownerid).
 * Dedup is GLOBAL by picture hash: UK_lake_image is UNIQUE on lake_image_hash ALONE, so the same
 * image is stored once across the whole table. Re-uploading a picture already stored (for this OR
 * any other owner) is therefore a silent no-op instead of a duplicate-key error that would abort
 * the upload batch and get logged.
 *
 *    @lake_id  uniqueidentifier - owning water body (lake/river) guid
 *    @image    varbinary(max)   - the (already resized) picture bytes
 *    @source   nvarchar         - source caption
 *    @author   nvarchar         - photo credit / author
 *    @link     nvarchar         - external link shown with the caption
 *    @hash     varbinary(256)   - hash of @image, computed by the caller (MD5 today)
 *    @stamp    datetime2        - upload timestamp
 *
 * Returns ONE row: lake_image_id (existing or new), inserted (1 = a new row was added, 0 = dup).
 *
 *  Usage:
 *      EXEC sp_add_lake_image 'fc0d917b-d053-11d8-92e2-080020a0f4c9', 0xFFD8, N'src', N'author', N'http://x', 0x1234, '2026-01-01'
 */
CREATE PROCEDURE [dbo].[sp_add_lake_image]
    @lake_id uniqueidentifier, @image varbinary(max),
    @source nvarchar(255), @author nvarchar(255), @link nvarchar(256),
    @hash varbinary(256), @stamp datetime2
AS
SET NOCOUNT ON
BEGIN TRY
    DECLARE @imgId int = NULL;
    DECLARE @inserted bit = 0;

    IF @lake_id IS NOT NULL AND @image IS NOT NULL AND @hash IS NOT NULL
    BEGIN
        -- UK_lake_image is UNIQUE on lake_image_hash (global), so a picture is stored once.
        SELECT @imgId = lake_image_id FROM dbo.lake_image WHERE lake_image_hash = @hash;

        IF @imgId IS NULL
        BEGIN
            -- lake_image_source/author/link are NOT NULL: coalesce blanks so a missing caption
            -- never turns a valid upload into a constraint failure.
            INSERT INTO dbo.lake_image
                ( lake_image_ownerid, lake_image_pic, lake_image_source, lake_image_author,
                  lake_image_link, lake_image_hash, lake_image_stamp )
            VALUES
                ( @lake_id, @image, ISNULL(@source, N''), ISNULL(@author, N''),
                  ISNULL(@link, N''), @hash, @stamp );
            SET @imgId = SCOPE_IDENTITY();
            SET @inserted = 1;
        END
    END

    SELECT @imgId AS lake_image_id, @inserted AS inserted;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_SEVERITY() AS ErrorSeverity,
           ERROR_STATE() AS ErrorState, ERROR_PROCEDURE() AS ErrorProcedure,
           ERROR_LINE() AS ErrorLine, ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_PlotSource' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_PlotSource
GO

-- exec sp_PlotSource 123, '2CFFB500-3E59-4120-9460-055856E9AC5C'
CREATE procedure dbo.sp_PlotSource @sid int, @fish varchar(64)
as
BEGIN TRY  
  SET NOCOUNT ON
  DECLARE @rst TABLE (dt datetime, tm float default(0), lvl float default(0), prc float default(0), dis float default(0));
  DECLARE @line varchar(max) = '?([';

  DECLARE @start date = DATEADD( DAY, -10, GETDATE());
  DECLARE @end date = DATEADD( DAY,  10, GETDATE());
  DECLARE @mli varchar(64), @WaterStation uniqueidentifier;
  SELECT TOP 1 @mli = MLI FROM WaterStation WHERE sid = @sid;
  INSERT INTO @rst (dt) SELECT * from dbo.GetDatePeriod( @start, @end );

  UPDATE t SET t.tm = tmHigh, t.prc = f.rain_today FROM @rst t JOIN weather_Forecast f ON (f.dt = t.dt) WHERE f.mli = @mli;
  UPDATE t SET t.lvl = elevation FROM @rst t JOIN WaterData f ON CAST(f.stamp AS DATE) = t.dt 
    WHERE f.mli = @mli and ( elevation is not null OR discharge is not null);

  SELECT @line = @line + '[Date.UTC(' + REPLACE(CONVERT(DATE, dt, 126), '-', ',') + '),' + CAST(tm AS varchar(16)) + '],' FROM @rst ORDER BY dt ASC
  SET @line = LEFT(@line, LEN(@line)-1) + ']);'

  SELECT @line
  RETURN
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
---------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_update_fish_zoo' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_update_fish_zoo
GO

CREATE PROCEDURE dbo.sp_update_fish_zoo @fish_id uniqueidentifier, @locked bit, @editor uniqueidentifier
   , @max_length float, @max_weight float, @avg_length float, @avg_weight float, @natural_color int, @longevity int
   , @fin nvarchar(max), @body nvarchar(max), @counts nvarchar(max), @shape nvarchar(max), @em nvarchar(max), @im nvarchar(max)
   
AS
SET NOCOUNT ON
BEGIN TRY  
  if @fish_Id IS NOT NULL 
  BEGIN
    DECLARE @rowcnt int = 0
    IF NOT EXISTS (SELECT * FROM dbo.fish_zoo WHERE fish_Id = @fish_Id)
    BEGIN
        INSERT INTO dbo.fish_zoo( fish_id, fish_max_length, fish_avg_length, fish_max_weight, fish_avg_weight
            , natural_color, longevity, fin, body, counts, shape, external_morphology, internal_morphology  )
         VALUES (@fish_Id, @max_length, @avg_length, @max_weight, @avg_weight, @natural_color, @longevity, @fin, @body, @counts, @shape, @em, @im );
        SET @rowcnt = @@ROWCOUNT
    END
    ELSE
    BEGIN
        UPDATE dbo.fish_zoo SET fish_max_length=@max_length, fish_avg_length=@avg_length, fish_max_weight=@max_weight, fish_avg_weight=@avg_weight
          , natural_color = @natural_color, longevity = @longevity, fin = @fin
           , body = @body, counts = @counts, shape = @shape, external_morphology = @em, internal_morphology = @im 
          WHERE fish_Id = @fish_Id
        SET @rowcnt = @@ROWCOUNT
    END
    IF @rowcnt > 1
        UPDATE dbo.fish Set stamp = GETUTCDATE() WHERE fish_id =  @fish_Id;
  END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_lake' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_lake
GO
-- to add new lakes/rivers
CREATE PROCEDURE dbo.sp_add_lake @lake_name sysname, @type int, @country char(2), @state char(2), @county nvarchar(64)
AS
SET NOCOUNT ON
BEGIN TRY  
    set @lake_name = RTRIM(LTRIM(@lake_name))
    insert into lake (lake_id, [locType], [lake_name], alt_name ) values (newid(), @type, @lake_name, null)

    declare @lake_id uniqueidentifier = (select TOP 1 lake_id from lake where lake_name = @lake_name ORDER BY stamp DESC);
    update Tributaries set country=@country, state=@state , county = @county  where side = 16 AND [Main_Lake_id]=Lake_id 
        and Lake_id = @lake_id ;
    select @lake_id, (select lake_name from lake where lake_id=@lake_id);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_save_lake' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_save_lake
GO
-- declare @link_list xml = CAST(N'<a>0a194de0-2892-e811-9104-00155d007b12</a><a>4f174d22-1c54-43ec-8f0d-eb8e80b7b25a</a><a>e31e6d05-fe6c-48b2-9b66-f36423812d61</a>' AS XML);
-- to link lakes/rivers
-- exec sp_save_lake '64cf30df-2892-e811-9104-00155d007b12'
CREATE PROCEDURE dbo.sp_save_lake @lake_id uniqueidentifier
AS
SET NOCOUNT ON
BEGIN TRY  
    IF @lake_id = NULL
        RETURN
    IF EXISTS (SELECT * FROM Tributaries WHERE lake_id = main_lake_id AND lake_id = @lake_id AND side = 16 )  -- source
    BEGIN
        DECLARE @source uniqueidentifier = (SELECT source FROM Lake WHERE lake_id = @lake_id );
        IF @source IS NOT NULL
        BEGIN
            UPDATE Tributaries SET main_lake_id = @source WHERE main_lake_id = lake_id AND lake_id = @lake_id AND side = 16 

            IF NOT EXISTS( SELECT * FROM Tributaries WHERE main_lake_id <> lake_id AND lake_id = @source )
            BEGIN
                INSERT INTO Tributaries (main_lake_id, lake_id, side) VALUES (@source, @lake_id, 64)    -- unknown status
            END
        END
    END ELSE
    BEGIN       -- INSERT instance
        INSERT INTO Tributaries (main_lake_id, lake_id, side) VALUES (@source, @lake_id, 16)
    END
    IF NOT EXISTS (SELECT * FROM Tributaries WHERE lake_id = main_lake_id AND lake_id = @lake_id AND side = 32 )  -- mouth
    BEGIN
        INSERT INTO Tributaries (main_lake_id, lake_id, side) VALUES (@source, @lake_id, 32)
    END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_add_lake_shape' AND xtype = 'P')
    DROP PROCEDURE dbo.sp_add_lake_shape
GO
CREATE PROCEDURE sp_add_lake_shape @lake_id uniqueidentifier, @sourceLat float, @sourceLon float, @mouthLat float, @mouthLon float, @state char(2), @location nvarchar(255), @shape nvarchar(max), @num int
WITH EXEC AS CALLER
AS
BEGIN TRY  
  BEGIN TRANSACTION;  
  SET NOCOUNT ON;
  UPDATE Tributaries SET lat = @sourceLat, lon = @sourceLon, [State]=@state, Country='CA' WHERE ( lat IS NULL OR lon IS NULL ) AND side IN (16, 32) AND Lake_id = @lake_id AND Lake_id = Main_Lake_id
  SET @location = RTRIM(@location)

  IF LEN(@location) > 1
      UPDATE Tributaries SET [location] = @location WHERE [location] IS NULL AND side IN (16, 32) AND Lake_id = @lake_id AND Lake_id = Main_Lake_id

  IF DATALENGTH(@shape) > 1 AND @num > 2
  BEGIN
    insert into Lake_Shape (lake_id, Lake_Shape_stamp, Lake_Shape_shape, Lake_Shape_hash)
        SELECT lake_id, getdate(), Lake_Shape_shape, CAST(HashBytes('MD5', Lake_Shape_shape.ToString()) as bigint)
            FROM (SELECT @lake_id AS lake_id, geography::STGeomFromText( 'LINESTRING('+ @shape + ')' , 4326) AS Lake_Shape_shape)x
  END
  COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0  
        ROLLBACK TRANSACTION;  
    declare @ErrorMessage sysname = ERROR_MESSAGE(), @ErrorSeverity int = ERROR_SEVERITY(), @ErrorState int = ERROR_STATE();
    SELECT ERROR_NUMBER()    AS ErrorNumber,    @ErrorSeverity, @ErrorState, ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE() AS ErrorLine,  @ErrorMessage;
    RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
END CATCH;     
GO
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spAddFish' AND type = 'P')
    DROP PROCEDURE dbo.spAddFish
GO
-- EXEC spAddFish '0c5d1cc6-849c-20c3-cf02-6258e4e37990', 734, '', 0
-- SELECT * FROM fish where sid = 734
CREATE PROCEDURE spAddFish @lakeid uniqueidentifier, @fishid int, @link nvarchar(512), @trustLevel int, @status tinyint, @method nvarchar(max)
AS
SET NOCOUNT ON
BEGIN TRY
   DECLARE @probability int = 10
   IF @trustLevel = 0  SET @probability = 100
   IF @trustLevel = 1  SET @probability = 80
   IF @trustLevel = 2  SET @probability = 65
   IF @trustLevel = 3  SET @probability = 30

   IF LEN(ISNULL(@link, '')) = 0 SET @link = (SELECT TOP 1 link FROM lake_fish ORDER BY created DESC)
 
  INSERT INTO lake_fish( Lake_id,fish_id,link,probability,probability_source_type,created, status, method ) 
	SELECT @lakeid, fish_id, @link, @probability, @trustLevel, GETDATE(), @status, @method FROM fish f WHERE sid = @fishid
		AND NOT EXISTS (SELECT * FROM lake_fish l WHERE lake_id = @lakeid AND f.fish_id = l.fish_id)
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Called by: docapi RiverController (PATCH /api/v1/river/fish/{guid}) via JdbcRiverFishCommandRepository,
--   the write counterpart of dbo.fn_lake_fishing_json -- itself modeled on the "Add" form of
--   FishTracker.Editor.EditLakeFish.aspx (AddFishToLake). Upserts a BATCH of species assignments for one
--   water body in a single call, writing the same fields the Add form writes: source link, Trust Level
--   (probability / probability_source_type), catch/release year (last_catch, year-only), and the
--   per-water-body conservation status bitmask.
--
--   @fish is a JSON array: [{"fishId":"<guid>","link":"<url>","trustLevel":0-4,"year":2024,"status":0}, ...]
--   trustLevel: 0 high priority (->probability 100), 1 site owner (80), 2 paid fisher (65),
--     3 unknown source (30), anything else/omitted (10) -- mirrors ddlTrustLevel on EditLakeFish.aspx.
--   status: bitmask, 1 at risk, 2 invasive, 4 special concern, 8 threatened, 16 non-native (0 = normal).
--
--   Deliberately conservative about what it overwrites -- this endpoint is for filling in NEW species
--   or enriching ones still missing a source, never for silently clobbering already-sourced data:
--     - fish not yet assigned to this lake                       -> INSERT,  action 'inserted'
--     - fish already assigned with an EMPTY/NULL link             -> UPDATE,  action 'updated'
--     - fish already assigned with a NON-EMPTY link                -> left alone, action 'skipped'
--     - fishId is a well-formed guid but not in dbo.fish           -> action 'unknown_fish'
--     - fishId is missing/not a guid at all                        -> action 'invalid_fish_id'
--   Unknown @lake_id -> a single NULL row (results IS NULL), same "not found" contract as
--   dbo.fn_lake_fishing_json / dbo.fn_lake_view_json.
--
--     EXEC dbo.sp_lake_fish_upsert_batch 'a55caadf-2892-e811-9104-00155d007b12',
--          N'[{"fishId":"a85ebf22-4ab9-4a91-a14a-cef6c8e64d97","link":"http://example.com","trustLevel":0,"year":2024,"status":0}]';
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_lake_fish_upsert_batch' AND type = 'P')
    DROP PROCEDURE dbo.sp_lake_fish_upsert_batch
GO
CREATE PROCEDURE dbo.sp_lake_fish_upsert_batch
    @lake_id uniqueidentifier,
    @fish    nvarchar(max)
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake_id)
    BEGIN
        SELECT CAST(NULL AS nvarchar(max)) AS results;
        RETURN;
    END

    DECLARE @items TABLE (
        rn         int IDENTITY(1,1) PRIMARY KEY,
        rawFishId  nvarchar(64) NULL,
        fishId     uniqueidentifier NULL,
        link       nvarchar(max) NULL,
        trustLevel int NULL,
        [year]     int NULL,
        status     tinyint NULL
    );

    INSERT INTO @items (rawFishId, fishId, link, trustLevel, [year], status)
    SELECT
        JSON_VALUE(value, '$.fishId'),
        TRY_CONVERT(uniqueidentifier, JSON_VALUE(value, '$.fishId')),
        NULLIF(LTRIM(RTRIM(JSON_VALUE(value, '$.link'))), ''),
        TRY_CONVERT(int, JSON_VALUE(value, '$.trustLevel')),
        TRY_CONVERT(int, JSON_VALUE(value, '$.year')),
        TRY_CONVERT(tinyint, JSON_VALUE(value, '$.status'))
    FROM OPENJSON(@fish);

    DECLARE @results TABLE (rn int, fishId nvarchar(64), fishName nvarchar(256), action varchar(20));

    DECLARE @rn int, @rawFishId nvarchar(64), @fishId uniqueidentifier, @link nvarchar(max),
            @trustLevel int, @year int, @status tinyint, @fishName nvarchar(256),
            @rowExists bit, @existingLink nvarchar(max), @probability tinyint;

    DECLARE items_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT rn, rawFishId, fishId, link, trustLevel, [year], status FROM @items ORDER BY rn;
    OPEN items_cursor;
    FETCH NEXT FROM items_cursor INTO @rn, @rawFishId, @fishId, @link, @trustLevel, @year, @status;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @fishName = NULL;
        SET @rowExists = 0;
        SET @existingLink = NULL;

        IF @fishId IS NULL
        BEGIN
            INSERT INTO @results (rn, fishId, fishName, action) VALUES (@rn, @rawFishId, NULL, 'invalid_fish_id');
        END
        ELSE
        BEGIN
            SELECT @fishName = fish_name FROM dbo.fish WHERE fish_id = @fishId;

            IF @fishName IS NULL
            BEGIN
                INSERT INTO @results (rn, fishId, fishName, action)
                VALUES (@rn, CONVERT(varchar(36), @fishId), NULL, 'unknown_fish');
            END
            ELSE
            BEGIN
                SELECT TOP 1 @existingLink = link, @rowExists = 1
                FROM dbo.lake_fish WHERE lake_id = @lake_id AND fish_id = @fishId
                ORDER BY created DESC;

                SET @probability = CASE ISNULL(@trustLevel, 4)
                                        WHEN 0 THEN 100 WHEN 1 THEN 80 WHEN 2 THEN 65 WHEN 3 THEN 30 ELSE 10 END;

                IF @rowExists = 0
                BEGIN
                    INSERT INTO dbo.lake_fish
                        (Lake_id, fish_id, link, probability, probability_source_type, created, last_catch, status)
                    VALUES
                        (@lake_id, @fishId, @link, @probability, ISNULL(@trustLevel, 0), GETUTCDATE(),
                         CASE WHEN @year IS NOT NULL THEN DATEFROMPARTS(@year, 1, 1) ELSE NULL END,
                         ISNULL(@status, 0));

                    INSERT INTO @results (rn, fishId, fishName, action)
                    VALUES (@rn, CONVERT(varchar(36), @fishId), @fishName, 'inserted');
                END
                ELSE IF LTRIM(RTRIM(ISNULL(@existingLink, ''))) = ''
                BEGIN
                    UPDATE dbo.lake_fish
                    SET link = @link,
                        probability = @probability,
                        probability_source_type = ISNULL(@trustLevel, probability_source_type),
                        created = GETUTCDATE(),
                        last_catch = CASE WHEN @year IS NOT NULL THEN DATEFROMPARTS(@year, 1, 1) ELSE last_catch END,
                        status = ISNULL(@status, status)
                    WHERE lake_id = @lake_id AND fish_id = @fishId;

                    INSERT INTO @results (rn, fishId, fishName, action)
                    VALUES (@rn, CONVERT(varchar(36), @fishId), @fishName, 'updated');
                END
                ELSE
                BEGIN
                    INSERT INTO @results (rn, fishId, fishName, action)
                    VALUES (@rn, CONVERT(varchar(36), @fishId), @fishName, 'skipped');
                END
            END
        END

        FETCH NEXT FROM items_cursor INTO @rn, @rawFishId, @fishId, @link, @trustLevel, @year, @status;
    END
    CLOSE items_cursor;
    DEALLOCATE items_cursor;

    SELECT ISNULL((
        SELECT fishId, fishName, action
        FROM @results
        ORDER BY rn
        FOR JSON PATH
    ), N'[]') AS results;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Called by: docapi RiverController (PATCH /api/v1/river/description/{guid}) via
--   JdbcRiverDescriptionCommandRepository -- the write counterpart of dbo.fn_lake_view_json /
--   dbo.fn_lake_description_json, modeled on the "General" tab of Editor/LakeEditor.aspx
--   (SaveLakeGeneral). A JSON MERGE PATCH: only keys present in @patch are touched, so a caller can
--   change one field without re-sending the whole document; sending a key with JSON null clears it.
--
--   Deliberately excludes the identity/linkage fields LakeEditor.aspx shows read-only in this same
--   spot -- lake_name, the lake_id itself, and source/mouth (both the resolved name AND the id) --
--   plus isFish (a derived cache no proc may write, see TR_insLakes_Fish/TR_delLakes_Fish) and mli
--   (a WaterStation linkage, a different kind of edit entirely). Any of
--   lakeName/source/sourceId/mouth/mouthId present in @patch is reported back as "protected", not
--   silently dropped, so a caller knows it did not take effect.
--
--   noFish honors the same rule LakeEditor.aspx enforces client-side: it cannot be set to true while
--   the lake has any assigned species (dbo.lake_fish) -- reported back as "ignored" rather than
--   silently applied or erroring the whole request.
--
--     EXEC dbo.sp_lake_description_update 'a55caadf-2892-e811-9104-00155d007b12',
--          N'{"description":"A small headwater stream.","link":"http://example.com","reviewed":true}';
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_lake_description_update' AND type = 'P')
    DROP PROCEDURE dbo.sp_lake_description_update
GO
CREATE PROCEDURE dbo.sp_lake_description_update
    @lake_id uniqueidentifier,
    @patch   nvarchar(max)
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake_id)
    BEGIN
        SELECT CAST(NULL AS nvarchar(max)) AS results;
        RETURN;
    END
    IF @patch IS NULL OR ISJSON(@patch) = 0
    BEGIN
        SELECT (SELECT CONVERT(varchar(36), @lake_id) AS lakeId,
                       JSON_QUERY('[]') AS updated, JSON_QUERY('[]') AS ignored,
                       JSON_QUERY('[{"field":"$","reason":"body is not well-formed JSON"}]') AS protectedFields
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    -- SQL Server does not allow a subquery inside an inline DECLARE @v = ... initializer, so @hasFish
    -- is declared then assigned in a separate SET.
    DECLARE @hasFish bit;
    SET @hasFish = CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.lake_fish WHERE lake_id = @lake_id)
                              THEN 1 ELSE 0 END AS bit);
    DECLARE @noFishGiven bit = CASE WHEN JSON_PATH_EXISTS(@patch, '$.noFish') = 1 THEN 1 ELSE 0 END;
    DECLARE @noFishValue bit = TRY_CONVERT(bit, JSON_VALUE(@patch, '$.noFish'));
    DECLARE @noFishBlocked bit = CASE WHEN @noFishGiven = 1 AND @noFishValue = 1 AND @hasFish = 1
                                       THEN 1 ELSE 0 END;

    UPDATE dbo.lake SET
        alt_name         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.altName')       = 1 THEN JSON_VALUE(@patch, '$.altName')       ELSE alt_name END,
        [native]         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.nativeName')    = 1 THEN JSON_VALUE(@patch, '$.nativeName')    ELSE [native] END,
        french_name      = CASE WHEN JSON_PATH_EXISTS(@patch, '$.french')        = 1 THEN JSON_VALUE(@patch, '$.french')        ELSE french_name END,
        link             = CASE WHEN JSON_PATH_EXISTS(@patch, '$.link')          = 1 THEN JSON_VALUE(@patch, '$.link')          ELSE link END,
        locType          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.type')          = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.type'))          ELSE locType END,
        length           = CASE WHEN JSON_PATH_EXISTS(@patch, '$.length_km')     = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.length_km'))     ELSE length END,
        width            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.width_km')      = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.width_km'))      ELSE width END,
        Shoreline        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.shoreline_km')  = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.shoreline_km'))  ELSE Shoreline END,
        depth            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.maxDepth_m')    = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.maxDepth_m'))    ELSE depth END,
        Volume           = CASE WHEN JSON_PATH_EXISTS(@patch, '$.volume_km3')    = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.volume_km3'))    ELSE Volume END,
        surface          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.surface_km2')   = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.surface_km2'))   ELSE surface END,
        Discharge        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.discharge_m3s') = 1 THEN JSON_VALUE(@patch, '$.discharge_m3s') ELSE Discharge END,
        basin            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.basin_km2')     = 1 THEN JSON_VALUE(@patch, '$.basin_km2')     ELSE basin END,
        watershield      = CASE WHEN JSON_PATH_EXISTS(@patch, '$.watershield_km2') = 1 THEN JSON_VALUE(@patch, '$.watershield_km2') ELSE watershield END,
        drainage         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.drainage')      = 1 THEN JSON_VALUE(@patch, '$.drainage')      ELSE drainage END,
        CGNDB            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.cgndb')         = 1 THEN JSON_VALUE(@patch, '$.cgndb')         ELSE CGNDB END,
        lake_road_access = CASE WHEN JSON_PATH_EXISTS(@patch, '$.roadAccess')    = 1 THEN JSON_VALUE(@patch, '$.roadAccess')    ELSE lake_road_access END,
        is_fishing_prohibited = CASE WHEN JSON_PATH_EXISTS(@patch, '$.fishingProhibited') = 1 THEN TRY_CONVERT(bit, JSON_VALUE(@patch, '$.fishingProhibited')) ELSE is_fishing_prohibited END,
        isolated         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.isolated')      = 1 THEN TRY_CONVERT(bit, JSON_VALUE(@patch, '$.isolated'))      ELSE isolated END,
        noFish           = CASE WHEN @noFishGiven = 1 AND @noFishBlocked = 0 THEN @noFishValue ELSE noFish END,
        reviewed         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.reviewed')      = 1 THEN TRY_CONVERT(bit, JSON_VALUE(@patch, '$.reviewed'))      ELSE reviewed END,
        descript         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.description')   = 1 THEN JSON_VALUE(@patch, '$.description')   ELSE descript END
    WHERE lake_id = @lake_id;

    DECLARE @updated TABLE (field nvarchar(50));
    INSERT INTO @updated (field)
    SELECT v.f FROM (VALUES
        ('altName'),('nativeName'),('french'),('link'),('type'),('length_km'),('width_km'),
        ('shoreline_km'),('maxDepth_m'),('volume_km3'),('surface_km2'),('discharge_m3s'),
        ('basin_km2'),('watershield_km2'),('drainage'),('cgndb'),('roadAccess'),
        ('fishingProhibited'),('isolated'),('reviewed'),('description')
    ) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;
    IF @noFishGiven = 1 AND @noFishBlocked = 0
        INSERT INTO @updated (field) VALUES ('noFish');

    DECLARE @ignored TABLE (field nvarchar(50), reason nvarchar(200));
    IF @noFishBlocked = 1
        INSERT INTO @ignored (field, reason)
        VALUES ('noFish', 'lake has assigned species -- No Fish cannot be set while species are assigned');

    DECLARE @protectedFields TABLE (field nvarchar(50), reason nvarchar(200));
    INSERT INTO @protectedFields (field, reason)
    SELECT v.f, 'not editable through this endpoint'
    FROM (VALUES ('lakeName'),('guid'),('source'),('sourceId'),('mouth'),('mouthId')) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;

    SELECT (
        SELECT
            CONVERT(varchar(36), @lake_id) AS lakeId,
            JSON_QUERY(ISNULL((SELECT field FROM @updated FOR JSON PATH), '[]')) AS updated,
            JSON_QUERY(ISNULL((SELECT field, reason FROM @ignored FOR JSON PATH), '[]')) AS ignored,
            JSON_QUERY(ISNULL((SELECT field, reason FROM @protectedFields FOR JSON PATH), '[]')) AS protectedFields
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS results;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Called by: docapi RiverController (PATCH /api/v1/river/source/{guid}) via
--   JdbcRiverLinkCommandRepository -- the write counterpart of dbo.fn_lake_source_json, modeled on the
--   Source tab of Editor/EditLakeLink.aspx?Type=16 (ButtonSubmit_Click). A JSON MERGE PATCH against the
--   single dbo.Tributaries row where Main_Lake_id = @lake_id AND side = 16 (at most one such row exists
--   -- see UK_Tributaries_Source): only keys present in @patch are touched, a key holding JSON null
--   clears that field.
--
--   Deliberately excludes every identity/linkage field EditLakeLink.aspx shows read-only in this exact
--   spot -- lakeName, guid (the main water body itself), and the linked point's own pointName/pointId
--   -- plus the row id and stamp, which are not user-editable fields at all. Any of those keys present
--   in @patch is reported back as "protected", not silently dropped, so a caller knows it did not take
--   effect. Relinking the source to a different water body (pointId) stays a UI-only action, same as
--   the identity fields on sp_lake_description_update.
--
--     EXEC dbo.sp_lake_source_update 'a55caadf-2892-e811-9104-00155d007b12',
--          N'{"lat":52.1,"lon":-95.4,"elevation":355,"description":"Headwater creek."}';
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_lake_source_update' AND type = 'P')
    DROP PROCEDURE dbo.sp_lake_source_update
GO
CREATE PROCEDURE dbo.sp_lake_source_update
    @lake_id uniqueidentifier,
    @patch   nvarchar(max)
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake_id)
    BEGIN
        SELECT CAST(NULL AS nvarchar(max)) AS results;
        RETURN;
    END
    IF @patch IS NULL OR ISJSON(@patch) = 0
    BEGIN
        SELECT (SELECT CONVERT(varchar(36), @lake_id) AS lakeId,
                       JSON_QUERY('[]') AS updated, JSON_QUERY('[]') AS ignored,
                       JSON_QUERY('[{"field":"$","reason":"body is not well-formed JSON"}]') AS protectedFields
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    UPDATE dbo.Tributaries SET
        lat          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.lat')          = 1 THEN TRY_CONVERT(float, JSON_VALUE(@patch, '$.lat'))       ELSE lat END,
        lon          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.lon')          = 1 THEN TRY_CONVERT(float, JSON_VALUE(@patch, '$.lon'))       ELSE lon END,
        elevation    = CASE WHEN JSON_PATH_EXISTS(@patch, '$.elevation')    = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.elevation'))   ELSE elevation END,
        Country      = CASE WHEN JSON_PATH_EXISTS(@patch, '$.country')      = 1 THEN JSON_VALUE(@patch, '$.country')                       ELSE Country END,
        State        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.state')       = 1 THEN JSON_VALUE(@patch, '$.state')                         ELSE State END,
        county       = CASE WHEN JSON_PATH_EXISTS(@patch, '$.county')      = 1 THEN JSON_VALUE(@patch, '$.county')                        ELSE county END,
        city         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.city')        = 1 THEN JSON_VALUE(@patch, '$.city')                          ELSE city END,
        district     = CASE WHEN JSON_PATH_EXISTS(@patch, '$.district')    = 1 THEN JSON_VALUE(@patch, '$.district')                      ELSE district END,
        municipality = CASE WHEN JSON_PATH_EXISTS(@patch, '$.municipality') = 1 THEN JSON_VALUE(@patch, '$.municipality')                 ELSE municipality END,
        region       = CASE WHEN JSON_PATH_EXISTS(@patch, '$.region')      = 1 THEN JSON_VALUE(@patch, '$.region')                        ELSE region END,
        zone         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.zone')        = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.zone'))        ELSE zone END,
        coast        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.coast')       = 1 THEN JSON_VALUE(@patch, '$.coast')                         ELSE coast END,
        location     = CASE WHEN JSON_PATH_EXISTS(@patch, '$.location')    = 1 THEN JSON_VALUE(@patch, '$.location')                      ELSE location END,
        descript     = CASE WHEN JSON_PATH_EXISTS(@patch, '$.description') = 1 THEN JSON_VALUE(@patch, '$.description')                   ELSE descript END
    WHERE Main_Lake_id = @lake_id AND side = 16;

    DECLARE @updated TABLE (field nvarchar(50));
    INSERT INTO @updated (field)
    SELECT v.f FROM (VALUES
        ('lat'),('lon'),('elevation'),('country'),('state'),('county'),('city'),
        ('district'),('municipality'),('region'),('zone'),('coast'),('location'),('description')
    ) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;

    DECLARE @protectedFields TABLE (field nvarchar(50), reason nvarchar(200));
    INSERT INTO @protectedFields (field, reason)
    SELECT v.f, 'not editable through this endpoint'
    FROM (VALUES ('guid'),('lakeName'),('id'),('pointId'),('pointName'),('stamp')) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;

    SELECT (
        SELECT
            CONVERT(varchar(36), @lake_id) AS lakeId,
            JSON_QUERY(ISNULL((SELECT field FROM @updated FOR JSON PATH), '[]')) AS updated,
            JSON_QUERY('[]') AS ignored,
            JSON_QUERY(ISNULL((SELECT field, reason FROM @protectedFields FOR JSON PATH), '[]')) AS protectedFields
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS results;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Called by: docapi RiverController (PATCH /api/v1/river/mouth/{guid}) via
--   JdbcRiverLinkCommandRepository -- same shape as dbo.sp_lake_source_update, but targets the
--   dbo.Tributaries row where Main_Lake_id = @lake_id AND side = 32 (the Mouth tab of
--   Editor/EditLakeLink.aspx?Type=32; at most one such row exists -- see UK_Tributaries_Mouth).
--
--     EXEC dbo.sp_lake_mouth_update 'a55caadf-2892-e811-9104-00155d007b12',
--          N'{"lat":51.9,"lon":-94.8,"elevation":198}';
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_lake_mouth_update' AND type = 'P')
    DROP PROCEDURE dbo.sp_lake_mouth_update
GO
CREATE PROCEDURE dbo.sp_lake_mouth_update
    @lake_id uniqueidentifier,
    @patch   nvarchar(max)
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake_id)
    BEGIN
        SELECT CAST(NULL AS nvarchar(max)) AS results;
        RETURN;
    END
    IF @patch IS NULL OR ISJSON(@patch) = 0
    BEGIN
        SELECT (SELECT CONVERT(varchar(36), @lake_id) AS lakeId,
                       JSON_QUERY('[]') AS updated, JSON_QUERY('[]') AS ignored,
                       JSON_QUERY('[{"field":"$","reason":"body is not well-formed JSON"}]') AS protectedFields
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    UPDATE dbo.Tributaries SET
        lat          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.lat')          = 1 THEN TRY_CONVERT(float, JSON_VALUE(@patch, '$.lat'))       ELSE lat END,
        lon          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.lon')          = 1 THEN TRY_CONVERT(float, JSON_VALUE(@patch, '$.lon'))       ELSE lon END,
        elevation    = CASE WHEN JSON_PATH_EXISTS(@patch, '$.elevation')    = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.elevation'))   ELSE elevation END,
        Country      = CASE WHEN JSON_PATH_EXISTS(@patch, '$.country')      = 1 THEN JSON_VALUE(@patch, '$.country')                       ELSE Country END,
        State        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.state')       = 1 THEN JSON_VALUE(@patch, '$.state')                         ELSE State END,
        county       = CASE WHEN JSON_PATH_EXISTS(@patch, '$.county')      = 1 THEN JSON_VALUE(@patch, '$.county')                        ELSE county END,
        city         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.city')        = 1 THEN JSON_VALUE(@patch, '$.city')                          ELSE city END,
        district     = CASE WHEN JSON_PATH_EXISTS(@patch, '$.district')    = 1 THEN JSON_VALUE(@patch, '$.district')                      ELSE district END,
        municipality = CASE WHEN JSON_PATH_EXISTS(@patch, '$.municipality') = 1 THEN JSON_VALUE(@patch, '$.municipality')                 ELSE municipality END,
        region       = CASE WHEN JSON_PATH_EXISTS(@patch, '$.region')      = 1 THEN JSON_VALUE(@patch, '$.region')                        ELSE region END,
        zone         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.zone')        = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.zone'))        ELSE zone END,
        coast        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.coast')       = 1 THEN JSON_VALUE(@patch, '$.coast')                         ELSE coast END,
        location     = CASE WHEN JSON_PATH_EXISTS(@patch, '$.location')    = 1 THEN JSON_VALUE(@patch, '$.location')                      ELSE location END,
        descript     = CASE WHEN JSON_PATH_EXISTS(@patch, '$.description') = 1 THEN JSON_VALUE(@patch, '$.description')                   ELSE descript END
    WHERE Main_Lake_id = @lake_id AND side = 32;

    DECLARE @updated TABLE (field nvarchar(50));
    INSERT INTO @updated (field)
    SELECT v.f FROM (VALUES
        ('lat'),('lon'),('elevation'),('country'),('state'),('county'),('city'),
        ('district'),('municipality'),('region'),('zone'),('coast'),('location'),('description')
    ) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;

    DECLARE @protectedFields TABLE (field nvarchar(50), reason nvarchar(200));
    INSERT INTO @protectedFields (field, reason)
    SELECT v.f, 'not editable through this endpoint'
    FROM (VALUES ('guid'),('lakeName'),('id'),('pointId'),('pointName'),('stamp')) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;

    SELECT (
        SELECT
            CONVERT(varchar(36), @lake_id) AS lakeId,
            JSON_QUERY(ISNULL((SELECT field FROM @updated FOR JSON PATH), '[]')) AS updated,
            JSON_QUERY('[]') AS ignored,
            JSON_QUERY(ISNULL((SELECT field, reason FROM @protectedFields FOR JSON PATH), '[]')) AS protectedFields
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS results;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Called by: docapi RegulationController (PATCH /api/v1/regulation) via
--   JdbcRegulationCommandRepository -- the write counterpart of Editor/LakeRegulation.aspx
--   (ButtonSubmit_Click / FindExistingRegId). Upserts ONE row of dbo.regulations, matched by the same
--   identity the ASPX page uses to decide Add-vs-Update -- the columns behind the two filtered unique
--   indexes UIX_reg_with_fish / UIX_reg_no_fish:
--     (reg_year, state, zone_id, Lake_id, fish_id, regulations_part, resident_type, regulations_date_start)
--
--   Scope is inferred from which of @lake / @zone are present in @body, exactly like the ASPX page's
--   scope modes (region / zone / water body):
--     lakeId set            -> water-body rule (fishId optional)
--     zoneId set (no lakeId) -> zone rule (fishId optional)
--     neither set            -> region rule: whole-country when stateGiven is omitted, else
--                                province/state-wide (fishId optional either way)
--   lakeId and zoneId are mutually exclusive -- a rule is never both (matches the ASPX's single
--   scope-mode selector). Unlike sp_lake_description_update this is not a partial merge-patch of an
--   existing row: country/state/year/scope identify WHICH row, and every other field it supports is
--   replaced outright on that row (mirrors BindRegParams, which always writes every field from the form).
--
--   Note: dbo.TR_regulations (FOR INSERT) auto-adds the row to lake_fish when a NEW water-body rule
--   also carries a fishId and that pairing isn't already there -- same as it does for a row inserted
--   by the ASPX page. A caller that expects PATCH /api/v1/river/fish/{guid}'s inserted/updated/skipped
--   reporting won't get it for this side effect; it is silent here, exactly as it is in the UI.
--
--     EXEC dbo.sp_regulation_upsert
--          N'{"country":"CA","state":"NL","lakeId":"200d4de0-2892-e811-9104-00155d007b12","year":2026,
--             "fishId":"a35109a0-63ba-4bf5-8a25-2e7e39b74f6e",
--             "link":"https://laws-lois.justice.gc.ca/eng/regulations/SOR-78-443/FullText.html",
--             "text":"Schedule I item 155: Bear Cove River, including Billy''s Pond Brook."}';
--     -- whole-country rule: omit "state" (or send it JSON null) entirely
--     EXEC dbo.sp_regulation_upsert N'{"country":"US","year":2026,"sport":5}';
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_regulation_upsert' AND type = 'P')
    DROP PROCEDURE dbo.sp_regulation_upsert
GO
CREATE PROCEDURE dbo.sp_regulation_upsert
    @body nvarchar(max)
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY
    IF @body IS NULL OR ISJSON(@body) = 0
    BEGIN
        SELECT (SELECT CAST(NULL AS int) AS id, CAST(NULL AS varchar(20)) AS action,
                       N'body is not well-formed JSON' AS [error]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    DECLARE @country char(2)   = ISNULL(JSON_VALUE(@body, '$.country'), N'CA');
    DECLARE @state char(2)     = JSON_VALUE(@body, '$.state');
    DECLARE @year  smallint    = TRY_CONVERT(smallint, JSON_VALUE(@body, '$.year'));
    IF @year IS NULL
    BEGIN
        SELECT (SELECT CAST(NULL AS int) AS id, CAST(NULL AS varchar(20)) AS action,
                       N'year is required' AS [error]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    DECLARE @zone int              = TRY_CONVERT(int, JSON_VALUE(@body, '$.zoneId'));
    DECLARE @lake uniqueidentifier = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@body, '$.lakeId'));
    IF @zone IS NOT NULL AND @lake IS NOT NULL
    BEGIN
        SELECT (SELECT CAST(NULL AS int) AS id, CAST(NULL AS varchar(20)) AS action,
                       N'zoneId and lakeId are mutually exclusive' AS [error]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END
    IF @lake IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake)
    BEGIN
        SELECT (SELECT CAST(NULL AS int) AS id, CAST(NULL AS varchar(20)) AS action,
                       N'lakeId not found' AS [error]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    DECLARE @fish uniqueidentifier = TRY_CONVERT(uniqueidentifier, JSON_VALUE(@body, '$.fishId'));
    IF @fish IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.fish WHERE fish_id = @fish)
    BEGIN
        SELECT (SELECT CAST(NULL AS int) AS id, CAST(NULL AS varchar(20)) AS action,
                       N'fishId not found' AS [error]
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    DECLARE @part            nvarchar(255) = ISNULL(JSON_VALUE(@body, '$.part'), N'');
    DECLARE @resident        tinyint       = ISNULL(TRY_CONVERT(tinyint, JSON_VALUE(@body, '$.residentType')), 0);
    DECLARE @dateStart       date          = TRY_CONVERT(date, JSON_VALUE(@body, '$.dateStart'));
    DECLARE @startText       varchar(64)   = JSON_VALUE(@body, '$.startText');
    DECLARE @dateEnd         date          = TRY_CONVERT(date, JSON_VALUE(@body, '$.dateEnd'));
    DECLARE @endText         varchar(64)   = JSON_VALUE(@body, '$.endText');
    DECLARE @dayFlags        tinyint       = TRY_CONVERT(tinyint, JSON_VALUE(@body, '$.dayFlags'));
    DECLARE @sport           int           = TRY_CONVERT(int, JSON_VALUE(@body, '$.sport'));
    DECLARE @consr           int           = TRY_CONVERT(int, JSON_VALUE(@body, '$.consr'));
    DECLARE @possessionSport int           = TRY_CONVERT(int, JSON_VALUE(@body, '$.possessionSport'));
    DECLARE @possessionConsr int           = TRY_CONVERT(int, JSON_VALUE(@body, '$.possessionConsr'));
    DECLARE @minLengthCm     decimal(5,1)  = TRY_CONVERT(decimal(5,1), JSON_VALUE(@body, '$.minLengthCm'));
    DECLARE @slotMinCm       decimal(5,1)  = TRY_CONVERT(decimal(5,1), JSON_VALUE(@body, '$.slotMinCm'));
    DECLARE @slotMaxCm       decimal(5,1)  = TRY_CONVERT(decimal(5,1), JSON_VALUE(@body, '$.slotMaxCm'));
    DECLARE @slotOverLimit   tinyint       = TRY_CONVERT(tinyint, JSON_VALUE(@body, '$.slotOverLimit'));
    DECLARE @methodFlags     tinyint       = TRY_CONVERT(tinyint, JSON_VALUE(@body, '$.methodFlags'));
    DECLARE @code            int           = TRY_CONVERT(int, JSON_VALUE(@body, '$.code'));
    DECLARE @link            nvarchar(255) = JSON_VALUE(@body, '$.link');
    DECLARE @text            nvarchar(max) = JSON_VALUE(@body, '$.text');

    DECLARE @existingId int;
    SELECT TOP 1 @existingId = id FROM dbo.regulations
    WHERE reg_year = @year AND country = @country
      AND ((@state IS NULL AND state IS NULL) OR state = @state)
      AND ((@zone IS NULL AND zone_id IS NULL) OR zone_id = @zone)
      AND ((@lake IS NULL AND Lake_id IS NULL) OR Lake_id = @lake)
      AND ((@fish IS NULL AND fish_id IS NULL) OR fish_id = @fish)
      AND regulations_part = @part AND resident_type = @resident
      AND ((@dateStart IS NULL AND regulations_date_start IS NULL) OR regulations_date_start = @dateStart);

    DECLARE @action varchar(20);
    IF @existingId IS NULL
    BEGIN
        INSERT INTO dbo.regulations (country, state, zone_id, Lake_id, fish_id, reg_year, regulations_part, resident_type
            , regulations_date_start, regulations_start, regulations_date_end, regulations_end, day_flags
            , regulations_sport, regulations_consr, possession_sport, possession_consr
            , min_length_cm, slot_min_cm, slot_max_cm, slot_over_limit, method_flags
            , regulations_code, regulations_link, regulations_text)
        VALUES (@country, @state, @zone, @lake, @fish, @year, @part, @resident
            , @dateStart, @startText, @dateEnd, @endText, @dayFlags
            , @sport, @consr, @possessionSport, @possessionConsr
            , @minLengthCm, @slotMinCm, @slotMaxCm, @slotOverLimit, @methodFlags
            , @code, @link, @text);
        SET @existingId = SCOPE_IDENTITY();
        SET @action = 'inserted';
    END
    ELSE
    BEGIN
        UPDATE dbo.regulations SET
            regulations_date_start = @dateStart, regulations_start = @startText,
            regulations_date_end   = @dateEnd,   regulations_end   = @endText,
            day_flags              = @dayFlags,
            regulations_sport      = @sport,     regulations_consr = @consr,
            possession_sport       = @possessionSport, possession_consr = @possessionConsr,
            min_length_cm           = @minLengthCm, slot_min_cm = @slotMinCm, slot_max_cm = @slotMaxCm,
            slot_over_limit         = @slotOverLimit, method_flags = @methodFlags,
            regulations_code        = @code, regulations_link = @link, regulations_text = @text,
            regulations_stamp       = GETUTCDATE()
        WHERE id = @existingId;
        SET @action = 'updated';
    END

    SELECT (
        SELECT @existingId AS id, @action AS action,
               CASE WHEN @lake IS NOT NULL THEN 'waterBody' WHEN @zone IS NOT NULL THEN 'zone' ELSE 'region' END AS scope
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS results;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_del_river' AND type = 'P')
    DROP PROCEDURE dbo.sp_del_river
GO
CREATE PROCEDURE [dbo].[sp_del_river]  @lake_id uniqueidentifier 
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON
    -- (the DELETE FROM Parking_Spot that stood here went with that retired table, 2026-08-11)
    DELETE FROM lake_fish WHERE @lake_id = lake_id
    DELETE FROM dbo.Tributaries  WHERE @lake_id = Main_Lake_id OR  @lake_id = Lake_id
	DELETE FROM lake  WHERE @lake_id = lake_id
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_add_tributary' AND type = 'P')
    DROP PROCEDURE dbo.sp_add_tributary
GO
/*
    @main_lake_id - could be  a river throu @lake_id
*/
CREATE PROCEDURE sp_add_tributary @main_lake_id uniqueidentifier, @lake_id uniqueidentifier, @type int, @lat float = NULL, @lon float = NULL
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON
    DECLARE @loctype int =  (SELECT locType FROM lake WHERE lake_id = @lake_id);
    IF @type = 1   -- link to lake
	BEGIN
        INSERT INTO Tributaries ([Main_Lake_id], [Lake_id], side, lat, lon) VALUES (@main_lake_id, @lake_id, 1, @lat, @lon ); 
	END ELSE
	IF  @loctype IN (1, 8, 8192)
	BEGIN
        -- The reciprocal row is always INSERTed (@type = 2 "through" = inflow AND outflow).
        -- It must never re-point the water body's own self-referencing source (side 16) / mouth
        -- (side 32) rows: TR_Lake_INS creates those for every new lake, UK_Tributaries_Source /
        -- UK_Tributaries_Mouth keep them unique (one each), and dbo.fn_EditLakeLink returns them
        -- (its "code 2" branch, Main_Lake_id = Lake_id) for the Source/Mouth tabs of
        -- Editor/EditLakeLink.aspx -- they carry that point's zone/district/county/city/elevation.
        -- Sides 4 and 8 are under no unique index, so a water body may hold several inflows/outflows
        -- and an unconditional INSERT here cannot collide.
        --
        -- Until 2026-07-30 each branch read
        --     IF @srcid IS NOT NULL INSERT ... ELSE UPDATE ... WHERE id = @srcid AND @srcid IS NOT NULL
        -- whose ELSE could never match (@srcid is NULL exactly when that branch runs). Two bugs:
        -- a legacy lake with no source placeholder silently got NO reciprocal row at all, and the
        -- @type = 8 branch tested @srcid but updated @mthid -- re-pointing the mouth row into a
        -- side-8 row and destroying the Mouth tab's data. Covered by unit_test@Tributary.sql
        -- TEST 5-8 (5 and 8 confirmed FAILing first).
        IF @type IN (2, 4)   -- inflow
            INSERT INTO Tributaries (main_lake_id, lake_id, side, lat, lon) VALUES (@lake_id, @main_lake_id, 4, @lat, @lon);

        IF @type IN (2, 8)   -- outflow
            INSERT INTO Tributaries (main_lake_id, lake_id, side, lat, lon) VALUES (@lake_id, @main_lake_id, 8, @lat, @lon);
	END
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_assign_border' AND type = 'P')
    DROP PROCEDURE dbo.sp_assign_border
GO
/*
    when assign mouth or source the exchange lat/lon if missed
    called from FishTracker.Editor.EditLakeLink.ButtonSubmit_Click
*/
CREATE PROCEDURE sp_assign_border @lake_id uniqueidentifier
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
    UPDATE LAKE SET stamp = getdate() WHERE lake_id = @lake_id
    -- set source/mouth if mouth/source was assigned
    UPDATE l SET lake_id = @lake_id FROM Tributaries l JOIN Tributaries t ON t.Main_Lake_id = @lake_id AND t.Lake_id = l.Main_Lake_id
        WHERE EXISTS (SELECT * FROM lake where locType IN (1,8,256) AND lake.lake_id = l.Main_Lake_id)
            AND l.Main_Lake_id = l.lake_id AND l.side IN (16,32) AND t.side IN (16,32) AND l.side <> t.side 
    -- se lat/lon
    UPDATE t SET t.lat = COALESCE(t.lat, m.lat), t.lon = COALESCE(t.lon, m.lon)
        FROM Tributaries t 
        JOIN ( SELECT * FROM Tributaries WHERE Main_Lake_id = @lake_id AND side IN (16,32) )m 
            ON t.Main_Lake_id = m.lake_id AND t.side <> m.side
        WHERE t.side IN (16,32)
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_exchange_latlon' AND type = 'P')
    DROP PROCEDURE dbo.sp_exchange_latlon
GO
/*
   exchange src/mnth ..  used only in MSSQLSMS mode
*/
CREATE PROCEDURE sp_exchange_latlon @lake_id uniqueidentifier
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
 DECLARE @slat float, @slon float, @mlat float, @mlon float 
 select @slat = lat, @slon = lon from [Tributaries] where Main_Lake_id=Lake_id and side = 32 and Main_Lake_id = @lake_id
 select @mlat = lat, @mlon = lon from [Tributaries] where Main_Lake_id=Lake_id and side = 16 and Main_Lake_id = @lake_id
 update [Tributaries] set lat= @slat, lon = @slon WHERE Main_Lake_id=Lake_id and side = 16 and Main_Lake_id = @lake_id
 update [Tributaries] set lat= @mlat, lon = @mlon WHERE Main_Lake_id=Lake_id and side = 32 and Main_Lake_id = @lake_id
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_build_regulations' AND type = 'P')
    DROP PROCEDURE dbo.sp_build_regulations
GO
/*
   extract dor for river regulations in xml format
   Usage: EXEC sp_build_regulations '0c369d7b-849c-20c3-6274-0fd28a9dbbf4'
   Link:   https://files.ontario.ca/on-con-188/ONCON-188_MNRF_CR_ontario-fishing-regulations-summary-v2.pdf
   Source: https://www.ontario.ca/page/sport-fishing-variation-order-fisheries-management-zone-1
*/
CREATE PROCEDURE sp_build_regulations @lake_id uniqueidentifier
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
    DECLARE @locType int, @lake_name sysname, @link nvarchar(1024), @IsFish bit, @regulations nvarchar(255), @link_reg nvarchar(255), @noFish bit

    SELECT @locType=locType, @lake_name=lake_name, @link=link, @IsFish=IsFish, @regulations=regulations, @link_reg=link_reg, @noFish=noFish 
        FROM lake v LEFT JOIN Tributaries t ON v.lake_id = t.Lake_id AND t.side IN (16, 32)
        WHERE v.lake_id = @lake_id;

    DECLARE @rg XML = (SELECT * FROM dbo.fn_GetLakeRegulations( @lake_id ) WHERE lake_id = @lake_id FOR XML AUTO)

    IF @lake_name IS NOt NULL
    BEGIN
        DECLARE @rs XML = (SELECT lake_id, @locType AS locType, @lake_name AS lake_name, @link AS link, @IsFish AS IsFish
            , @regulations AS regulations, @link_reg AS link_reg, @noFish AS noFish FROM lake WHERE lake_id = @lake_id FOR XML AUTO, BINARY BASE64)
        IF @rs IS NOT NULL
        BEGIN
          SELECT CAST( COALESCE(CAST(@rs AS nvarchar(MAX)), '') + COALESCE(CAST(@rg AS nvarchar(MAX)), '') AS xml) AS doc;
        END
    END
    RETURN @@ROWCOUNT      
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_delete_with_cascade' AND type = 'P')
    DROP PROCEDURE dbo.sp_delete_with_cascade
GO
/* 
Recursive row delete procedure. 

It deletes all rows in the table specified that conform to the criteria selected, 
while also deleting any child/grandchild records and so on.  This is designed to do the 
same sort of thing as Access's cascade delete function. It first reads the sysforeignkeys 
table to find any child tables, then deletes the soon-to-be orphan records from them using 
recursive calls to this procedure. Once all child records are gone, the rows are deleted 
from the selected table.   It is designed at this time to be run at the command line. It could 
also be used in code, but the printed output will not be available.
*/
CREATE PROCEDURE dbo.sp_delete_with_cascade
(
@cTableName varchar(50), /* name of the table where rows are to be deleted */
@cCriteria nvarchar(1000) /* criteria used to delete the rows required */
)
As
BEGIN
SET NOCOUNT ON
declare     @cTab varchar(255), /* name of the child table */
    @cCol varchar(255), /* name of the linking field on the child table */
    @cRefTab varchar(255), /* name of the parent table */
    @cRefCol varchar(255), /* name of the linking field in the parent table */
    @cFKName varchar(255), /* name of the foreign key */
    @cSQL nvarchar(1000), /* query string passed to the sp_ExecuteSQL procedure */
    @cChildCriteria nvarchar(1000) /* criteria to be used to delete 
                                           records from the child table */


/* declare the cursor containing the foreign key constraint information */
DECLARE cFKey CURSOR LOCAL FOR 
SELECT SO1.name AS Tab, 
       SC1.name AS Col, 
       SO2.name AS RefTab, 
       SC2.name AS RefCol, 
       FO.name AS FKName
FROM dbo.sysforeignkeys FK  
INNER JOIN dbo.syscolumns SC1 ON FK.fkeyid = SC1.id 
                              AND FK.fkey = SC1.colid 
INNER JOIN dbo.syscolumns SC2 ON FK.rkeyid = SC2.id 
                              AND FK.rkey = SC2.colid 
INNER JOIN dbo.sysobjects SO1 ON FK.fkeyid = SO1.id 
INNER JOIN dbo.sysobjects SO2 ON FK.rkeyid = SO2.id 
INNER JOIN dbo.sysobjects FO ON FK.constid = FO.id
WHERE SO2.Name = @cTableName

OPEN cFKey
FETCH NEXT FROM cFKey INTO @cTab, @cCol, @cRefTab, @cRefCol, @cFKName
WHILE @@FETCH_STATUS = 0
     BEGIN
    /* build the criteria to delete rows from the child table. As it uses the 
           criteria passed to this procedure, it gets progressively larger with 
           recursive calls */
    SET @cChildCriteria = @cCol + ' in (SELECT [' + @cRefCol + '] FROM [' + 
                              @cRefTab +'] WHERE ' + @cCriteria + ')'
    /* call this procedure to delete the child rows */
    EXEC sp_delete_with_cascade @cTab, @cChildCriteria 
    FETCH NEXT FROM cFKey INTO @cTab, @cCol, @cRefTab, @cRefCol, @cFKName
     END
Close cFKey
DeAllocate cFKey
/* finally delete the rows from this table and display the rows affected  */
SET @cSQL = 'DELETE FROM [' + @cTableName + '] WHERE ' + @cCriteria
/* change NOCOUNT option as smartgwt as complains if there is no count returned */
SET NOCOUNT OFF
EXEC sp_ExecuteSQL @cSQL;
END;
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_sys_update_loc' AND type = 'P')
    DROP PROCEDURE dbo.sp_sys_update_loc
GO
 
CREATE PROCEDURE sp_sys_update_loc @line sysname, @loc sysname, @district sysname
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
	update [Tributaries] set [district] = @district, location = @loc  where TRIM(@line) in (location, [district])

	update [Tributaries] set location = @district, [district] = @loc  where [district] = @loc
 
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 
/*
declare @data xml = (SELECT * FROM OPENROWSET(BULK N'k:\temp\path.xml', SINGLE_CLOB) rs);

EXEC sp_push_us_water_data '08313000', 'NY', 'Streamflow', 'ft^2/s', '<root><a d="2020-09-12" v="2.70" /><a d="2020-09-13" v="2.72" /></root>'
EXEC sp_push_us_water_data '08313000', 'NY', 'Gage height', 'ft', '"<root><a d="2020-09-12" v="2.70" /><a d="2020-09-13" v="2.72" /></root>'
select * from waterdata where mli = '08313000'
*/
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_push_us_water_data' AND type = 'P')
    DROP PROCEDURE dbo.sp_push_us_water_data
GO

/*
	parse XML data FROM USGS water data center
*/
 
CREATE PROCEDURE dbo.sp_push_us_water_data @mli sysname, @state sysname, @name sysname, @unit varchar(64),  @xmldoc XML
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
	IF DATALENGTH(@xmldoc) = 0 OR LEN(@mli) = 0 OR LEN(@state) = 0
		RETURN;

	-- Exact match, not LIKE: this is a catalogue lookup, not a search. LIKE made it fail three ways -
	-- USGS names contain [ ] ('Total nitrogen [nitrate + nitrite + ...]'), which LIKE reads as a
	-- character class so the row never matched itself; `unit LIKE NULL` is UNKNOWN so unitless
	-- measurements never matched either; and _ / % in an incoming name matched OTHER stored names,
	-- silently skipping a genuinely new measurement. Covered by unit_test@PushUsWaterData.sql.
	IF NOT EXISTS (SELECT * FROM UScode
	                WHERE name = @name
	                  AND (unit = @unit OR (unit IS NULL AND @unit IS NULL)))
	BEGIN
		-- Own TRY/CATCH: UK_UScode_name_unit means two collectors pushing the same NEW measurement
		-- at once can have one of them lose the race here. The catalogue is incidental to the push -
		-- it must never cost us the readings below - and the row exists either way, so swallow it.
		BEGIN TRY
			INSERT INTO UScode (name, unit) VALUES (@name , @unit)
		END TRY
		BEGIN CATCH
		END CATCH
	END

	DECLARE @koef_elevation float = (CASE WHEN @unit IN ('ft', ' in ft', ' feet') THEN 0.3048000097536 ELSE 1 END);
	DECLARE @koef_discharge float = (
		CASE WHEN @unit = 'ft^3/s'  THEN 101.941  
		     WHEN @unit = 'gal/min' THEN 350.227125 
			                        ELSE 1            -- [m^3/hr] 
		END);
	DECLARE @koef_velocity float = (
		CASE WHEN @unit IN ('ft/s', ' feet per second') THEN 101.941  
		     WHEN @unit = 'miles per hour'  THEN 0.44704 ELSE 1 
		END);

	;WITH cte AS
	 (
		SELECT dt
			, CASE WHEN @name in ( 'Streamflow')  THEN val ELSE NULL END							   AS discharge	-- [m^3/hr]
			, CASE WHEN @name in ('Water velocity reading from field sensor'
								, 'Mean water velocity for discharge computation' )  
								THEN val ELSE NULL END												   AS velocity  -- [m/s] 
			, CASE WHEN @name in ( 'Gage height', 'Stream water level elevation above NAVD 1988', 'Elevation of reservoir water surface above datum'
								 , 'Lake or reservoir elevation above United States Bureau of Reclamation Klamath Basin (USBRKB) Datum'
								 , 'Lake or reservoir water surface elevation above NAVD 1988'
								 , 'Lake or reservoir water surface elevation above NGVD 1929'
								 , 'Estuary or ocean water surface elevation above NAVD 1988'
								 , 'Stream water level elevation above NGVD 1929'
								 , 'Estuary or ocean water surface elevation above NGVD 1929'
								 , 'Lake or reservoir water surface elevation above NGVD 1929'
								 , 'Lake or reservoir elevation above New York State Barge Canal Datum (NYBCD)') THEN val ELSE NULL END AS elevation  -- [m]
			, CASE WHEN @name = 'Temperature' AND @unit = 'Water'  THEN val ELSE NULL END			    AS temperature
			, CASE WHEN @name in ( 'Turbidity')  THEN val ELSE NULL END							        AS turbidity	-- 

			, CASE WHEN @name = 'Barometric pressure'  THEN val ELSE NULL END						    AS pressure
			, CASE WHEN @name in ('Wind speed', 'Wind gust speed')  THEN val ELSE NULL END				AS wind
			, CASE WHEN @name = 'Temperature' AND @unit = 'Air'  THEN val ELSE NULL END			        AS air
			, CASE WHEN @name in ('Wind direction', 'Wind gust direction') THEN val ELSE NULL END       AS winddir
			, CASE WHEN @name = 'Relative humidity' THEN val ELSE NULL END						        AS humidity
			, CASE WHEN @name = 'Precipitation' THEN val ELSE NULL END						            AS precipitation

			, CASE WHEN @name in ('Chlorophylls', 'Chlorophyll <i>a</i>')  THEN val ELSE NULL END		AS chlorophylls
			, CASE WHEN @name = 'Phycocyanins (cyanobacteria)'  THEN val ELSE NULL END					AS phycocyanins
			, CASE WHEN @name = 'Cyanobacteria (blue-green algae)'  THEN val ELSE NULL END				AS cyanobacteria
			, CASE WHEN @name = 'Phycoerythrin (blue-green algae)'  THEN val ELSE NULL END				AS phycoerythrin
			, CASE WHEN @name = 'Orthophosphate'  THEN val ELSE NULL END								AS orthophosphate
			, CASE WHEN @name = 'Nitrate'  THEN val ELSE NULL END										AS nitrate
			, CASE WHEN @name = 'Chloride'  THEN val ELSE NULL END										AS chloride
			, CASE WHEN @name = 'Dissolved oxygen'  THEN val ELSE NULL END								AS oxygen
			, CASE WHEN @name = 'pH'  THEN val ELSE NULL END											AS ph
			, CASE WHEN @name = 'Salinity'  THEN val ELSE NULL END							        	AS salinity
			FROM
		(
			SELECT X.C.value(N'@d', N'date') as dt,   X.C.value(N'@v', N'float') as val
				FROM (SELECT @xmldoc AS XML_DATA) DATA CROSS APPLY DATA.XML_DATA.nodes(N'/root/a') as X(C)
		)x
	)
	MERGE INTO WaterData AS t
        USING cte AS source ON CAST(t.stamp AS DATE ) = source.dt AND t.mli = @mli
    WHEN MATCHED THEN 
        UPDATE SET t.discharge = COALESCE(source.discharge * @koef_discharge,   t.discharge)
		, t.elevation          = COALESCE(source.elevation * @koef_elevation,   t.elevation)
		, t.velocity           = COALESCE(source.velocity  * @koef_velocity,	t.velocity)
		, t.temperature        = COALESCE(source.temperature,					t.temperature)
		, t.turbidity          = COALESCE(source.turbidity,				    	t.turbidity)

		, t.pressure           = COALESCE(source.pressure,						t.pressure)
		, t.air                = COALESCE(source.air,							t.air)
		, t.wind               = COALESCE(source.wind,							t.wind)
		, t.winddir            = COALESCE(source.winddir,						t.winddir)
		, t.humidity           = COALESCE(source.humidity,						t.humidity)
		, t.precipitation      = COALESCE(source.precipitation,					t.precipitation)

		, t.chlorophylls       = COALESCE(source.chlorophylls,					t.chlorophylls)
		, t.phycocyanins       = COALESCE(source.phycocyanins,					t.phycocyanins)
		, t.cyanobacteria      = COALESCE(source.cyanobacteria,					t.cyanobacteria)
		, t.phycoerythrin      = COALESCE(source.phycoerythrin,					t.phycoerythrin)
		, t.orthophosphate     = COALESCE(source.orthophosphate,				t.orthophosphate)
		, t.nitrate            = COALESCE(source.nitrate,						t.nitrate)
		, t.chloride           = COALESCE(source.chloride,						t.chloride)
		, t.oxygen             = COALESCE(source.oxygen,						t.oxygen)
		, t.salinity           = COALESCE(source.salinity,						t.salinity)
		, t.ph                 = COALESCE(source.ph,							t.ph)
    WHEN NOT MATCHED BY TARGET THEN  
        INSERT (stamp, discharge, elevation, mli,  pressure, chlorophylls, salinity, phycocyanins, phycoerythrin, cyanobacteria, orthophosphate, nitrate, chloride, wind, temperature, oxygen, ph, velocity, winddir, humidity, precipitation) 
		VALUES ( dt,  discharge,  elevation, @mli, pressure, chlorophylls, salinity, phycocyanins, phycoerythrin, cyanobacteria, orthophosphate, nitrate, chloride, wind, temperature, oxygen, ph, velocity, winddir, humidity, precipitation );
	RETURN @@ROWCOUNT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;  
GO 

------------------------------------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_ows_meteo' AND type = 'P')
    DROP PROCEDURE dbo.sp_ows_meteo
GO



/*
    Procedure parse TWC (Weather Channel) JSON and upsert into weather_Forecast.
    One row per day (max 6).  Latest daypart values win (night over day).
    MERGE upserts on mli + dt.
    Temperatures converted from °F to °C.
 
        called from [TR_ows_meteo]
*/
CREATE  PROCEDURE [dbo].[sp_ows_meteo]
      @js   nvarchar(max)
    , @mli  varchar(64)
    , @link uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
 
    BEGIN TRY
 
        IF @js IS NULL OR @mli IS NULL OR @link IS NULL OR ISJSON(@js) <> 1
            RETURN;
 
        ;WITH
        ---------- daily-level arrays ------------------
        daily_time AS
        (
            SELECT
                  CAST([key] AS int) AS idx
                , TRY_CONVERT(datetime2(0), REPLACE(LEFT([value], 19), 'T', ' ')) AS validTimeLocal
            FROM OPENJSON(@js, '$.validTimeLocal')
        ),
        daily_tmax AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS tmHigh
            FROM OPENJSON(@js, '$.temperatureMax')
        ),
        daily_tmin AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS tmLow
            FROM OPENJSON(@js, '$.temperatureMin')
        ),
        daily_qpf AS
        (
            SELECT CAST([key] AS int) AS idx, ISNULL(TRY_CONVERT(float, [value]), 0.0) AS qpf
            FROM OPENJSON(@js, '$.qpf')
        ),
        daily_narrative AS
        (
            SELECT CAST([key] AS int) AS idx, [value] AS narrative
            FROM OPENJSON(@js, '$.narrative')
        ),
        daily_data AS
        (
            SELECT
                  t.idx
                , t.validTimeLocal
                , CAST(t.validTimeLocal AS date) AS dt
                , mx.tmHigh
                , mn.tmLow
                , q.qpf
                , n.narrative
            FROM daily_time t
            LEFT JOIN daily_tmax      mx ON mx.idx = t.idx
            LEFT JOIN daily_tmin      mn ON mn.idx = t.idx
            LEFT JOIN daily_qpf       q  ON q.idx  = t.idx
            LEFT JOIN daily_narrative  n  ON n.idx  = t.idx
            WHERE t.validTimeLocal IS NOT NULL
        ),
 
        /* ── daypart arrays (day/night pairs: idx/2 = daily row) */
        dp_dayOrNight AS
        (
            SELECT CAST([key] AS int) AS idx, [value] AS dayOrNight
            FROM OPENJSON(@js, '$.daypart[0].dayOrNight')
        ),
        dp_temperature AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS air_temperature
            FROM OPENJSON(@js, '$.daypart[0].temperature')
        ),
        dp_humidity AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(int, [value]) AS humidity
            FROM OPENJSON(@js, '$.daypart[0].relativeHumidity')
        ),
        dp_pop AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(int, [value]) AS pop
            FROM OPENJSON(@js, '$.daypart[0].precipChance')
        ),
        dp_wind_speed AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS wind_max_speed
            FROM OPENJSON(@js, '$.daypart[0].windSpeed')
        ),
        dp_wind_degree AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS wind_degree
            FROM OPENJSON(@js, '$.daypart[0].windDirection')
        ),
        dp_wind_dir AS
        (
            SELECT CAST([key] AS int) AS idx, LEFT([value], 3) AS wind_direction
            FROM OPENJSON(@js, '$.daypart[0].windDirectionCardinal')
        ),
        dp_iconCode AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(int, [value]) AS iconCode
            FROM OPENJSON(@js, '$.daypart[0].iconCode')
        ),
        dp_wxShort AS
        (
            SELECT CAST([key] AS int) AS idx, [value] AS wxPhraseShort
            FROM OPENJSON(@js, '$.daypart[0].wxPhraseShort')
        ),
        dp_wxLong AS
        (
            SELECT CAST([key] AS int) AS idx, [value] AS wxPhraseLong
            FROM OPENJSON(@js, '$.daypart[0].wxPhraseLong')
        ),
        dp_qpf AS
        (
            SELECT CAST([key] AS int) AS idx, ISNULL(TRY_CONVERT(float, [value]), 0.0) AS dp_qpf
            FROM OPENJSON(@js, '$.daypart[0].qpf')
        ),
        dp_narrative AS
        (
            SELECT CAST([key] AS int) AS idx, [value] AS dp_narrative
            FROM OPENJSON(@js, '$.daypart[0].narrative')
        ),
 
        -----------combine all daypart fields, map to daily index --------------
        daypart_data AS
        (
            SELECT
                  dn.idx
                , dn.idx / 2                AS daily_idx
                , dn.dayOrNight
                , tmp.air_temperature
                , hum.humidity
                , pp.pop
                , ws.wind_max_speed
                , wd.wind_degree
                , wdir.wind_direction
                , ic.iconCode
                , wxs.wxPhraseShort
                , wxl.wxPhraseLong
                , dq.dp_qpf
                , dpn.dp_narrative
            FROM dp_dayOrNight dn
            LEFT JOIN dp_temperature  tmp  ON tmp.idx  = dn.idx
            LEFT JOIN dp_humidity     hum  ON hum.idx  = dn.idx
            LEFT JOIN dp_pop          pp   ON pp.idx   = dn.idx
            LEFT JOIN dp_wind_speed   ws   ON ws.idx   = dn.idx
            LEFT JOIN dp_wind_degree  wd   ON wd.idx   = dn.idx
            LEFT JOIN dp_wind_dir     wdir ON wdir.idx = dn.idx
            LEFT JOIN dp_iconCode     ic   ON ic.idx   = dn.idx
            LEFT JOIN dp_wxShort      wxs  ON wxs.idx  = dn.idx
            LEFT JOIN dp_wxLong       wxl  ON wxl.idx  = dn.idx
            LEFT JOIN dp_qpf          dq   ON dq.idx   = dn.idx
            LEFT JOIN dp_narrative    dpn  ON dpn.idx  = dn.idx
            WHERE dn.dayOrNight IS NOT NULL          -- skip JSON nulls
        ),
 
        ------------------ latest daypart per day (night > day by idx) ------------
        dp_ranked AS
        (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY daily_idx ORDER BY idx DESC) AS rn
            FROM daypart_data
        ),
        latest_dp AS
        (
            SELECT * FROM dp_ranked WHERE rn = 1
        ),
 
        ------------ day/night precipitation split --------------------------
        dp_precip AS
        (
            SELECT
                  daily_idx
                , SUM(CASE WHEN dayOrNight = 'D' THEN dp_qpf ELSE 0 END) AS gpfDay
                , SUM(CASE WHEN dayOrNight = 'N' THEN dp_qpf ELSE 0 END) AS gpfNight
            FROM daypart_data
            GROUP BY daily_idx
        ),
 
        ------------- daytime temperature (D part only) for tmDay -----------
        dp_day_temp AS
        (
            SELECT daily_idx, air_temperature AS tmDay
            FROM daypart_data
            WHERE dayOrNight = 'D'
        ),
 
        ------------- final source: 1 row per day ----------------------------
        src AS
        (
            SELECT
                  @link AS [link]
                /* F → C;  COALESCE mirrors original fallback logic */
                , ROUND((COALESCE(d.tmHigh, lp.air_temperature, d.tmLow) - 32.0) * (5.0/9.0), 1) AS tmHigh
                , ROUND((COALESCE(d.tmLow,  lp.air_temperature, d.tmHigh) - 32.0) * (5.0/9.0), 1) AS tmLow
                , ISNULL(pr.gpfDay, 0.0)   AS gpfDay
                , ISNULL(pr.gpfNight, 0.0)  AS gpfNight
                , lp.humidity
                , lp.wind_max_speed
                , lp.wind_degree
                , lp.wind_direction
                , LEFT(COALESCE(lp.wxPhraseShort, d.narrative), 64)              AS shortText
                , LEFT(COALESCE(lp.wxPhraseLong, lp.dp_narrative, d.narrative), 255) AS longText
                , CONCAT('wc_', ISNULL(CONVERT(varchar(12), lp.iconCode), 'na'), '.png') AS icon
                , lp.pop
                , d.dt
                , CAST(d.validTimeLocal AS time(7)) AS tm
                , @mli AS mli
                , CAST(NULL AS int) AS city_id
                , CAST(NULL AS int) AS pressure           -- not in TWC JSON
                , TRY_CONVERT(int, ROUND(d.qpf, 0))      AS rain_today
                , TRY_CONVERT(int, ROUND((lp.air_temperature - 32.0) * (5.0/9.0), 0)) AS air_temperature
                , ROUND((dt_temp.tmDay - 32.0) * (5.0/9.0), 1) AS tmDay
                , lp.iconCode AS weather_code
            FROM daily_data d
            LEFT JOIN latest_dp   lp      ON lp.daily_idx      = d.idx
            LEFT JOIN dp_precip   pr      ON pr.daily_idx      = d.idx
            LEFT JOIN dp_day_temp dt_temp ON dt_temp.daily_idx  = d.idx
        )
 
        MERGE dbo.weather_Forecast AS t
        USING src
           ON t.mli = src.mli
          AND t.dt  = src.dt
 
        WHEN MATCHED THEN
            UPDATE SET
                  t.[link]            = src.[link]
                , t.tmHigh            = ISNULL(src.tmHigh, t.tmHigh)
                , t.tmLow             = ISNULL(src.tmLow, t.tmLow)
                , t.gpfDay            = src.gpfDay
                , t.gpfNight          = src.gpfNight
                , t.humidity          = src.humidity
                , t.wind_max_speed    = src.wind_max_speed
                , t.wind_degree       = src.wind_degree
                , t.wind_direction    = src.wind_direction
                , t.shortText         = src.shortText
                , t.longText          = src.longText
                , t.icon              = src.icon
                , t.pop               = src.pop
                , t.tm                = src.tm
                , t.pressure          = src.pressure
                , t.rain_today        = src.rain_today
                , t.air_temperature   = src.air_temperature
                , t.tmDay             = src.tmDay
                , t.weather_code      = src.weather_code
 
        WHEN NOT MATCHED BY TARGET THEN
            INSERT
            (
                  [link], [tmHigh], [tmLow], [gpfDay], [gpfNight]
                , [humidity], [wind_max_speed], [wind_degree], [wind_direction]
                , [shortText], [longText], [icon], [pop]
                , [dt], [tm], [mli], [city_id]
                , [pressure], [rain_today], [air_temperature], [tmDay], [weather_code]
            )
            VALUES
            (
                  src.[link]
                , ISNULL(src.tmHigh, 0)
                , ISNULL(src.tmLow, 0)
                , ISNULL(src.gpfDay, 0)
                , ISNULL(src.gpfNight, 0)
                , src.humidity
                , src.wind_max_speed
                , src.wind_degree
                , src.wind_direction
                , src.shortText
                , src.longText
                , src.icon
                , src.pop
                , src.dt
                , src.tm
                , src.mli
                , src.city_id
                , src.pressure
                , src.rain_today
                , src.air_temperature
                , src.tmDay
                , src.weather_code
            );
 
    END TRY
    BEGIN CATCH
        SELECT
              ERROR_NUMBER()    AS ErrorNumber
            , ERROR_SEVERITY()  AS ErrorSeverity
            , ERROR_STATE()     AS ErrorState
            , ERROR_PROCEDURE() AS ErrorProcedure
            , ERROR_LINE()      AS ErrorLine
            , ERROR_MESSAGE()   AS ErrorMessage;
    END CATCH
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------


/*
	Procedure parse JSON doc and then insert into diffrent tables:
	1. WaterStation - meteo from water station
	2. weather_Forecast

		called from [TR_ows_meteo]  (dbo.ows_meteo rows whose type = 2)

    TWO DOCUMENT SHAPES are handled, because the weather worker stores more than one provider's
    document under type = 2:

      * Open-Meteo      -- $.hourly.time[] + $.daily.time[], already METRIC (degC, km/h, mm, hPa)
      * Visual Crossing -- $.days[], one object per day, in US UNITS (degF, mph, inches, mb)

    Everything downstream (dbo.fn_station_weather_today, dbo.fn_plot_weather) expects metric, so the
    Visual Crossing branch converts. Until 2026-08-12 only Open-Meteo was understood and a
    Visual Crossing document parsed to zero rows -- the MERGE simply had nothing to merge, and
    nothing was written, with NO error, because an empty parse looks exactly like success. Stations
    that were being collected showed no weather at all (e.g. MLI 13068500).

    A document in NEITHER shape is a deliberate no-op. Those two are the only FORECASTS the worker
    stores under type = 2; measured on prod it also stores, under the same type, weather.gov/NWS
    GeoJSON ($.@context/$.properties), MSC SWOB GeoJSON ($.features[]), Weather Underground station
    observations ($.observations[]) and a current-conditions document ($.currentConditionsHistory).
    Those carry OBSERVATIONS, not a forecast -- there is nothing in them that could honestly become a
    weather_Forecast row, so they are left alone rather than invented from. Raising here is NOT an
    option: this runs inside TR_ows_meteo, so an error would abort the worker's UPDATE and throw
    away the payload it just fetched. The fix for those belongs in the worker, which should stop
    stamping every provider type = 2.
    (The Weather Company / Weather Underground v3 DAILY FORECAST -- $.daypart[] + $.temperatureMax --
    is a different document again, and dbo.sp_ows_meteo already parses it under type = 1.)

    Covered by UNIT_TESTS/unit_test@OwsMeteoOpen.sql.
*/
CREATE OR ALTER PROCEDURE [dbo].[sp_ows_meteo_open]
      @js   nvarchar(max)
    , @mli  varchar(64)
    , @link uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        IF @js IS NULL OR @mli IS NULL OR @link IS NULL OR ISJSON(@js) <> 1
            RETURN;

        ------------------------------------------------------------------------------------------
        -- Visual Crossing:  $.days[] , one object per day, US units.  Handled and returned here so
        -- the Open-Meteo block below stays exactly as it was.
        ------------------------------------------------------------------------------------------
        IF JSON_QUERY(@js, '$.days') IS NOT NULL AND JSON_QUERY(@js, '$.hourly') IS NULL
        BEGIN
            ;WITH vc_raw AS
            (
                SELECT d.dt, d.tempmax, d.tempmin, d.temp, d.humidity, d.precip, d.precipprob
                     , d.windspeed, d.winddir, d.pressure, d.conditions, d.[description], d.icon
                FROM OPENJSON(@js, '$.days')
                WITH (
                      dt            date          '$.datetime'
                    , tempmax       float         '$.tempmax'
                    , tempmin       float         '$.tempmin'
                    , temp          float         '$.temp'
                    , humidity      float         '$.humidity'
                    , precip        float         '$.precip'
                    , precipprob    float         '$.precipprob'
                    , windspeed     float         '$.windspeed'
                    , winddir       float         '$.winddir'
                    , pressure      float         '$.pressure'
                    , conditions    nvarchar(200) '$.conditions'
                    , [description] nvarchar(400) '$.description'
                    , icon          nvarchar(64)  '$.icon'
                ) d
                -- the document runs 15 days and its first day is often YESTERDAY in the station's
                -- time zone; keep the same today..today+6 horizon the Open-Meteo branch produces
                WHERE d.dt IS NOT NULL
                  AND d.dt >= CAST(GETDATE() AS date)
                  AND d.dt <  DATEADD(day, 7, CAST(GETDATE() AS date))
            ),
            vc AS
            (
                SELECT dt
                     -- US units in, metric out
                     , (tempmax - 32.0) * 5.0 / 9.0 AS tmHigh          -- degF -> degC
                     , (tempmin - 32.0) * 5.0 / 9.0 AS tmLow
                     , (temp    - 32.0) * 5.0 / 9.0 AS tmDay
                     , humidity                                        -- % either way
                     , precip    * 25.4             AS rain_mm         -- inches -> mm
                     , precipprob
                     , windspeed * 1.609344         AS wind_max_speed  -- mph -> km/h
                     , winddir
                     , pressure                                        -- mb = hPa, no conversion
                     , conditions
                     , [description]
                     -- map the provider's icon onto the same codes the Open-Meteo branch emits, so
                     -- weather_code and the om_*.png icon namespace stay consistent across providers
                     , CASE icon
                         WHEN 'clear-day'             THEN 0
                         WHEN 'clear-night'           THEN 0
                         WHEN 'wind'                  THEN 1
                         WHEN 'partly-cloudy-day'     THEN 2
                         WHEN 'partly-cloudy-night'   THEN 2
                         WHEN 'cloudy'                THEN 3
                         WHEN 'fog'                   THEN 45
                         WHEN 'rain'                  THEN 63
                         WHEN 'showers-day'           THEN 80
                         WHEN 'showers-night'         THEN 80
                         WHEN 'snow'                  THEN 73
                         WHEN 'snow-showers-day'      THEN 71
                         WHEN 'snow-showers-night'    THEN 71
                         WHEN 'sleet'                 THEN 65
                         WHEN 'hail'                  THEN 95
                         WHEN 'thunder-rain'          THEN 95
                         WHEN 'thunder-showers-day'   THEN 95
                         WHEN 'thunder-showers-night' THEN 95
                         ELSE NULL
                       END AS weather_code
                FROM vc_raw
            ),
            src AS
            (
                SELECT
                      @link AS [link]
                    , v.tmHigh
                    , v.tmLow
                    -- the daily document has no hourly resolution, so the day's total rainfall is
                    -- split evenly rather than claimed for daytime; the SUM is what fn_plot_weather
                    -- and the prc calculation actually use, and that stays correct
                    , v.rain_mm / 2.0 AS gpfDay
                    , v.rain_mm / 2.0 AS gpfNight
                    , v.humidity
                    , v.wind_max_speed
                    , v.winddir AS wind_degree
                    , CASE
                        WHEN v.winddir IS NULL THEN NULL
                        WHEN v.winddir >= 337.5 OR v.winddir < 22.5 THEN 'N'
                        WHEN v.winddir < 67.5  THEN 'NE'
                        WHEN v.winddir < 112.5 THEN 'E'
                        WHEN v.winddir < 157.5 THEN 'SE'
                        WHEN v.winddir < 202.5 THEN 'S'
                        WHEN v.winddir < 247.5 THEN 'SW'
                        WHEN v.winddir < 292.5 THEN 'W'
                        ELSE 'NW'
                      END AS wind_direction
                    , v.conditions    AS shortText
                    , v.[description] AS longText
                    , CONCAT('om_', ISNULL(CONVERT(varchar(12), v.weather_code), 'na'), '.png') AS icon
                    , TRY_CONVERT(int, v.precipprob) AS pop
                    , v.dt
                    -- a daily document has no hour. tm must stay NOT NULL to match the Open-Meteo
                    -- rows: dbo.fnWeatherForecast selects "WHERE tm IS NULL", so a NULL here would
                    -- make these rows visible to a caller that no other forecast row reaches.
                    , CAST('00:00:00' AS time(7)) AS tm
                    , @mli AS mli
                    , CAST(NULL AS int) AS city_id
                    , TRY_CONVERT(int, ROUND(v.pressure, 0)) AS pressure
                    , TRY_CONVERT(int, ROUND(v.rain_mm,  0)) AS rain_today
                    , TRY_CONVERT(int, ROUND(v.tmDay,    0)) AS air_temperature
                    , v.tmDay
                    , v.weather_code
                FROM vc v
            )
            MERGE dbo.weather_Forecast AS t
            USING src
               ON t.mli = src.mli
              AND t.dt  = src.dt

            WHEN MATCHED THEN
                UPDATE SET
                      t.[link]            = src.[link]
                    , t.tmHigh            = ISNULL(src.tmHigh, t.tmHigh)
                    , t.tmLow             = ISNULL(src.tmLow, t.tmLow)
                    , t.gpfDay            = src.gpfDay
                    , t.gpfNight          = src.gpfNight
                    , t.humidity          = src.humidity
                    , t.wind_max_speed    = src.wind_max_speed
                    , t.wind_degree       = src.wind_degree
                    , t.wind_direction    = src.wind_direction
                    , t.shortText         = LEFT(src.shortText, 64)
                    , t.longText          = LEFT(src.longText, 255)
                    , t.icon              = LEFT(src.icon, 255)
                    , t.pop               = src.pop
                    , t.tm                = src.tm
                    , t.pressure          = src.pressure
                    , t.rain_today        = src.rain_today
                    , t.air_temperature   = src.air_temperature
                    , t.tmDay             = src.tmDay
                    , t.weather_code      = src.weather_code

            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                      [link], [tmHigh], [tmLow], [gpfDay], [gpfNight]
                    , [humidity], [wind_max_speed], [wind_degree], [wind_direction]
                    , [shortText], [longText], [icon], [pop]
                    , [dt], [tm], [mli], [city_id]
                    , [pressure], [rain_today], [air_temperature], [tmDay], [weather_code]
                )
                VALUES
                (
                      src.[link]
                    , ISNULL(src.tmHigh, 0)
                    , ISNULL(src.tmLow, 0)
                    , ISNULL(src.gpfDay, 0)
                    , ISNULL(src.gpfNight, 0)
                    , src.humidity
                    , src.wind_max_speed
                    , src.wind_degree
                    , src.wind_direction
                    , LEFT(src.shortText, 64)
                    , LEFT(src.longText, 255)
                    , LEFT(src.icon, 255)
                    , src.pop
                    , src.dt
                    , src.tm
                    , src.mli
                    , src.city_id
                    , src.pressure
                    , src.rain_today
                    , src.air_temperature
                    , src.tmDay
                    , src.weather_code
                );

            RETURN;
        END

        ------------------------------------------------------------------------------------------
        -- Not an Open-Meteo document either (e.g. the Weather Underground $.observations[] shape):
        -- nothing here can become a forecast row, so leave weather_Forecast alone.
        ------------------------------------------------------------------------------------------
        IF JSON_QUERY(@js, '$.hourly') IS NULL
            RETURN;

        ;WITH
        -- ------------------- hourly arrays ----------------------
        hourly_time AS
        (
            SELECT
                  CAST([key] AS int) AS idx
                , TRY_CONVERT(datetime2(0), REPLACE([value], 'T', ' ')) AS validTimeLocal
            FROM OPENJSON(@js, '$.hourly.time')
        ),
        hourly_temperature AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS air_temperature
            FROM OPENJSON(@js, '$.hourly.temperature_2m')
        ),
        hourly_humidity AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS humidity
            FROM OPENJSON(@js, '$.hourly.relative_humidity_2m')
        ),
        hourly_pop AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(int, [value]) AS pop
            FROM OPENJSON(@js, '$.hourly.precipitation_probability')
        ),
        hourly_pressure AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(int, [value]) AS pressure
            FROM OPENJSON(@js, '$.hourly.pressure_msl')
        ),
        hourly_wind_speed AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS wind_max_speed
            FROM OPENJSON(@js, '$.hourly.wind_speed_10m')
        ),
        hourly_wind_degree AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS wind_degree
            FROM OPENJSON(@js, '$.hourly.wind_direction_10m')
        ),
        hourly_weather_code AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(int, [value]) AS weather_code
            FROM OPENJSON(@js, '$.hourly.weather_code')
        ),
        hourly_rain AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS rain_mm
            FROM OPENJSON(@js, '$.hourly.rain')
        ),
        hourly_data AS
        (
            SELECT
                  t.idx
                , t.validTimeLocal
                , CAST(t.validTimeLocal AS date) AS dt
                , CAST(t.validTimeLocal AS time(7)) AS tm
                , tmp.air_temperature
                , hum.humidity
                , pp.pop
                , prs.pressure
                , ws.wind_max_speed
                , wd.wind_degree
                , wc.weather_code
                , rn.rain_mm
            FROM hourly_time t
            LEFT JOIN hourly_temperature  tmp ON tmp.idx = t.idx
            LEFT JOIN hourly_humidity     hum ON hum.idx = t.idx
            LEFT JOIN hourly_pop          pp  ON pp.idx  = t.idx
            LEFT JOIN hourly_pressure     prs ON prs.idx = t.idx
            LEFT JOIN hourly_wind_speed   ws  ON ws.idx  = t.idx
            LEFT JOIN hourly_wind_degree  wd  ON wd.idx  = t.idx
            LEFT JOIN hourly_weather_code wc  ON wc.idx  = t.idx
            LEFT JOIN hourly_rain         rn  ON rn.idx  = t.idx
            WHERE t.validTimeLocal IS NOT NULL
        ),

        ------------------ pick latest hour per day ─────────----------
        hourly_ranked AS
        (
            SELECT *
                 , ROW_NUMBER() OVER (PARTITION BY dt ORDER BY validTimeLocal DESC) AS rn
            FROM hourly_data
        ),
        latest_hourly AS
        (
            SELECT * FROM hourly_ranked WHERE rn = 1
        ),

        ------------------- daily arrays ───────────────────----------
        daily_time AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(date, [value]) AS dt
            FROM OPENJSON(@js, '$.daily.time')
        ),
        daily_tmax AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS tmHigh
            FROM OPENJSON(@js, '$.daily.temperature_2m_max')
        ),
        daily_tmin AS
        (
            SELECT CAST([key] AS int) AS idx, TRY_CONVERT(float, [value]) AS tmLow
            FROM OPENJSON(@js, '$.daily.temperature_2m_min')
        ),
        daily_data AS
        (
            SELECT d.dt, mx.tmHigh, mn.tmLow
            FROM daily_time d
            LEFT JOIN daily_tmax mx ON mx.idx = d.idx
            LEFT JOIN daily_tmin mn ON mn.idx = d.idx
            WHERE d.dt IS NOT NULL
        ),

       ---- rain / daytime temp aggregated per day ─────------------
        rain_by_day AS
        (
            SELECT
                  h.dt
                , SUM(CASE WHEN DATEPART(HOUR, h.validTimeLocal) BETWEEN 6 AND 17
                           THEN ISNULL(h.rain_mm, 0) ELSE 0 END) AS gpfDay
                , SUM(CASE WHEN DATEPART(HOUR, h.validTimeLocal) NOT BETWEEN 6 AND 17
                           THEN ISNULL(h.rain_mm, 0) ELSE 0 END) AS gpfNight
                , SUM(ISNULL(h.rain_mm, 0)) AS rain_today
                , AVG(CASE WHEN DATEPART(HOUR, h.validTimeLocal) BETWEEN 6 AND 17
                           THEN h.air_temperature END) AS tmDay
            FROM hourly_data h
            GROUP BY h.dt
        ),

        ---------------- final source: 1 row per day (max 7) ──────------------
        src AS
        (
            SELECT
                  @link AS [link]
                , d.tmHigh
                , d.tmLow
                , ISNULL(r.gpfDay, 0.0)   AS gpfDay
                , ISNULL(r.gpfNight, 0.0)  AS gpfNight
                , h.humidity
                , h.wind_max_speed
                , h.wind_degree
                , CASE
                    WHEN h.wind_degree IS NULL THEN NULL
                    WHEN h.wind_degree >= 337.5 OR h.wind_degree < 22.5 THEN 'N'
                    WHEN h.wind_degree < 67.5  THEN 'NE'
                    WHEN h.wind_degree < 112.5 THEN 'E'
                    WHEN h.wind_degree < 157.5 THEN 'SE'
                    WHEN h.wind_degree < 202.5 THEN 'S'
                    WHEN h.wind_degree < 247.5 THEN 'SW'
                    WHEN h.wind_degree < 292.5 THEN 'W'
                    ELSE 'NW'
                  END AS wind_direction
                , CASE h.weather_code
                    WHEN 0  THEN 'Clear'
                    WHEN 1  THEN 'Mainly clear'
                    WHEN 2  THEN 'Partly cloudy'
                    WHEN 3  THEN 'Overcast'
                    WHEN 45 THEN 'Fog'
                    WHEN 48 THEN 'Rime fog'
                    WHEN 51 THEN 'Light drizzle'
                    WHEN 53 THEN 'Drizzle'
                    WHEN 55 THEN 'Dense drizzle'
                    WHEN 61 THEN 'Light rain'
                    WHEN 63 THEN 'Rain'
                    WHEN 65 THEN 'Heavy rain'
                    WHEN 71 THEN 'Light snow'
                    WHEN 73 THEN 'Snow'
                    WHEN 75 THEN 'Heavy snow'
                    WHEN 80 THEN 'Rain showers'
                    WHEN 81 THEN 'Rain showers'
                    WHEN 82 THEN 'Heavy showers'
                    WHEN 95 THEN 'Thunderstorm'
                    ELSE 'Unknown'
                  END AS shortText
                , CASE h.weather_code
                    WHEN 0  THEN 'Clear sky'
                    WHEN 1  THEN 'Mainly clear sky'
                    WHEN 2  THEN 'Partly cloudy'
                    WHEN 3  THEN 'Overcast'
                    WHEN 45 THEN 'Fog'
                    WHEN 48 THEN 'Depositing rime fog'
                    WHEN 51 THEN 'Light drizzle'
                    WHEN 53 THEN 'Moderate drizzle'
                    WHEN 55 THEN 'Dense drizzle'
                    WHEN 61 THEN 'Slight rain'
                    WHEN 63 THEN 'Moderate rain'
                    WHEN 65 THEN 'Heavy rain'
                    WHEN 71 THEN 'Slight snow fall'
                    WHEN 73 THEN 'Moderate snow fall'
                    WHEN 75 THEN 'Heavy snow fall'
                    WHEN 80 THEN 'Slight rain showers'
                    WHEN 81 THEN 'Moderate rain showers'
                    WHEN 82 THEN 'Violent rain showers'
                    WHEN 95 THEN 'Thunderstorm'
                    ELSE 'Unknown weather condition'
                  END AS longText
                , CONCAT('om_', ISNULL(CONVERT(varchar(12), h.weather_code), 'na'), '.png') AS icon
                , h.pop
                , h.dt
                , h.tm
                , @mli AS mli
                , CAST(NULL AS int) AS city_id
                , h.pressure
                , TRY_CONVERT(int, ROUND(r.rain_today, 0)) AS rain_today
                , TRY_CONVERT(int, ROUND(h.air_temperature, 0)) AS air_temperature
                , r.tmDay
                , h.weather_code
            FROM latest_hourly h
            LEFT JOIN daily_data  d ON d.dt = h.dt
            LEFT JOIN rain_by_day r ON r.dt = h.dt
        )

        MERGE dbo.weather_Forecast AS t
        USING src
           ON t.mli = src.mli
          AND t.dt  = src.dt

        WHEN MATCHED THEN
            UPDATE SET
                  t.[link]            = src.[link]
                , t.tmHigh            = ISNULL(src.tmHigh, t.tmHigh)
                , t.tmLow             = ISNULL(src.tmLow, t.tmLow)
                , t.gpfDay            = src.gpfDay
                , t.gpfNight          = src.gpfNight
                , t.humidity          = src.humidity
                , t.wind_max_speed    = src.wind_max_speed
                , t.wind_degree       = src.wind_degree
                , t.wind_direction    = src.wind_direction
                , t.shortText         = LEFT(src.shortText, 64)
                , t.longText          = LEFT(src.longText, 255)
                , t.icon              = LEFT(src.icon, 255)
                , t.pop               = src.pop
                , t.tm                = src.tm
                , t.pressure          = src.pressure
                , t.rain_today        = src.rain_today
                , t.air_temperature   = src.air_temperature
                , t.tmDay             = src.tmDay
                , t.weather_code      = src.weather_code

        WHEN NOT MATCHED BY TARGET THEN
            INSERT
            (
                  [link], [tmHigh], [tmLow], [gpfDay], [gpfNight]
                , [humidity], [wind_max_speed], [wind_degree], [wind_direction]
                , [shortText], [longText], [icon], [pop]
                , [dt], [tm], [mli], [city_id]
                , [pressure], [rain_today], [air_temperature], [tmDay], [weather_code]
            )
            VALUES
            (
                  src.[link]
                , ISNULL(src.tmHigh, 0)
                , ISNULL(src.tmLow, 0)
                , ISNULL(src.gpfDay, 0)
                , ISNULL(src.gpfNight, 0)
                , src.humidity
                , src.wind_max_speed
                , src.wind_degree
                , src.wind_direction
                , LEFT(src.shortText, 64)
                , LEFT(src.longText, 255)
                , LEFT(src.icon, 255)
                , src.pop
                , src.dt
                , src.tm
                , src.mli
                , src.city_id
                , src.pressure
                , src.rain_today
                , src.air_temperature
                , src.tmDay
                , src.weather_code
            );

    END TRY
    BEGIN CATCH
        SELECT
              ERROR_NUMBER()    AS ErrorNumber
            , ERROR_SEVERITY()  AS ErrorSeverity
            , ERROR_STATE()     AS ErrorState
            , ERROR_PROCEDURE() AS ErrorProcedure
            , ERROR_LINE()      AS ErrorLine
            , ERROR_MESSAGE()   AS ErrorMessage;
    END CATCH
END
GO

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
/*
    THE canonical forecast shredder. One procedure for EVERY provider.

    The weather workers (efcs-backend WeatherService in C#, efj-backend weather service in Java)
    convert each provider's document to a canonical envelope BEFORE storing it in dbo.ows_meteo.ows,
    so this procedure never has to know which provider produced it.

        { "schema":"fishfind.weather.forecast/v1", "provider":"visual-crossing", "providerType":4,
          "mli":"13068500", "fetchedUtc":"...",
          "days":[ { "date":..., "time":..., "tempHighC":..., "tempLowC":..., "tempC":...,
                     "tempDayC":..., "humidityPct":..., "windSpeedKmh":..., "windDegrees":...,
                     "windDirection":..., "pressureHpa":..., "precipChancePct":..., "precipMm":...,
                     "precipDayMm":..., "precipNightMm":..., "weatherCode":..., "icon":...,
                     "conditionsShort":..., "conditionsLong":... } ],
          "raw":{ ...the provider's original document... } }

    The members map 1:1 onto dbo.weather_Forecast, so this is OPENJSON ... WITH ... MERGE and nothing
    else. Unit conversion, provider quirks, picking one row per day and mapping icons all happen in
    the worker now, where they are unit-testable and where a failure can THROW -- which it cannot do
    here, because this runs inside TR_ows_meteo and an error would abort the worker's UPDATE and
    discard the payload it just fetched. That silence is what hid a whole provider until 2026-08-12.

    $.raw is deliberately ignored. It exists so a stored payload can still be inspected and replayed;
    that is what made the Visual Crossing diagnosis possible, and it survives the move to canonical.

    An envelope version this database does not know is a NO-OP, never a guess: a worker deployed
    ahead of the database must not have its payload half-parsed.

        called from [TR_ows_meteo]
    Covered by UNIT_TESTS/unit_test@OwsMeteoCanonical.sql.
*/
CREATE OR ALTER PROCEDURE [dbo].[sp_ows_meteo_canonical]
      @js   nvarchar(max)
    , @mli  varchar(64)
    , @link uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        IF @js IS NULL OR @mli IS NULL OR @link IS NULL OR ISJSON(@js) <> 1
            RETURN;

        IF JSON_VALUE(@js, '$.schema') <> N'fishfind.weather.forecast/v1'
            RETURN;

        ;WITH src AS
        (
            SELECT
                  @link AS [link]
                , d.dt
                , d.tm
                , d.tmHigh
                , d.tmLow
                , d.air_temperature
                , d.tmDay
                , d.humidity
                , d.wind_max_speed
                , d.wind_degree
                , d.wind_direction
                , d.pressure
                , d.pop
                , d.rain_today
                , d.gpfDay
                , d.gpfNight
                , d.weather_code
                , d.icon
                , d.shortText
                , d.longText
                , @mli AS mli
                , CAST(NULL AS int) AS city_id
            FROM OPENJSON(@js, '$.days')
            WITH (
                  dt              date         '$.date'
                , tm              time(7)      '$.time'
                , tmHigh          float        '$.tempHighC'
                , tmLow           float        '$.tempLowC'
                , air_temperature int          '$.tempC'
                , tmDay           float        '$.tempDayC'
                , humidity        float        '$.humidityPct'
                , wind_max_speed  float        '$.windSpeedKmh'
                , wind_degree     float        '$.windDegrees'
                , wind_direction  varchar(8)   '$.windDirection'
                , pressure        int          '$.pressureHpa'
                , pop             int          '$.precipChancePct'
                , rain_today      int          '$.precipMm'
                , gpfDay          float        '$.precipDayMm'
                , gpfNight        float        '$.precipNightMm'
                , weather_code    int          '$.weatherCode'
                , icon            varchar(255) '$.icon'
                , shortText       varchar(64)  '$.conditionsShort'
                , longText        varchar(255) '$.conditionsLong'
            ) d
            WHERE d.dt IS NOT NULL
        )
        MERGE dbo.weather_Forecast AS t
        USING src
           ON t.mli = src.mli
          AND t.dt  = src.dt

        WHEN MATCHED THEN
            UPDATE SET
                  t.[link]            = src.[link]
                , t.tmHigh            = ISNULL(src.tmHigh, t.tmHigh)
                , t.tmLow             = ISNULL(src.tmLow, t.tmLow)
                , t.gpfDay            = ISNULL(src.gpfDay, 0)
                , t.gpfNight          = ISNULL(src.gpfNight, 0)
                , t.humidity          = src.humidity
                , t.wind_max_speed    = src.wind_max_speed
                , t.wind_degree       = src.wind_degree
                , t.wind_direction    = src.wind_direction
                , t.shortText         = src.shortText
                , t.longText          = src.longText
                , t.icon              = src.icon
                , t.pop               = src.pop
                , t.tm                = src.tm
                , t.pressure          = src.pressure
                , t.rain_today        = src.rain_today
                , t.air_temperature   = src.air_temperature
                , t.tmDay             = src.tmDay
                , t.weather_code      = src.weather_code

        WHEN NOT MATCHED BY TARGET THEN
            INSERT
            (
                  [link], [tmHigh], [tmLow], [gpfDay], [gpfNight]
                , [humidity], [wind_max_speed], [wind_degree], [wind_direction]
                , [shortText], [longText], [icon], [pop]
                , [dt], [tm], [mli], [city_id]
                , [pressure], [rain_today], [air_temperature], [tmDay], [weather_code]
            )
            VALUES
            (
                  src.[link]
                , ISNULL(src.tmHigh, 0)
                , ISNULL(src.tmLow, 0)
                , ISNULL(src.gpfDay, 0)
                , ISNULL(src.gpfNight, 0)
                , src.humidity
                , src.wind_max_speed
                , src.wind_degree
                , src.wind_direction
                , src.shortText
                , src.longText
                , src.icon
                , src.pop
                , src.dt
                , src.tm
                , src.mli
                , src.city_id
                , src.pressure
                , src.rain_today
                , src.air_temperature
                , src.tmDay
                , src.weather_code
            );

    END TRY
    BEGIN CATCH
        SELECT
              ERROR_NUMBER()    AS ErrorNumber
            , ERROR_SEVERITY()  AS ErrorSeverity
            , ERROR_STATE()     AS ErrorState
            , ERROR_PROCEDURE() AS ErrorProcedure
            , ERROR_LINE()      AS ErrorLine
            , ERROR_MESSAGE()   AS ErrorMessage;
    END CATCH
END
GO


------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_save_lake_state' AND type = 'P')
    DROP PROCEDURE dbo.sp_save_lake_state
GO

/*
	save river state to database

	declare @data xml = N'<root PH="4" TDS="3.4"/>';
	EXEC sp_save_lake_state @data,  '743a5733-bf0d-11d8-92e2-080020a0f4c9', 4
	SELECT * FROM Lake_State WHERE lake_id = '743a5733-bf0d-11d8-92e2-080020a0f4c9'
*/
 
CREATE PROCEDURE dbo.sp_save_lake_state @data xml, @lake_id uniqueidentifier,  @month int
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
  IF NOT EXISTS (SELECT * FROM Lake_State WHERE Lake_id = @lake_id AND [month] = @month)
  BEGIN   -- get latest changed month
	INSERT INTO Lake_State (PH, phosphorus, TDS, Conductivity, Alkalinity, Hardness, Sodium
		, Chloride, Bicarbonate, Transparency, Oxygen, Salinity, Clarity, Velocity, water_degree, air_degree
		, [month], lake_id )
		SELECT TOP 1 PH, phosphorus, TDS, Conductivity, Alkalinity, Hardness, Sodium
		, Chloride, Bicarbonate, Transparency, Oxygen, Salinity, Clarity, Velocity, water_degree, air_degree
		, @month, lake_id FROM Lake_State
			WHERE lake_id = @lake_id ORDER BY stamp DESC

	IF NOT EXISTS (SELECT * FROM Lake_State WHERE Lake_id = @lake_id AND [month] = @month)
		INSERT INTO Lake_State ( [month], lake_id) VALUES (@month, @lake_id)
  END;

  ;WITH cte AS
  (
	SELECT  X.C.value(N'@PH', N'float')      as ph
	 , X.C.value(N'@phosphorus', N'float')   as phosphorus
	 , X.C.value(N'@TDS', N'float')          as tds
	 , X.C.value(N'@Conductivity', N'float') as Conductivity
	 , X.C.value(N'@Alkalinity', N'float')   as Alkalinity
	 , X.C.value(N'@Hardness', N'float')     as Hardness
	 , X.C.value(N'@Sodium', N'float')       as Sodium
	 , X.C.value(N'@Chloride', N'float')     as Chloride
	 , X.C.value(N'@Bicarbonate', N'float')  as Bicarbonate
	 , X.C.value(N'@Transparency', N'float') as Transparency
	 , X.C.value(N'@Oxygen', N'float')       as Oxygen
	 , X.C.value(N'@Salinity', N'float')     as Salinity
	 , X.C.value(N'@Clarity', N'float')      as Clarity
	 , X.C.value(N'@Velocity', N'float')     as Velocity
	 , X.C.value(N'@water_degree', N'float') as water_degree
	 , X.C.value(N'@air_degree', N'float')   as air_degree
	 , X.C.value(N'@cold_cool', N'bit')      as cold_cool
	 , X.C.value(N'@flow_stand', N'bit')     as flow_stand
	  FROM (SELECT @data AS XML_DATA) DATA CROSS APPLY DATA.XML_DATA.nodes(N'/root') as X(C)
  )update l SET l.ph = cte.ph,           l.phosphorus  = cte.phosphorus 
	, l.Conductivity = cte.Conductivity, l.Alkalinity  = cte.Alkalinity 
	, l.Hardness     = cte.Hardness ,    l.Sodium      = cte.Sodium 
	, l.Chloride     = cte.Chloride  ,   l.Bicarbonate = cte.Bicarbonate 
	, l.Transparency = cte.Transparency, l.Oxygen      = cte.Oxygen 
	, l.Salinity     = cte.Salinity  ,   l.Clarity     = cte.Clarity 
	, l.Velocity     = cte.Velocity ,    l.tds         = cte.tds
	, l.water_degree = cte.water_degree, l.air_degree  = cte.air_degree
	, l.flow_stand = cte.flow_stand,     l.cold_cool  = cte.cold_cool
  FROM cte JOIN Lake_State l ON l.lake_id = @lake_id AND l.month = @month

  RETURN @@ROWCOUNT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     

GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spUpdateFishFood' AND type = 'P')
    DROP PROCEDURE dbo.spUpdateFishFood
GO


CREATE PROCEDURE dbo.spUpdateFishFood @fish_id uniqueidentifier
   , @food_habitat int, @locked bit, @editor uniqueidentifier
   , @terrestrial_insects int
   , @terrestrial_animals int
   , @crustaceans int
   , @node_food_habitat nvarchar(max)
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
	UPDATE dbo.fish Set stamp = GETUTCDATE(), locked = @locked, editor=@editor 
	  , food_habitat=@food_habitat, terrestrial_insects=@terrestrial_insects
	  , terrestrial_animals=@terrestrial_animals, crustaceans=@crustaceans
	  , node_food_habitat = @node_food_habitat
	  WHERE fish_id =  @fish_Id;

  RETURN @@ROWCOUNT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spUpdateFishPredator' AND type = 'P')
    DROP PROCEDURE dbo.spUpdateFishPredator
GO

/*
		Add fish as a food for predator

		EXEC  dbo.spUpdateFishPredator '2cffb500-3e59-4120-9460-055856e9ac5c', 'dc38e981-2a0e-4f55-9179-6c6f9619cf0b'
*/

CREATE PROCEDURE dbo.spUpdateFishPredator @fish_id uniqueidentifier, @predator_id uniqueidentifier
WITH EXEC AS CALLER
AS 
BEGIN TRY  
SET NOCOUNT ON;
    IF @fish_id = @predator_id
		RETURN;
	If NOT EXISTS (SELECT * FROM fish_predator WHERE fish_id = @fish_id AND @predator_id = predator_id)
		INSERT INTO fish_predator (fish_id, predator_id) VALUES (@fish_id, @predator_id);

  RETURN @@ROWCOUNT;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO


------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_AddCaWaterData' AND type = 'P')
    DROP PROCEDURE dbo.sp_AddCaWaterData
GO
/*
	WaterWorkerService service call procedure to update canadian water data 

    declare @jsondoc nvarchar(max) = N'[{\"dt\":\"2021-01-27T00:00:00-05:00\",\"wl\":8.85,\"ds\":2.399},{\"dt\":\"2021-01-28T18:00:00-05:00\",\"wl\":7.19,\"ds\":2.339}]';
	EXEC  sp_AddCaWaterData '02CA007', 'ON', @jsondoc, 1.0

	select * from WaterData where mli='02CA007' and CAST(stamp AS DATE) >= '20200127' order by stamp desc

	delete from WaterData where mli='02CA007' and CAST(stamp AS DATE) >= '20200127'
*/

CREATE PROCEDURE sp_AddCaWaterData @mli varchar(64), @state nvarchar(8),  @jsondoc nvarchar(max), @koef float
AS
SET NOCOUNT ON
BEGIN TRY
    IF @jsondoc IS NULL
		RETURN
	declare @val nvarchar(max) = replace(@jsondoc, N'\"', N'"');
	
;WITH cte( discharge, elevation, dt)  AS
(
	SELECT AVG(ds), AVG(wl), CAST(dt AS DATE) FROM 
	(
		SELECT ds, wl, CONVERT(datetime, replace(LEFT(dt, 19), N'T', N' '), 120) AS dt 
			FROM OPENJSON(@val) WITH (dt varchar(32), wl float, ds float) 
	)x  GROUP BY CAST(dt AS DATE)
)
MERGE INTO WaterData AS t
        USING cte AS source ON CAST(t.stamp AS DATE ) = source.dt AND t.mli = @mli
    WHEN MATCHED THEN 
        UPDATE SET t.discharge = COALESCE(source.discharge * @koef,   t.discharge)
				 , t.elevation = COALESCE(source.elevation * @koef,   t.elevation)
    WHEN NOT MATCHED BY TARGET THEN  
        INSERT (stamp, discharge, elevation, mli ) 
		VALUES ( dt,  discharge,  elevation, @mli );

	RETURN @@ROWCOUNT
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;     
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spClear' AND type = 'P')
    DROP PROCEDURE dbo.spClear
GO
CREATE PROCEDURE dbo.spClear
AS
SET NOCOUNT ON
	BEGIN TRY 
	-- clear [SessionHandler]
	  ;WITH RankedSessions AS (
		SELECT
			id,
			ROW_NUMBER() OVER(PARTITION BY host, CAST(startSess AS DATE) ORDER BY startSess ASC) AS rn
		FROM
			[dbo].[SessionHandler]
	)
	DELETE FROM [dbo].[SessionHandler]
	WHERE id IN (
		SELECT id FROM RankedSessions WHERE rn > 1
	);
	SELECT @@ROWCOUNT
	--
	 delete from [dbo].[WaterData] where stamp < CAST(DATEADD(day, -15, GETDATE()) AS DATE);
	 SELECT @@ROWCOUNT
   --
	 delete from [dbo].[weather_Forecast]  where dt < CAST(DATEADD(day, -15, GETDATE()) AS DATE);
	 SELECT @@ROWCOUNT
 
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;   
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- used in water data services
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_DisableWaterStation' AND type = 'P')
    DROP PROCEDURE dbo.sp_DisableWaterStation
GO

CREATE OR ALTER PROCEDURE dbo.sp_DisableWaterStation
    @mli varchar(64)
AS
SET NOCOUNT ON
BEGIN TRY 

    UPDATE dbo.WaterStation SET supported = 0 WHERE mli = @mli;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH

GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_UpdateWaterData' AND type = 'P')
    DROP PROCEDURE dbo.sp_UpdateWaterData
GO

CREATE PROCEDURE dbo.sp_UpdateWaterData
    @mli varchar(64),
    @stamp datetime2,
    @elevation float,
    @discharge float
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.WaterData
    SET elevation = @elevation,
        discharge = @discharge
    WHERE mli = @mli
      AND stamp = @stamp;

    IF @@ROWCOUNT = 0
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.WaterData (mli, stamp, elevation, discharge)
            VALUES (@mli, @stamp, @elevation, @discharge);

            -- Delete records older than 15 days after a successful insert
            DELETE FROM dbo.WaterData
            WHERE @mli = mli AND stamp < DATEADD(DAY, -15, GETDATE());
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2601, 2627)
            BEGIN
                UPDATE dbo.WaterData
                SET elevation = @elevation,
                    discharge = @discharge
                WHERE mli = @mli
                  AND stamp = @stamp;
            END
            ELSE
            BEGIN
                THROW;
            END
        END CATCH
    END
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Drop existing procedure if it exists
IF OBJECT_ID('dbo.sp_upsert_fish_catch_probability', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_upsert_fish_catch_probability;
GO
/*
-- Example: Set catch probabilities for Salmon, Chinook
EXEC dbo.sp_upsert_fish_catch_probability 
    @fish_id = '5d069a33-6b36-4314-bd49-8a32a6c92245',
    @probability_jan = 5,
    @probability_feb = 5,
    @probability_mar = 10,
    @probability_apr = 30,
    @probability_may = 100,
    @probability_jun = 220,
    @probability_jul = 380,
    @probability_aug = 500,
    @probability_sep = 480,
    @probability_oct = 260,
    @probability_nov = 80,
    @probability_dec = 10;
*/

/*  stored procedure that accepts a fish ID and 12 probability values for storing the catch probability for each month. 
The procedure will validate the input, then use a MERGE statement to insert or update the probabilities 
in the fish_catch_probability table. It will return the number of rows affected.
*/
CREATE PROCEDURE dbo.sp_upsert_fish_catch_probability
(
    @fish_id            uniqueidentifier,
    @probability_jan    smallint,
    @probability_feb    smallint,
    @probability_mar    smallint,
    @probability_apr    smallint,
    @probability_may    smallint,
    @probability_jun    smallint,
    @probability_jul    smallint,
    @probability_aug    smallint,
    @probability_sep    smallint,
    @probability_oct    smallint,
    @probability_nov    smallint,
    @probability_dec    smallint
)
AS
SET NOCOUNT ON
	BEGIN TRY 
 -- Validate fish_id exists
    IF NOT EXISTS (SELECT 1 FROM dbo.fish WHERE fish_id = @fish_id)
    BEGIN
        RAISERROR('Fish ID does not exist in fish table', 16, 1);
        RETURN;
    END

    -- Validate all probabilities are in valid range (0-500)
    IF (@probability_jan NOT BETWEEN 0 AND 500 OR
        @probability_feb NOT BETWEEN 0 AND 500 OR
        @probability_mar NOT BETWEEN 0 AND 500 OR
        @probability_apr NOT BETWEEN 0 AND 500 OR
        @probability_may NOT BETWEEN 0 AND 500 OR
        @probability_jun NOT BETWEEN 0 AND 500 OR
        @probability_jul NOT BETWEEN 0 AND 500 OR
        @probability_aug NOT BETWEEN 0 AND 500 OR
        @probability_sep NOT BETWEEN 0 AND 500 OR
        @probability_oct NOT BETWEEN 0 AND 500 OR
        @probability_nov NOT BETWEEN 0 AND 500 OR
        @probability_dec NOT BETWEEN 0 AND 500)
    BEGIN
        RAISERROR('All probability values must be between 0 and 500', 16, 1);
        RETURN;
    END

    -- Create a table variable with all 12 months
    DECLARE @MonthData TABLE (month tinyint, probability smallint);
    
    INSERT INTO @MonthData (month, probability)
    VALUES 
        (1,  @probability_jan),
        (2,  @probability_feb),
        (3,  @probability_mar),
        (4,  @probability_apr),
        (5,  @probability_may),
        (6,  @probability_jun),
        (7,  @probability_jul),
        (8,  @probability_aug),
        (9,  @probability_sep),
        (10, @probability_oct),
        (11, @probability_nov),
        (12, @probability_dec);

    -- Use MERGE to insert or update all 12 months
    MERGE INTO dbo.fish_catch_probability AS target
    USING @MonthData AS source
    ON target.fish_id = @fish_id AND target.month = source.month
    WHEN MATCHED THEN
        UPDATE SET target.probability = source.probability
    WHEN NOT MATCHED THEN
        INSERT (fish_id, month, probability)
        VALUES (@fish_id, source.month, source.probability);
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;          
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Step 1: Create a User-Defined Table Type
IF TYPE_ID('dbo.DailyProbabilityType') IS NOT NULL
    DROP TYPE dbo.DailyProbabilityType;
GO

/*
-- Declare and populate the table variable
DECLARE @probs dbo.DailyProbabilityType;

INSERT INTO @probs ([day], probability)
VALUES 
    (1, 30), (2, 35), (3, 40), (4, 45), (5, 50), (6, 55), (7, 60),
    (8, 65), (9, 70), (10, 75), (11, 80), (12, 85), (13, 90), (14, 95),
    (15, 100), (16, 95), (17, 90), (18, 85), (19, 80), (20, 75),
    (21, 70), (22, 65), (23, 60), (24, 55), (25, 50), (26, 45), (27, 40), (28, 35);

EXEC dbo.sp_upsert_fish_lunar_catch_probability 
    @fish_id = '5d069a33-6b36-4314-bd49-8a32a6c92245',
    @probabilities = @probs;    


    Alternative procedure that accepts a fish ID and a table-valued parameter (TVP) containing day and probability values. 
    The procedure will validate the input, then use a MERGE statement to insert or update the probabilities in the fish_lunar_catch_probability table. 
    It will return the number of rows affected.
*/

CREATE TYPE dbo.DailyProbabilityType AS TABLE
(
    [day]       tinyint NOT NULL PRIMARY KEY,
    probability smallint NOT NULL
);
GO

-- Step 2: Create the stored procedure using TVP
IF OBJECT_ID('dbo.sp_upsert_fish_lunar_catch_probability', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_upsert_fish_lunar_catch_probability;
GO

CREATE PROCEDURE dbo.sp_upsert_fish_lunar_catch_probability
(
    @fish_id uniqueidentifier,
    @probabilities dbo.DailyProbabilityType READONLY
)
AS
SET NOCOUNT ON
BEGIN TRY

    -- Validate fish_id exists
    IF NOT EXISTS (SELECT 1 FROM dbo.fish WHERE fish_id = @fish_id)
    BEGIN
        RAISERROR('Fish ID does not exist in fish table', 16, 1);
        RETURN;
    END

    -- Validate day range (1-28)
    IF EXISTS (SELECT 1 FROM @probabilities WHERE [day] < 1 OR [day] > 28)
    BEGIN
        RAISERROR('Day values must be between 1 and 28', 16, 1);
        RETURN;
    END

    -- Validate probability range (0-100)
    IF EXISTS (SELECT 1 FROM @probabilities WHERE probability < 0 OR probability > 100)
    BEGIN
        RAISERROR('Probability values must be between 0 and 100', 16, 1);
        RETURN;
    END

    -- MERGE to insert or update
    MERGE INTO dbo.fish_lunar_catch_probability AS target
    USING @probabilities AS source
    ON target.fish_id = @fish_id AND target.[day] = source.[day]
    WHEN MATCHED THEN
        UPDATE SET target.probability = source.probability
    WHEN NOT MATCHED THEN
        INSERT (fish_id, [day], probability)
        VALUES (@fish_id, source.[day], source.probability);

END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spPersistIpBan' AND type = 'P')
    DROP PROCEDURE dbo.spPersistIpBan
GO

CREATE PROCEDURE [dbo].spPersistIpBan (@counterPage int, @agent nvarchar(255), @host nvarchar(255), @ip4 varchar(15), @startPage nvarchar(255), @baned bit, @id uniqueidentifier)
AS
SET NOCOUNT ON
	BEGIN TRY 
	 UPDATE SessionHandler SET counterPage = @counterPage, userAgent = @agent, host = @host, baned = 1 WHERE (@ip4 <> '' AND ip4 = @ip4)
     IF @@ROWCOUNT > 0
     BEGIN
        RETURN;
     END
     INSERT INTO SessionHandler (id, userAgent, host, startPage, baned, ip4, counterPage) VALUES (@id, @agent, @host, @startPage, @baned, @ip4, @counterPage)
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;          
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'spRegisterPageHit' AND type = 'P')
    DROP PROCEDURE dbo.spRegisterPageHit
GO

CREATE PROCEDURE [dbo].spRegisterPageHit(@counterPage int, @agent nvarchar(255), @host nvarchar(255), @ip4 varchar(15), @startPage nvarchar(255), @baned bit, @id uniqueidentifier)
AS
SET NOCOUNT ON
	BEGIN TRY 
	 UPDATE SessionHandler SET counterPage = ISNULL(counterPage, 0) + @counterPage, userAgent = @agent, host = @host, startPage = @startPage, baned = 0 WHERE activityDate = CAST(GETUTCDATE() AS date) AND (@ip4 <> '' AND ip4 = @ip4)
     IF @@ROWCOUNT > 0
     BEGIN
        RETURN;
     END
     INSERT INTO SessionHandler (id, userAgent, host, startPage, baned, ip4, counterPage) VALUES (@id, @agent, @host, @startPage, @baned, @ip4, @counterPage)
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH;          
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_add_catch_memo' AND type = 'P')
    DROP PROCEDURE dbo.sp_add_catch_memo
GO

-- 7. sp_add_catch_memo : upsert (author + 60-day lock enforced) --------------
CREATE OR ALTER PROCEDURE dbo.sp_add_catch_memo
    @id          UNIQUEIDENTIFIER,
    @lake_id     UNIQUEIDENTIFIER,
    @userid      UNIQUEIDENTIFIER,
    @fish_id     UNIQUEIDENTIFIER = NULL,
    @species     NVARCHAR(120)    = NULL,
    @title       NVARCHAR(200)    = NULL,
    @text        NVARCHAR(MAX)    = NULL,
    @lat         FLOAT            = NULL,
    @lon         FLOAT            = NULL,
    @method      NVARCHAR(200)    = NULL,
    @tackle      NVARCHAR(200)    = NULL,
    @lure        NVARCHAR(200)    = NULL,
    @catch_date  DATETIME2        = NULL,
    @weight      FLOAT            = NULL,
    @weight_unit NVARCHAR(8)      = NULL,   -- 'kg' | 'lb'
    @length      FLOAT            = NULL,
    @length_unit NVARCHAR(8)      = NULL,   -- 'cm' | 'in'
    @released    BIT              = NULL,   -- 1 = catch & release
    @private     BIT              = 0,      -- 1 = only author + admins see it
    @weather_temp     FLOAT         = NULL,   -- snapshot from dbo.fn_catch_weather_snapshot at save time
    @weather_pressure FLOAT         = NULL,
    @weather_text     NVARCHAR(64)  = NULL,
    @weather_icon     NVARCHAR(255) = NULL,
    @water_temp       FLOAT         = NULL,   -- water temp snapshot from dbo.fn_catch_weather_snapshot
    @is_admin    BIT              = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM dbo.catch_memo WHERE catch_memo_id = @id)
    BEGIN
        UPDATE dbo.catch_memo
        SET catch_memo_fish_id     = @fish_id,
            catch_memo_species     = @species,
            catch_memo_title       = @title,
            catch_memo_text        = @text,
            catch_memo_lat         = @lat,
            catch_memo_lon         = @lon,
            catch_memo_method      = @method,
            catch_memo_tackle      = @tackle,
            catch_memo_lure        = @lure,
            catch_memo_catch_date  = @catch_date,
            catch_memo_weight      = @weight,
            catch_memo_weight_unit = @weight_unit,
            catch_memo_length      = @length,
            catch_memo_length_unit = @length_unit,
            catch_memo_released    = @released,
            catch_memo_private     = ISNULL(@private, 0),
            catch_memo_weather_temp     = @weather_temp,
            catch_memo_weather_pressure = @weather_pressure,
            catch_memo_weather_text     = @weather_text,
            catch_memo_weather_icon     = @weather_icon,
            catch_memo_water_temp       = @water_temp,
            catch_memo_updated     = SYSUTCDATETIME()
        WHERE catch_memo_id = @id
          AND ( @is_admin = 1
                OR ( catch_memo_userid = @userid
                     AND DATEDIFF(DAY, catch_memo_created, SYSUTCDATETIME()) <= 60 ) );
    END
    ELSE
    BEGIN
        INSERT INTO dbo.catch_memo
            (catch_memo_id, catch_memo_lake_id, catch_memo_userid, catch_memo_fish_id,
             catch_memo_species, catch_memo_title, catch_memo_text, catch_memo_lat, catch_memo_lon,
             catch_memo_method, catch_memo_tackle, catch_memo_lure, catch_memo_catch_date,
             catch_memo_weight, catch_memo_weight_unit, catch_memo_length, catch_memo_length_unit,
             catch_memo_released, catch_memo_private,
             catch_memo_weather_temp, catch_memo_weather_pressure, catch_memo_weather_text, catch_memo_weather_icon,
             catch_memo_water_temp)
        VALUES
            (@id, @lake_id, @userid, @fish_id,
             @species, @title, @text, @lat, @lon,
             @method, @tackle, @lure, @catch_date,
             @weight, @weight_unit, @length, @length_unit,
             @released, ISNULL(@private, 0),
             @weather_temp, @weather_pressure, @weather_text, @weather_icon,
             @water_temp);
    END
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_add_catch_memo_photo' AND type = 'P')
    DROP PROCEDURE dbo.sp_add_catch_memo_photo
GO
-- 8. sp_add_catch_memo_photo : attach one photo (author + lock enforced, max 3
--    non-hidden photos per memo -- covers both the web form and the mobile
--    endpoint, which both call this proc) -------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_add_catch_memo_photo
    @memo_id     UNIQUEIDENTIFIER,
    @userid      UNIQUEIDENTIFIER,
    @pic         VARBINARY(MAX),
    @label       NVARCHAR(260) = NULL,
    @ord         INT           = 0,
    @description NVARCHAR(500) = NULL,
    @author      NVARCHAR(200) = NULL,
    @is_admin    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @photo_count INT;
    SELECT @photo_count = COUNT(*) FROM dbo.catch_memo_photo
    WHERE catch_memo_photo_memoid = @memo_id AND catch_memo_photo_hidden = 0;

    IF @photo_count < 3
       AND EXISTS (
        SELECT 1 FROM dbo.catch_memo
        WHERE catch_memo_id = @memo_id
          AND ( @is_admin = 1
                OR ( catch_memo_userid = @userid
                     AND DATEDIFF(DAY, catch_memo_created, SYSUTCDATETIME()) <= 60 ) ) )
    BEGIN
        -- id generated here (not a table DEFAULT): catch_memo_photo_id is a UNIQUEIDENTIFIER, safe
        -- to generate independently on any peer-to-peer replication node, unlike the INT IDENTITY
        -- this column used to be.
        DECLARE @new_id UNIQUEIDENTIFIER;
        EXEC dbo.sp_NewGuidV7 @new_id OUTPUT;
        INSERT INTO dbo.catch_memo_photo
            (catch_memo_photo_id, catch_memo_photo_memoid, catch_memo_photo_pic, catch_memo_photo_label, catch_memo_photo_ord,
             catch_memo_photo_description, catch_memo_photo_author)
        VALUES (@new_id, @memo_id, @pic, @label, @ord, @description, @author);
    END
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_del_catch_memo' AND type = 'P')
    DROP PROCEDURE dbo.sp_del_catch_memo
GO

-- 9. sp_del_catch_memo : delete a memo (photos cascade) ----------------------
CREATE OR ALTER PROCEDURE dbo.sp_del_catch_memo
    @id       UNIQUEIDENTIFIER,
    @userid   UNIQUEIDENTIFIER,
    @is_admin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.catch_memo
    WHERE catch_memo_id = @id
      AND ( @is_admin = 1
            OR ( catch_memo_userid = @userid
                 AND DATEDIFF(DAY, catch_memo_created, SYSUTCDATETIME()) <= 60 ) );
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_clone_catch_memo' AND type = 'P')
    DROP PROCEDURE dbo.sp_clone_catch_memo
GO
-- sp_clone_catch_memo : copy an existing memo for @userid as a starting point for a new catch --
-- everything EXCEPT species/weight/length/photos (the angler fills those in for the new catch).
-- @new_id is generated by the caller (wfCatchMemoEdit.aspx.cs, via Models/GuidV7.cs), matching how
-- sp_add_catch_memo already works. No-ops (0 rows inserted) when:
--   * @userid already has an unfinished clone (fn_catch_memo_pending_clone_id) -- one at a time,
--     enforced here too even though the C# page already checks this before calling in.
--   * @source_id doesn't exist, or is a private memo not owned by @userid/an admin -- a private
--     memo's other fields are only ever visible to its author/admins, so cloning must respect that
--     even though a non-owner would never be offered the "Clone" link for it in the first place.
CREATE OR ALTER PROCEDURE dbo.sp_clone_catch_memo
    @source_id UNIQUEIDENTIFIER,
    @new_id    UNIQUEIDENTIFIER,
    @userid    UNIQUEIDENTIFIER,
    @is_admin  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF dbo.fn_catch_memo_pending_clone_id(@userid) IS NOT NULL
        RETURN;

    INSERT INTO dbo.catch_memo
        (catch_memo_id, catch_memo_lake_id, catch_memo_userid, catch_memo_title, catch_memo_text,
         catch_memo_lat, catch_memo_lon, catch_memo_method, catch_memo_tackle, catch_memo_lure,
         catch_memo_catch_date, catch_memo_released, catch_memo_private,
         catch_memo_weather_temp, catch_memo_weather_pressure, catch_memo_weather_text, catch_memo_weather_icon,
         catch_memo_water_temp, catch_memo_cloned_from)
    SELECT
        @new_id, catch_memo_lake_id, @userid, catch_memo_title, catch_memo_text,
        catch_memo_lat, catch_memo_lon, catch_memo_method, catch_memo_tackle, catch_memo_lure,
        catch_memo_catch_date, catch_memo_released, catch_memo_private,
        catch_memo_weather_temp, catch_memo_weather_pressure, catch_memo_weather_text, catch_memo_weather_icon,
        catch_memo_water_temp, catch_memo_id
    FROM dbo.catch_memo
    WHERE catch_memo_id = @source_id
      AND ( catch_memo_private = 0 OR @is_admin = 1 OR catch_memo_userid = @userid );
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_del_catch_memo_photo' AND type = 'P')
    DROP PROCEDURE dbo.sp_del_catch_memo_photo
GO

 

-- 10. sp_del_catch_memo_photo : remove a single photo (author + lock enforced) -
--     Admins physically delete the row. Everyone else only "hides" it (sets
--     catch_memo_photo_hidden = 1) -- the row/bytes stay for admin review;
--     fn_catch_memo_photo_list / fn_catch_memo_photo_handler both exclude
--     hidden photos, so it disappears from every view either way.
CREATE OR ALTER PROCEDURE dbo.sp_del_catch_memo_photo
    @photo_id UNIQUEIDENTIFIER,
    @userid   UNIQUEIDENTIFIER,
    @is_admin BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @is_admin = 1
    BEGIN
        DELETE FROM dbo.catch_memo_photo WHERE catch_memo_photo_id = @photo_id;
    END
    ELSE
    BEGIN
        UPDATE p
        SET catch_memo_photo_hidden = 1
        FROM dbo.catch_memo_photo p
        JOIN dbo.catch_memo m ON m.catch_memo_id = p.catch_memo_photo_memoid
        WHERE p.catch_memo_photo_id = @photo_id
          AND m.catch_memo_userid = @userid
          AND DATEDIFF(DAY, m.catch_memo_created, SYSUTCDATETIME()) <= 60;
    END
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_toggle_catch_memo_photo_like' AND type = 'P')
    DROP PROCEDURE dbo.sp_toggle_catch_memo_photo_like
GO
-- sp_toggle_catch_memo_photo_like : a logged-in user likes / unlikes a Catch Log photo (binary
-- toggle). Any authenticated user may like any visible photo (no author/lock check -- likes are
-- public appreciation, not editing). A like on a hidden or non-existent photo is ignored. Returns a
-- single row (liked, like_count) reflecting the NEW state, which the HandlerLike.ashx endpoint
-- echoes back to the page as JSON.
CREATE OR ALTER PROCEDURE dbo.sp_toggle_catch_memo_photo_like
    @photo_id UNIQUEIDENTIFIER,
    @userid   UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @liked BIT = 0;

    IF EXISTS (SELECT 1 FROM dbo.catch_memo_photo
               WHERE catch_memo_photo_id = @photo_id AND catch_memo_photo_hidden = 0)
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.catch_memo_photo_like
                   WHERE catch_memo_photo_like_photoid = @photo_id
                     AND catch_memo_photo_like_userid  = @userid)
        BEGIN
            DELETE FROM dbo.catch_memo_photo_like
            WHERE catch_memo_photo_like_photoid = @photo_id
              AND catch_memo_photo_like_userid  = @userid;
            SET @liked = 0;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.catch_memo_photo_like (catch_memo_photo_like_photoid, catch_memo_photo_like_userid)
            VALUES (@photo_id, @userid);
            SET @liked = 1;
        END
    END

    SELECT
        @liked AS liked,
        ( SELECT COUNT(*) FROM dbo.catch_memo_photo_like
          WHERE catch_memo_photo_like_photoid = @photo_id ) AS like_count;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_add_catch_memo_comment' AND type = 'P')
    DROP PROCEDURE dbo.sp_add_catch_memo_comment
GO
-- sp_add_catch_memo_comment : any logged-in user posts a comment to a memo's discussion. No
-- author/lock check (discussion is open to all registered users); empty text and non-existent memos
-- are ignored. Returns the created row (id, text, created, author name) so HandlerComment.ashx can
-- echo it straight back to the page without a re-query.
CREATE OR ALTER PROCEDURE dbo.sp_add_catch_memo_comment
    @memo_id UNIQUEIDENTIFIER,
    @userid  UNIQUEIDENTIFIER,
    @text    NVARCHAR(2000)
AS
BEGIN
    SET NOCOUNT ON;

    IF @text IS NULL OR LEN(LTRIM(RTRIM(@text))) = 0 RETURN;
    IF NOT EXISTS (SELECT 1 FROM dbo.catch_memo WHERE catch_memo_id = @memo_id) RETURN;

    DECLARE @new_id UNIQUEIDENTIFIER;
    EXEC dbo.sp_NewGuidV7 @new_id OUTPUT;

    INSERT INTO dbo.catch_memo_comment
        (catch_memo_comment_id, catch_memo_comment_memoid, catch_memo_comment_userid, catch_memo_comment_text)
    VALUES (@new_id, @memo_id, @userid, LTRIM(RTRIM(@text)));

    SELECT
        c.catch_memo_comment_id,
        c.catch_memo_comment_text,
        c.catch_memo_comment_created,
        u.userName AS catch_memo_comment_user_name
    FROM dbo.catch_memo_comment c
    LEFT JOIN dbo.Users u ON u.id = c.catch_memo_comment_userid
    WHERE c.catch_memo_comment_id = @new_id;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_del_catch_memo_comment' AND type = 'P')
    DROP PROCEDURE dbo.sp_del_catch_memo_comment
GO
-- sp_del_catch_memo_comment : SOFT-delete a single comment (the row and its text are kept). The
-- comment's own author may delete it; admins may delete any (moderation). Everyone else is a no-op.
-- The kept text lets an admin still see what was said (rendered struck-through); non-admins just
-- see the word "deleted". Already-deleted comments are a clean no-op.
CREATE OR ALTER PROCEDURE dbo.sp_del_catch_memo_comment
    @comment_id UNIQUEIDENTIFIER,
    @userid     UNIQUEIDENTIFIER,
    @is_admin   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.catch_memo_comment
    SET catch_memo_comment_deleted = 1
    WHERE catch_memo_comment_id = @comment_id
      AND catch_memo_comment_deleted = 0
      AND ( @is_admin = 1 OR catch_memo_comment_userid = @userid );
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
--  Private user-to-user messaging
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_send_user_message' AND type = 'P')
    DROP PROCEDURE dbo.sp_send_user_message
GO
-- sp_send_user_message : deliver a private message from @from to a recipient (given by @to_id, or
-- resolved from @to_name). Returns a single row (status, banned):
--   status = 'sent'         -- delivered
--          | 'banned'       -- @from holds an account send ban (the >50 anti-spam ban): nothing sent
--          | 'blocked'      -- the recipient has blocked @from
--          | 'no_recipient' -- @to_name/@to_id doesn't resolve to a live user
--          | 'self'         -- can't message yourself
--          | 'empty'        -- blank text
--   banned = 1 when THIS send pushed @from over 50 messages and auto-banned the account.
CREATE OR ALTER PROCEDURE dbo.sp_send_user_message
    @from    UNIQUEIDENTIFIER,
    @text    NVARCHAR(2000),
    @to_id   UNIQUEIDENTIFIER = NULL,
    @to_name NVARCHAR(64)     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @to UNIQUEIDENTIFIER = NULL;

    IF EXISTS (SELECT 1 FROM dbo.user_send_ban WHERE user_send_ban_userid = @from)
    BEGIN
        SELECT 'banned' AS status, CAST(1 AS BIT) AS banned; RETURN;
    END
    IF @text IS NULL OR LEN(LTRIM(RTRIM(@text))) = 0
    BEGIN
        SELECT 'empty' AS status, CAST(0 AS BIT) AS banned; RETURN;
    END

    -- resolve the recipient (id wins; otherwise by unique userName), live users only
    IF @to_id IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Users WHERE id = @to_id AND deleted = 0)
        SET @to = @to_id;
    ELSE IF @to_name IS NOT NULL
        SELECT TOP 1 @to = id FROM dbo.Users WHERE userName = @to_name AND deleted = 0;

    IF @to IS NULL
    BEGIN
        SELECT 'no_recipient' AS status, CAST(0 AS BIT) AS banned; RETURN;
    END
    IF @to = @from
    BEGIN
        SELECT 'self' AS status, CAST(0 AS BIT) AS banned; RETURN;
    END
    IF EXISTS (SELECT 1 FROM dbo.user_message_block
               WHERE user_message_block_userid = @to AND user_message_block_blockedid = @from)
    BEGIN
        SELECT 'blocked' AS status, CAST(0 AS BIT) AS banned; RETURN;
    END

    DECLARE @id UNIQUEIDENTIFIER;
    EXEC dbo.sp_NewGuidV7 @id OUTPUT;
    INSERT INTO dbo.user_message (user_message_id, user_message_from, user_message_to, user_message_text)
    VALUES (@id, @from, @to, LTRIM(RTRIM(@text)));

    -- Anti-spam: once a user has sent MORE THAN 50 messages, ban the account from sending further.
    -- (The message that tips it over 50 is still delivered; the next attempt returns 'banned'.)
    DECLARE @banned BIT = 0;
    IF (SELECT COUNT(*) FROM dbo.user_message WHERE user_message_from = @from) > 50
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.user_send_ban WHERE user_send_ban_userid = @from)
            INSERT INTO dbo.user_send_ban (user_send_ban_userid, user_send_ban_reason)
            VALUES (@from, N'auto: over 50 messages sent');
        SET @banned = 1;
    END

    SELECT 'sent' AS status, @banned AS banned;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_block_user_sender' AND type = 'P')
    DROP PROCEDURE dbo.sp_block_user_sender
GO
-- sp_block_user_sender : the recipient @userid blocks @blockedid from sending them messages
-- (idempotent; can't block yourself).
CREATE OR ALTER PROCEDURE dbo.sp_block_user_sender
    @userid    UNIQUEIDENTIFIER,
    @blockedid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    IF @userid = @blockedid RETURN;
    IF NOT EXISTS (SELECT 1 FROM dbo.user_message_block
                   WHERE user_message_block_userid = @userid AND user_message_block_blockedid = @blockedid)
        INSERT INTO dbo.user_message_block (user_message_block_userid, user_message_block_blockedid)
        VALUES (@userid, @blockedid);
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_unblock_user_sender' AND type = 'P')
    DROP PROCEDURE dbo.sp_unblock_user_sender
GO
-- sp_unblock_user_sender : the recipient @userid lifts their block on @blockedid.
CREATE OR ALTER PROCEDURE dbo.sp_unblock_user_sender
    @userid    UNIQUEIDENTIFIER,
    @blockedid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.user_message_block
    WHERE user_message_block_userid = @userid AND user_message_block_blockedid = @blockedid;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_mark_user_messages_read' AND type = 'P')
    DROP PROCEDURE dbo.sp_mark_user_messages_read
GO
-- sp_mark_user_messages_read : mark all of @userid's received messages as read (called when they
-- open their inbox).
CREATE OR ALTER PROCEDURE dbo.sp_mark_user_messages_read
    @userid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.user_message SET user_message_read = 1
    WHERE user_message_to = @userid AND user_message_read = 0;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_admin_unban_user' AND type = 'P')
    DROP PROCEDURE dbo.sp_admin_unban_user
GO
-- sp_admin_unban_user : lift an account send ban (admin-only -- HandlerMessage.ashx checks
-- DbLayer.IsAdminUser before calling). Target given by @userid or resolved from @name. Returns a
-- single row (status = 'unbanned' | 'no_user').
CREATE OR ALTER PROCEDURE dbo.sp_admin_unban_user
    @userid UNIQUEIDENTIFIER = NULL,
    @name   NVARCHAR(64)     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @u UNIQUEIDENTIFIER = @userid;
    IF @u IS NULL AND @name IS NOT NULL
        SELECT TOP 1 @u = id FROM dbo.Users WHERE userName = @name AND deleted = 0;

    IF @u IS NULL
    BEGIN
        SELECT 'no_user' AS status; RETURN;
    END
    DELETE FROM dbo.user_send_ban WHERE user_send_ban_userid = @u;
    SELECT 'unbanned' AS status;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_users_sync_outbox_take' AND type = 'P')
    DROP PROCEDURE dbo.sp_users_sync_outbox_take
GO
-- sp_users_sync_outbox_take : called by the fishfind-frontend RabbitMQ users-sync dispatcher
-- (aspnet/tools/Run-UsersSyncDispatch.ps1) to read the oldest undispatched dbo.UsersSyncOutbox
-- rows. The caller must ack each row (sp_users_sync_outbox_ack) only after it has been durably
-- published to RabbitMQ; a row left unacked is simply re-read next run -- harmless, because the
-- cproxy consumer dedups by the outbox_id-derived eventId.
CREATE OR ALTER PROCEDURE dbo.sp_users_sync_outbox_take
    @batchSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@batchSize)
          outbox_id, action, id, UsersId, userName, email, lastVisit, access, suspended, authType, deleted, deletedUtc, created_utc
    FROM dbo.UsersSyncOutbox
    WHERE dispatched_utc IS NULL
    ORDER BY outbox_id;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_users_sync_outbox_ack' AND type = 'P')
    DROP PROCEDURE dbo.sp_users_sync_outbox_ack
GO
-- sp_users_sync_outbox_ack : marks one dbo.UsersSyncOutbox row dispatched after the fishfind-frontend
-- dispatcher confirms RabbitMQ accepted the publish ({"routed":true}). Idempotent -- acking an
-- already-dispatched or unknown outbox_id updates zero rows rather than erroring.
CREATE OR ALTER PROCEDURE dbo.sp_users_sync_outbox_ack
    @outbox_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.UsersSyncOutbox SET dispatched_utc = SYSUTCDATETIME()
    WHERE outbox_id = @outbox_id AND dispatched_utc IS NULL;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_users_sync_outbox_purge' AND type = 'P')
    DROP PROCEDURE dbo.sp_users_sync_outbox_purge
GO
-- sp_users_sync_outbox_purge : deletes dispatched dbo.UsersSyncOutbox rows older than @olderThanDays
-- so the outbox stays bounded. Never deletes an undispatched row, however old.
CREATE OR ALTER PROCEDURE dbo.sp_users_sync_outbox_purge
    @olderThanDays INT = 7
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.UsersSyncOutbox
    WHERE dispatched_utc IS NOT NULL
      AND dispatched_utc < DATEADD(DAY, -@olderThanDays, SYSUTCDATETIME());
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_add_catch_pending_fish' AND type = 'P')
    DROP PROCEDURE dbo.sp_add_catch_pending_fish
GO
-- sp_add_catch_pending_fish : queue a typed species suggestion (dedup + skip-known)
CREATE OR ALTER PROCEDURE dbo.sp_add_catch_pending_fish
    @lake_id   UNIQUEIDENTIFIER,
    @userid    UNIQUEIDENTIFIER,
    @fish_name NVARCHAR(120)
AS
BEGIN
    SET NOCOUNT ON;
    IF @fish_name IS NULL OR LTRIM(RTRIM(@fish_name)) = N'' RETURN;
    SET @fish_name = LTRIM(RTRIM(@fish_name));

    -- already a species of this water body? then it isn't "new"
    IF EXISTS (SELECT 1 FROM dbo.lake_fish lf JOIN dbo.fish f ON f.fish_id = lf.fish_id
               WHERE lf.lake_Id = @lake_id AND f.fish_name = @fish_name)
        RETURN;

    -- already queued for this water body?
    IF EXISTS (SELECT 1 FROM dbo.catch_pending_fish
               WHERE catch_pending_fish_lake_id = @lake_id
                 AND catch_pending_fish_name    = @fish_name
                 AND catch_pending_fish_status  = 0)
        RETURN;

    -- id generated here (not a table DEFAULT): catch_pending_fish_id is a UNIQUEIDENTIFIER, safe
    -- to generate independently on any peer-to-peer replication node, unlike the INT IDENTITY
    -- this column used to be.
    DECLARE @new_id UNIQUEIDENTIFIER;
    EXEC dbo.sp_NewGuidV7 @new_id OUTPUT;
    INSERT INTO dbo.catch_pending_fish
        (catch_pending_fish_id, catch_pending_fish_lake_id, catch_pending_fish_userid, catch_pending_fish_name)
    VALUES (@new_id, @lake_id, @userid, @fish_name);
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_set_catch_pending_fish_status' AND type = 'P')
    DROP PROCEDURE dbo.sp_set_catch_pending_fish_status
GO
-- sp_set_catch_pending_fish_status : admin approve(1) / dismiss(2) ----------
CREATE OR ALTER PROCEDURE dbo.sp_set_catch_pending_fish_status
    @id           UNIQUEIDENTIFIER,
    @status       TINYINT,
    @admin_userid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.catch_pending_fish
    SET catch_pending_fish_status     = @status,
        catch_pending_fish_decided    = SYSUTCDATETIME(),
        catch_pending_fish_decided_by = @admin_userid
    WHERE catch_pending_fish_id = @id;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_clean_old_water_data' AND type = 'P')
    DROP PROCEDURE dbo.sp_clean_old_water_data
GO
-- exec [sp_clean_old_water_data]
 
CREATE OR ALTER PROCEDURE [dbo].[sp_clean_old_water_data]
    @DaysToKeep INT = 15,
    @BatchSize INT = 1000,
    @DelayBetweenBatchesMs INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @RowsDeleted INT = 1;
    DECLARE @TotalDeleted INT = 0;
    DECLARE @CutoffDate DATE = CAST(DATEADD(day, -@DaysToKeep, GETDATE()) AS DATE);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @DelayString CHAR(12);

    WHILE @RowsDeleted > 0
    BEGIN
        BEGIN TRY
            DELETE TOP (@BatchSize)
            FROM [dbo].[WaterData]
            WHERE stamp < @CutoffDate;

            SET @RowsDeleted = @@ROWCOUNT;
            SET @TotalDeleted = @TotalDeleted + @RowsDeleted;

            IF @RowsDeleted > 0
            BEGIN
                -- PRINT 'Deleted ' + CAST(@RowsDeleted AS VARCHAR(10)) + ' rows. Total: ' + CAST(@TotalDeleted AS VARCHAR(10));
                
                -- Optional delay between batches
                IF @DelayBetweenBatchesMs > 0 AND @RowsDeleted = @BatchSize
                BEGIN
                    WAITFOR DELAY @DelayString;
                END
            END
        END TRY
        BEGIN CATCH
            DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
            DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
            DECLARE @ErrorState INT = ERROR_STATE();
            
            PRINT 'Error occurred after deleting ' + CAST(@TotalDeleted AS VARCHAR(10)) + ' rows';
            PRINT 'Error: ' + @ErrorMessage;
            
            RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
            RETURN;
        END CATCH
    END
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_clean_old_weather_data' AND type = 'P')
    DROP PROCEDURE dbo.sp_clean_old_water_data
GO
-- exec [sp_clean_old_weather_data]
 
CREATE OR ALTER PROCEDURE [dbo].sp_clean_old_weather_data
    @DaysToKeep INT = 15,
    @BatchSize INT = 1000,
    @DelayBetweenBatchesMs INT = 0
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @RowsDeleted INT = 1;
    DECLARE @TotalDeleted INT = 0;
    DECLARE @CutoffDate DATE = CAST(DATEADD(day, -@DaysToKeep, GETDATE()) AS DATE);
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @DelayString CHAR(12);

    WHILE @RowsDeleted > 0
    BEGIN
        BEGIN TRY
            DELETE TOP (@BatchSize)
            FROM [dbo].weather_Forecast
            WHERE dt < @CutoffDate;

            SET @RowsDeleted = @@ROWCOUNT;
            SET @TotalDeleted = @TotalDeleted + @RowsDeleted;

            IF @RowsDeleted > 0
            BEGIN
                -- PRINT 'Deleted ' + CAST(@RowsDeleted AS VARCHAR(10)) + ' rows. Total: ' + CAST(@TotalDeleted AS VARCHAR(10));
                
                -- Optional delay between batches
                IF @DelayBetweenBatchesMs > 0 AND @RowsDeleted = @BatchSize
                BEGIN
                    WAITFOR DELAY @DelayString;
                END
            END
        END TRY
        BEGIN CATCH
            DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
            DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
            DECLARE @ErrorState INT = ERROR_STATE();
            
            PRINT 'Error occurred after deleting ' + CAST(@TotalDeleted AS VARCHAR(10)) + ' rows';
            PRINT 'Error: ' + @ErrorMessage;
            
            RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
            RETURN;
        END CATCH
    END
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------

IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_water_station_503_refresh_due' AND type = 'P')
    DROP PROCEDURE dbo.sp_water_station_503_refresh_due
GO
/*
    Called by service/waterservice StationHttp503BackoffRepository.refreshDue before loading stations.
    Any water station whose weekly/monthly retry date has arrived is re-enabled by resetting backoffstate.
    vwWaterStation includes only supported stations, so restored rows become eligible for processing again.
*/
CREATE PROCEDURE dbo.sp_water_station_503_refresh_due
      @today date
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.WaterStation
       SET backoffstate = 0
         , backoff_next_date = NULL
         , supported = 1
     WHERE backoffstate IN (2, 3)
       AND backoff_next_date IS NOT NULL
       AND backoff_next_date <= @today;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_water_station_503_record' AND type = 'P')
    DROP PROCEDURE dbo.sp_water_station_503_record
GO
/*
    Called by service/waterservice StationHttp503BackoffRepository.recordHttp503.
    Advances HTTP 503 backoff on dbo.WaterStation:
      - backoffstate 0/1 are daily tracking states and remain supported.
      - 3 consecutive daily 503 dates => backoffstate 2 (weekly), supported=0.
      - 4 weekly 503 dates => backoffstate 3 (monthly), supported=0.
      - repeated 503 on the same date is idempotent.
*/
CREATE PROCEDURE dbo.sp_water_station_503_record
      @provider    sysname
    , @country     char(2)
    , @station_mli varchar(64)
    , @state       char(2)
    , @today       date
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @backoffstate int
        , @daily int
        , @weekly int
        , @last date
        , @next date;

    SELECT
          @backoffstate = backoffstate
        , @daily = backoff_daily_503_count
        , @weekly = backoff_weekly_503_count
        , @last = backoff_last_503_date
      FROM dbo.WaterStation WITH (UPDLOCK, HOLDLOCK)
     WHERE country = @country
       AND mli = @station_mli;

    IF @backoffstate IS NULL
    BEGIN
        RETURN;
    END

    IF @backoffstate IN (0, 1)
    BEGIN
        SET @daily = CASE
            WHEN @last IS NULL THEN 1
            WHEN @last = @today THEN @daily
            WHEN @last = DATEADD(day, -1, @today) THEN @daily + 1
            ELSE 1
        END;
        SET @weekly = 0;

        IF @daily >= 3
        BEGIN
            SET @backoffstate = 2;
            SET @next = DATEADD(day, 7, @today);
        END
        ELSE
        BEGIN
            SET @backoffstate = 1;
            SET @next = NULL;
        END
    END
    ELSE IF @backoffstate = 2
    BEGIN
        SET @weekly = CASE WHEN @last = @today THEN @weekly ELSE @weekly + 1 END;

        IF @weekly >= 4
        BEGIN
            SET @backoffstate = 3;
            SET @next = DATEADD(month, 1, @today);
        END
        ELSE
        BEGIN
            SET @next = DATEADD(day, 7, @today);
        END
    END
    ELSE
    BEGIN
        SET @backoffstate = 3;
        SET @next = DATEADD(month, 1, @today);
    END

    UPDATE dbo.WaterStation
       SET state = @state
         , backoffstate = @backoffstate
         , backoff_daily_503_count = @daily
         , backoff_weekly_503_count = @weekly
         , backoff_last_503_date = @today
         , backoff_next_date = @next
         , supported = CASE WHEN @backoffstate IN (2, 3) THEN 0 ELSE supported END
     WHERE country = @country
       AND mli = @station_mli;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_water_station_503_reset' AND type = 'P')
    DROP PROCEDURE dbo.sp_water_station_503_reset
GO
/*
    Called by service/waterservice StationHttp503BackoffRepository.recordProcessed.
    A successful station processing run removes any HTTP 503 backoff state and restores support.
*/
CREATE PROCEDURE dbo.sp_water_station_503_reset
      @provider    sysname
    , @country     char(2)
    , @station_mli varchar(64)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.WaterStation
       SET backoffstate = 0
         , backoff_daily_503_count = 0
         , backoff_weekly_503_count = 0
         , backoff_last_503_date = NULL
         , backoff_next_date = NULL
         , supported = 1
     WHERE country = @country
       AND mli = @station_mli;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_water_station_503_summary_by_state' AND type = 'P')
    DROP PROCEDURE dbo.sp_water_station_503_summary_by_state
GO
/*
    Called by operations/reporting to reduce HTTP 503 backoff water stations by state and stage.
*/
CREATE PROCEDURE dbo.sp_water_station_503_summary_by_state
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
          state
        , CASE backoffstate WHEN 1 THEN 'DAILY' WHEN 2 THEN 'WEEKLY' WHEN 3 THEN 'MONTHLY' ELSE 'NORMAL' END AS backoff_stage
        , COUNT_BIG(*) AS station_count
      FROM dbo.WaterStation
     WHERE backoffstate <> 0
     GROUP BY state, backoffstate
     ORDER BY state, backoff_stage;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_news_import' AND type = 'P')
    DROP PROCEDURE dbo.sp_news_import
GO
--
-- Creates ONE news article from an interchange JSON document -- the exact shape dbo.fn_news_json
-- emits and the News.aspx "Save JSON" / AddNews "Import from JSON" round-trip uses -- and returns
-- the new news_id as a single scalar result set.
--
-- Called by: docapi -- com.fishfind.docapi.repo.JdbcNewsQueryRepository.importJson, reached from
--   NewsController POST /api/v1/news/import.
--
-- The 3 paragraph photos arrive base64-encoded (as fn_news_json emits them) and are decoded back to
-- varbinary via xs:base64Binary. lake_id / fish1..3 accept a GUID string or null (bad text -> null
-- via TRY_CONVERT, so a malformed id can't fail the whole insert). The article is inserted PUBLISHED
-- (news_publish = 1); an absent/blank date defaults to now. news_title carries a UNIQUE index, so
-- importing a title that already exists raises the duplicate-key error, surfaced to the caller.
--
--   Usage: EXEC dbo.sp_news_import N'{ "title": "...", "author": "...", "photo0": "<base64>", ... }';
--
CREATE PROCEDURE dbo.sp_news_import @json nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @title nvarchar(max), @author nvarchar(500), @authorLink nvarchar(1024),
        @source nvarchar(255), @sourceLink nvarchar(1024), @videoLink nvarchar(255),
        @paragraph0 nvarchar(max), @paragraph1 nvarchar(max), @paragraph2 nvarchar(max),
        @country char(2), @date varchar(10),
        @lakeId varchar(36), @fish1Id varchar(36), @fish2Id varchar(36), @fish3Id varchar(36),
        @photo0 varchar(max), @photoAuthor0 nvarchar(64), @photoAlt0 nvarchar(128),
        @photo1 varchar(max), @photoAuthor1 nvarchar(64), @photoAlt1 nvarchar(128),
        @photo2 varchar(max), @photoAuthor2 nvarchar(64), @photoAlt2 nvarchar(128);

    SELECT
        @title = title, @author = author, @authorLink = authorLink,
        @source = source, @sourceLink = sourceLink, @videoLink = videoLink,
        @paragraph0 = paragraph0, @paragraph1 = paragraph1, @paragraph2 = paragraph2,
        @country = country, @date = [date],
        @lakeId = lakeId, @fish1Id = fish1Id, @fish2Id = fish2Id, @fish3Id = fish3Id,
        @photo0 = photo0, @photoAuthor0 = photoAuthor0, @photoAlt0 = photoAlt0,
        @photo1 = photo1, @photoAuthor1 = photoAuthor1, @photoAlt1 = photoAlt1,
        @photo2 = photo2, @photoAuthor2 = photoAuthor2, @photoAlt2 = photoAlt2
    FROM OPENJSON(@json) WITH (
        title        nvarchar(max)  '$.title',
        author       nvarchar(500)  '$.author',
        authorLink   nvarchar(1024) '$.authorLink',
        source       nvarchar(255)  '$.source',
        sourceLink   nvarchar(1024) '$.sourceLink',
        videoLink    nvarchar(255)  '$.videoLink',
        paragraph0   nvarchar(max)  '$.paragraph0',
        paragraph1   nvarchar(max)  '$.paragraph1',
        paragraph2   nvarchar(max)  '$.paragraph2',
        country      char(2)        '$.country',
        [date]       varchar(10)    '$.date',
        lakeId       varchar(36)    '$.lakeId',
        fish1Id      varchar(36)    '$.fish1Id',
        fish2Id      varchar(36)    '$.fish2Id',
        fish3Id      varchar(36)    '$.fish3Id',
        photo0       varchar(max)   '$.photo0',
        photoAuthor0 nvarchar(64)   '$.photoAuthor0',
        photoAlt0    nvarchar(128)  '$.photoAlt0',
        photo1       varchar(max)   '$.photo1',
        photoAuthor1 nvarchar(64)   '$.photoAuthor1',
        photoAlt1    nvarchar(128)  '$.photoAlt1',
        photo2       varchar(max)   '$.photo2',
        photoAuthor2 nvarchar(64)   '$.photoAuthor2',
        photoAlt2    nvarchar(128)  '$.photoAlt2'
    );

    IF @title IS NULL OR LTRIM(RTRIM(@title)) = N''
    BEGIN
        RAISERROR('sp_news_import: a non-empty "title" is required', 16, 1);
        RETURN;
    END

    DECLARE @new_id uniqueidentifier = NEWID();

    INSERT INTO dbo.news (
        news_id, news_title, news_author, news_author_link, news_source, news_source_link,
        news_video_link, news_paragraph0, news_paragraph1, news_paragraph2, country,
        news_stamp, news_publish, lake_id, fish1_id, fish2_id, fish3_id,
        news_photo0, news_photo_author0, news_photo_alt0,
        news_photo1, news_photo_author1, news_photo_alt1,
        news_photo2, news_photo_author2, news_photo_alt2
    )
    VALUES (
        @new_id, @title, @author, @authorLink, @source, @sourceLink,
        @videoLink, @paragraph0, @paragraph1, @paragraph2, @country,
        COALESCE(TRY_CONVERT(datetime2, @date), SYSUTCDATETIME()), 1,
        TRY_CONVERT(uniqueidentifier, @lakeId),
        TRY_CONVERT(uniqueidentifier, @fish1Id),
        TRY_CONVERT(uniqueidentifier, @fish2Id),
        TRY_CONVERT(uniqueidentifier, @fish3Id),
        CASE WHEN @photo0 IS NOT NULL THEN CAST('' AS xml).value('xs:base64Binary(sql:variable("@photo0"))', 'varbinary(max)') END,
        @photoAuthor0, @photoAlt0,
        CASE WHEN @photo1 IS NOT NULL THEN CAST('' AS xml).value('xs:base64Binary(sql:variable("@photo1"))', 'varbinary(max)') END,
        @photoAuthor1, @photoAlt1,
        CASE WHEN @photo2 IS NOT NULL THEN CAST('' AS xml).value('xs:base64Binary(sql:variable("@photo2"))', 'varbinary(max)') END,
        @photoAuthor2, @photoAlt2
    );

    SELECT @new_id AS news_id;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------

IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_news_doc_add' AND type = 'P')
    DROP PROCEDURE dbo.sp_news_doc_add
GO
--
-- Creates ONE news article from a fn_news_doc-shaped JSON document and returns the new news_id as a
-- single scalar result set.
--
-- Called by: docapi -- com.fishfind.docapi.repo.NewsDocumentRepository.addDocument, reached from
--   NewsController POST /api/v1/news. The repository runs "EXEC dbo.sp_news_doc_add ?" and takes the
--   first scalar of the result set as the new id. This is the generic CRUD add; the fuller interchange
--   import (base64 photos 0..2, author/source of each) is dbo.sp_news_import.
--
-- Body shape mirrors dbo.fn_news_doc (the GET document): title, author, author_link, source,
-- source_link, video_link, credit, photo_alt, paragraph0..2, country, date, lake_id, a base64 lead
-- photo, and fishes:[{ id }] (up to 3 are kept). The article is inserted PUBLISHED (news_publish = 1);
-- an absent/blank date defaults to now. lake_id / fish ids accept a GUID string or null (bad text ->
-- null via TRY_CONVERT). news_title is UNIQUE, so a duplicate title raises the duplicate-key error,
-- surfaced to the caller. Read-only fields fn_news_doc derives (flag, lake_name, fish names) are ignored.
--
--   Usage: EXEC dbo.sp_news_doc_add N'{ "title": "...", "paragraph0": "...", "fishes": [{ "id": "..." }] }';
--
CREATE PROCEDURE dbo.sp_news_doc_add @json nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @title nvarchar(max), @author nvarchar(500), @authorLink nvarchar(1024),
        @source nvarchar(255), @sourceLink nvarchar(1024), @videoLink nvarchar(255),
        @credit nvarchar(64), @photoAlt nvarchar(128),
        @paragraph0 nvarchar(max), @paragraph1 nvarchar(max), @paragraph2 nvarchar(max),
        @country char(2), @date varchar(10), @lakeId varchar(36), @photo0 varchar(max);

    SELECT
        @title = title, @author = author, @authorLink = author_link,
        @source = source, @sourceLink = source_link, @videoLink = video_link,
        @credit = credit, @photoAlt = photo_alt,
        @paragraph0 = paragraph0, @paragraph1 = paragraph1, @paragraph2 = paragraph2,
        @country = country, @date = [date], @lakeId = lake_id, @photo0 = photo
    FROM OPENJSON(@json) WITH (
        title       nvarchar(max)  '$.title',
        author      nvarchar(500)  '$.author',
        author_link nvarchar(1024) '$.author_link',
        source      nvarchar(255)  '$.source',
        source_link nvarchar(1024) '$.source_link',
        video_link  nvarchar(255)  '$.video_link',
        credit      nvarchar(64)   '$.credit',
        photo_alt   nvarchar(128)  '$.photo_alt',
        paragraph0  nvarchar(max)  '$.paragraph0',
        paragraph1  nvarchar(max)  '$.paragraph1',
        paragraph2  nvarchar(max)  '$.paragraph2',
        country     char(2)        '$.country',
        [date]      varchar(10)    '$.date',
        lake_id     varchar(36)    '$.lake_id',
        photo       varchar(max)   '$.photo'
    );

    -- Up to 3 mentioned fishes, from the fn_news_doc "fishes":[{ id, name }] array (id only is used).
    DECLARE @fish1 varchar(36), @fish2 varchar(36), @fish3 varchar(36);
    SELECT @fish1 = MAX(CASE WHEN rn = 1 THEN id END),
           @fish2 = MAX(CASE WHEN rn = 2 THEN id END),
           @fish3 = MAX(CASE WHEN rn = 3 THEN id END)
    FROM (
        SELECT id, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS rn
        FROM OPENJSON(@json, '$.fishes') WITH (id varchar(36) '$.id')
    ) q;

    IF @title IS NULL OR LTRIM(RTRIM(@title)) = N''
    BEGIN
        RAISERROR('sp_news_doc_add: a non-empty "title" is required', 16, 1);
        RETURN;
    END

    DECLARE @new_id uniqueidentifier = NEWID();

    INSERT INTO dbo.news (
        news_id, news_title, news_author, news_author_link, news_source, news_source_link,
        news_video_link, news_paragraph0, news_paragraph1, news_paragraph2, country,
        news_stamp, news_publish, lake_id, fish1_id, fish2_id, fish3_id,
        news_photo0, news_photo_author0, news_photo_alt0
    )
    VALUES (
        @new_id, @title, @author, @authorLink, @source, @sourceLink,
        @videoLink, @paragraph0, @paragraph1, @paragraph2, @country,
        COALESCE(TRY_CONVERT(datetime2, @date), SYSUTCDATETIME()), 1,
        TRY_CONVERT(uniqueidentifier, @lakeId),
        TRY_CONVERT(uniqueidentifier, @fish1),
        TRY_CONVERT(uniqueidentifier, @fish2),
        TRY_CONVERT(uniqueidentifier, @fish3),
        CASE WHEN @photo0 IS NOT NULL THEN CAST('' AS xml).value('xs:base64Binary(sql:variable("@photo0"))', 'varbinary(max)') END,
        @credit, @photoAlt
    );

    SELECT @new_id AS news_id;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------

IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_news_doc_update' AND type = 'P')
    DROP PROCEDURE dbo.sp_news_doc_update
GO
--
-- Updates ONE news article (addressed by news_id) from a fn_news_doc-shaped JSON document and returns
-- the news_id as a single scalar result set.
--
-- Called by: docapi -- com.fishfind.docapi.repo.NewsDocumentRepository.updateDocument, reached from
--   NewsController PUT /api/v1/news/{id}. The repository runs "EXEC dbo.sp_news_doc_update ?, ?"
--   (id, json) and takes the first scalar as the affected id.
--
-- Body shape is the same as dbo.sp_news_doc_add / dbo.fn_news_doc. PUT semantics: the scalar text
-- fields, country, lake_id and the up-to-3 fishes are REPLACED from the body (a field absent from the
-- body is written as NULL). TWO fields are PRESERVED when the body omits them, so a metadata-only edit
-- need not resend them: the publish date (absent/blank "date" keeps the stored news_stamp) and the
-- lead photo (a null/absent "photo" keeps the stored news_photo0; a present base64 "photo" replaces it).
-- Fetch the current document with fn_news_doc, edit, and PUT it back for a faithful round-trip.
--
CREATE PROCEDURE dbo.sp_news_doc_update @news_id uniqueidentifier, @json nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @title nvarchar(max), @author nvarchar(500), @authorLink nvarchar(1024),
        @source nvarchar(255), @sourceLink nvarchar(1024), @videoLink nvarchar(255),
        @credit nvarchar(64), @photoAlt nvarchar(128),
        @paragraph0 nvarchar(max), @paragraph1 nvarchar(max), @paragraph2 nvarchar(max),
        @country char(2), @date varchar(10), @lakeId varchar(36), @photo0 varchar(max);

    SELECT
        @title = title, @author = author, @authorLink = author_link,
        @source = source, @sourceLink = source_link, @videoLink = video_link,
        @credit = credit, @photoAlt = photo_alt,
        @paragraph0 = paragraph0, @paragraph1 = paragraph1, @paragraph2 = paragraph2,
        @country = country, @date = [date], @lakeId = lake_id, @photo0 = photo
    FROM OPENJSON(@json) WITH (
        title       nvarchar(max)  '$.title',
        author      nvarchar(500)  '$.author',
        author_link nvarchar(1024) '$.author_link',
        source      nvarchar(255)  '$.source',
        source_link nvarchar(1024) '$.source_link',
        video_link  nvarchar(255)  '$.video_link',
        credit      nvarchar(64)   '$.credit',
        photo_alt   nvarchar(128)  '$.photo_alt',
        paragraph0  nvarchar(max)  '$.paragraph0',
        paragraph1  nvarchar(max)  '$.paragraph1',
        paragraph2  nvarchar(max)  '$.paragraph2',
        country     char(2)        '$.country',
        [date]      varchar(10)    '$.date',
        lake_id     varchar(36)    '$.lake_id',
        photo       varchar(max)   '$.photo'
    );

    DECLARE @fish1 varchar(36), @fish2 varchar(36), @fish3 varchar(36);
    SELECT @fish1 = MAX(CASE WHEN rn = 1 THEN id END),
           @fish2 = MAX(CASE WHEN rn = 2 THEN id END),
           @fish3 = MAX(CASE WHEN rn = 3 THEN id END)
    FROM (
        SELECT id, ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS rn
        FROM OPENJSON(@json, '$.fishes') WITH (id varchar(36) '$.id')
    ) q;

    IF @title IS NULL OR LTRIM(RTRIM(@title)) = N''
    BEGIN
        RAISERROR('sp_news_doc_update: a non-empty "title" is required', 16, 1);
        RETURN;
    END

    UPDATE dbo.news
    SET news_title        = @title,
        news_author       = @author,
        news_author_link  = @authorLink,
        news_source       = @source,
        news_source_link  = @sourceLink,
        news_video_link   = @videoLink,
        news_paragraph0   = @paragraph0,
        news_paragraph1   = @paragraph1,
        news_paragraph2   = @paragraph2,
        country           = @country,
        news_stamp        = COALESCE(TRY_CONVERT(datetime2, @date), news_stamp),
        lake_id           = TRY_CONVERT(uniqueidentifier, @lakeId),
        fish1_id          = TRY_CONVERT(uniqueidentifier, @fish1),
        fish2_id          = TRY_CONVERT(uniqueidentifier, @fish2),
        fish3_id          = TRY_CONVERT(uniqueidentifier, @fish3),
        news_photo0       = CASE WHEN @photo0 IS NOT NULL
                                 THEN CAST('' AS xml).value('xs:base64Binary(sql:variable("@photo0"))', 'varbinary(max)')
                                 ELSE news_photo0 END,
        news_photo_author0 = @credit,
        news_photo_alt0    = @photoAlt
    WHERE news_id = @news_id;

    SELECT @news_id AS news_id;
END
GO
------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Stores the NWS station resolved for a water gauge (see dbo.weather_gov_station).
-- Upsert keyed on mli: one row per gauge, always holding the newest answer. Pass @station_id = NULL
-- to record "asked, nothing nearby" so the resolver stops re-asking that point.
-- Called by: WeatherService (C#) Data/WeatherGovStationRepository.SaveAsync
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_save_weather_gov_station' AND type = 'P')
    DROP PROCEDURE dbo.sp_save_weather_gov_station
GO
CREATE PROCEDURE dbo.sp_save_weather_gov_station
      @mli        varchar(64)
    , @lat        float
    , @lon        float
    , @station_id varchar(16) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.weather_gov_station
       SET station_id = @station_id, lat = @lat, lon = @lon, stamp = GETUTCDATE()
     WHERE mli = @mli;

    IF @@ROWCOUNT = 0
        INSERT dbo.weather_gov_station (mli, station_id, lat, lon)
        VALUES (@mli, @station_id, @lat, @lon);
END
GO

------------------------------------------------------------------------------
-- Records whether a provider could serve a gauge (see dbo.weather_station_coverage).
-- Upsert on (mli, provider): the flag is the current fact, so a gap that later resolves clears
-- rather than accumulating history.
-- Called by: WeatherService (C#) Data/WeatherStationCoverageRepository.SaveAsync, from the
--            station processors as each station is attempted.
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_save_weather_station_coverage' AND type = 'P')
    DROP PROCEDURE dbo.sp_save_weather_station_coverage
GO
CREATE PROCEDURE dbo.sp_save_weather_station_coverage
      @mli      varchar(64)
    , @provider varchar(32)
    , @covered  bit
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.weather_station_coverage
       SET covered = @covered, stamp = GETUTCDATE()
     WHERE mli = @mli AND provider = @provider;

    IF @@ROWCOUNT = 0
        INSERT dbo.weather_station_coverage (mli, provider, covered)
        VALUES (@mli, @provider, @covered);
END
GO

------------------------------------------------------------------------------
-- sp_upsert_page_count_daily: upsert daily page visit counters for the top 20 pages.
-- If the date already exists, add to existing counters; otherwise insert a new row.
-- Called by: FishTracker Models/PageCounter.cs (PageCounter.FlushToDatabase).
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'sp_upsert_page_count_daily' AND type = 'P')
    DROP PROCEDURE dbo.sp_upsert_page_count_daily
GO
CREATE PROCEDURE dbo.sp_upsert_page_count_daily
      @page_count_date DATETIME2
    , @home            BIGINT = 0
    , @news            BIGINT = 0
    , @species         BIGINT = 0
    , @forecast        BIGINT = 0
    , @rivers          BIGINT = 0
    , @fishing_log     BIGINT = 0
    , @regulations     BIGINT = 0
    , @weather         BIGINT = 0
    , @map_pages       BIGINT = 0
    , @login           BIGINT = 0
    , @profile         BIGINT = 0
    , @register        BIGINT = 0
    , @watersheds      BIGINT = 0
    , @search          BIGINT = 0
    , @lake_editor     BIGINT = 0
    , @fish_editor     BIGINT = 0
    , @news_editor     BIGINT = 0
    , @water_stations  BIGINT = 0
    , @catch_memo      BIGINT = 0
    , @api_forecast    BIGINT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Convert input datetime to UTC midnight (date only)
    DECLARE @date DATE = CAST(@page_count_date AS DATE);

    -- Upsert: update existing row or insert new one
    UPDATE dbo.PageCountDaily
    SET
        home            = home + @home,
        news            = news + @news,
        species         = species + @species,
        forecast        = forecast + @forecast,
        rivers          = rivers + @rivers,
        fishing_log     = fishing_log + @fishing_log,
        regulations     = regulations + @regulations,
        weather         = weather + @weather,
        map_pages       = map_pages + @map_pages,
        login           = login + @login,
        profile         = profile + @profile,
        register        = register + @register,
        watersheds      = watersheds + @watersheds,
        search          = search + @search,
        lake_editor     = lake_editor + @lake_editor,
        fish_editor     = fish_editor + @fish_editor,
        news_editor     = news_editor + @news_editor,
        water_stations  = water_stations + @water_stations,
        catch_memo      = catch_memo + @catch_memo,
        api_forecast    = api_forecast + @api_forecast
    WHERE page_count_date = @date;

    -- If no row was updated, insert a new one
    IF @@ROWCOUNT = 0
    BEGIN
        INSERT INTO dbo.PageCountDaily (
            page_count_date, home, news, species, forecast, rivers, fishing_log,
            regulations, weather, map_pages, login, profile, register, watersheds,
            search, lake_editor, fish_editor, news_editor, water_stations, catch_memo, api_forecast
        ) VALUES (
            @date, @home, @news, @species, @forecast, @rivers, @fishing_log,
            @regulations, @weather, @map_pages, @login, @profile, @register, @watersheds,
            @search, @lake_editor, @fish_editor, @news_editor, @water_stations, @catch_memo, @api_forecast
        );
    END
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- sp_user_api_key_issue : issue (or re-issue) the personal REST-API key of one user, for the
-- "API access" section of Account/Profile.aspx (fishfind-frontend, btnKeyIssue_Click).
-- At most ONE live key per user: any key the user already had is soft-deleted in the same
-- transaction, so re-issuing immediately revokes the previous one (fn_user_api_key_user stops
-- resolving it). Both GUIDs are v7, minted here by dbo.sp_NewGuidV7 - the caller never supplies
-- the secret. Returns one row shaped like dbo.fn_user_api_key_list plus a status column:
--   'issued'    - key created; the row carries it
--   'no_user'   - unknown or soft-deleted account
--   'suspended' - the account is suspended/banned
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_user_api_key_issue' AND type = 'P')
    DROP PROCEDURE dbo.sp_user_api_key_issue
GO
CREATE PROCEDURE dbo.sp_user_api_key_issue
    @userid UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE id = @userid AND deleted = 0)
    BEGIN
        SELECT 'no_user' AS status, CAST(NULL AS UNIQUEIDENTIFIER) AS key_id,
               CAST(NULL AS UNIQUEIDENTIFIER) AS api_key, CAST(NULL AS DATETIME2) AS created_utc,
               CAST(NULL AS DATETIME2) AS expires_utc, CAST(NULL AS DATETIME2) AS disabled_utc,
               CAST(0 AS BIT) AS is_disabled, CAST(0 AS BIT) AS is_expired;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.Users WHERE id = @userid AND ISNULL(suspended, 0) <> 0)
    BEGIN
        SELECT 'suspended' AS status, CAST(NULL AS UNIQUEIDENTIFIER) AS key_id,
               CAST(NULL AS UNIQUEIDENTIFIER) AS api_key, CAST(NULL AS DATETIME2) AS created_utc,
               CAST(NULL AS DATETIME2) AS expires_utc, CAST(NULL AS DATETIME2) AS disabled_utc,
               CAST(0 AS BIT) AS is_disabled, CAST(0 AS BIT) AS is_expired;
        RETURN;
    END

    DECLARE @id     UNIQUEIDENTIFIER;
    DECLARE @secret UNIQUEIDENTIFIER;
    EXEC dbo.sp_NewGuidV7 @id     OUTPUT;
    EXEC dbo.sp_NewGuidV7 @secret OUTPUT;

    DECLARE @now DATETIME2 = SYSUTCDATETIME();

    BEGIN TRAN;
        -- Revoke whatever the user held before: the old secret is kept on file (never re-issued)
        -- but stops authenticating the moment this commits.
        UPDATE dbo.user_api_key
            SET user_api_key_deleted = @now
            WHERE user_api_key_userid  = @userid
              AND user_api_key_deleted IS NULL;

        INSERT INTO dbo.user_api_key (user_api_key_id, user_api_key_userid, user_api_key_secret, user_api_key_created)
        VALUES (@id, @userid, @secret, @now);
    COMMIT;

    SELECT 'issued' AS status, k.key_id, k.api_key, k.created_utc, k.expires_utc,
           k.disabled_utc, k.is_disabled, k.is_expired
        FROM dbo.fn_user_api_key_list(@userid) k
        WHERE k.key_id = @id;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- sp_user_api_key_disable : turn one REST-API key off (@disabled = 1) or back on (@disabled = 0),
-- for Account/Profile.aspx btnKeyDisable_Click. A disabled key keeps its value but stops
-- authenticating (fn_user_api_key_user returns NULL for it) until it is enabled again.
-- Scoped by @userid as well as @key_id, so a tampered key id can only ever hit your own key.
-- Idempotent, and a deleted key can no longer be toggled.
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_user_api_key_disable' AND type = 'P')
    DROP PROCEDURE dbo.sp_user_api_key_disable
GO
CREATE PROCEDURE dbo.sp_user_api_key_disable
    @userid   UNIQUEIDENTIFIER,
    @key_id   UNIQUEIDENTIFIER,
    @disabled BIT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.user_api_key
        SET user_api_key_disabled = CASE WHEN @disabled = 1
                                         THEN ISNULL(user_api_key_disabled, SYSUTCDATETIME())
                                         ELSE NULL END
        WHERE user_api_key_id      = @key_id
          AND user_api_key_userid  = @userid
          AND user_api_key_deleted IS NULL;
END
GO

------------------------------------------------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------------------------------------------------
-- sp_user_api_key_delete : permanently revoke one REST-API key, for Account/Profile.aspx
-- btnKeyDelete_Click. Soft delete: the row is KEPT (history, and the secret must never be handed
-- out again) but fn_user_api_key_list stops returning it and fn_user_api_key_user stops resolving
-- it. Scoped by @userid, same reasoning as sp_user_api_key_disable. Idempotent.
IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_user_api_key_delete' AND type = 'P')
    DROP PROCEDURE dbo.sp_user_api_key_delete
GO
CREATE PROCEDURE dbo.sp_user_api_key_delete
    @userid UNIQUEIDENTIFIER,
    @key_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.user_api_key
        SET user_api_key_deleted = SYSUTCDATETIME()
        WHERE user_api_key_id      = @key_id
          AND user_api_key_userid  = @userid
          AND user_api_key_deleted IS NULL;
END
GO
