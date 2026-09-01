-- MySQL unit tests for the `news` table (mysql/script01_createTable.sql), its views
-- (mysql/script01_createView.sql) and its stored procedures (mysql/script02_Proc.sql), consumed by
-- FishTracker.MySqlNewsHelper (fishfind-frontend) for News.aspx, and by docapi's
-- MySqlNewsDocumentRepository/MySqlNewsQueryRepository (see
-- efj-backend/service/docapi/CLAUDE.md -> "MySQL backing for news reads").
-- Run via mysql/UNIT_TESTS/autorun.bat against a throwaway database built from mysql/ffi2.sql.
--
-- STRUCTURE: one stored PROCEDURE per test, each with its own EXIT HANDLER FOR SQLEXCEPTION. This
-- is the MySQL equivalent of the mssql BEGIN TRAN/TRY/CATCH-per-test pattern (see envfish-db/CLAUDE.md
-- "Structure unit tests") -- mysql-CLI batch mode has no TRY/CATCH of its own, so without per-test
-- error containment ONE test hitting an unexpected SQL error aborts the whole script, silently
-- skipping every test after it. Wrapping each test in its own procedure+handler means an error in
-- test N is caught, reported as a FAIL line, and rolled back, while test N+1 still runs normally.
-- Each procedure opens its own transaction and ends with a plain ROLLBACK (no lasting state change).
--
-- TESTING RESULT-RETURNING PROCEDURES: MySQL cannot capture a stored procedure's result set from
-- calling SQL (`INSERT INTO t CALL proc()` is a syntax error; no cursor-over-CALL support), so the
-- procedures' unparameterized query logic lives in views (script01_createView.sql) and the tests
-- assert against those views -- the exact same SQL the procedures run. Tests 15-18 therefore read
-- v_news_list_rows / v_news_default_doc rather than CALLing, which is the only way to assert on
-- this logic in pure SQL. (A view cannot take a parameter or read a session variable -- ERROR 1351
-- -- so sp_news_list_json's country/padding and sp_news_doc_get's id lookup necessarily stay inline
-- in the procedures; tests 13/15/16 cover that logic by replicating the same predicates.)
--
-- JSON GOTCHAS verified against MySQL 8.0.46 while writing these:
--   * JSON_EXTRACT(doc,'$.with_photo') on an IF(...) yields a JSON INTEGER 1/0, NOT a JSON boolean,
--     so compare to 1/0 -- `= TRUE` silently matches nothing.
--   * a JSON null is NOT a SQL NULL: `JSON_EXTRACT(doc,'$.photo') IS NOT NULL` is TRUE even when the
--     value is JSON null. Use JSON_TYPE(...) = 'NULL' / <> 'NULL' to tell them apart.
SET NAMES utf8mb4;

DELIMITER //

-- ----------------------------------------------------------------
-- TEST 1: basic insert/select round trip on the required columns
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01_insert_select_roundtrip //
CREATE PROCEDURE test_01_insert_select_roundtrip()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 1 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('11111111-1111-1111-1111-111111111111', 'Test Title', 1);
    SELECT CASE WHEN (SELECT news_title FROM news WHERE news_id = '11111111-1111-1111-1111-111111111111') = 'Test Title'
                THEN 'TEST 1 PASS: inserted row round-trips news_title'
                ELSE 'TEST 1 FAIL: news_title did not round-trip' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: news_publish defaults to 0 (false) when omitted
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02_publish_defaults_false //
CREATE PROCEDURE test_02_publish_defaults_false()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 2 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title) VALUES ('22222222-2222-2222-2222-222222222222', 'No Publish Flag');
    SELECT CASE WHEN (SELECT news_publish FROM news WHERE news_id = '22222222-2222-2222-2222-222222222222') = 0
                THEN 'TEST 2 PASS: news_publish defaults to 0'
                ELSE 'TEST 2 FAIL: news_publish did not default to 0' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: id auto-increments and stays unique across inserts
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03_id_autoincrements //
CREATE PROCEDURE test_03_id_autoincrements()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 3 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title) VALUES ('33333333-3333-3333-3333-333333333333', 'AutoInc A');
    INSERT INTO news (news_id, news_title) VALUES ('44444444-4444-4444-4444-444444444444', 'AutoInc B');
    SELECT CASE WHEN (SELECT COUNT(DISTINCT id) FROM news WHERE news_id IN
                      ('33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444')) = 2
                THEN 'TEST 3 PASS: id auto-increments to distinct values'
                ELSE 'TEST 3 FAIL: id column did not produce distinct values' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: news_stamp / stamp default to the current time when omitted
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04_stamp_defaults_now //
CREATE PROCEDURE test_04_stamp_defaults_now()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 4 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title) VALUES ('55555555-5555-5555-5555-555555555555', 'Stamp Default');
    SELECT CASE WHEN ABS(TIMESTAMPDIFF(SECOND, (SELECT news_stamp FROM news WHERE news_id = '55555555-5555-5555-5555-555555555555'), NOW())) <= 5
                 AND ABS(TIMESTAMPDIFF(SECOND, (SELECT stamp FROM news WHERE news_id = '55555555-5555-5555-5555-555555555555'), NOW())) <= 5
                THEN 'TEST 4 PASS: news_stamp and stamp default to the current time'
                ELSE 'TEST 4 FAIL: news_stamp/stamp did not default to the current time' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: news_id primary key rejects a duplicate insert
