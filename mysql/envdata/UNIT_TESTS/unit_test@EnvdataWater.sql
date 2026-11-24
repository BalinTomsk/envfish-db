-- MySQL envdata unit tests: station mirror, water readings, station_current, HTTP 503 back-off, job_run.
-- STRUCTURE (envfish-db/AGENTS.md "Structure MySQL unit tests"): one PROCEDURE per test, own EXIT HANDLER, own
-- transaction, ROLLBACK at the end; one output line per test, under 80 characters.
SET NAMES utf8mb4;

DELIMITER //

-- helper: a bare station row (tests only)
DROP PROCEDURE IF EXISTS t_station //
CREATE PROCEDURE t_station(IN p_sid INT, IN p_mli VARCHAR(64), IN p_country CHAR(2), IN p_has_fish TINYINT)
BEGIN
    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, loc_name, master_stamp, mirror_stamp, has_fish)
    VALUES (p_sid, p_mli, UUID(), p_country, 'ON', 45, -79, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP(), p_has_fish);
END //

-- ----------------------------------------------------------------
-- TEST 1: the mirror creates stations, reads hasFish true/1, defaults supported to 1
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL sp_station_mirror('[{"sid":90001,"mli":"T01A","id":"a0000000-0000-0000-0000-000000000001","country":"CA",
        "state":"ON","lat":43.5,"lon":-79.6,"locName":"A","hasFish":true},
        {"sid":90002,"mli":"T01B","id":"a0000000-0000-0000-0000-000000000002","country":"US","lat":43,"lon":-88,
        "locName":"B","hasFish":0}]', v_n);
    SELECT COUNT(*) INTO v_ok FROM station
     WHERE (station_id = 90001 AND mli = 'T01A' AND has_fish = 1 AND supported = 1)
        OR (station_id = 90002 AND mli = 'T01B' AND has_fish = 0 AND supported = 1 AND state IS NULL);
    SELECT IF(v_n = 2 AND v_ok = 2, 'TEST 1 PASS: mirror creates stations with has_fish and supported',
                                    'TEST 1 FAIL: mirror did not create the two stations') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: a re-mirror updates identity but never the ingest-owned `supported`
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL sp_station_mirror('[{"sid":90001,"mli":"T02","id":"a0000000-0000-0000-0000-000000000001","country":"CA",
        "lat":1,"lon":2,"locName":"old","supported":1}]', v_n);
    UPDATE station SET supported = 0 WHERE station_id = 90001;
    CALL sp_station_mirror('[{"sid":90001,"mli":"T02","id":"a0000000-0000-0000-0000-000000000001","country":"CA",
        "lat":1,"lon":2,"locName":"new","supported":1,"hasFish":1}]', v_n);
    SELECT COUNT(*) INTO v_ok FROM station WHERE station_id = 90001 AND loc_name = 'new' AND supported = 0 AND has_fish = 1;
    SELECT IF(v_ok = 1, 'TEST 2 PASS: re-mirror updates identity, keeps supported',
                        'TEST 2 FAIL: re-mirror lost supported or kept old identity') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: CA save stores readings, -999 discharge becomes NULL, same time overwrites
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_n INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T03', 'CA', 1);
    CALL sp_water_save_ca('T03', '[{"s":"2026-11-24 10:00:00","e":1.5,"d":20.5},{"s":"2026-11-24T10:05:00","e":1.6,"d":-999}]');
    CALL sp_water_save_ca('T03', '[{"s":"2026-11-24 10:00:00","e":1.7,"d":21}]');
    SELECT COUNT(*) INTO v_n FROM water_reading WHERE station_id = 90001;
    SELECT COUNT(*) INTO v_ok FROM water_reading
     WHERE (station_id = 90001 AND ts = '2026-11-24 10:00:00' AND elevation = 1.7 AND discharge = 21)
        OR (station_id = 90001 AND ts = '2026-11-24 10:05:00' AND elevation = 1.6 AND discharge IS NULL);
    SELECT IF(v_n = 2 AND v_ok = 2, 'TEST 3 PASS: CA save upserts by time, -999 stored as NULL',
                                    'TEST 3 FAIL: CA readings not upserted or -999 kept') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: station_current takes the newest reading; a partial reading keeps the missing values
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T04', 'CA', 1);
    CALL sp_water_save_ca('T04', '[{"s":"2026-11-24 10:00:00","e":1.5,"d":20.5}]');
    CALL sp_water_save_ca('T04', '[{"s":"2026-11-24 11:00:00","e":1.9,"d":-999}]');
    SELECT COUNT(*) INTO v_ok FROM station_current c JOIN station s ON s.station_id = c.station_id
     WHERE c.station_id = 90001 AND c.ts = '2026-11-24 11:00:00' AND c.elevation = 1.9 AND c.discharge = 20.5
       AND s.upd_data = '2026-11-24 11:00:00';
    SELECT IF(v_ok = 1, 'TEST 4 PASS: partial reading moves ts, keeps the old discharge',
                        'TEST 4 FAIL: partial reading did not merge into station_current') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: an empty reading never moves station_current.ts forward
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05 //
CREATE PROCEDURE test_05()
BEGIN
    DECLARE v_ts DATETIME;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 5 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T05', 'CA', 1);
    CALL sp_water_save_ca('T05', '[{"s":"2026-11-24 10:00:00","e":1.5,"d":20.5}]');
    CALL sp_water_save_ca('T05', '[{"s":"2026-11-24 12:00:00","e":null,"d":-999}]');
    SELECT ts INTO v_ts FROM station_current WHERE station_id = 90001;
    SELECT IF(v_ts = '2026-11-24 10:00:00', 'TEST 5 PASS: an empty reading leaves station_current.ts',
                                            'TEST 5 FAIL: an empty reading moved station_current.ts') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: a late batch of older readings never moves station_current back in time
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06 //
CREATE PROCEDURE test_06()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 6 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T06', 'CA', 1);
    CALL sp_water_save_ca('T06', '[{"s":"2026-11-24 10:00:00","e":1.5,"d":20.5}]');
    CALL sp_water_save_ca('T06', '[{"s":"2026-11-23 10:00:00","e":9.9,"d":99}]');
    SELECT COUNT(*) INTO v_ok FROM station_current
     WHERE station_id = 90001 AND ts = '2026-11-24 10:00:00' AND elevation = 1.5 AND discharge = 20.5;
    SELECT IF(v_ok = 1, 'TEST 6 PASS: older readings leave station_current unchanged',
                        'TEST 6 FAIL: an older batch moved station_current back') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: US save converts to metric: ft3/s -> m3/s, ft -> m, mph -> km/h, inches -> mm
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07 //
CREATE PROCEDURE test_07()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 7 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T07', 'US', 1);
    CALL sp_water_save_us('T07', 'WI', '[
        {"name":"Streamflow","unit":"ft^3/s","points":[{"d":"2026-11-23","v":100}]},
        {"name":"Gage height","unit":"ft","points":[{"d":"2026-11-23","v":10}]},
        {"name":"Wind speed","unit":"mph","points":[{"d":"2026-11-23","v":10}]},
        {"name":"Precipitation","unit":"total, in","points":[{"d":"2026-11-23","v":1}]}]');
    SELECT COUNT(*) INTO v_ok FROM water_reading
     WHERE station_id = 90002 AND ts = '2026-11-23 00:00:00'
       AND ABS(discharge - 2.8316846592) < 1e-9 AND ABS(elevation - 3.048) < 1e-9
       AND ABS(wind - 16.09344) < 1e-9 AND ABS(precipitation - 25.4) < 1e-9;
    SELECT IF(v_ok = 1, 'TEST 7 PASS: US flow, level, wind, rain stored metric in one row',
                        'TEST 7 FAIL: US units not converted to metric') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: US pressure is stored in mm Hg: mmHg as is, kPa x 7.50062, hPa x 0.750062
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08 //
CREATE PROCEDURE test_08()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 8 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T08', 'US', 1);
    CALL sp_water_save_us('T08', 'WI', '[
        {"name":"Barometric pressure","unit":"mmHg","points":[{"d":"2026-11-21","v":755.34}]},
        {"name":"Barometric pressure","unit":"uncorrected, kPa","points":[{"d":"2026-11-22","v":101.3}]},
        {"name":"Barometric pressure","unit":"hPa","points":[{"d":"2026-11-23","v":1013}]}]');
    SELECT COUNT(*) INTO v_ok FROM water_reading
     WHERE station_id = 90002 AND ((ts = '2026-11-21' AND pressure_mm = 755.3)
        OR (ts = '2026-11-22' AND pressure_mm = 759.8) OR (ts = '2026-11-23' AND pressure_mm = 759.8));
    SELECT IF(v_ok = 3, 'TEST 8 PASS: US pressure stored in mm Hg from mmHg, kPa and hPa',
                        'TEST 8 FAIL: US pressure not converted to mm Hg') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: US pH is the real value (WaterData truncated 7.62 to 7, CurrentWaterState showed 0.7)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09 //
