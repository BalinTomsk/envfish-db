SET QUOTED_IDENTIFIER ON
GO
/*
  Unit tests for service status (sp_service_status_report / sp_service_status_delete / fn_service_status_list).
  Uses the real tables dbo.ServiceStatus and dbo.ServiceRequestCount (serviceName 'ut_svc'). Each test rolls back
  its own transaction.

  TEST  1 - first report inserts the row, lower-cased, no restart
  TEST  2 - heartbeat moves lastSeenUtc and keeps the start
  TEST  3 - a later process start becomes restartUtc
  TEST  4 - a message older than lastSeenUtc is ignored (applied = 0)
  TEST  5 - an older lastAction does not overwrite a newer one
  TEST  6 - an unknown event is rejected
  TEST  7 - fn_service_status_list: fresh heartbeat is alive with uptime
  TEST  8 - fn_service_status_list: silent service is dead, no uptime
  TEST  9 - fn_service_status_list: 'stop' is dead even when fresh
  TEST 10 - sp_service_status_delete removes the row
  TEST 11 - first report counts its whole request total
  TEST 12 - same process counts only the growth of its total
  TEST 13 - a restarted process counts its new total from zero
  TEST 14 - a stale message or one without a total counts nothing
  TEST 15 - fn_service_status_list sums the last hour / day / 30 days
  TEST 16 - buckets older than 31 days are pruned; delete drops them
*/
SET NOCOUNT ON;
GO
BEGIN TRAN Test01
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'UT_Svc', 'UT_Host', 'start', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:00:01', NULL, NULL;
    IF (SELECT applied FROM @r) = 1 AND EXISTS (SELECT 1 FROM dbo.ServiceStatus
        WHERE serviceName = 'ut_svc' AND machineName = 'ut_host' AND startUtc = '2026-10-01 10:00:00'
          AND restartUtc IS NULL AND lastEvent = 'start' AND version = '1.0.0')
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test01' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 1 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: first report inserts the row';
ELSE RAISERROR ('TEST 1 FAIL [%dms]: first report did not insert the row', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test01
GO
BEGIN TRAN Test02
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'start', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:00:01';
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:01:01';
    IF EXISTS (SELECT 1 FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc'
        AND lastSeenUtc = '2026-10-01 10:01:01' AND lastEvent = 'heartbeat'
        AND startUtc = '2026-10-01 10:00:00' AND restartUtc IS NULL)
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test02' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 2 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: heartbeat moves lastSeenUtc only';
ELSE RAISERROR ('TEST 2 FAIL [%dms]: heartbeat did not update the row', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test02
GO
BEGIN TRAN Test03
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'start', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:00:01';
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'start', '1.1.0',
        '2026-10-02 08:00:00', '2026-10-02 08:00:01';
    IF EXISTS (SELECT 1 FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc'
        AND startUtc = '2026-10-01 10:00:00' AND restartUtc = '2026-10-02 08:00:00' AND version = '1.1.0')
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test03' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 3 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: later process start becomes restartUtc';
ELSE RAISERROR ('TEST 3 FAIL [%dms]: restart was not recorded', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test03
GO
BEGIN TRAN Test04
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'stop', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 12:00:00';
    DELETE FROM @r;
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 11:59:00';
    IF (SELECT applied FROM @r) = 0 AND EXISTS (SELECT 1 FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc'
        AND lastEvent = 'stop' AND lastSeenUtc = '2026-10-01 12:00:00')
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test04' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 4 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: out-of-order message is ignored';
ELSE RAISERROR ('TEST 4 FAIL [%dms]: stale message changed the row', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test04
GO
BEGIN TRAN Test05
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:05:00', '2026-10-01 10:04:00', N'station NEW';
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:06:00', '2026-10-01 10:03:00', N'station OLD';
    IF EXISTS (SELECT 1 FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc'
        AND lastAction = N'station NEW' AND lastActionUtc = '2026-10-01 10:04:00'
        AND lastSeenUtc = '2026-10-01 10:06:00')
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test05' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 5 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: older lastAction is not kept';
ELSE RAISERROR ('TEST 5 FAIL [%dms]: older lastAction overwrote a newer one', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test05
GO
BEGIN TRAN Test06
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
BEGIN TRY
    EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'reboot', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:00:01';
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE 'sp_service_status_report:%'
       AND NOT EXISTS (SELECT 1 FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc')
        SET @ok = 1;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 6 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: unknown event is rejected';
ELSE RAISERROR ('TEST 6 FAIL [%dms]: unknown event was not rejected', 16, -1, @ElapsedMs);
IF @@TRANCOUNT > 0 ROLLBACK TRAN Test06
GO
BEGIN TRAN Test07
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @started datetime2(0) = DATEADD(hour, -2, @now);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0', @started, @now;
    IF EXISTS (SELECT 1 FROM dbo.fn_service_status_list(180) WHERE serviceName = 'ut_svc'
        AND state = 'alive' AND upSeconds BETWEEN 7190 AND 7260)
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test07' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 7 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: fresh heartbeat lists alive with uptime';
ELSE RAISERROR ('TEST 7 FAIL [%dms]: fresh service not listed alive', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test07
GO
BEGIN TRAN Test08
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @seen datetime2(0) = DATEADD(minute, -10, SYSUTCDATETIME());
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @seen;
    IF EXISTS (SELECT 1 FROM dbo.fn_service_status_list(180) WHERE serviceName = 'ut_svc'
        AND state = 'dead' AND upSeconds IS NULL)
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test08' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 8 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: silent service lists dead';
ELSE RAISERROR ('TEST 8 FAIL [%dms]: silent service not listed dead', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test08
GO
BEGIN TRAN Test09
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'stop', '1.0.0',
        '2026-10-01 10:00:00', @now;
    IF EXISTS (SELECT 1 FROM dbo.fn_service_status_list(180) WHERE serviceName = 'ut_svc' AND state = 'dead')
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test09' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 9 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: stopped service lists dead';
ELSE RAISERROR ('TEST 9 FAIL [%dms]: stopped service not listed dead', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test09
GO
BEGIN TRAN Test10
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @d TABLE (deleted int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'start', '1.0.0',
        '2026-10-01 10:00:00', '2026-10-01 10:00:01';
    DECLARE @id uniqueidentifier = (SELECT id FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc');
    INSERT INTO @d EXEC dbo.sp_service_status_delete @id;
    IF (SELECT deleted FROM @d) = 1 AND NOT EXISTS (SELECT 1 FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc')
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test10' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 10 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: delete removes the row';
ELSE RAISERROR ('TEST 10 FAIL [%dms]: row was not deleted', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test10
GO
BEGIN TRAN Test11
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @earlier datetime2(0) = DATEADD(minute, -1, @now);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @now, NULL, NULL, 5;
    IF (SELECT SUM(c.requests) FROM dbo.ServiceRequestCount c JOIN dbo.ServiceStatus s ON s.id = c.serviceStatusId
        WHERE s.serviceName = 'ut_svc') = 5
       AND (SELECT requestTotal FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc') = 5
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test11' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 11 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: first report counts its total';
ELSE RAISERROR ('TEST 11 FAIL [%dms]: first request total not counted', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test11
GO
BEGIN TRAN Test12
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @earlier datetime2(0) = DATEADD(minute, -1, @now);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @earlier, NULL, NULL, 5;
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @now, NULL, NULL, 12;
    IF (SELECT SUM(c.requests) FROM dbo.ServiceRequestCount c JOIN dbo.ServiceStatus s ON s.id = c.serviceStatusId
        WHERE s.serviceName = 'ut_svc') = 12
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test12' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 12 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: same process counts the growth';
ELSE RAISERROR ('TEST 12 FAIL [%dms]: request growth miscounted', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test12
GO
BEGIN TRAN Test13
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @earlier datetime2(0) = DATEADD(minute, -1, @now);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @earlier, NULL, NULL, 100;
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'start', '1.0.0',
        '2026-10-02 10:00:00', @now, NULL, NULL, 3;
    IF (SELECT SUM(c.requests) FROM dbo.ServiceRequestCount c JOIN dbo.ServiceStatus s ON s.id = c.serviceStatusId
        WHERE s.serviceName = 'ut_svc') = 103
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test13' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 13 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: restart counts from zero';
ELSE RAISERROR ('TEST 13 FAIL [%dms]: restart total miscounted', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test13
GO
BEGIN TRAN Test14
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @earlier datetime2(0) = DATEADD(minute, -1, @now);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @now, NULL, NULL, 10;
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @earlier, NULL, NULL, 50;
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @now;
    IF (SELECT SUM(c.requests) FROM dbo.ServiceRequestCount c JOIN dbo.ServiceStatus s ON s.id = c.serviceStatusId
        WHERE s.serviceName = 'ut_svc') = 10
       AND (SELECT requestTotal FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc') = 10
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test14' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 14 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: stale or countless message adds 0';
ELSE RAISERROR ('TEST 14 FAIL [%dms]: stale or countless message was counted', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test14
GO
BEGIN TRAN Test15
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @earlier datetime2(0) = DATEADD(minute, -1, @now);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @now, NULL, NULL, 1;
    DECLARE @id uniqueidentifier = (SELECT id FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc');
    INSERT INTO dbo.ServiceRequestCount (serviceStatusId, bucketUtc, requests) VALUES
        (@id, DATEADD(minute, -30, @now), 10),
        (@id, DATEADD(hour, -5, @now), 100),
        (@id, DATEADD(day, -10, @now), 1000),
        (@id, DATEADD(day, -31, @now), 10000);
    IF EXISTS (SELECT 1 FROM dbo.fn_service_status_list(180) WHERE serviceName = 'ut_svc'
        AND requestsHour = 11 AND requestsDay = 111 AND requestsMonth = 1111)
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test15' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 15 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: hour / day / 30-day sums';
ELSE RAISERROR ('TEST 15 FAIL [%dms]: request window sums wrong', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test15
GO
BEGIN TRAN Test16
DECLARE @tStart datetime2 = SYSUTCDATETIME(), @ElapsedMs int, @ok bit = 0;
DECLARE @r TABLE (applied int);
DECLARE @now datetime2(0) = SYSUTCDATETIME();
DECLARE @earlier datetime2(0) = DATEADD(minute, -1, @now);
DECLARE @d TABLE (deleted int);
BEGIN TRY
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @earlier, NULL, NULL, 1;
    DECLARE @id uniqueidentifier = (SELECT id FROM dbo.ServiceStatus WHERE serviceName = 'ut_svc');
    INSERT INTO dbo.ServiceRequestCount (serviceStatusId, bucketUtc, requests)
        VALUES (@id, DATEADD(day, -40, @now), 7);
    INSERT INTO @r EXEC dbo.sp_service_status_report 'ut_svc', 'ut_host', 'heartbeat', '1.0.0',
        '2026-10-01 10:00:00', @now, NULL, NULL, 2;
    DECLARE @pruned bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.ServiceRequestCount
        WHERE serviceStatusId = @id AND bucketUtc < DATEADD(day, -31, @now)) THEN 0 ELSE 1 END;
    INSERT INTO @d EXEC dbo.sp_service_status_delete @id;
    IF @pruned = 1 AND NOT EXISTS (SELECT 1 FROM dbo.ServiceRequestCount WHERE serviceStatusId = @id)
        SET @ok = 1;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage, 'Test16' AS ErrorProcedure;
END CATCH
SET @ElapsedMs = DATEDIFF(millisecond, @tStart, SYSUTCDATETIME());
IF @ok = 1 PRINT 'TEST 16 PASS [' + CAST(@ElapsedMs AS varchar) + 'ms]: old buckets pruned, delete drops all';
ELSE RAISERROR ('TEST 16 FAIL [%dms]: request buckets not pruned or deleted', 16, -1, @ElapsedMs);
ROLLBACK TRAN Test16
GO
