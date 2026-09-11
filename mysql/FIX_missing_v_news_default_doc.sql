-- ============================================================================================
-- PRODUCTION FIX — run this in the Winhost MySQL control panel (phpMyAdmin / DB manager)
-- Database: mysql_111487_envfish
--
-- WHY THIS FILE EXISTS
-- --------------------
-- `v_news_default_doc` is defined in script01_createView.sql but was NEVER CREATED in the live
-- Winhost database. Only its dependencies made it there:
--     v_news_default_grp1..grp5, v_news_default_ranked, v_news_default_top, v_news_list_rows
--
-- `sp_news_default()` is just:  SELECT doc FROM v_news_default_doc ORDER BY rn LIMIT 5;
-- so with the view absent it failed with:
--     java.sql.SQLSyntaxErrorException: Table 'mysql_111487_envfish.v_news_default_doc' doesn't exist
--
-- That took down all THREE home-page reads at once, because docapi serves them from one shared
-- assembly:  GET /api/v1/news/default, /news/featured, /news/more  -> 500 in production.
-- (/news/list was unaffected — it uses v_news_list_rows, which does exist. That asymmetry is what
-- proved it was a missing object rather than a MySQL connectivity problem.)
--
-- ⚠ THIS FILE CANNOT BE RUN AS `portos` — CONFIRMED TWICE, FROM TWO DIFFERENT HOSTS
-- ---------------------------------------------------------------------------------
-- The application's MySQL account (`portos`) holds:
--     SELECT, DELETE, DROP, REFERENCES, INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW,
--     ALTER ROUTINE, TRIGGER
-- It has NO CREATE, CREATE VIEW or CREATE ROUTINE. Attempted and refused:
--     2026-09-09  ERROR 1142  CREATE VIEW command denied to user 'portos'@'<docapi-droplet>'
--     2026-09-09  ERROR 1142  CREATE VIEW command denied to user 'portos'@'<workstation>'
-- Two different source hosts, same refusal — so this is NOT a per-host grant gap that adding an IP
-- would fix. `portos` lacks the privilege outright, and it is the only MySQL credential stored
-- anywhere in this codebase (frontend secrets.config, efj-backend/secret/mysql.cred, and docapi's
-- own env all resolve to it). Running this file as `portos` from anywhere will fail the same way.
--
-- Note the shape of that grant list: DROP and ALTER are present, CREATE is not. `portos` can
-- destroy the sibling views (v_news_default_grp1..5, _ranked, _top, v_news_list_rows) but cannot
-- recreate them. Do not experiment against them.
--
-- WHAT ACTUALLY UNBLOCKS THIS — one of:
--   1. Run this file from the Winhost control panel's own DB tool, IF that tool connects as the
--      database owner rather than as `portos`. (The sibling views exist, so something once had the
--      privilege — most likely this.)
--   2. Ask Winhost support to either:
--         GRANT CREATE VIEW ON `mysql_111487_envfish`.* TO 'portos'@'%';
--      or create the view for you by running the statement at the bottom of this file.
--      Some shared hosts withhold CREATE VIEW deliberately, because a view carries a DEFINER.
--
-- THERE IS NO OUTAGE WAITING ON THIS. docapi 1.8.3 already serves all three endpoints correctly
-- by inlining this view's body (see below). This file is cleanup toward the intended design, not a
-- fix for anything currently broken — it can sit here indefinitely without harm.
--
-- INTERIM WORKAROUND CURRENTLY IN PRODUCTION (docapi 1.8.3)
-- --------------------------------------------------------
-- MySqlNewsQueryRepository.DEFAULT_SQL now inlines this view's body as a query instead of calling
-- sp_news_default(). It depends only on objects that exist, so the endpoints work today.
--
-- AFTER RUNNING THIS FILE
-- -----------------------
-- The intended design is restored and the workaround can be reverted: set
--     static final String DEFAULT_SQL = "CALL sp_news_default()";
-- in MySqlNewsQueryRepository.java, rebuild, redeploy. Verify with:
--     GET /api/v1/news/default   -> 200
-- Verify this file worked, before touching the code:
--     SELECT COUNT(*) FROM information_schema.TABLES
--      WHERE TABLE_SCHEMA='mysql_111487_envfish' AND TABLE_NAME='v_news_default_doc';   -- expect 1
--     CALL sp_news_default();                                                            -- expect 5 rows
--
-- This definition is copied verbatim from mysql/script01_createView.sql — keep them identical.
-- ============================================================================================

DROP VIEW IF EXISTS v_news_default_doc;

CREATE VIEW v_news_default_doc AS
SELECT
    r.rn,
    JSON_OBJECT(
        'news_id', n.news_id,
        'date', DATE_FORMAT(n.news_stamp, '%Y-%m-%d'),
        'country', n.country,
        'flag', IF(n.country IS NULL OR n.country = '', 'empty.gif', CONCAT(n.country, '.png')),
        'title', n.news_title,
        'author', n.news_author,
        'author_link', n.news_author_link,
        'source', n.news_source,
        'source_link', n.news_source_link,
        'credit', n.news_photo_author0,
        'photo_alt', n.news_photo_alt0,
        'paragraph0', n.news_paragraph0,
        'paragraph1', n.news_paragraph1,
        'lake_id', n.lake_id,
        'fish1_id', n.fish1_id,
        'fish2_id', n.fish2_id,
        'fish3_id', n.fish3_id,
        -- The right column renders a one-line teaser, not the whole paragraph: the first line of
        -- news_paragraph0, falling back to news_paragraph1 when paragraph0 is blank. Mirrors
        -- dbo.fn_default_news_json's @with_photo = 0 shape (and _Default.LoadSmallNews, which does
        -- the same split in C#). CR is stripped first so a CRLF article does not leave a trailing
        -- \r on the snippet; a body with no newline at all yields the whole (trimmed) text.
        -- Emitted for EVERY item, not just the right column, because this is one shared shape --
        -- a lead simply ignores it in favour of paragraph0/paragraph1.
        'snippet', TRIM(SUBSTRING_INDEX(
            REPLACE(COALESCE(NULLIF(n.news_paragraph0, ''), n.news_paragraph1, ''), '\r', ''),
            '\n', 1)),
        'photo', IF(r.rn <= 2 AND LENGTH(n.news_photo0) > 100, TO_BASE64(n.news_photo0), NULL),
        'with_photo', IF(r.rn <= 2, TRUE, FALSE)
    ) AS doc
FROM v_news_default_ranked r
JOIN news n ON n.news_id = r.news_id;
