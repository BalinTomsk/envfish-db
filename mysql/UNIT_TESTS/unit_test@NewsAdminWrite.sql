-- MySQL unit tests for the news-admin WRITE procedures added to mysql/script02_Proc.sql
-- (sp_news_admin_draft_create, sp_news_admin_publish, sp_news_admin_photo_update), which back
-- docapi's MySqlNewsAdminCommandRepository ("jdbc" profile) and, through it,
-- fishfind-frontend's Editor/AddNews.aspx admin authoring page -- see
-- fishfind-frontend/Editor/CLAUDE.md for the 2026-09-14 session that moved that page off SQL
-- Server's dbo.news. Run via mysql/UNIT_TESTS/autorun.bat against a throwaway database built
-- from mysql/ffi2.sql. NOT YET RUN against a live MySQL server as of writing (the workstation
-- cannot reach Winhost and no local MySQL 8 container was reachable this session -- see
-- envfish-db/CLAUDE.md "The workstation cannot reach the Winhost MySQL" for the standard
-- workaround); review carefully before trusting a green run blindly.
--
-- STRUCTURE: one stored PROCEDURE per test, each with its own EXIT HANDLER FOR SQLEXCEPTION and
-- its own transaction, rolled back at the end -- see envfish-db/CLAUDE.md "Structure MySQL unit
-- tests" and unit_test@NewsMySQL.sql for the pattern this mirrors.
--
-- WHY THESE TESTS CHECK TABLE STATE, NOT THE PROCEDURES' OWN RESULT SETS: MySQL cannot capture a
-- stored procedure's result set from calling SQL (no INSERT INTO t CALL proc(), no cursor-over-
-- CALL), so a test cannot assign `CALL sp_news_admin_publish(...)`'s SELECT output to a variable.
-- Every test here instead calls the procedure and then asserts on the `news` row it left behind,
-- which is what the caller (docapi) ultimately cares about anyway.
SET NAMES utf8mb4;

DELIMITER //

-- ----------------------------------------------------------------
-- TEST 1: sp_news_admin_draft_create purges unpublished drafts and creates one fresh row
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01_draft_create_purges_and_inserts //
CREATE PROCEDURE test_01_draft_create_purges_and_inserts()
BEGIN
    DECLARE v_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;
    DECLARE v_stale_gone INT;
    DECLARE v_new_row INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 1 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a1000000-0000-0000-0000-000000000001', 'Stale Draft', 0);

    CALL sp_news_admin_draft_create(v_id);

    SELECT COUNT(*) INTO v_stale_gone FROM news WHERE news_id = 'a1000000-0000-0000-0000-000000000001';
    SELECT COUNT(*) INTO v_new_row FROM news
     WHERE news_id = v_id AND news_title = 'title' AND news_author = 'Vantus' AND news_publish = 0;

    SELECT CASE WHEN v_id IS NOT NULL AND CHAR_LENGTH(v_id) = 36 AND v_stale_gone = 0 AND v_new_row = 1
                THEN 'TEST 1 PASS: stale draft purged, fresh placeholder draft created'
                ELSE 'TEST 1 FAIL: draft not created, or the stale draft not purged' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: sp_news_admin_draft_create never purges a published article
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02_draft_create_keeps_published //
CREATE PROCEDURE test_02_draft_create_keeps_published()
BEGIN
    DECLARE v_id CHAR(36);
    DECLARE v_still_there INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 2 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a1000000-0000-0000-0000-000000000002', 'Published Article', 1);

    CALL sp_news_admin_draft_create(v_id);

    SELECT COUNT(*) INTO v_still_there FROM news WHERE news_id = 'a1000000-0000-0000-0000-000000000002';

    SELECT CASE WHEN v_still_there = 1
                THEN 'TEST 2 PASS: a published article survives the draft purge'
                ELSE 'TEST 2 FAIL: a published article was deleted' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: sp_news_admin_publish inserts a full new row (upsert INSERT path)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03_publish_inserts_new_row //