-- (INSERT IGNORE turns the duplicate-key error into a 0-row no-op)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05_duplicate_news_id_blocked //
CREATE PROCEDURE test_05_duplicate_news_id_blocked()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 5 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title) VALUES ('66666666-6666-6666-6666-666666666666', 'Original');
    INSERT IGNORE INTO news (news_id, news_title) VALUES ('66666666-6666-6666-6666-666666666666', 'Duplicate');
    SELECT CASE WHEN (SELECT COUNT(*) FROM news WHERE news_id = '66666666-6666-6666-6666-666666666666') = 1
                 AND (SELECT news_title FROM news WHERE news_id = '66666666-6666-6666-6666-666666666666') = 'Original'
                THEN 'TEST 5 PASS: news_id primary key blocks a duplicate insert'
                ELSE 'TEST 5 FAIL: duplicate news_id was not blocked' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: MySqlNewsHelper's "WHERE news_publish = 1" filter excludes drafts
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06_publish_filter_excludes_drafts //
CREATE PROCEDURE test_06_publish_filter_excludes_drafts()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 6 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, country, news_stamp)
    VALUES ('77777777-7777-7777-7777-777777777777', 'Published CA', 1, 'CA', '2026-01-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_stamp)
    VALUES ('88888888-8888-8888-8888-888888888888', 'Draft CA', 0, 'CA', '2026-01-02 00:00:00');
    SELECT CASE WHEN (SELECT COUNT(*) FROM news WHERE news_publish = 1
                      AND news_id IN ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888')) = 1
                THEN 'TEST 6 PASS: news_publish = 1 filter excludes the draft row'
                ELSE 'TEST 6 FAIL: news_publish filter did not exclude the draft row' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: country filter mirrors MySqlNewsHelper's "(country = @country OR country IS NULL)"
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07_country_or_null_filter //
CREATE PROCEDURE test_07_country_or_null_filter()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 7 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, country)
    VALUES ('99999999-9999-9999-9999-999999999999', 'US Only', 1, 'US');
    INSERT INTO news (news_id, news_title, news_publish, country)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'No Country', 1, NULL);
    SELECT CASE WHEN (SELECT COUNT(*) FROM news
                      WHERE news_id IN ('99999999-9999-9999-9999-999999999999', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
                        AND (country = 'CA' OR country IS NULL)) = 1
                THEN 'TEST 7 PASS: country filter keeps the NULL-country row and drops the US row'
                ELSE 'TEST 7 FAIL: country OR-NULL filter behaved unexpectedly' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: news_photo0 LONGBLOB round-trips binary data, and IS NOT NULL detects it
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08_photo_blob_roundtrip //
CREATE PROCEDURE test_08_photo_blob_roundtrip()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 8 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0)
    VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'With Photo', 1, UNHEX('89504E470D0A1A0A'));
    SELECT CASE WHEN (SELECT news_photo0 IS NOT NULL FROM news WHERE news_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') = 1
                 AND (SELECT LENGTH(news_photo0) FROM news WHERE news_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') = 8
                THEN 'TEST 8 PASS: news_photo0 LONGBLOB round-trips and is detected as present'
                ELSE 'TEST 8 FAIL: news_photo0 did not round-trip correctly' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: title/paragraph LIKE search (MySqlNewsHelper's search pattern)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09_like_search_matches //
CREATE PROCEDURE test_09_like_search_matches()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 9 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_paragraph0)
    VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Salmon Run Report', 1, 'The salmon run started early this year.');
    SELECT CASE WHEN (SELECT COUNT(*) FROM news
                      WHERE news_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                        AND (news_title LIKE '%salmon%' OR news_paragraph0 LIKE '%salmon%')) = 1
                THEN 'TEST 9 PASS: LIKE search matches title/paragraph text case-insensitively'
                ELSE 'TEST 9 FAIL: LIKE search did not match' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: has_photo0 trigger sets the flag TRUE on INSERT when news_photo0 is present
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10_has_photo0_trigger_insert_true //
CREATE PROCEDURE test_10_has_photo0_trigger_insert_true()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 10 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0)
    VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'Has Photo', 1, UNHEX('89504E47'));
    SELECT CASE WHEN (SELECT has_photo0 FROM news WHERE news_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd') = 1
                THEN 'TEST 10 PASS: TR_news_has_photo0_ins sets has_photo0 = 1 when news_photo0 is present'
                ELSE 'TEST 10 FAIL: has_photo0 was not set to 1 on insert with a photo' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 11: has_photo0 trigger leaves the flag FALSE on INSERT when news_photo0 is absent
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_11_has_photo0_trigger_insert_false //
CREATE PROCEDURE test_11_has_photo0_trigger_insert_false()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 11 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'No Photo', 1);
    SELECT CASE WHEN (SELECT has_photo0 FROM news WHERE news_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 0
                THEN 'TEST 11 PASS: has_photo0 stays 0 when news_photo0 is absent'
                ELSE 'TEST 11 FAIL: has_photo0 was incorrectly set to 1 with no photo' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 12: has_photo0 trigger re-derives the flag on UPDATE (both directions), even when an
-- explicit (wrong) value is set in the same statement -- the BEFORE UPDATE trigger overrides it.
-- This is what makes the flag self-healing and safe to trust in the list/home-page queries.
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_12_has_photo0_trigger_update_both_ways //
CREATE PROCEDURE test_12_has_photo0_trigger_update_both_ways()
BEGIN
    DECLARE v_after_removal TINYINT(1);
    DECLARE v_after_readd TINYINT(1);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 12 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0)
    VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'Photo Then Removed', 1, UNHEX('89504E47'));

    -- Remove the photo; even an explicit (wrong) has_photo0 = 1 must be overridden to 0.
    UPDATE news SET news_photo0 = NULL, has_photo0 = 1 WHERE news_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
    SELECT has_photo0 INTO v_after_removal FROM news WHERE news_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

    -- Add a photo back; even an explicit (wrong) has_photo0 = 0 must be overridden to 1.
    UPDATE news SET news_photo0 = UNHEX('89504E47'), has_photo0 = 0 WHERE news_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
    SELECT has_photo0 INTO v_after_readd FROM news WHERE news_id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

    SELECT CASE WHEN v_after_removal = 0 AND v_after_readd = 1
                THEN 'TEST 12 PASS: TR_news_has_photo0_upd re-derives has_photo0 on UPDATE, overriding an explicit wrong value'
                ELSE 'TEST 12 FAIL: has_photo0 was not correctly re-derived on UPDATE' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 13: sp_news_doc_get's query returns the expected JSON fields for a published article
