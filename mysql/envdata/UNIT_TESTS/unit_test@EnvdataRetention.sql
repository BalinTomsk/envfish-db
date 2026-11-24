-- MySQL envdata unit tests: retention - water_reading day partitions (sp_water_reading_rotate), and the two
-- nightly clean procedures.
-- EXCEPTION to the per-test ROLLBACK rule: partition DDL commits implicitly, so TESTS 1-2 and 4 cannot roll back.
-- They start from a reset table (one p_max partition, as script01_createTable.sql builds it), clean up their own
-- rows, and t_reset puts the table back at the end, so the database is left as ffi2.sql produced it.
-- Every test still has its own EXIT HANDLER, so one failure never skips the rest.
SET NAMES utf8mb4;

DELIMITER //

DROP PROCEDURE IF EXISTS t_reset //
CREATE PROCEDURE t_reset()
BEGIN
    DELETE FROM water_reading WHERE station_id = 90001;
    DELETE FROM water_reading_day WHERE station_id = 90001;
    DELETE FROM job_run WHERE service = 'test-retention';
    DELETE FROM station WHERE station_id = 90001;
    ALTER TABLE water_reading REMOVE PARTITIONING;
    ALTER TABLE water_reading PARTITION BY RANGE (TO_DAYS(ts)) (PARTITION p_max VALUES LESS THAN MAXVALUE);
END //

DROP PROCEDURE IF EXISTS t_station //
CREATE PROCEDURE t_station()
BEGIN
    INSERT INTO station (station_id, mli, ws_id, country, lat, lon, loc_name, master_stamp, mirror_stamp)
    VALUES (90001, 'R01', UUID(), 'CA', 45, -79, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP());
END //

-- ----------------------------------------------------------------
-- TEST 1: rotate splits p_max into one partition per day up to today + 3, and is idempotent
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_d1 INT;
    DECLARE v_a1 INT;
    DECLARE v_d2 INT;
    DECLARE v_a2 INT;
    DECLARE v_parts INT;
    DECLARE v_last VARCHAR(64);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    CALL t_reset();
    CALL sp_water_reading_rotate('2026-11-24', 30, 3, v_d1, v_a1);
    CALL sp_water_reading_rotate('2026-11-24', 30, 3, v_d2, v_a2);
    SELECT COUNT(*), MAX(CASE WHEN partition_name <> 'p_max' THEN partition_name END) INTO v_parts, v_last
      FROM information_schema.partitions WHERE table_schema = DATABASE() AND table_name = 'water_reading';
    SELECT IF(v_a1 = 34 AND v_d1 = 0 AND v_a2 = 0 AND v_d2 = 0 AND v_parts = 35 AND v_last = 'p_20261127',
              'TEST 1 PASS: 34 day partitions to today+3, second run adds none',
              'TEST 1 FAIL: rotate did not add the day partitions once') AS message;
END //

-- ----------------------------------------------------------------
-- TEST 2: rotate drops whole days older than the cut, and their readings; newer readings stay
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_d INT;
    DECLARE v_a INT;
    DECLARE v_rows VARCHAR(64);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    CALL t_reset();
    CALL t_station();
    CALL sp_water_reading_rotate('2026-11-24', 30, 3, v_d, v_a);
    INSERT INTO water_reading (station_id, ts, discharge) VALUES
        (90001, '2026-10-20 05:00:00', 1), (90001, '2026-10-31 23:59:00', 2),
        (90001, '2026-11-01 00:00:00', 3), (90001, '2026-11-24 12:00:00', 4), (90001, '2027-01-01 00:00:00', 5);
    CALL sp_water_reading_rotate('2026-12-01', 30, 3, v_d, v_a);
    SELECT GROUP_CONCAT(discharge ORDER BY ts) INTO v_rows FROM water_reading WHERE station_id = 90001;
    SELECT IF(v_d = 7 AND v_a = 7 AND v_rows = '3,4,5', 'TEST 2 PASS: days before the cut dropped with their rows',
                                                       'TEST 2 FAIL: rotate dropped the wrong days') AS message;
    DELETE FROM water_reading WHERE station_id = 90001;
    DELETE FROM station WHERE station_id = 90001;
END //

-- ----------------------------------------------------------------
-- TEST 3: weather clean deletes days older than 15 back; recent days and the forecast stay
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_w INT;
    DECLARE v_p INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station();
    INSERT INTO weather_day (station_id, dt, provider_type, stamp) VALUES
        (90001, UTC_DATE() - INTERVAL 16 DAY, 2, UTC_TIMESTAMP()), (90001, UTC_DATE() - INTERVAL 15 DAY, 2, UTC_TIMESTAMP()),
        (90001, UTC_DATE() + INTERVAL 15 DAY, 2, UTC_TIMESTAMP());
    INSERT INTO station_pressure_day (station_id, dt, stamp) VALUES
        (90001, UTC_DATE() - INTERVAL 16 DAY, UTC_TIMESTAMP()), (90001, UTC_DATE(), UTC_TIMESTAMP());
    CALL sp_clean_old_weather_data(NULL);
    SELECT COUNT(*) INTO v_w FROM weather_day WHERE station_id = 90001;
    SELECT COUNT(*) INTO v_p FROM station_pressure_day WHERE station_id = 90001;
    SELECT IF(v_w = 2 AND v_p = 1, 'TEST 3 PASS: weather older than 15 days deleted, forecast kept',
                                   'TEST 3 FAIL: weather retention wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: water clean keeps daily aggregates and job runs 30 days
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_days INT;
    DECLARE v_jobs INT;
    DECLARE v_id BIGINT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    CALL t_reset();
    CALL t_station();
    INSERT INTO water_reading_day (station_id, dt, n, q_n, stamp) VALUES
        (90001, UTC_DATE() - INTERVAL 31 DAY, 1, 1, UTC_TIMESTAMP()), (90001, UTC_DATE() - INTERVAL 30 DAY, 1, 1, UTC_TIMESTAMP());
    CALL sp_job_run_record('test-retention', 'x', UTC_TIMESTAMP() - INTERVAL 31 DAY, UTC_TIMESTAMP() - INTERVAL 31 DAY,
                           'ok', 0, NULL, v_id);
    CALL sp_job_run_record('test-retention', 'x', UTC_TIMESTAMP(), NULL, 'ok', 0, NULL, v_id);
    CALL sp_clean_old_water_data(NULL);
    SELECT COUNT(*) INTO v_days FROM water_reading_day WHERE station_id = 90001;
    SELECT COUNT(*) INTO v_jobs FROM job_run WHERE service = 'test-retention';
    SELECT IF(v_days = 1 AND v_jobs = 1, 'TEST 4 PASS: day aggregates and job runs kept 30 days',
                                         'TEST 4 FAIL: water retention wrong') AS message;
END //

DELIMITER ;

CALL test_01();
CALL test_02();
CALL test_03();
CALL test_04();
CALL t_reset();

DROP PROCEDURE IF EXISTS test_01;
DROP PROCEDURE IF EXISTS test_02;
DROP PROCEDURE IF EXISTS test_03;
DROP PROCEDURE IF EXISTS test_04;
DROP PROCEDURE IF EXISTS t_reset;
DROP PROCEDURE IF EXISTS t_station;