CREATE PROCEDURE test_03_publish_inserts_new_row()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 3 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_publish(
        'a3000000-0000-0000-0000-000000000003', 'A Fisherman''s Tale', 'Some Author', 'Some Source',
        'https://source.example/a', 'https://author.example/a', '2026-01-02 03:04:05.000000',
        'https://video.example/a', 'Body zero.', 'Body one.', 'Body two.', 'CA',
        'b0000000-0000-0000-0000-00000000000b',
        'f1000000-0000-0000-0000-0000000000f1', NULL, NULL
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a3000000-0000-0000-0000-000000000003'
       AND news_title = 'A Fisherman''s Tale' AND news_author = 'Some Author' AND news_publish = 1
       AND country = 'CA' AND lake_id = 'b0000000-0000-0000-0000-00000000000b'
       AND fish1_id = 'f1000000-0000-0000-0000-0000000000f1' AND fish2_id IS NULL AND fish3_id IS NULL
       AND news_paragraph0 = 'Body zero.' AND news_paragraph2 = 'Body two.';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 3 PASS: a fresh news_id is inserted with every field'
                ELSE 'TEST 3 FAIL: inserted row did not match the supplied fields' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: sp_news_admin_publish updates an existing row in place (upsert UPDATE path)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04_publish_updates_existing_row //
CREATE PROCEDURE test_04_publish_updates_existing_row()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 4 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_author, news_publish)
    VALUES ('a4000000-0000-0000-0000-000000000004', 'title', 'Vantus', 0);

    CALL sp_news_admin_publish(
        'a4000000-0000-0000-0000-000000000004', 'Real Title', 'Real Author', NULL, NULL, NULL,
        '2026-02-03 04:05:06.000000', NULL, 'Real body.', NULL, NULL, 'US', NULL, NULL, NULL, NULL
    );

    SELECT COUNT(*) INTO v_count FROM news WHERE news_id = 'a4000000-0000-0000-0000-000000000004';
    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a4000000-0000-0000-0000-000000000004'
       AND news_title = 'Real Title' AND news_author = 'Real Author' AND news_publish = 1
       AND country = 'US' AND news_paragraph0 = 'Real body.';

    SELECT CASE WHEN v_count = 1 AND v_ok = 1
                THEN 'TEST 4 PASS: an existing draft is updated in place, not duplicated'
                ELSE 'TEST 4 FAIL: draft not updated in place, or the row count changed' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: sp_news_admin_publish called twice with byte-identical values does not error and