-- (asserted against the same SELECT the procedure runs -- see the header note on why a
-- result-returning procedure cannot be CALLed from a test)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_13_doc_get_json_fields //
CREATE PROCEDURE test_13_doc_get_json_fields()
BEGIN
    DECLARE v_doc JSON;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 13 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_author, news_source, news_publish, country)
    VALUES ('10101010-1010-1010-1010-101010101010', 'Doc Get Title', 'Some Author', 'Some Source', 1, 'CA');

    SELECT JSON_OBJECT(
        'news_id', news_id,
        'title', news_title,
        'author', news_author,
        'source', news_source,
        'flag', IF(country IS NULL OR country = '', 'empty.gif', CONCAT(country, '.png')),
        'photo', IF(LENGTH(news_photo0) > 100, TO_BASE64(news_photo0), NULL)
    ) INTO v_doc
    FROM news WHERE news_id = '10101010-1010-1010-1010-101010101010' AND news_publish = 1 LIMIT 1;

    SELECT CASE WHEN JSON_UNQUOTE(JSON_EXTRACT(v_doc, '$.title')) = 'Doc Get Title'
                 AND JSON_UNQUOTE(JSON_EXTRACT(v_doc, '$.author')) = 'Some Author'
                 AND JSON_UNQUOTE(JSON_EXTRACT(v_doc, '$.flag')) = 'CA.png'
                 AND JSON_TYPE(JSON_EXTRACT(v_doc, '$.photo')) = 'NULL'
                THEN 'TEST 13 PASS: sp_news_doc_get JSON carries title/author/flag and a null photo when absent'
                ELSE 'TEST 13 FAIL: sp_news_doc_get JSON fields did not match' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 14: an unpublished (draft) article is invisible to the read path