CREATE PROCEDURE test_09()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 9 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T09', 'US', 1);
    CALL sp_water_save_us('T09', 'WI', '[{"name":"pH","unit":"water, unfiltered, field, standard units",
        "points":[{"d":"2026-11-23","v":7.62}]}]');
    SELECT COUNT(*) INTO v_ok FROM water_reading r JOIN station_current c ON c.station_id = r.station_id
     WHERE r.station_id = 90002 AND r.ph = 7.62 AND c.ph = 7.62;
    SELECT IF(v_ok = 1, 'TEST 9 PASS: US pH 7.62 stored as 7.62 in reading and current',
                        'TEST 9 FAIL: US pH not stored as the real value') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: oxygen is taken in mg/L only; the % saturation series is ignored
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10 //
CREATE PROCEDURE test_10()
BEGIN
    DECLARE v_ox DOUBLE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 10 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T10', 'US', 1);
    CALL sp_water_save_us('T10', 'WI', '[
        {"name":"Dissolved oxygen","unit":"water, unfiltered, mg/L","points":[{"d":"2026-11-23","v":9.1}]},
        {"name":"Dissolved oxygen","unit":"water, unfiltered, % saturation","points":[{"d":"2026-11-23","v":98}]}]');
    SELECT oxygen INTO v_ox FROM water_reading WHERE station_id = 90002;
    SELECT IF(v_ox = 9.1, 'TEST 10 PASS: oxygen kept in mg/L, % saturation ignored',
                          'TEST 10 FAIL: oxygen overwritten by % saturation') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 11: a day with only unmapped series is not written (WaterData got an empty row)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_11 //
