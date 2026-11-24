-- MySQL envdata unit tests: sp_water_backfill (the one-off load of MSSQL WaterData by EnvService.Migrator, plan step 3).
-- One PROCEDURE per test, own handler, own transaction, ROLLBACK.
SET NAMES utf8mb4;

DELIMITER //

DROP PROCEDURE IF EXISTS t_station //
CREATE PROCEDURE t_station(IN p_sid INT, IN p_mli VARCHAR(64))
BEGIN
    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, loc_name, master_stamp, mirror_stamp)
    VALUES (p_sid, p_mli, UUID(), 'US', 'WI', 45, -88, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP());
END //

-- ----------------------------------------------------------------
-- TEST 1: metric rows are stored as given, for several stations in one call
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'B01A');
    CALL t_station(90002, 'B01B');
    CALL sp_water_backfill('[
        {"sid":90001,"ts":"2026-11-20 00:00:00","discharge":2.5,"elevation":1.2,"pressure_mm":755.3,"oxygen":8.1},
        {"sid":90002,"ts":"2026-11-20 10:05:00","discharge":7,"turbidity":3,"velocity":1,"wind":12,"winddir":270,
         "humidity":80,"precipitation":2,"salinity":0.1,"nitrate":0.2,"chloride":0.3,"chlorophylls":0.4,
         "phycocyanins":0.5,"phycoerythrin":0.6}]', v_n);
    SELECT COUNT(*) INTO v_ok FROM water_reading
     WHERE (station_id = 90001 AND discharge = 2.5 AND elevation = 1.2 AND pressure_mm = 755.3 AND oxygen = 8.1)
        OR (station_id = 90002 AND discharge = 7 AND turbidity = 3 AND winddir = 270 AND phycoerythrin = 0.6);
    SELECT IF(v_n = 2 AND v_ok = 2, 'TEST 1 PASS: backfill stores metric rows of several stations',
                                    'TEST 1 FAIL: backfill rows not stored as given') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: a value already in envdata wins (live 11.0.0 data is never overwritten by older MSSQL data)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'B02');
    INSERT INTO water_reading (station_id, ts, discharge) VALUES (90001, '2026-11-20 10:00:00', 9);
    CALL sp_water_backfill('[{"sid":90001,"ts":"2026-11-20 10:00:00","discharge":1,"elevation":2}]', v_n);
    SELECT COUNT(*) INTO v_ok FROM water_reading WHERE station_id = 90001 AND discharge = 9 AND elevation = 2;
    SELECT IF(v_ok = 1, 'TEST 2 PASS: existing values win, missing ones are filled',
                        'TEST 2 FAIL: backfill overwrote an existing value') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: rows of a station envdata does not know are skipped, not an error; p_count counts stored rows only
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_n INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'B03');
    CALL sp_water_backfill('[{"sid":90001,"ts":"2026-11-20 10:00:00","discharge":1},
                             {"sid":99999999,"ts":"2026-11-20 10:00:00","discharge":1}]', v_n);
    SELECT IF(v_n = 1 AND NOT EXISTS (SELECT 1 FROM water_reading WHERE station_id = 99999999),
              'TEST 3 PASS: unknown station skipped, p_count = stored rows',
              'TEST 3 FAIL: unknown station not skipped or wrong count') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: station_current is refreshed for every station of the batch, from its newest reading
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'B04A');
    CALL t_station(90002, 'B04B');
    CALL sp_water_backfill('[{"sid":90001,"ts":"2026-11-19 00:00:00","discharge":1,"oxygen":7},
                             {"sid":90001,"ts":"2026-11-20 00:00:00","discharge":2},
                             {"sid":90002,"ts":"2026-11-20 08:00:00","elevation":3}]', v_n);
    SELECT COUNT(*) INTO v_ok FROM station_current
     WHERE (station_id = 90001 AND ts = '2026-11-20' AND discharge = 2 AND oxygen = 7)
        OR (station_id = 90002 AND ts = '2026-11-20 08:00:00' AND elevation = 3);
    SELECT IF(v_ok = 2, 'TEST 4 PASS: station_current refreshed for each station',
                        'TEST 4 FAIL: station_current not refreshed by the backfill') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: a row carrying no value at all is not stored (empty WaterData rows exist)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05 //
CREATE PROCEDURE test_05()
BEGIN
    DECLARE v_n INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 5 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'B05');
    CALL sp_water_backfill('[{"sid":90001,"ts":"2026-11-20 10:00:00"}]', v_n);
    SELECT IF(v_n = 0 AND NOT EXISTS (SELECT 1 FROM water_reading WHERE station_id = 90001),
              'TEST 5 PASS: an empty row is not stored',
              'TEST 5 FAIL: an empty row was stored') AS message;
    ROLLBACK;
END //

DELIMITER ;

CALL test_01();
CALL test_02();
CALL test_03();
CALL test_04();
CALL test_05();

DROP PROCEDURE IF EXISTS test_01;
DROP PROCEDURE IF EXISTS test_02;
DROP PROCEDURE IF EXISTS test_03;
DROP PROCEDURE IF EXISTS test_04;
DROP PROCEDURE IF EXISTS test_05;
DROP PROCEDURE IF EXISTS t_station;