-- does not duplicate the row -- the MySQL "ROW_COUNT() counts CHANGED rows, not matched rows"
-- trap the procedure's own comment warns about.
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05_publish_idempotent_resubmit //
CREATE PROCEDURE test_05_publish_idempotent_resubmit()
BEGIN
    DECLARE v_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 5 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_publish(
        'a5000000-0000-0000-0000-000000000005', 'Same Title', 'Same Author', NULL, NULL, NULL,
        '2026-03-04 05:06:07.000000', NULL, 'Same body.', NULL, NULL, 'CA', NULL, NULL, NULL, NULL
    );
    CALL sp_news_admin_publish(
        'a5000000-0000-0000-0000-000000000005', 'Same Title', 'Same Author', NULL, NULL, NULL,
        '2026-03-04 05:06:07.000000', NULL, 'Same body.', NULL, NULL, 'CA', NULL, NULL, NULL, NULL
    );

    SELECT COUNT(*) INTO v_count FROM news WHERE news_id = 'a5000000-0000-0000-0000-000000000005';

    SELECT CASE WHEN v_count = 1
                THEN 'TEST 5 PASS: an identical resubmit neither errors nor duplicates the row'
                ELSE 'TEST 5 FAIL: a resubmit did not leave exactly one row' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: sp_news_admin_photo_update writes bytes + author + alt onto slot 0
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06_photo_update_writes_slot0 //
CREATE PROCEDURE test_06_photo_update_writes_slot0()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 6 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a6000000-0000-0000-0000-000000000006', 'title', 0);

    CALL sp_news_admin_photo_update(
        'a6000000-0000-0000-0000-000000000006', 0, 0x89504E47, 'Photo Author', 'Photo Alt'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a6000000-0000-0000-0000-000000000006'
       AND news_photo0 = 0x89504E47 AND news_photo_author0 = 'Photo Author' AND news_photo_alt0 = 'Photo Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 6 PASS: slot 0 photo bytes/author/alt are all written'
                ELSE 'TEST 6 FAIL: slot 0 columns did not match' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: sp_news_admin_photo_update with NULL author/alt leaves the existing values alone
-- (COALESCE), while still replacing the photo bytes
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07_photo_update_null_author_alt_preserved //
CREATE PROCEDURE test_07_photo_update_null_author_alt_preserved()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 7 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo1, news_photo_author1, news_photo_alt1)
    VALUES ('a7000000-0000-0000-0000-000000000007', 'title', 0, 0x00, 'Original Author', 'Original Alt');

    CALL sp_news_admin_photo_update(
        'a7000000-0000-0000-0000-000000000007', 1, 0x11223344, NULL, NULL
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a7000000-0000-0000-0000-000000000007'
       AND news_photo1 = 0x11223344 AND news_photo_author1 = 'Original Author' AND news_photo_alt1 = 'Original Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 7 PASS: NULL author/alt keep stored values, bytes still update'
                ELSE 'TEST 7 FAIL: author/alt were overwritten, or bytes were not updated' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: sp_news_admin_photo_update on an unknown news_id changes nothing and inserts no
-- phantom row
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08_photo_update_unknown_id_is_noop //
CREATE PROCEDURE test_08_photo_update_unknown_id_is_noop()
BEGIN
    DECLARE v_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 8 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_photo_update(
        'a8000000-0000-0000-0000-000000000008', 0, 0x89504E47, 'X', 'Y'
    );

    SELECT COUNT(*) INTO v_count FROM news WHERE news_id = 'a8000000-0000-0000-0000-000000000008';

    SELECT CASE WHEN v_count = 0
                THEN 'TEST 8 PASS: an unknown news_id is a clean no-op, no row is created'
                ELSE 'TEST 8 FAIL: a phantom row was created for an unknown news_id' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: sp_news_admin_photo_update with an out-of-range index touches no column on an
-- otherwise-existing row
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09_photo_update_bad_index_noop //
CREATE PROCEDURE test_09_photo_update_bad_index_noop()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 9 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0)
    VALUES ('a9000000-0000-0000-0000-000000000009', 'title', 0, 0xAABBCC);

    CALL sp_news_admin_photo_update(
        'a9000000-0000-0000-0000-000000000009', 3, 0x99887766, 'Should Not Apply', 'Should Not Apply'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a9000000-0000-0000-0000-000000000009'
       AND news_photo0 = 0xAABBCC AND news_photo_author0 IS NULL;

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 9 PASS: an out-of-range index leaves every photo column untouched'
                ELSE 'TEST 9 FAIL: a column changed despite an invalid slot index' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: slots 0/1/2 are independent -- writing slot 1 never touches slot 0 or slot 2
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10_photo_update_slots_independent //
CREATE PROCEDURE test_10_photo_update_slots_independent()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 10 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0, news_photo2)
    VALUES ('a1000000-0000-0000-0000-000000000010', 'title', 0, 0x01, 0x02);

    CALL sp_news_admin_photo_update(
        'a1000000-0000-0000-0000-000000000010', 1, 0x03, 'Slot1 Author', 'Slot1 Alt'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a1000000-0000-0000-0000-000000000010'
       AND news_photo0 = 0x01 AND news_photo1 = 0x03 AND news_photo2 = 0x02
       AND news_photo_author1 = 'Slot1 Author' AND news_photo_alt1 = 'Slot1 Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 10 PASS: writing slot 1 leaves slot 0 and slot 2 untouched'
                ELSE 'TEST 10 FAIL: a write to slot 1 leaked into another slot' END AS message;
    ROLLBACK;
END //

-- ================================================================================================
-- sp_news_doc_insert / sp_news_doc_update (docapi 1.16.0, 2026-09-18) -- the MySQL replacements
-- for SQL Server's dbo.sp_news_doc_add / dbo.sp_news_import / dbo.sp_news_doc_update behind
-- POST /api/v1/news, POST /news/import and PUT /api/v1/news/{id}. sp_news_doc_insert generates its
-- own id, which a test cannot capture from calling SQL (see the header), so the insert tests find
-- their row by a title unique to that test instead.
-- ================================================================================================

-- ----------------------------------------------------------------
-- TEST 11: sp_news_doc_insert creates one PUBLISHED row carrying every supplied field
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_11_doc_insert_creates_published_row //
CREATE PROCEDURE test_11_doc_insert_creates_published_row()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 11 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_doc_insert(
        'T11 Insert Title', 'Some Author', 'https://author.example/11', 'Some Source',
        'https://source.example/11', 'https://video.example/11', 'Body zero.', 'Body one.', NULL,
        'US', '2026-03-04 05:06:07.000000', 'b0000000-0000-0000-0000-00000000000b',
        'f1000000-0000-0000-0000-0000000000f1', 'f2000000-0000-0000-0000-0000000000f2', NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_title = 'T11 Insert Title' AND news_publish = 1
       AND news_author = 'Some Author' AND news_author_link = 'https://author.example/11'
       AND news_source = 'Some Source' AND news_source_link = 'https://source.example/11'
       AND news_video_link = 'https://video.example/11'
       AND news_paragraph0 = 'Body zero.' AND news_paragraph1 = 'Body one.' AND news_paragraph2 IS NULL
       AND country = 'US' AND news_stamp = '2026-03-04 05:06:07.000000'
       AND lake_id = 'b0000000-0000-0000-0000-00000000000b'
       AND fish1_id = 'f1000000-0000-0000-0000-0000000000f1'
       AND fish2_id = 'f2000000-0000-0000-0000-0000000000f2' AND fish3_id IS NULL
       AND news_photo0 IS NULL AND has_photo0 = 0
       AND CHAR_LENGTH(news_id) = 36;

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 11 PASS: sp_news_doc_insert writes one published row, every field'
                ELSE 'TEST 11 FAIL: sp_news_doc_insert row did not match the supplied fields' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 12: a NULL stamp means "now", and all three photo slots are stored (import's shape)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_12_doc_insert_default_stamp_and_three_photos //
CREATE PROCEDURE test_12_doc_insert_default_stamp_and_three_photos()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 12 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_doc_insert(
        'T12 Three Photos', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL,
        UNHEX('FFD8FF00'), 'Author Zero', 'Alt zero',
        UNHEX('89504E47'), 'Author One', 'Alt one',
        UNHEX('47494638'), NULL, 'Alt two'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_title = 'T12 Three Photos' AND news_publish = 1
       AND news_stamp BETWEEN NOW(6) - INTERVAL 1 MINUTE AND NOW(6) + INTERVAL 1 MINUTE
       AND news_photo0 = UNHEX('FFD8FF00') AND news_photo_author0 = 'Author Zero' AND news_photo_alt0 = 'Alt zero'
       AND news_photo1 = UNHEX('89504E47') AND news_photo_author1 = 'Author One' AND news_photo_alt1 = 'Alt one'
       AND news_photo2 = UNHEX('47494638') AND news_photo_author2 IS NULL AND news_photo_alt2 = 'Alt two'
       -- the trigger, not the procedure, keeps the cached flag honest
       AND has_photo0 = 1;

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 12 PASS: NULL stamp is now, 3 photo slots stored, has_photo0 set'
                ELSE 'TEST 12 FAIL: default stamp or photo slots did not match' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 13: a blank title is refused with SQLSTATE 45000 and writes nothing
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_13_doc_insert_blank_title_refused //
CREATE PROCEDURE test_13_doc_insert_blank_title_refused()
BEGIN
    DECLARE v_before INT;
    DECLARE v_after INT;
    DECLARE v_signalled INT DEFAULT 0;
    -- Anything OTHER than the expected 45000 (e.g. 1305, the procedure missing entirely) must still
    -- report FAIL and let the remaining tests run -- the inner CONTINUE HANDLER is more specific, so
    -- it still wins for 45000. Without this, a missing procedure aborted the whole file here.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
        SELECT 'TEST 13 FAIL: unexpected SQL error (not the expected SQLSTATE 45000)' AS message;

    SELECT COUNT(*) INTO v_before FROM news;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_signalled = 1;
        CALL sp_news_doc_insert(
            '   ', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        );
    END;
    SELECT COUNT(*) INTO v_after FROM news;

    SELECT CASE WHEN v_signalled = 1 AND v_after = v_before
                THEN 'TEST 13 PASS: a blank title is refused with SQLSTATE 45000, no row'
                ELSE 'TEST 13 FAIL: a blank title was not refused with SQLSTATE 45000' END AS message;
END //

-- ----------------------------------------------------------------
-- TEST 14: sp_news_doc_update is a FULL replace of the text fields -- a NULL clears the column --
-- and never touches the publish flag (a draft stays a draft)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_14_doc_update_full_replace_keeps_publish //
CREATE PROCEDURE test_14_doc_update_full_replace_keeps_publish()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 14 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_author, news_source, news_paragraph1, country,
                      lake_id, fish1_id, news_publish)
    VALUES ('a1400000-0000-0000-0000-000000000014', 'Old Title', 'Old Author', 'Old Source',
            'Old body one.', 'CA', 'b0000000-0000-0000-0000-00000000000b',
            'f1000000-0000-0000-0000-0000000000f1', 0);

    CALL sp_news_doc_update(
        'a1400000-0000-0000-0000-000000000014', 'New Title', 'New Author', NULL, NULL, NULL, NULL,
        'New body zero.', NULL, NULL, 'US', NULL, NULL, 'f3000000-0000-0000-0000-0000000000f3', NULL, NULL,
        NULL, NULL, NULL
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a1400000-0000-0000-0000-000000000014'
       AND news_title = 'New Title' AND news_author = 'New Author'
       AND news_source IS NULL                -- absent from the PUT -> cleared, as SQL Server did
       AND news_paragraph0 = 'New body zero.'
       AND news_paragraph1 IS NULL            -- ditto
       AND country = 'US' AND lake_id IS NULL
       AND fish1_id = 'f3000000-0000-0000-0000-0000000000f3'
       AND news_publish = 0;                  -- still a draft

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 14 PASS: update replaces text fields, NULL clears, publish kept'
                ELSE 'TEST 14 FAIL: full-replace semantics or publish flag did not hold' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 15: a NULL stamp keeps the stored stamp, a NULL photo0 keeps the stored bytes, and the slot-0
-- author/alt are set directly (NULL clears them) -- the three exceptions dbo.sp_news_doc_update had
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_15_doc_update_keeps_stamp_and_photo //
CREATE PROCEDURE test_15_doc_update_keeps_stamp_and_photo()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 15 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_stamp, news_publish,
                      news_photo0, news_photo_author0, news_photo_alt0,
                      news_photo1, news_photo_author1)
    VALUES ('a1500000-0000-0000-0000-000000000015', 'Keep Me', '2025-12-25 10:00:00.000000', 1,
            UNHEX('FFD8FFAA'), 'Old Credit', 'Old Alt', UNHEX('89504E47'), 'Slot One Author');

    CALL sp_news_doc_update(
        'a1500000-0000-0000-0000-000000000015', 'Keep Me Edited', NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, 'New Alt'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a1500000-0000-0000-0000-000000000015'
       AND news_title = 'Keep Me Edited'
       AND news_stamp = '2025-12-25 10:00:00.000000'   -- NULL stamp: kept
       AND news_photo0 = UNHEX('FFD8FFAA')             -- NULL photo0: kept
       AND has_photo0 = 1
       AND news_photo_author0 IS NULL                  -- set directly: cleared
       AND news_photo_alt0 = 'New Alt'                 -- set directly
       AND news_photo1 = UNHEX('89504E47')             -- slot 1 untouched
       AND news_photo_author1 = 'Slot One Author';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 15 PASS: NULL stamp/photo0 kept, slot-0 metadata set, slot 1 kept'
                ELSE 'TEST 15 FAIL: stamp/photo keep-rules or slot-0 metadata did not hold' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 16: a new photo0 replaces the bytes, and has_photo0 follows via the trigger
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_16_doc_update_replaces_photo0 //
CREATE PROCEDURE test_16_doc_update_replaces_photo0()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 16 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a1600000-0000-0000-0000-000000000016', 'No Photo Yet', 1);

    CALL sp_news_doc_update(
        'a1600000-0000-0000-0000-000000000016', 'Now With Photo', NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        UNHEX('FFD8FFBB'), 'Credit', 'Alt'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a1600000-0000-0000-0000-000000000016'
       AND news_photo0 = UNHEX('FFD8FFBB') AND has_photo0 = 1
       AND news_photo_author0 = 'Credit' AND news_photo_alt0 = 'Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 16 PASS: a supplied photo0 replaces the bytes and has_photo0 follows'
                ELSE 'TEST 16 FAIL: photo0 was not replaced or has_photo0 did not follow' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 17: updating an unknown id writes nothing -- it must NOT upsert the way sp_news_admin_publish
-- does, or a PUT to a mistyped id would silently create an article
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_17_doc_update_unknown_id_is_noop //
CREATE PROCEDURE test_17_doc_update_unknown_id_is_noop()
BEGIN
    DECLARE v_before INT;
    DECLARE v_after INT;
    DECLARE v_row INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 17 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    SELECT COUNT(*) INTO v_before FROM news;
    CALL sp_news_doc_update(
        'a1700000-0000-0000-0000-000000000017', 'Ghost', NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    );
    SELECT COUNT(*) INTO v_after FROM news;
    SELECT COUNT(*) INTO v_row FROM news WHERE news_id = 'a1700000-0000-0000-0000-000000000017';

    SELECT CASE WHEN v_after = v_before AND v_row = 0
                THEN 'TEST 17 PASS: an unknown id is a no-op (no upsert)'
                ELSE 'TEST 17 FAIL: updating an unknown id created or changed a row' END AS message;
    ROLLBACK;
END //

DELIMITER ;

-- ==================================================================
-- Run every test. Each CALL is independent (its own transaction + EXIT HANDLER), so one test's
-- failure or unexpected SQL error does not prevent the rest from running.
-- ==================================================================
CALL test_01_draft_create_purges_and_inserts();
CALL test_02_draft_create_keeps_published();
CALL test_03_publish_inserts_new_row();
CALL test_04_publish_updates_existing_row();
CALL test_05_publish_idempotent_resubmit();
CALL test_06_photo_update_writes_slot0();
CALL test_07_photo_update_null_author_alt_preserved();
CALL test_08_photo_update_unknown_id_is_noop();
CALL test_09_photo_update_bad_index_noop();
CALL test_10_photo_update_slots_independent();
CALL test_11_doc_insert_creates_published_row();
CALL test_12_doc_insert_default_stamp_and_three_photos();
CALL test_13_doc_insert_blank_title_refused();
CALL test_14_doc_update_full_replace_keeps_publish();
CALL test_15_doc_update_keeps_stamp_and_photo();
CALL test_16_doc_update_replaces_photo0();
CALL test_17_doc_update_unknown_id_is_noop();

-- Clean up the test procedures themselves so the throwaway database ends in the same shape
-- ffi2.sql produced (no lasting state change -- the same rule each test's ROLLBACK follows).
DROP PROCEDURE IF EXISTS test_01_draft_create_purges_and_inserts;
DROP PROCEDURE IF EXISTS test_02_draft_create_keeps_published;
DROP PROCEDURE IF EXISTS test_03_publish_inserts_new_row;
DROP PROCEDURE IF EXISTS test_04_publish_updates_existing_row;
DROP PROCEDURE IF EXISTS test_05_publish_idempotent_resubmit;
DROP PROCEDURE IF EXISTS test_06_photo_update_writes_slot0;
DROP PROCEDURE IF EXISTS test_07_photo_update_null_author_alt_preserved;
DROP PROCEDURE IF EXISTS test_08_photo_update_unknown_id_is_noop;
DROP PROCEDURE IF EXISTS test_09_photo_update_bad_index_noop;
DROP PROCEDURE IF EXISTS test_10_photo_update_slots_independent;
DROP PROCEDURE IF EXISTS test_11_doc_insert_creates_published_row;
DROP PROCEDURE IF EXISTS test_12_doc_insert_default_stamp_and_three_photos;
DROP PROCEDURE IF EXISTS test_13_doc_insert_blank_title_refused;
DROP PROCEDURE IF EXISTS test_14_doc_update_full_replace_keeps_publish;
DROP PROCEDURE IF EXISTS test_15_doc_update_keeps_stamp_and_photo;
DROP PROCEDURE IF EXISTS test_16_doc_update_replaces_photo0;
DROP PROCEDURE IF EXISTS test_17_doc_update_unknown_id_is_noop;