CREATE PROCEDURE test_11()
BEGIN
    DECLARE v_n INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 11 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T11', 'US', 1);
    CALL sp_water_save_us('T11', 'WI', '[
        {"name":"Specific conductance","unit":"uS/cm","points":[{"d":"2026-11-22","v":500}]},
        {"name":"Temperature","unit":"Water","points":[{"d":"2026-11-22","v":5}]}]');
    SELECT COUNT(*) INTO v_n FROM water_reading WHERE station_id = 90002;
    SELECT IF(v_n = 0, 'TEST 11 PASS: unmapped-only day writes no reading',
                       'TEST 11 FAIL: unmapped series wrote an empty reading') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 12: all series of a new day reach station_current (MSSQL kept only the first one)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_12 //
CREATE PROCEDURE test_12()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 12 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T12', 'US', 1);
    CALL sp_water_save_us('T12', 'WI', '[
        {"name":"Streamflow","unit":"m^3/s","points":[{"d":"2026-11-23","v":5}]},
        {"name":"Dissolved oxygen","unit":"mg/L","points":[{"d":"2026-11-23","v":8.5}]},
        {"name":"Turbidity","unit":"FNU","points":[{"d":"2026-11-23","v":3}]}]');
    SELECT COUNT(*) INTO v_ok FROM station_current
     WHERE station_id = 90002 AND discharge = 5 AND oxygen = 8.5 AND turbidity = 3 AND ts = '2026-11-23';
    SELECT IF(v_ok = 1, 'TEST 12 PASS: flow, oxygen and turbidity all reach station_current',
                        'TEST 12 FAIL: not every series reached station_current') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 13: a later US series keeps the values already stored for that day
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_13 //
CREATE PROCEDURE test_13()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 13 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'T13', 'US', 1);
    CALL sp_water_save_us('T13', 'WI', '[{"name":"Streamflow","unit":"m^3/s","points":[{"d":"2026-11-23","v":5}]}]');
    CALL sp_water_save_us('T13', 'WI', '[{"name":"Turbidity","unit":"FNU","points":[{"d":"2026-11-23","v":3}]}]');
    SELECT COUNT(*) INTO v_ok FROM water_reading WHERE station_id = 90002 AND discharge = 5 AND turbidity = 3;
    SELECT IF(v_ok = 1, 'TEST 13 PASS: a later series merges, earlier values stay',
                        'TEST 13 FAIL: a later series erased stored values') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 14: an unknown station mli is an error (SQLSTATE 45000), nothing is written
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_14 //
CREATE PROCEDURE test_14()
BEGIN
    DECLARE v_err INT DEFAULT 0;
    DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_err = v_err + 1;
    START TRANSACTION;
    CALL sp_water_save_ca('T14-NOPE', '[{"s":"2026-11-24 10:00:00","e":1,"d":1}]');
    CALL sp_water_save_us('T14-NOPE', 'WI', '[]');
    SELECT IF(v_err = 2, 'TEST 14 PASS: unknown mli raises 45000 in both save procedures',
                         'TEST 14 FAIL: unknown mli was not rejected') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 15: 503 back-off: 3 consecutive days -> weekly and unsupported; same day twice counts once
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_15 //
CREATE PROCEDURE test_15()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 15 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T15', 'CA', 1);
    CALL sp_station_503_record('ec', 'CA', 'T15', 'ON', '2026-11-20');
    CALL sp_station_503_record('ec', 'CA', 'T15', 'ON', '2026-11-20');
    CALL sp_station_503_record('ec', 'CA', 'T15', 'ON', '2026-11-21');
    SELECT COUNT(*) INTO v_ok FROM station WHERE station_id = 90001 AND backoff_state = 1 AND backoff_daily_503_count = 2;
    CALL sp_station_503_record('ec', 'CA', 'T15', 'ON', '2026-11-22');
    SELECT v_ok + COUNT(*) INTO v_ok FROM station
     WHERE station_id = 90001 AND backoff_state = 2 AND supported = 0 AND backoff_next_date = '2026-11-29';
    SELECT IF(v_ok = 2, 'TEST 15 PASS: 3 daily 503s -> weekly, unsupported, same day once',
                        'TEST 15 FAIL: daily 503 back-off rules broken') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 16: 503 back-off: 4 weekly 503s -> monthly; refresh_due re-enables; reset clears
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_16 //
CREATE PROCEDURE test_16()
BEGIN
    DECLARE v_ok INT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 16 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T16', 'CA', 1);
    UPDATE station SET backoff_state = 2, supported = 0, backoff_weekly_503_count = 3,
                       backoff_last_503_date = '2026-11-01' WHERE station_id = 90001;
    CALL sp_station_503_record('ec', 'CA', 'T16', 'ON', '2026-11-08');
    SELECT COUNT(*) INTO v_ok FROM station WHERE station_id = 90001 AND backoff_state = 3 AND backoff_next_date = '2026-12-08';
    CALL sp_station_503_refresh_due('2026-12-08');
    SELECT v_ok + COUNT(*) INTO v_ok FROM station WHERE station_id = 90001 AND backoff_state = 0 AND supported = 1;
    UPDATE station SET backoff_state = 1, backoff_daily_503_count = 2 WHERE station_id = 90001;
    CALL sp_station_503_reset('ec', 'CA', 'T16');
    SELECT v_ok + COUNT(*) INTO v_ok FROM station
     WHERE station_id = 90001 AND backoff_state = 0 AND backoff_daily_503_count = 0 AND processed IS NOT NULL;
    SELECT IF(v_ok = 3, 'TEST 16 PASS: weekly -> monthly, refresh_due and reset restore',
                        'TEST 16 FAIL: weekly/monthly 503 rules broken') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 17: v_station_water_due lists supported stations only, with the current reading time
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_17 //
CREATE PROCEDURE test_17()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 17 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T17A', 'CA', 1);
    CALL t_station(90002, 'T17B', 'CA', 1);
    UPDATE station SET supported = 0 WHERE station_id = 90002;
    CALL sp_water_save_ca('T17A', '[{"s":"2026-11-24 10:00:00","e":1,"d":1}]');
    SELECT COUNT(*) INTO v_ok FROM v_station_water_due
     WHERE mli IN ('T17A', 'T17B') AND (mli = 'T17A' AND stamp = '2026-11-24 10:00:00' AND tz = 0);
    SELECT IF(v_ok = 1 AND NOT EXISTS (SELECT 1 FROM v_station_water_due WHERE mli = 'T17B'),
              'TEST 17 PASS: water due view lists supported stations with stamp',
              'TEST 17 FAIL: water due view wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 18: job_run: a recorded cycle is pending until handed over
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_18 //
CREATE PROCEDURE test_18()
BEGIN
    DECLARE v_id BIGINT;
    DECLARE v_n INT;
    DECLARE v_before INT;
    DECLARE v_after INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 18 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL sp_job_run_record('waterservice', 'water-ca', '2026-11-24 10:00:00', NULL, 'ok', 12, NULL, v_id);
    SELECT COUNT(*) INTO v_before FROM v_job_run_pending WHERE job_run_id = v_id AND items = 12;
    CALL sp_job_run_handed_over(v_id, v_n);
    SELECT COUNT(*) INTO v_after FROM v_job_run_pending WHERE job_run_id = v_id;
    SELECT IF(v_before = 1 AND v_after = 0 AND v_n >= 1, 'TEST 18 PASS: job_run pending until handed over',
                                                        'TEST 18 FAIL: job_run hand-over broken') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 19: v_station_state carries sid, mli and the current reading
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_19 //
CREATE PROCEDURE test_19()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 19 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'T19', 'CA', 1);
    CALL sp_water_save_ca('T19', '[{"s":"2026-11-24 10:00:00","e":1.25,"d":7}]');
    SELECT COUNT(*) INTO v_ok FROM v_station_state WHERE sid = 90001 AND mli = 'T19' AND discharge = 7 AND elevation = 1.25;
    SELECT IF(v_ok = 1, 'TEST 19 PASS: v_station_state shows the current reading',
                        'TEST 19 FAIL: v_station_state wrong') AS message;
    ROLLBACK;
