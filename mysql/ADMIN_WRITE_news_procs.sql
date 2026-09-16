-- ============================================================================================
-- PRODUCTION SETUP -- run this in the Winhost MySQL control panel (phpMyAdmin / DB manager)
-- Database: mysql_111487_envfish
--
-- WHY THIS FILE EXISTS
-- --------------------
-- Editor/AddNews.aspx (fishfind-frontend) is being migrated off SQL Server's dbo.news, which is
-- being dropped, onto this MySQL news table -- see fishfind-frontend/Editor/CLAUDE.md for the
-- 2026-09-14 session. That needs three new stored procedures (sp_news_admin_draft_create,
-- sp_news_admin_publish, sp_news_admin_photo_update), defined in mysql/script02_Proc.sql.
--
-- THIS FILE CANNOT BE RUN AS `portos` -- SAME BLOCKER AS FIX_missing_v_news_default_doc.sql
-- -------------------------------------------------------------------------------------------
-- The application's MySQL account (`portos`) holds:
--     SELECT, DELETE, DROP, REFERENCES, INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW,
--     ALTER ROUTINE, TRIGGER
-- No INSERT, no UPDATE, no CREATE ROUTINE. Attempting `CREATE PROCEDURE` as portos fails with
-- the same ERROR 1142 the view fix hit, from any host -- see that file for the confirmed detail.
-- `portos` is the only MySQL credential stored anywhere in this codebase (frontend
-- secrets.config, efj-backend/secret/mysql.cred, docapi's own env), so this genuinely cannot be
-- applied from the app side or from this workstation.
--
-- WHAT ACTUALLY UNBLOCKS THIS -- one of:
--   1. Run this file from the Winhost control panel's own DB tool, which appears to connect as
--      the database owner rather than as `portos` (the existing sp_news_doc_get / sp_news_list_json
--      / sp_news_default procedures already live there, created the same way).
--   2. Ask Winhost support to grant `portos` CREATE ROUTINE (and, if you want the app account
--      itself able to write `news` directly rather than only through a definer-rights routine,
--      INSERT and UPDATE too) on `mysql_111487_envfish`.
--
-- AFTER RUNNING THIS FILE
-- -----------------------
-- `portos` already holds a blanket EXECUTE grant on this schema (see above), and a MySQL stored
-- routine runs under its DEFINER's privileges by default -- so as soon as these three procedures
-- exist (created by whichever account ran this script), `portos` can CALL them successfully even
-- though it has no INSERT/UPDATE of its own. No further grant should be needed. Verify with:
--     CALL sp_news_admin_draft_create(@id); SELECT @id;                        -- expect a new UUID,
--                                                                               -- and a matching
--                                                                               -- unpublished row
--     SELECT news_id, news_title, news_publish FROM news WHERE news_id = @id;  -- news_publish = 0
--     DELETE FROM news WHERE news_id = @id;                                    -- clean up the probe row
--
-- This definition is copied verbatim from mysql/script02_Proc.sql -- keep them identical, and
-- re-run this file (it is idempotent, DROP+CREATE) if that source ever changes.
-- ============================================================================================

DELIMITER //

DROP PROCEDURE IF EXISTS sp_news_admin_draft_create //
CREATE PROCEDURE sp_news_admin_draft_create(
    OUT p_news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    DELETE FROM news WHERE news_publish <> 1;

    SET p_news_id = UUID();

    INSERT INTO news (news_id, news_title, news_author, news_publish, news_stamp)
    VALUES (p_news_id, 'title', 'Lepsik', 0, NOW(6));
END //

DROP PROCEDURE IF EXISTS sp_news_admin_publish //
CREATE PROCEDURE sp_news_admin_publish(
    IN p_news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_title VARCHAR(128) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_author VARCHAR(500) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_source VARCHAR(255) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_source_link VARCHAR(1024) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_author_link VARCHAR(1024) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_stamp DATETIME(6),
    IN p_video_link VARCHAR(255) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_paragraph0 LONGTEXT CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_paragraph1 LONGTEXT CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_paragraph2 LONGTEXT CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_country CHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_lake_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_fish1_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_fish2_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_fish3_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    DECLARE v_exists INT DEFAULT 0;

    SELECT COUNT(*) INTO v_exists FROM news WHERE news_id = p_news_id;

    IF v_exists = 1 THEN
        UPDATE news SET
            news_title = p_title,
            news_author = p_author,
            news_source = p_source,
            news_source_link = p_source_link,
            news_author_link = p_author_link,
            news_stamp = p_stamp,
            news_publish = 1,
            news_video_link = p_video_link,
            news_paragraph0 = p_paragraph0,
            news_paragraph1 = p_paragraph1,
            news_paragraph2 = p_paragraph2,
            country = p_country,
            lake_id = p_lake_id,
            fish1_id = p_fish1_id,
            fish2_id = p_fish2_id,
            fish3_id = p_fish3_id
        WHERE news_id = p_news_id;

        SELECT p_news_id AS news_id, 'updated' AS action;
    ELSE
        INSERT INTO news (
            news_id, news_title, news_author, news_source, news_source_link, news_author_link,
            news_stamp, news_publish, news_video_link, news_paragraph0, news_paragraph1,
            news_paragraph2, country, lake_id, fish1_id, fish2_id, fish3_id
        ) VALUES (
            p_news_id, p_title, p_author, p_source, p_source_link, p_author_link,
            p_stamp, 1, p_video_link, p_paragraph0, p_paragraph1,
            p_paragraph2, p_country, p_lake_id, p_fish1_id, p_fish2_id, p_fish3_id
        );

        SELECT p_news_id AS news_id, 'inserted' AS action;
    END IF;
END //

DROP PROCEDURE IF EXISTS sp_news_admin_photo_update //
CREATE PROCEDURE sp_news_admin_photo_update(
    IN p_news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_index TINYINT,
    IN p_photo LONGBLOB,
    IN p_author VARCHAR(64) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_alt VARCHAR(128) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    DECLARE v_exists INT DEFAULT 0;

    SELECT COUNT(*) INTO v_exists FROM news WHERE news_id = p_news_id;

    IF v_exists = 1 AND p_index = 0 THEN
        UPDATE news SET
            news_photo0 = p_photo,
            news_photo_author0 = COALESCE(p_author, news_photo_author0),
            news_photo_alt0 = COALESCE(p_alt, news_photo_alt0)
        WHERE news_id = p_news_id;
    ELSEIF v_exists = 1 AND p_index = 1 THEN
        UPDATE news SET
            news_photo1 = p_photo,
            news_photo_author1 = COALESCE(p_author, news_photo_author1),
            news_photo_alt1 = COALESCE(p_alt, news_photo_alt1)
        WHERE news_id = p_news_id;
    ELSEIF v_exists = 1 AND p_index = 2 THEN
        UPDATE news SET
            news_photo2 = p_photo,
            news_photo_author2 = COALESCE(p_author, news_photo_author2),
            news_photo_alt2 = COALESCE(p_alt, news_photo_alt2)
        WHERE news_id = p_news_id;
    END IF;

    SELECT v_exists AS found, (v_exists = 1 AND p_index BETWEEN 0 AND 2) AS updated;
END //

DELIMITER ;