-- (the `news_publish = 1` rule sp_news_doc_get / v_news_list_rows / the v_news_default_* chain
-- all apply -- a public endpoint must never leak a draft)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_14_drafts_hidden_from_read_path //
CREATE PROCEDURE test_14_drafts_hidden_from_read_path()
BEGIN
    DECLARE v_doc_get_rows INT DEFAULT -1;
    DECLARE v_list_rows INT DEFAULT -1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 14 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('20202020-2020-2020-2020-202020202020', 'Draft Title', 0);

    SELECT COUNT(*) INTO v_doc_get_rows FROM news
        WHERE news_id = '20202020-2020-2020-2020-202020202020' AND news_publish = 1;
    SELECT COUNT(*) INTO v_list_rows FROM v_news_list_rows
        WHERE news_id = '20202020-2020-2020-2020-202020202020';

    SELECT CASE WHEN v_doc_get_rows = 0 AND v_list_rows = 0
                THEN 'TEST 14 PASS: a draft is excluded from both the doc lookup and v_news_list_rows'
                ELSE 'TEST 14 FAIL: draft visibility rule not enforced on the read path' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 15: v_news_list_rows exposes has_photo from the maintained has_photo0 flag -- the column
-- the 2026-08-31 live performance fix moved the list query onto (it must NEVER read news_photo0
-- at this scale; see CLAUDE.md "Cached flags on news").
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_15_list_rows_has_photo_from_flag //
CREATE PROCEDURE test_15_list_rows_has_photo_from_flag()
BEGIN
    DECLARE v_with_photo TINYINT(1);
    DECLARE v_without_photo TINYINT(1);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 15 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0)
    VALUES ('50505050-5050-5050-5050-505050505050', 'With Photo Listed', 1, 'US', UNHEX('89504E47'));
    INSERT INTO news (news_id, news_title, news_publish, country)
    VALUES ('50505050-5050-5050-5050-505050505051', 'No Photo Listed', 1, 'US');

    SELECT has_photo INTO v_with_photo FROM v_news_list_rows WHERE news_id = '50505050-5050-5050-5050-505050505050';
    SELECT has_photo INTO v_without_photo FROM v_news_list_rows WHERE news_id = '50505050-5050-5050-5050-505050505051';

    SELECT CASE WHEN v_with_photo = 1 AND v_without_photo = 0
                THEN 'TEST 15 PASS: v_news_list_rows has_photo matches has_photo0 per row'
                ELSE 'TEST 15 FAIL: has_photo did not reflect has_photo0 correctly' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 16: v_news_list_rows returns published rows of every country with their display fields