END //

DELIMITER ;

CALL test_01();
CALL test_02();
CALL test_03();
CALL test_04();
CALL test_05();
CALL test_06();
CALL test_07();
CALL test_08();
CALL test_09();
CALL test_10();
CALL test_11();
CALL test_12();
CALL test_13();
CALL test_14();
CALL test_15();
CALL test_16();
CALL test_17();
CALL test_18();
CALL test_19();

DROP PROCEDURE IF EXISTS test_01;
DROP PROCEDURE IF EXISTS test_02;
DROP PROCEDURE IF EXISTS test_03;
DROP PROCEDURE IF EXISTS test_04;
DROP PROCEDURE IF EXISTS test_05;
DROP PROCEDURE IF EXISTS test_06;
DROP PROCEDURE IF EXISTS test_07;
DROP PROCEDURE IF EXISTS test_08;
DROP PROCEDURE IF EXISTS test_09;
DROP PROCEDURE IF EXISTS test_10;
DROP PROCEDURE IF EXISTS test_11;
DROP PROCEDURE IF EXISTS test_12;
DROP PROCEDURE IF EXISTS test_13;
DROP PROCEDURE IF EXISTS test_14;
DROP PROCEDURE IF EXISTS test_15;
DROP PROCEDURE IF EXISTS test_16;
DROP PROCEDURE IF EXISTS test_17;
DROP PROCEDURE IF EXISTS test_18;
DROP PROCEDURE IF EXISTS test_19;
DROP PROCEDURE IF EXISTS t_station;