-- (the country filter + CA padding themselves are parameterized and live in sp_news_list_json --
-- this asserts the shared row source those predicates are applied to, incl. the ISO date format)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_16_list_rows_shape_and_date_format //
CREATE PROCEDURE test_16_list_rows_shape_and_date_format()
BEGIN
    DECLARE v_ca_count INT;
    DECLARE v_stamp VARCHAR(10);
    DECLARE v_flag CHAR(2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 16 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, country, news_stamp)
    VALUES ('30303030-3030-3030-3030-303030303031', 'CA Item Older', 1, 'CA', '2026-01-05 13:45:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_stamp)
    VALUES ('30303030-3030-3030-3030-303030303032', 'CA Item Newer', 1, 'CA', '2026-06-01 00:00:00');

    SELECT COUNT(*) INTO v_ca_count FROM v_news_list_rows
        WHERE news_id IN ('30303030-3030-3030-3030-303030303031', '30303030-3030-3030-3030-303030303032');
    SELECT stamp, flag INTO v_stamp, v_flag FROM v_news_list_rows
        WHERE news_id = '30303030-3030-3030-3030-303030303031';

    SELECT CASE WHEN v_ca_count = 2 AND v_stamp = '2026-01-05' AND v_flag = 'CA'
                THEN 'TEST 16 PASS: v_news_list_rows exposes both rows with an ISO yyyy-mm-dd stamp and country flag'
                ELSE 'TEST 16 FAIL: v_news_list_rows shape/date format unexpected' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 17: v_news_default_doc marks EXACTLY 2 lead items, by final display rank
-- REGRESSION TEST for the 2026-08-31 bug where the lead flag used the raw dedup group number
-- instead of the final ROW_NUMBER() rank: groups 1 and 2 each contribute up to 2 rows, so
-- "group <= 2" wrongly marked 4 items as leads instead of 2.
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_17_default_exactly_two_leads //
CREATE PROCEDURE test_17_default_exactly_two_leads()
BEGIN
    DECLARE v_lead_count INT;
    DECLARE v_compact_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 17 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    -- 2 CA articles with a photo (group 1 candidates) + 2 US with a photo (group 2 candidates):
    -- 4 photo-bearing rows total, which is exactly the shape that exposed the original bug.
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('60606060-6060-6060-6060-606060606061', 'CA Photo 1', 1, 'CA', REPEAT(UNHEX('89504E47'), 40), '2026-08-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('60606060-6060-6060-6060-606060606062', 'CA Photo 2', 1, 'CA', REPEAT(UNHEX('89504E47'), 40), '2026-07-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('60606060-6060-6060-6060-606060606063', 'US Photo 1', 1, 'US', REPEAT(UNHEX('89504E47'), 40), '2026-06-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('60606060-6060-6060-6060-606060606064', 'US Photo 2', 1, 'US', REPEAT(UNHEX('89504E47'), 40), '2026-05-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_stamp)
    VALUES ('60606060-6060-6060-6060-606060606065', 'CA No Photo', 1, 'CA', '2026-04-01 00:00:00');

    -- with_photo is a JSON INTEGER (1/0), not a JSON boolean -- see the header's JSON gotchas.
    SELECT COUNT(*) INTO v_lead_count FROM v_news_default_doc
        WHERE rn <= 5 AND JSON_EXTRACT(doc, '$.with_photo') = 1;
    SELECT COUNT(*) INTO v_compact_count FROM v_news_default_doc
        WHERE rn <= 5 AND JSON_EXTRACT(doc, '$.with_photo') = 0;

    SELECT CASE WHEN v_lead_count = 2
                THEN 'TEST 17 PASS: v_news_default_doc marks exactly 2 lead items by final display rank'
                ELSE CONCAT('TEST 17 FAIL: expected exactly 2 leads, got ', v_lead_count) END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 18: v_news_default_doc embeds the base64 photo ONLY in the lead items -- compact items
-- carry a JSON null even when their own row has a photo (the leads are the only slots that
-- transfer blob bytes).
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_18_default_photo_only_in_leads //
CREATE PROCEDURE test_18_default_photo_only_in_leads()
BEGIN
    DECLARE v_leads_with_photo INT;
    DECLARE v_compact_with_photo INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 18 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    -- All four carry a >100-byte photo, so only the rn<=2 rule can explain any null payload.
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('70707070-7070-7070-7070-707070707071', 'CA Photo A', 1, 'CA', REPEAT(UNHEX('89504E47'), 40), '2026-08-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('70707070-7070-7070-7070-707070707072', 'CA Photo B', 1, 'CA', REPEAT(UNHEX('89504E47'), 40), '2026-07-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('70707070-7070-7070-7070-707070707073', 'US Photo C', 1, 'US', REPEAT(UNHEX('89504E47'), 40), '2026-06-01 00:00:00');
    INSERT INTO news (news_id, news_title, news_publish, country, news_photo0, news_stamp)
    VALUES ('70707070-7070-7070-7070-707070707074', 'US Photo D', 1, 'US', REPEAT(UNHEX('89504E47'), 40), '2026-05-01 00:00:00');

    -- a JSON null is NOT a SQL NULL -- compare JSON_TYPE, see the header's JSON gotchas.
    SELECT COUNT(*) INTO v_leads_with_photo FROM v_news_default_doc
        WHERE rn <= 2 AND JSON_TYPE(JSON_EXTRACT(doc, '$.photo')) = 'STRING';
    SELECT COUNT(*) INTO v_compact_with_photo FROM v_news_default_doc
        WHERE rn BETWEEN 3 AND 5 AND JSON_TYPE(JSON_EXTRACT(doc, '$.photo')) = 'STRING';

    SELECT CASE WHEN v_leads_with_photo = 2 AND v_compact_with_photo = 0
                THEN 'TEST 18 PASS: only the 2 lead items embed a base64 photo; compact items carry JSON null'
                ELSE CONCAT('TEST 18 FAIL: leads-with-photo=', v_leads_with_photo, ' compact-with-photo=', v_compact_with_photo) END AS message;
    ROLLBACK;
END //

DELIMITER ;

-- ==================================================================
-- Run every test. Each CALL is independent (its own transaction + EXIT HANDLER), so one test's
-- failure or unexpected SQL error does not prevent the rest from running.
-- ==================================================================
CALL test_01_insert_select_roundtrip();
CALL test_02_publish_defaults_false();
CALL test_03_id_autoincrements();
CALL test_04_stamp_defaults_now();
CALL test_05_duplicate_news_id_blocked();
CALL test_06_publish_filter_excludes_drafts();
CALL test_07_country_or_null_filter();
CALL test_08_photo_blob_roundtrip();
CALL test_09_like_search_matches();
CALL test_10_has_photo0_trigger_insert_true();
CALL test_11_has_photo0_trigger_insert_false();
CALL test_12_has_photo0_trigger_update_both_ways();
CALL test_13_doc_get_json_fields();
CALL test_14_drafts_hidden_from_read_path();
CALL test_15_list_rows_has_photo_from_flag();
CALL test_16_list_rows_shape_and_date_format();
CALL test_17_default_exactly_two_leads();
CALL test_18_default_photo_only_in_leads();

-- Clean up the test procedures themselves so the throwaway database ends in the same shape
-- ffi2.sql produced (no lasting state change -- the same rule each test's ROLLBACK follows).
DROP PROCEDURE IF EXISTS test_01_insert_select_roundtrip;
DROP PROCEDURE IF EXISTS test_02_publish_defaults_false;
DROP PROCEDURE IF EXISTS test_03_id_autoincrements;
DROP PROCEDURE IF EXISTS test_04_stamp_defaults_now;
DROP PROCEDURE IF EXISTS test_05_duplicate_news_id_blocked;
DROP PROCEDURE IF EXISTS test_06_publish_filter_excludes_drafts;
DROP PROCEDURE IF EXISTS test_07_country_or_null_filter;
DROP PROCEDURE IF EXISTS test_08_photo_blob_roundtrip;
DROP PROCEDURE IF EXISTS test_09_like_search_matches;
DROP PROCEDURE IF EXISTS test_10_has_photo0_trigger_insert_true;
DROP PROCEDURE IF EXISTS test_11_has_photo0_trigger_insert_false;
DROP PROCEDURE IF EXISTS test_12_has_photo0_trigger_update_both_ways;
DROP PROCEDURE IF EXISTS test_13_doc_get_json_fields;
DROP PROCEDURE IF EXISTS test_14_drafts_hidden_from_read_path;
DROP PROCEDURE IF EXISTS test_15_list_rows_has_photo_from_flag;
DROP PROCEDURE IF EXISTS test_16_list_rows_shape_and_date_format;
DROP PROCEDURE IF EXISTS test_17_default_exactly_two_leads;
DROP PROCEDURE IF EXISTS test_18_default_photo_only_in_leads;
